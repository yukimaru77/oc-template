#!/usr/bin/env bash
set -euo pipefail

echo "$(date -Is) searxng-search called: $*" >> /tmp/searxng-search.log

SEARXNG_URL="${SEARXNG_URL:-http://10.65.100.1:18080}"
LIMIT=5
FORMAT="markdown"

usage() {
  cat <<'EOH'
Usage:
  searxng_search.sh [--limit N] [--json] <query>
EOH
}

QUERY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)
      LIMIT="${2:?--limit requires a value}"
      shift 2
      ;;
    --json)
      FORMAT="json"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -n "$QUERY" ]]; then
        QUERY+=" "
      fi
      QUERY+="$1"
      shift
      ;;
  esac
done

if [[ -z "$QUERY" ]]; then
  usage >&2
  exit 2
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

curl -fsS --get \
  --data-urlencode "q=${QUERY}" \
  --data "format=json" \
  --data "language=all" \
  --data "safesearch=0" \
  --data "categories=general" \
  "${SEARXNG_URL%/}/search" > "$TMP"

if [[ "$FORMAT" == "json" ]]; then
  jq --argjson limit "$LIMIT" '
    {
      query: .query,
      results: (
        (.results // [])
        | map({
            title: (.title // ""),
            url: (.url // ""),
            content: (.content // ""),
            engine: (.engine // "")
          })
        | .[:$limit]
      )
    }
  ' "$TMP"
  exit 0
fi

jq -r --argjson limit "$LIMIT" '
  def clean:
    gsub("[\r\n\t]+"; " ")
    | gsub("  +"; " ")
    | sub("^ "; "")
    | sub(" $"; "");

  "Search query: " + (.query // "") + "\n"
  + (
      (.results // [])
      | .[:$limit]
      | to_entries
      | map(
          "## \(.key + 1). \(.value.title // "(no title)" | clean)\n"
          + "- URL: \(.value.url // "")\n"
          + (
              if (.value.content // "") != "" then
                "- Snippet: \(.value.content | clean)\n"
              else
                ""
              end
            )
          + (
              if (.value.engine // "") != "" then
                "- Engine: \(.value.engine)\n"
              else
                ""
              end
            )
        )
      | join("\n")
    )
' "$TMP"
