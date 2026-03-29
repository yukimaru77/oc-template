#!/usr/bin/env bash
set -euo pipefail

NAME="${1:-}"
if [[ -z "${NAME}" ]]; then
  echo "usage: oc-new-project.sh <project-name>" >&2
  exit 1
fi

if [[ ! "${NAME}" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]]; then
  echo "project name must match: ^[a-z0-9][a-z0-9-]{1,30}$" >&2
  exit 1
fi

BASE="/srv/openclaw-manager"
TOK_DIR="${BASE}/tokens"
PROJ_DIR="${BASE}/projects/${NAME}"
UNUSED="${TOK_DIR}/unused_tokens.txt"
USED="${TOK_DIR}/used_tokens.tsv"
BROKEN="${TOK_DIR}/broken_tokens.tsv"
USER_ID_FILE="${TOK_DIR}/your_telegram_user_id.txt"
LOCK="${TOK_DIR}/pool.lock"
TEMPLATE_DIR="${BASE}/workspace-template"
CONFIG_TEMPLATE="${BASE}/templates/openclaw.json"

TOKEN=""
BOT_USERNAME=""
FINALIZED=0
BROKEN_MARKED=0

cleanup() {
  rc=$?
  if [[ $rc -ne 0 && $FINALIZED -eq 0 && -n "${TOKEN}" && $BROKEN_MARKED -eq 0 ]]; then
    exec 9>"${LOCK}"
    flock 9
    printf '%s\n' "${TOKEN}" >> "${UNUSED}"
  fi

  if [[ $rc -ne 0 ]]; then
    if incus info "${NAME}" >/dev/null 2>&1; then
      incus delete -f "${NAME}" >/dev/null 2>&1 || true
    fi
  fi

  exit $rc
}
trap cleanup EXIT

if incus info "${NAME}" >/dev/null 2>&1; then
  echo "project already exists: ${NAME}" >&2
  exit 1
fi

mkdir -p "${PROJ_DIR}/workspace" "${PROJ_DIR}/secrets" "${PROJ_DIR}/logs"
chmod 700 "${PROJ_DIR}" "${PROJ_DIR}/secrets"
chmod 755 "${PROJ_DIR}/workspace"

if [[ -d "${TEMPLATE_DIR}" ]]; then
  cp -a "${TEMPLATE_DIR}/." "${PROJ_DIR}/workspace/" 2>/dev/null || true
fi

ADMIN_TG_ID="$(tr -d '\r\n' < "${USER_ID_FILE}")"

exec 9>"${LOCK}"
flock 9
grep -v '^[[:space:]]*$' "${UNUSED}" > "${UNUSED}.clean" || true
mv "${UNUSED}.clean" "${UNUSED}"

if [[ ! -s "${UNUSED}" ]]; then
  echo "unused_tokens.txt is empty" >&2
  exit 1
fi

TOKEN="$(head -n 1 "${UNUSED}" | tr -d '\r')"
tail -n +2 "${UNUSED}" > "${UNUSED}.tmp"
mv "${UNUSED}.tmp" "${UNUSED}"
flock -u 9

BOT_INFO="$(curl -fsS "https://api.telegram.org/bot${TOKEN}/getMe")" || {
  exec 9>"${LOCK}"
  flock 9
  printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "${NAME}" "getMe_failed" "${TOKEN}" >> "${BROKEN}"
  BROKEN_MARKED=1
  echo "token failed getMe; moved to broken_tokens.tsv" >&2
  exit 1
}

BOT_OK="$(printf '%s' "${BOT_INFO}" | jq -r '.ok')"
if [[ "${BOT_OK}" != "true" ]]; then
  exec 9>"${LOCK}"
  flock 9
  printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "${NAME}" "getMe_not_ok" "${TOKEN}" >> "${BROKEN}"
  BROKEN_MARKED=1
  echo "token is not usable; moved to broken_tokens.tsv" >&2
  exit 1
fi

BOT_USERNAME="$(printf '%s' "${BOT_INFO}" | jq -r '.result.username')"

curl -fsS -X POST "https://api.telegram.org/bot${TOKEN}/deleteWebhook" \
  -d "drop_pending_updates=true" >/dev/null || true

curl -fsS -X POST "https://api.telegram.org/bot${TOKEN}/setMyName" \
  -d "name=OpenClaw ${NAME}" >/dev/null || true

printf '%s' "${TOKEN}" > "${PROJ_DIR}/secrets/telegram.token"
chmod 600 "${PROJ_DIR}/secrets/telegram.token"

incus init local:oc-base-img "${NAME}"
incus config set "${NAME}" security.nesting true
incus config set "${NAME}" security.syscalls.intercept.mknod true
incus config set "${NAME}" security.syscalls.intercept.setxattr true
incus config set "${NAME}" nvidia.runtime true
incus config set "${NAME}" boot.autostart true
incus config device add "${NAME}" gpu gpu
incus config device add "${NAME}" workspace disk \
  source="${PROJ_DIR}/workspace" \
  path=/workspace \
  shift=true

incus start "${NAME}"

for i in $(seq 1 30); do
  if incus exec "${NAME}" -- bash -lc 'ps -p 1 -o comm= | grep -qx systemd'; then
    break
  fi
  sleep 1
done

for i in $(seq 1 30); do
  if incus exec "${NAME}" -- bash -lc 'systemctl --system is-system-running >/dev/null 2>&1 || systemctl --system is-system-running | grep -Eq "running|degraded|starting"'; then
    break
  fi
  sleep 1
done

incus file push "${PROJ_DIR}/secrets/telegram.token" "${NAME}/srv/openclaw/telegram.token"
incus exec "${NAME}" -- chmod 600 /srv/openclaw/telegram.token

if [[ -f "${CONFIG_TEMPLATE}" ]]; then
  incus file push "${CONFIG_TEMPLATE}" "${NAME}/tmp/openclaw-template.json"
fi

incus exec "${NAME}" -- bash -lc "
python3 - <<'PY'
import json
from pathlib import Path

def merge(dst, src):
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            merge(dst[k], v)
        else:
            dst[k] = v

p = Path('/srv/openclaw/openclaw.json')
with p.open() as f:
    cfg = json.load(f)

tpl = Path('/tmp/openclaw-template.json')
if tpl.exists():
    with tpl.open() as f:
        override = json.load(f)
    merge(cfg, override)

channels = cfg.setdefault('channels', {})
channels['telegram'] = {
  'enabled': True,
  'tokenFile': '/srv/openclaw/telegram.token',
  'dmPolicy': 'allowlist',
  'allowFrom': [${ADMIN_TG_ID}]
}

with p.open('w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
PY
rm -f /tmp/openclaw-template.json
"

incus exec "${NAME}" -- systemctl restart openclaw

sleep 8

incus exec "${NAME}" -- bash -lc '
source /etc/profile.d/openclaw-env.sh
openclaw gateway status --deep
' >/dev/null

exec 9>"${LOCK}"
flock 9
printf '%s\t%s\t@%s\t%s\n' "$(date -Is)" "${NAME}" "${BOT_USERNAME}" "${TOKEN}" >> "${USED}"
FINALIZED=1

echo "@${BOT_USERNAME}"
