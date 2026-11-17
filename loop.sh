#!/usr/bin/env bash
# Runs retry.sh again and again for RUN_SECONDS (default 110 s),
# so each GitHub run gets several tries for the same billed minutes.
# Stops early on success, or if retry.sh reports a real problem.
DEADLINE=$(( SECONDS + ${RUN_SECONDS:-110} ))
round=0
while (( SECONDS < DEADLINE )); do
  round=$((round + 1))
  echo "=== Round $round ==="
  bash retry.sh
  rc=$?
  if [[ $rc -ne 0 ]]; then exit "$rc"; fi
  if grep -q '^result=' "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null; then exit 0; fi
  if (( SECONDS + 15 >= DEADLINE )); then break; fi
  sleep 10
done
echo "Finished $round rounds - no capacity yet. Next run in ~20 minutes."
exit 0
