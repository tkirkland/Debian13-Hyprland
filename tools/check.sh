#!/usr/bin/env bash
# Development quality gate: bash -n and shellcheck over every shell file.
set -euo pipefail

cd "$(dirname "$0")/.."

declare -a files=()
while IFS= read -r f; do
  files+=("$f")
done < <(find . -path ./.git -prune -o -name '*.sh' -print | sort)

status=0
for f in "${files[@]}"; do
  if ! bash -n "$f"; then
    echo "SYNTAX FAIL: $f" >&2
    status=1
  fi
done

if ! shellcheck --severity=style --external-sources "${files[@]}"; then
  status=1
fi

if ((status == 0)); then
  echo "OK: ${#files[@]} files pass bash -n and shellcheck"
fi
exit "$status"
