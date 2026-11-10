#!/bin/bash
# Builds Mneme, runs the test suite, a CLI smoke test and the app's offscreen smoke test, and writes everything
# to .logs/latest.log. Usage: bash Scripts/check.sh
set -u
cd "$(dirname "$0")/.."
mkdir -p .logs
LOG=.logs/latest.log
TMP_LOG=.logs/latest.log.partial

run() {
  echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ)  $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)  $(uname -m)"
  echo "== developer dir: $(xcode-select -p 2>/dev/null)"
  swift --version 2>&1 | head -n 2

  echo
  echo "== swift build"
  swift build 2>&1
  local build=$?
  if [ $build -ne 0 ]; then
    echo "RESULT: FAIL (build failed)"
    return 1
  fi

  echo
  echo "== swift test"
  swift test 2>&1
  local tests=$?

  echo
  echo "== CLI smoke test"
  local smoke=0
  local scratch
  scratch=$(mktemp -d)
  local bin=.build/debug/mneme
  $bin --help > /dev/null || smoke=1
  $bin list --archive "$scratch/archive" || smoke=1
  $bin languages set en fr ar --archive "$scratch/archive" || smoke=1
  $bin glossary add Stella "New York" --archive "$scratch/archive" || smoke=1
  $bin glossary --archive "$scratch/archive" || smoke=1
  $bin models list --models-dir "$scratch/models" || smoke=1
  $bin note "Une idée à garder pour demain" --title "Idée" --archive "$scratch/archive" || smoke=1
  if $bin search idee --archive "$scratch/archive" | grep -q "note"; then
    echo "the note was found by search"
  else
    echo "search did not find the note"
    smoke=1
  fi
  $bin verify --archive "$scratch/archive" || smoke=1
  # Without a prepared model and without --allow-download, ingest must refuse before touching the network.
  if $bin ingest "$scratch/none.wav" --archive "$scratch/archive" --models-dir "$scratch/models" 2> "$scratch/err.txt"; then
    echo "ingest unexpectedly succeeded without a model"
    smoke=1
  else
    echo "ingest without a model refused as expected: $(cat "$scratch/err.txt")"
  fi
  rm -rf "$scratch"

  echo
  echo "== app smoke test (temporary archive, offscreen)"
  local app=0
  rm -rf .logs/screens
  .build/debug/MnemeApp --smoke-test --screenshots .logs/screens 2>&1 || app=1

  if [ $tests -eq 0 ] && [ $smoke -eq 0 ] && [ $app -eq 0 ]; then
    echo "RESULT: PASS"
    return 0
  fi
  echo "RESULT: FAIL (tests=$tests smoke=$smoke app=$app)"
  return 1
}

run > "$TMP_LOG" 2>&1
status=$?
mv -f "$TMP_LOG" "$LOG"
grep -E "error:|RESULT:" "$LOG" | tail -n 15

# Real-model checks run only when requested ("model-check", "glossary-check", "probe", "turbo", "codeswitch",
# "baseline" or "gate" in .logs/request), never on ordinary builds.
if [ $status -eq 0 ] && grep -qE "model-check|glossary-check|probe|turbo|codeswitch|baseline|gate" .logs/request 2>/dev/null; then
  echo "Running model checks (log: .logs/model-check.log)..."
  bash ./Scripts/model-check.sh "$(head -n 1 .logs/request)" > .logs/model-check.log 2>&1
  status=$?
  grep -E "MODEL CHECK:" .logs/model-check.log | tail -n 1
fi

# "build-app" in .logs/request also packages build/Mneme.app (release build, ad-hoc signed).
if [ $status -eq 0 ] && grep -q "build-app" .logs/request 2>/dev/null; then
  echo "Building Mneme.app (log: .logs/build-app.log)..."
  bash ./Scripts/build-app.sh > .logs/build-app.log 2>&1
  status=$?
  grep -E "error:|BUILD APP:" .logs/build-app.log | tail -n 5
fi
exit $status
