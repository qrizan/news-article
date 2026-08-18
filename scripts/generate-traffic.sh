#!/usr/bin/env bash
set -euo pipefail

DURATION_SECONDS="${1:-180}"
INTERVAL_SECONDS="${2:-1}"

TARGETS=(
  "https://news.localhost/"
  "https://news.localhost/posts"
  "https://news.localhost/categories"
  "https://admin.localhost/"
  "https://api.localhost/api/public/posts"
  "https://api.localhost/api/public/categories"
)

end=$((SECONDS + DURATION_SECONDS))
count=0

while [ "$SECONDS" -lt "$end" ]; do
  for url in "${TARGETS[@]}"; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    count=$((count + 1))
    printf '%s %s %s\n' "$(date '+%H:%M:%S')" "$code" "$url"
  done
  sleep "$INTERVAL_SECONDS"
done

printf 'selesai: %d request dalam %ds\n' "$count" "$DURATION_SECONDS"
