#!/bin/bash
# Checks with real Whisper models. Started by check.sh when .logs/request contains "model-check"
# or "glossary-check"; the request text is passed as the first argument.
#
# model-check:
#   1. End-to-end test with Whisper tiny: speech from `say` -> transcript -> validated archive entry.
#   2. Release build, then download and prepare the accurate model (Whisper large-v3).
#   3. Accent smoke test with the macOS voices, in reference-language and language-detection modes.
# glossary-check:
#   Re-runs the accent smoke test with names from the first report in a scratch archive's glossary,
#   to confirm that the glossary prompt fixes names without harming other transcriptions.
#
# Downloads happen only in model-check, and only the first time, from huggingface.co/argmaxinc/whisperkit-coreml
# into ~/Library/Application Support/Mneme/Models: tiny (about 75 MB) and large-v3 (about 3 GB).
set -u
cd "$(dirname "$0")/.."
MODE="${1:-model-check}"
status=0
step() { echo; echo "== $(date +%H:%M:%S) $*"; }
finish() {
  echo
  if [ $status -eq 0 ]; then echo "MODEL CHECK: PASS"; else echo "MODEL CHECK: FAIL"; fi
  exit $status
}
want() { [[ "$MODE" == *"$1"* ]]; }
# "model-check" runs everything except the glossary and probe runs; "e2e", "glossary" and "probe" select single steps.
RUN_E2E=0; RUN_DOWNLOAD=0; RUN_EVAL=0; RUN_GLOSSARY=0; RUN_PROBE=0
if want model-check; then RUN_E2E=1; RUN_DOWNLOAD=1; RUN_EVAL=1; fi
if want e2e; then RUN_E2E=1; fi
if want glossary; then RUN_GLOSSARY=1; fi
if want probe; then RUN_PROBE=1; fi

if [ $RUN_E2E -eq 1 ]; then
  step "end-to-end test (Whisper tiny)"
  if MNEME_MODEL_TESTS=1 swift test --filter EndToEndTests > .logs/e2e.log 2>&1; then
    grep -E "Test Case|Executed" .logs/e2e.log | tail -n 4
  else
    status=1
    grep -vE "^\[[0-9]+/[0-9]+\]" .logs/e2e.log | tail -n 60
  fi
fi

step "release build"
if swift build -c release > .logs/release-build.log 2>&1; then
  tail -n 1 .logs/release-build.log
else
  grep -E "error:" .logs/release-build.log | head -n 20
  status=1
  finish
fi
BIN=.build/release/mneme

if [ $RUN_DOWNLOAD -eq 1 ]; then
  step "download and prepare the accurate model"
  $BIN models download accurate 2>&1 || status=1
fi

step "macOS voices"
if [ ! -s eval/say/manifest.jsonl ]; then
  bash ./Scripts/make-say-samples.sh eval/say --multilingual 2>&1 || status=1
else
  echo "Reusing eval/say/manifest.jsonl ($(wc -l < eval/say/manifest.jsonl | tr -d ' ') samples)"
fi

if [ $RUN_EVAL -eq 1 ]; then
  step "accent evaluation: reference language"
  $BIN eval eval/say/manifest.jsonl --model accurate --out .logs/eval-say-reference 2>&1 || status=1

  step "accent evaluation: language detection"
  $BIN eval eval/say/manifest.jsonl --model accurate --language-mode detect --out .logs/eval-say-detect 2>&1 || status=1
fi

if [ $RUN_PROBE -eq 1 ]; then
  # Raw decoder output for clips that came back empty with the glossary prompt.
  for clip in en-AU-Karen-4:en de-DE-Anna-1:de; do
    name="${clip%%:*}"; language="${clip##*:}"
    step "probe $name without a prompt"
    $BIN transcribe "eval/say/$name.aiff" --language "$language" --raw --model accurate 2>&1 || status=1
    step "probe $name with the glossary prompt"
    $BIN transcribe "eval/say/$name.aiff" --language "$language" --raw --model accurate --term Amira --term "Inês" --term "पुणे" 2>&1 || status=1
    step "probe $name with the glossary prompt, without word timings"
    $BIN transcribe "eval/say/$name.aiff" --language "$language" --raw --no-words --model accurate --term Amira --term "Inês" --term "पुणे" 2>&1 || status=1
  done
fi

if [ $RUN_GLOSSARY -eq 1 ]; then
  step "accent evaluation: reference language, with a glossary"
  ARCHIVE=.logs/eval-archive
  $BIN glossary add "Amira" "Inês" "पुणे" --archive "$ARCHIVE" 2>&1 || status=1
  $BIN eval eval/say/manifest.jsonl --model accurate --use-glossary --archive "$ARCHIVE" --out .logs/eval-say-glossary 2>&1 || status=1
fi

finish
