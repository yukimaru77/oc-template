#!/usr/bin/env bash
set -euo pipefail

NAME="${1:-}"
if [[ -z "${NAME}" ]]; then
  echo "usage: oc-delete-project.sh <project-name>" >&2
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
LOCK="${TOK_DIR}/pool.lock"

TOKEN="$(awk -F'\t' -v n="${NAME}" '$2==n{tok=$4} END{print tok}' "${USED}" 2>/dev/null || true)"

exec 9>"${LOCK}"
flock 9

if [[ -n "${TOKEN}" ]]; then
  if ! grep -Fxq "${TOKEN}" "${UNUSED}" 2>/dev/null; then
    printf '%s\n' "${TOKEN}" >> "${UNUSED}"
  fi
fi

awk -F'\t' -v n="${NAME}" '$2!=n' "${USED}" > "${USED}.tmp"
mv "${USED}.tmp" "${USED}"

flock -u 9

if incus info "${NAME}" >/dev/null 2>&1; then
  incus exec "${NAME}" -- bash -lc 'find /workspace -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' || true
  incus delete -f "${NAME}"
fi

sudo /usr/local/sbin/oc-delete-project-root "${NAME}"

echo "deleted: ${NAME}"
