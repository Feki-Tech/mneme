# Changelog

All notable changes to Mneme are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and versions follow [Semantic Versioning](https://semver.org/). `MnemeVersion.current`
(`Sources/MnemeCore/Support/Version.swift`) and the release tag must match; the release workflow checks it.

## [Unreleased]

No release has been tagged yet; the first one will be 0.1.0.

### Added

- Private, on-device archive for macOS: recordings, transcripts and notes in SQLite with versioning, full-text search
  and read-back verification; the SwiftUI app (recording, playback, review of uncertain passages, notes) and the
  `mneme` command-line tool.
- Accent-robust transcription with Whisper through WhisperKit: language identification restricted to the speaker's
  languages, glossary prompts, quality flags; large-v3 turbo as the default model.
- Speakers who switch languages: recordings cut into sentence windows at pauses, one language per window.
- Model lifecycle: a manifest with the SHA-256 of every model file is written on first use and checked on every
  load; the model fingerprint is recorded with every transcript and evaluation (`mneme models verify`).
- Comparable evaluation reports (`report.json`: model fingerprint, decoding settings, dataset fingerprint, machine)
  and a promotion gate, `mneme eval --gate <baseline>` (exit 0 passed, 1 refused, 2 error), with the baselines in
  `Evaluation/baselines/` and the canonical suites in `Scripts/model-check.sh baseline|gate`.
- `mneme models quality`: speed, uncertain passages and the user's corrections per model and fingerprint, computed
  on the Mac from the archive.
- Seeded property tests: error-rate alignment against a Levenshtein oracle, idempotent text normalisation, speech
  windows that tile recordings and cut in pauses, manifest round trips, closed language resolution.
- GitHub Actions: CI (lockfile-only dependency resolution, build, tests, CLI and app smoke tests, screenshots, a
  test-gated `Mneme.app` artifact from `main`), model evaluation with real Whisper models, tag-driven releases with
  checksums and build-provenance attestations; Dependabot; pull request and issue templates; `SECURITY.md`.

### Changed

- One version source, `MnemeVersion.current`, for the tool, the app bundle, transcripts and reports.
- `Scripts/build-app.sh` takes the version and build number from the environment and can sign with a Developer ID
  identity and the hardened runtime.
