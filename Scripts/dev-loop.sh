#!/bin/bash
# Re-runs ./Scripts/check.sh whenever .logs/request changes (touch it to trigger a run).
# Leave it running in a Terminal window while Claude iterates on the code. Ctrl-C stops it.
cd "$(dirname "$0")/.."
mkdir -p .logs
touch .logs/request
last=""
echo "Mneme dev loop: watching .logs/request. Ctrl-C to stop."
while true; do
  current=$(stat -f %m .logs/request 2>/dev/null || echo 0)
  if [ "$current" != "$last" ]; then
    last="$current"
    echo "[$(date +%H:%M:%S)] building and testing..."
    bash ./Scripts/check.sh   # bash: works even if a copy lost its executable bit
    echo "[$(date +%H:%M:%S)] done. Full log: .logs/latest.log"
  fi
  sleep 2
done
