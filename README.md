# Mneme: on-device voice archive

Mneme is a Mac app for recording thoughts and writing notes, with the engine behind it also available as a command-line tool:

- **The app.** Record, play back, review the passages the recogniser was unsure about, write and edit notes, search everything.
- **Speech recognition on your Mac.** Whisper large-v3 runs through WhisperKit (Core ML on the Apple Neural Engine). It handles many accents and 100 languages.
- **A structured archive.** SQLite stores entries, recordings, versioned transcripts, segments and word timings, with full-text search. The original recordings are kept, verified by checksum.
- **Accent tests.** A harness reports word and character error rates per accent, region and language.

Nothing leaves your Mac. The network is used only to download a speech model, and only when you ask for it.

## Requirements

- macOS 14 or later. Apple silicon is strongly recommended.
- Xcode 16 or later. `xcode-select -p` should point at Xcode: the Command Line Tools alone do not include XCTest.
- About 4 GB of free disk space for the accurate model, or 1 GB for the fast one.

## Build and test

```bash
cd ~/Documents/Mneme
swift build
swift test                 # unit tests; no model or network needed
bash Scripts/check.sh      # build + tests + CLI and app smoke tests, log in .logs/latest.log
```

The first build downloads the Swift packages (WhisperKit and swift-argument-parser) from GitHub.

To run the end-to-end test with a real model and speech synthesised by `say`, set `MNEME_MODEL_TESTS=1`. The first run downloads the tiny model, about 75 MB:

```bash
MNEME_MODEL_TESTS=1 swift test --filter EndToEndTests
```

## The Mac app

```bash
bash Scripts/build-app.sh        # release build, then build/Mneme.app (signed for this Mac only)
open build/Mneme.app
```

The first recording asks for microphone access. The app uses the same archive and models as the `mneme` command.

- **Recording (⌘R).** The recording is written to a working file as uncompressed audio, so a crash or power loss keeps everything recorded up to that moment; the next launch archives it. When you stop, it is encoded to AAC, checked against the working file, archived and verified, and only then is the working file removed. Transcription starts right after, one recording at a time.
- **Playback.** Play the whole recording (⌥Space) or click a passage's time to hear just that passage. The passage being played is highlighted.
- **Review (⇧⌘R).** Every passage flagged as uncertain, across the archive. Listen, then correct it or confirm it as right. Corrections become new transcript versions, feed your accent data set, and suggest glossary terms.
- **Notes (⌘N).** Typed notes are versioned like transcripts: saving changed text adds a version and keeps the earlier ones. Leaving the editor saves too. The language of each note is detected and stored.
- **Search.** Transcripts, notes and titles, ignoring case and accents.
- **Settings.** Your languages, the glossary, the speech model (a download starts only when you click it, with its size shown), and the archive check.
- **Deletion.** Removes the recording, all transcript and note versions and the search entries. Deleted database content is overwritten, not left in free pages.

Without a model, recordings are still archived and wait for transcription.

## First run: download a model

Each download is something you choose, and you see its size before it starts:

```bash
swift run mneme models download          # accurate: Whisper large-v3, about 3 GB (default)
swift run mneme models download fast     # large-v3 turbo, compressed, about 626 MB
swift run mneme models                   # what is installed
```

Models come from `huggingface.co/argmaxinc/whisperkit-coreml` and are stored in `~/Library/Application Support/Mneme/Models`.

After the download, the model is loaded once. This caches the tokenizer and lets Core ML compile the model for your Mac, which can take several minutes. From then on, Mneme works fully offline.

Other commands never download anything unless you pass `--allow-download`.

The examples below write `mneme` for short. Use `swift run mneme ...`, or build once with `swift build -c release` and run `.build/release/mneme` (or copy it to a folder on your PATH).

## Everyday use

```bash
mneme languages set en fr ar               # the languages you speak, most used first
mneme glossary add "Sfax" "Dr. Ben Salah"  # names and terms to spell correctly
mneme ingest ~/Desktop/memo.m4a --title "Monday ideas"
mneme list
mneme show 9c41e2ab                        # segments, timings, quality flags (-v 1 for an older version)
mneme search stella                        # case and accents ignored; the last word matches as a prefix
mneme correct 9c41e2ab 2 "Please call Stella tomorrow."
mneme note "Idée pour le livre : commencer par la mer." --title "Livre"
mneme delete 9c41e2ab --yes                # permanent, with its recording and history
mneme verify                               # database, search index and recording checksums
mneme paths
```

Supported audio formats are wav, m4a, mp3, aiff, caf and flac. Every command accepts `--archive <folder>` to use another archive, and `--json` where it prints results.

## How recognition is made robust to accents

1. **A large multilingual model.** Whisper large-v3, with its full 32-layer decoder, is the default (`--model accurate`). It was trained on a very large amount of multilingual audio from many kinds of speakers. `--model fast` trades a little robustness for several times the speed.
2. **Language identification limited to your languages.** Accented speech is often taken for another language, and the whole recording is then transcribed in that language. For example, accented English may be detected as Hindi, or accented French as Arabic. With a profile (`mneme languages set ...`):
   - Mneme chooses only among your languages.
   - With a single language, it skips identification entirely.
   - Each transcript records the language, how it was chosen, and the model's own first guess.
3. **A personal glossary.** The glossary is passed to the decoder as a prompt, so names, places and technical terms are spelled the way you spell them. When you correct a segment, Mneme suggests the new names to add.
   - On the macOS-voices test, the glossary brought WER from 1.1% to 0.2%: every misspelled name was fixed.
   - Prompted transcripts keep segment timings but not word timings. With a prompt, WhisperKit 1.1 misplaces word timings at the end of the 30-second window.
   - A chunk that comes back without words when the prompt is used is transcribed again without the prompt. The glossary can improve spelling but never cost speech.
4. **Robust decoding.** Audio is split at silences (voice-activity detection). Decoding falls back to a higher temperature when the output looks unreliable, which is Whisper's standard defence against repetition loops. Word timings are kept.
5. **Review flags, not silent errors.** Each segment is flagged when the model was unsure:
   - low confidence
   - repetition
   - probable silence (once WhisperKit reports a no-speech probability: version 1.1 does not, so Mneme stores it as unknown)
   - temperature fallback
   - uncertain words
   - unreliable timing

   `mneme show` lists these segments so you can check them.
6. **Corrections become your accent dataset.** A correction is saved as a new transcript version, and earlier versions are kept. Corrected segments are marked as verified. Two commands use them:
   - `mneme export-verified` exports them as an evaluation set of your own voice.
   - `mneme eval` then measures how well each model handles your accent.

   The same export is the starting point for fine-tuning later.

## How writes to the archive are kept correct

- **Validation first.** Before anything is written, each transcript is checked and normalised:
  - Whisper control tokens and control characters are removed.
  - Text is stored in Unicode NFC.
  - Timestamps must be finite and within the recording.
  - Overlaps are resolved.
  - Confident speech is never dropped because of its timestamps. If a segment is placed beyond the end of the recording, its text is kept, its timing is estimated and it is flagged `unreliable_timing`. Only low-confidence or repetitive text there is dropped, as a hallucination.
  - Word timings that disagree with their segment are dropped, and the segment text is kept.
  - The language code must be one Whisper supports.

  Each repair is counted and reported. Corrupt input is refused, and nothing is written.
- **One transaction per write.** The entry, recording, transcript, segments, words and search index are written together. Before the transaction commits, the transcript is read back and compared with the validated input. Any difference rolls back the whole write.
- **Originals.** Each recording is:
  - copied once
  - verified against its SHA-256
  - stored under its checksum
  - made read-only

  Importing the same file twice is detected.
- **Database safeguards.**
  - Tables are `STRICT` with `CHECK` constraints.
  - Foreign keys are enforced.
  - The journal is WAL, with `synchronous=FULL`.
  - Migrations are versioned, and a newer archive is never opened by an older build.
- **Recordings made in the app.** They are written to a crash-safe working file, encoded, checked, archived and verified before the working file is deleted. An interrupted import resumes without creating a second entry.
- **Integrity check.** `mneme verify` (or Archive > Verify Archive in the app) checks the database structure, the search index and every recording's checksum.

## Accent evaluation

A manifest is a JSONL file with one utterance per line. Only `audio` and `text` are required:

```json
{"audio": "clips/0001.wav", "text": "reference transcript", "language": "en", "accent": "scottish", "region": "uk", "speaker": "s12", "start": 3.2, "end": 9.8}
```

```bash
mneme eval manifest.jsonl                          # decode in the reference language
mneme eval manifest.jsonl --language-mode detect   # also counts accents mistaken for another language
mneme eval manifest.jsonl --model fast --limit 50
```

Each run writes these files to `./mneme-eval/<date>-<model>/`:

- `results.jsonl`: one line per utterance, written as the run goes.
- `summary.json`
- `report.md`: overall WER, CER, language errors and speed, then each accent, region and language, worst first.

Error rates are micro-averaged after removing case, punctuation and annotations. For languages written without spaces, read CER rather than WER.

Data sets you can use:

| Source | What it covers | How |
|---|---|---|
| macOS voices | Regional English voices (US, UK, Australia, Ireland, India, South Africa, Scotland), plus other languages with `--multilingual`. Synthetic, so a smoke test only. | `./Scripts/make-say-samples.sh` then `mneme eval eval/say/manifest.jsonl` |
| Speech Accent Archive | 2,000+ speakers from 200+ first languages reading the same English paragraph. Download it from Kaggle (`rtatman/speech-accent-archive`) and unzip it. | `mneme prepare-eval speech-accent-archive <folder> --max-per-accent 5` |
| EdAcc | Conversational English from speakers of 40+ accents (Edinburgh, CC BY-SA 4.0). | `python3 Scripts/export_hf_accent_dataset.py edinburghcstr/edacc --split test --region-column l1 --max-per-accent 25 --out eval/edacc` |
| Your own voice | The segments you corrected or verified. | `mneme export-verified --clips` then `mneme eval eval/verified/manifest.jsonl` |

Check each dataset's licence before redistributing anything derived from it.

## Where data lives

```
~/Library/Application Support/Mneme/
  Archive/            private folder (0700)
    archive.sqlite    entries, transcripts, notes, segments, words, search index (0600)
    blobs/ab/<sha256>.m4a   original recordings, read-only
  Recordings/         the app's working files while recording (0700); normally empty
  Models/             WhisperKit models
```

## Development loop

`./Scripts/dev-loop.sh` re-runs `check.sh` whenever `.logs/request` changes. Leave it running in Terminal while changes are made from another session. Each run writes the full build and test output to `.logs/latest.log`, ending with `RESULT: PASS` or `RESULT: FAIL`.

`check.sh` also runs the app's smoke test (`MnemeApp --smoke-test`): it exercises a temporary archive and renders every screen offscreen. When `.logs/request` contains `build-app`, a passing run also packages `build/Mneme.app`.

When `.logs/request` contains `model-check`, `check.sh` also runs `Scripts/model-check.sh` after a passing build. That script runs the end-to-end test with Whisper tiny, downloads and prepares the accurate model, and runs the macOS-voices accent evaluation in both language modes. Its output goes to `.logs/model-check.log`, and the reports to `.logs/eval-say-*`.

## Layout

```
Sources/MnemeCore     archive, validation, language policy, metrics, evaluation (no third-party dependencies)
Sources/MnemeSpeech   WhisperKit engine, model management, ingest pipeline, accent evaluator
Sources/MnemeCLI      the `mneme` command
Sources/MnemeApp      the SwiftUI app (packaged by Scripts/build-app.sh)
Tests/                unit tests and the opt-in end-to-end test
Scripts/              build loop, sample generation, dataset export
```
