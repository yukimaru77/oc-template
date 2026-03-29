#!/usr/bin/env bash
set -euo pipefail

TOKEN="${1:-}"
if [[ -z "${TOKEN}" ]]; then
  echo "usage: oc-add-token.sh <telegram-bot-token>" >&2
  exit 1
fi

BASE="/srv/openclaw-manager"
TOK_DIR="${BASE}/tokens"
UNUSED="${TOK_DIR}/unused_tokens.txt"
USED="${TOK_DIR}/used_tokens.tsv"
BROKEN="${TOK_DIR}/broken_tokens.tsv"
LOCK="${TOK_DIR}/pool.lock"

BOT_INFO="$(curl -fsS "https://api.telegram.org/bot${TOKEN}/getMe")"
BOT_OK="$(printf '%s' "${BOT_INFO}" | jq -r '.ok')"

if [[ "${BOT_OK}" != "true" ]]; then
  echo "token is not usable" >&2
  exit 1
fi

BOT_USERNAME="$(printf '%s' "${BOT_INFO}" | jq -r '.result.username')"

exec 9>"${LOCK}"
flock 9

if grep -Fxq "${TOKEN}" "${UNUSED}" 2>/dev/null; then
  echo "@${BOT_USERNAME} already exists in unused_tokens.txt"
  exit 0
fi

if awk -F'\t' -v t="${TOKEN}" '$4==t{found=1} END{exit !found}' "${USED}" 2>/dev/null; then
  echo "@${BOT_USERNAME} is already in used_tokens.tsv" >&2
  exit 1
fi

if awk -F'\t' -v t="${TOKEN}" '$4==t{found=1} END{exit !found}' "${BROKEN}" 2>/dev/null; then
  echo "@${BOT_USERNAME} is already in broken_tokens.tsv" >&2
  exit 1
fi

printf '%s\n' "${TOKEN}" >> "${UNUSED}"
flock -u 9

echo "@${BOT_USERNAME}"
