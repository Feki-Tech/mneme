# Security

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: **Security → Report a vulnerability** on this repository
(<https://github.com/Feki-Tech/mneme/security/advisories/new>). Do not open a public issue, and do not attach
recordings, transcripts or notes from a real archive; a synthetic reproduction (for example audio made with `say`)
is enough. You can expect an acknowledgement within a week.

Only the latest release is supported with fixes.

## Security model

Mneme is a single-user macOS app whose data never leaves the Mac by design: recordings, transcripts, notes and
speech models are stored and processed locally. There is no account, no server and no telemetry. The network is
used for one thing only: downloading a speech model from `huggingface.co/argmaxinc/whisperkit-coreml` when the user
asks for it (Settings, `mneme models download`, or `--allow-download`). That removes whole classes of threats; what
remains is concentrated in the archive on disk and in the model files Mneme executes.

Convention, as in the rest of the docs: statements about current behaviour name the code; anything not implemented
is marked *(proposed)*.

### Surfaces and controls

| # | Surface | Current controls | Residual risk |
|---|---|---|---|
| S1 | **Archive database** (`~/Library/Application Support/Mneme/Archive`) | Folder `0700`, database `0600` (`ArchiveStore.init`); `secure_delete` and WAL (`Database`); every write is read back and verified; deleting an entry removes its rows, search entries and files, then checkpoints the WAL (`ArchiveStore.deleteEntry`) | Not encrypted beyond FileVault; anyone with the user's session can read it. Turn on FileVault. |
| S2 | **Original recordings** (content-addressed blobs) | Stored read-only (`0444`) under the `0700` archive folder (`BlobStore`); SHA-256 recorded and checked by `mneme verify` | Deleted files are unlinked, not overwritten: on an SSD only FileVault protects deleted data. |
| S3 | **Speech model files** (Core ML, executed by Mneme) | Downloaded only on request, from one repository over HTTPS (WhisperKit); a manifest with the SHA-256 of every file is written on first use, names and sizes are checked on every load, `mneme models verify` re-hashes everything; the model fingerprint is stamped on every transcript (`ModelManifest`, `WhisperEngine.identifyModel`) | WhisperKit fetches a variant from the repository's default branch, so the first download is trusted as published (no pinned revision). Fingerprints of evaluated models are recorded in the baselines. |
| S4 | **Microphone** | macOS permission prompt with a purpose string (`NSMicrophoneUsageDescription`); release builds with a hardened runtime request only `com.apple.security.device.audio-input` (`Scripts/build-app.sh`) | None beyond the permission the user grants. |
| S5 | **Working recordings** (crash-safe files during recording) | Written to a `0700` folder, imported idempotently, encoded and verified before the working file is removed (`RecorderModel`, `ArchiveWorker.importRecording`) | A crash leaves the working file until the next launch imports it. |
| S6 | **Evaluation data** (`eval/`, `mneme export-verified`) | Ignored by Git (`.gitignore`); exported manifests point into the archive unless `--clips` copies audio out | A user who commits an exported folder publishes their own voice: the pull request template asks for no personal data. |
| S7 | **Build and release pipeline** | Workflows with least-privilege tokens (`contents: read` unless a job must write); third-party actions pinned to commit SHAs; dependencies resolved from the committed `Package.resolved` only (`--force-resolved-versions`); Dependabot for Swift packages and actions; releases test-gated, with SHA-256 checksums and build-provenance attestations; Developer ID signing and notarisation when the secrets exist (`.github/workflows/`) | Ad hoc signed releases (no secrets configured) cannot be verified by Gatekeeper; users must check the attestation (`gh attestation verify`) or the checksum. |

### Accepted risks

- **No at-rest encryption of its own.** FileVault is the control; a separate encrypted "vault" for sensitive
  entries is reserved in the schema (`entry.privacy`) but not implemented *(proposed)*.
- **First model download is trusted as published.** Pinning a Hugging Face revision needs a download path WhisperKit
  1.1 does not offer *(proposed: pin revisions, and refuse a download whose fingerprint differs from the evaluated one)*.
- **Synthetic evaluation data.** The quality gates run on macOS voices, not on real accented speakers; they catch
  regressions, they do not certify accuracy (docs/MLOPS.md).

### Hardening roadmap *(proposed)*

1. Expected fingerprints for the built-in model profiles, checked after download.
2. An optional encrypted vault for entries marked private, keyed from the user's keychain.
3. Developer ID signing and notarisation for every release (needs an Apple Developer account).
