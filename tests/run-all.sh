#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
for t in tests/*.sh; do
  [[ "${t}" == *test-helpers* || "${t}" == *run-all* ]] && continue
  echo "== ${t}"
  bash "${t}" || status=1
done
exit "${status}"
