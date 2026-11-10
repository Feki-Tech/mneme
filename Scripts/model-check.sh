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
# baseline / gate (docs/MLOPS.md):
#   The canonical evaluation suites (accents in the reference language, accents with language detection,
#   code-switching per sentence) with the default model, or also the accurate one when the request says
#   "accurate". "baseline" stores each run's report.json in Evaluation/baselines/ (review the diff, then commit;
#   never edit a baseline by hand). "gate" runs the same suites with `mneme eval --gate` against those baselines
#   and fails on any regression. Also used by the model-eval workflow on GitHub Actions.
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
RUN_E2E=0; RUN_DOWNLOAD=0; RUN_EVAL=0; RUN_GLOSSARY=0; RUN_PROBE=0; RUN_TURBO=0; RUN_CODESWITCH=0; RUN_SUITES=""
if want model-check; then RUN_E2E=1; RUN_DOWNLOAD=1; RUN_EVAL=1; fi
if want e2e; then RUN_E2E=1; fi
if want glossary; then RUN_GLOSSARY=1; fi
if want probe; then RUN_PROBE=1; fi
if want turbo; then RUN_TURBO=1; fi
if want codeswitch; then RUN_CODESWITCH=1; fi
if want baseline; then RUN_SUITES=baseline; fi
if want gate; then RUN_SUITES=gate; fi

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


if [ $RUN_TURBO -eq 1 ]; then
  # Speed and accuracy of large-v3 turbo against large-v3 (approved download: 626 MB, done once).
  step "download and prepare the fast model (large-v3 turbo)"
  $BIN models download fast 2>&1 || status=1

  step "accent evaluation (fast): reference language"
  $BIN eval eval/say/manifest.jsonl --model fast --out .logs/eval-say-fast-reference 2>&1 | tail -n 12 || status=1
  step "accent evaluation (fast): language detection"
  $BIN eval eval/say/manifest.jsonl --model fast --language-mode detect --out .logs/eval-say-fast-detect 2>&1 | tail -n 12 || status=1

  step "long recordings"
  bash ./Scripts/make-longform-samples.sh eval/long 2>&1 || status=1
  for model in fast accurate; do
    for clip in eval/long/*.aiff; do
      name="$(basename "$clip" .aiff)"
      step "long recording $name with $model"
      started=$(python3 -c 'import time; print(time.time())')
      if $BIN transcribe "$clip" --model "$model" --language "$name" --json > ".logs/long-$model-$name.json" 2> ".logs/long-$model-$name.err"; then
        python3 - "$clip" ".logs/long-$model-$name.json" "$started" <<'PY'
import json, sys, time
clip, path, started = sys.argv[1], sys.argv[2], float(sys.argv[3])
wall = time.time() - started
data = json.load(open(path))
duration = data["durationSeconds"]
transcript = data["transcript"]
processing = transcript.get("processingSeconds") or 0
print(f"audio {duration:.1f} s, transcription {processing:.1f} s (real-time factor {processing / duration:.2f}), "
      f"load and preparation {wall - processing:.1f} s, segments {len(transcript.get('segments', []))}")
PY
      else
        status=1
        tail -n 5 ".logs/long-$model-$name.err"
      fi
    done
  done
fi


if [ $RUN_CODESWITCH -eq 1 ]; then
  # Code-switching: one language per recording (the original behaviour) against one per window and one per
  # sentence, with large-v3 turbo and large-v3. Then the monolingual accent set with per-sentence identification
  # among ten languages, to check that it costs nothing when nobody switches.
  step "code-switching samples"
  bash ./Scripts/make-codeswitch-samples.sh eval/cs 2>&1 || status=1
  CS_ARCHIVE=.logs/cs-archive
  SAY_ARCHIVE=.logs/say-archive
  $BIN languages set fr en de ar --archive "$CS_ARCHIVE" > /dev/null 2>&1 || status=1
  $BIN languages set en fr de es it pt nl ar hi tr --archive "$SAY_ARCHIVE" > /dev/null 2>&1 || status=1
  CS_MODELS="fast accurate"
  if want codeswitch-fast; then CS_MODELS="fast"; fi
  for model in $CS_MODELS; do
    for strategy in recording window sentence; do
      step "code-switching: $model, one language per $strategy"
      $BIN eval eval/cs/manifest.jsonl --model "$model" --language-mode detect --use-profile --archive "$CS_ARCHIVE" \
        --language-strategy "$strategy" --out ".logs/eval-cs-$model-$strategy" > ".logs/eval-cs-$model-$strategy.log" 2>&1 || status=1
    done
    if [ -s eval/long/en.aiff ]; then
      step "long English recording: $model, one language per sentence among four"
      $BIN transcribe eval/long/en.aiff --model "$model" --profile fr,en,de,ar --json > ".logs/long-$model-en-sentence.json" 2>/dev/null || status=1
      python3 -c "import json; d = json.load(open('.logs/long-$model-en-sentence.json')); t = d['transcript']; p = t.get('processingSeconds') or 0; print(f\"audio {d['durationSeconds']:.1f} s, transcription {p:.1f} s (real-time factor {p / d['durationSeconds']:.2f}), windows {t['provenance']['settings'].get('windows')}, languages {t['provenance']['settings'].get('speech_by_language')}\")" || status=1
    fi
    step "accent set: $model, one language per sentence among ten"
    $BIN eval eval/say/manifest.jsonl --model "$model" --language-mode detect --use-profile --archive "$SAY_ARCHIVE" \
      --language-strategy sentence --out ".logs/eval-say-$model-sentence" > ".logs/eval-say-$model-sentence.log" 2>&1 || status=1
  done
  step "summary"
  python3 - <<'PY'
import json, pathlib
rows = []
for folder in sorted(pathlib.Path(".logs").glob("eval-*")):
    summary = folder / "summary.json"
    if not summary.exists():
        continue
    data = json.loads(summary.read_text())
    overall = data.get("overall", {})
    rows.append((folder.name, overall.get("items"), overall.get("wer"), overall.get("cer"), data.get("realTimeFactor")))
print(f"{'run':38} {'items':>5} {'WER':>7} {'CER':>7} {'RTF':>6}")
for name, items, wer, cer, rtf in rows:
    fmt = lambda value: f"{value * 100:6.1f}%" if isinstance(value, (int, float)) else "     -"
    print(f"{name:38} {items or 0:>5} {fmt(wer)} {fmt(cer)} {rtf if rtf is None else round(rtf, 2):>6}")
PY
  for log in .logs/eval-cs-*-sentence.log; do
    echo "--- $log"
    grep -E "WER|LANGUAGE|error" "$log" | head -n 20
  done
fi


if [ -n "$RUN_SUITES" ]; then
  # Canonical suites: the same data, settings and models every time, so runs can be compared. Samples are
  # generated once and reused: their audio is part of each report's dataset fingerprint.
  SUITE_MODELS="fast"
  if want accurate; then SUITE_MODELS="fast accurate"; fi
  if [ ! -s eval/cs/manifest.jsonl ] || ! grep -q '"languages"' eval/cs/manifest.jsonl; then
    step "code-switching samples"
    bash ./Scripts/make-codeswitch-samples.sh eval/cs 2>&1 || status=1
  fi
  SUITE_ARCHIVE=.logs/suite-archive
  $BIN languages set fr en de ar --archive "$SUITE_ARCHIVE" > /dev/null 2>&1 || status=1
  mkdir -p Evaluation/baselines
  for model in $SUITE_MODELS; do
    step "prepare the $model model"
    if $BIN models download "$model" > ".logs/prepare-$model.log" 2>&1; then
      tail -n 1 ".logs/prepare-$model.log"
    else
      status=1
      tail -n 5 ".logs/prepare-$model.log"
    fi
    for suite in say-reference say-detect codeswitch-sentence; do
      case "$suite" in
        say-reference) manifest=eval/say/manifest.jsonl; args=(--language-mode reference) ;;
        say-detect) manifest=eval/say/manifest.jsonl; args=(--language-mode detect) ;;
        codeswitch-sentence)
          manifest=eval/cs/manifest.jsonl
          args=(--language-mode detect --use-profile --archive "$SUITE_ARCHIVE" --language-strategy sentence) ;;
      esac
      out=".logs/$RUN_SUITES-$suite.$model"
      baseline="Evaluation/baselines/$suite.$model.json"
      rm -rf "$out"
      step "$RUN_SUITES: $suite ($model)"
      if [ "$RUN_SUITES" = gate ]; then
        if [ ! -f "$baseline" ]; then
          echo "no baseline $baseline: run the baseline suites first"
          status=1
          continue
        fi
        "$BIN" eval "$manifest" --model "$model" "${args[@]}" --out "$out" --gate "$baseline" > "$out.log" 2>&1
        code=$?
        if [ -f "$out/gate.md" ]; then cat "$out/gate.md"; else tail -n 20 "$out.log"; fi
        [ $code -eq 0 ] || status=1
      else
        if "$BIN" eval "$manifest" --model "$model" "${args[@]}" --out "$out" > "$out.log" 2>&1; then
          cp "$out/report.json" "$baseline"
          python3 -c "import json, sys; r = json.load(open(sys.argv[1])); o = r['summary']['overall']; print(f\"{sys.argv[1]}: {o['items']} items, WER {o['wer'] * 100:.1f}%, CER {o['cer'] * 100:.1f}%, language errors {o['languageMismatches']}, model {r['model']['fingerprint']}, data {r['dataset']['fingerprint']}\")" "$baseline" || status=1
        else
          status=1
          tail -n 20 "$out.log"
        fi
      fi
    done
  done
fi

finish
