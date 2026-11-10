# MLOps and DevOps

This document brings the operating practices of [ai-gym-coach](https://github.com/Feki-Tech/ai-gym-coach) (which
inherited them from edgesense-ai) to Mneme: dependency locking, a model lifecycle with manifests, fixed evaluation
sets, a promotion gate against committed baselines, CI that gates every artifact on its tests, and tag-driven
releases. They are adapted to what Mneme is: a local-first macOS app whose model is a third-party Whisper checkpoint
running on the device, with no server and no telemetry.

Convention carried over from ai-gym-coach: statements about current behaviour name the code; anything not
implemented is marked *(proposed)*.

## 1. What transferred, and where it lives

| ai-gym-coach practice | In Mneme | Where |
|---|---|---|
| `uv.lock` committed, CI installs with `uv sync --frozen` | `Package.resolved` committed; CI resolves with `--force-resolved-versions` and fails if a build rewrites the file | `Package.resolved`, `ci.yml` |
| Self-test suites on every push, same commands locally and in CI | `Scripts/check.sh`: build, unit and property tests, CLI smoke test, app smoke test rendering every screen; CI runs the same script on a macOS 26 runner and keeps the screenshots | `Scripts/check.sh`, `ci.yml` |
| Deploy artifacts gated on tests (`needs: selftest`) | `Mneme.app` packaged from `main` only after the tests pass (`needs: test`) | `ci.yml` (`app` job) |
| Classifier manifest: version, seed, training-data hash, eval snapshot | Model manifest: SHA-256 of every model file and a 12-digit fingerprint, written on first use, checked on every load | `ModelManifest`, `WhisperEngine.identifyModel` |
| Prompt version and fingerprint stamped on every trace line and eval report | Model fingerprint and Mneme version stamped on every transcript's provenance and every evaluation report | `WhisperEngine.transcribe`, `EvalRunReport` |
| Fixed held-out evaluation harness | Canonical suites on fixed generated data, identified by a dataset fingerprint | `Scripts/model-check.sh baseline\|gate`, `EvalDataset` |
| Champion/challenger gate: absolute bar plus no regression, exit 0/1/2, never auto-promote | `mneme eval --gate <baseline>` with the same contract | `EvalGate`, `EvaluationCommands.swift` |
| Eval baseline committed only from real runs, recording model, prompt, temperature and seed | Baselines in `Evaluation/baselines/` record model fingerprint, decoding settings, dataset fingerprint and machine; the gate notes every difference | `Evaluation/` |
| `model-gate.yml` and the nightly `coach-eval.yml`: real model on a runner, report in the job summary, artifacts | `model-eval.yml`: weekly, on demand, and on pull requests that touch the speech pipeline | `model-eval.yml` |
| Local trace and `coach_ops.py --report` (metrics only, nothing uploaded) | `mneme models quality`: speed, uncertain passages and the user's corrections per model fingerprint, from the archive | `ArchiveStore.modelQuality`, `ModelCommands.swift` |
| Property-based harness (dependency-free seeded fuzz) | Seeded property tests with a SplitMix64 generator; `PROPERTY_SEED` replays or explores | `Tests/MnemeCoreTests/PropertyTests.swift` |
| TestFlight upload and `android-v*` releases | `v*` tags: version check, full check, app and tool, checksums, build provenance; Developer ID signing and notarisation once the secrets exist | `release.yml`, `Scripts/build-app.sh` |
| STRIDE security document | Surfaces, controls and residual risks of a local archive | `SECURITY.md` |

Added as general good practice: Dependabot for Swift packages and GitHub Actions, third-party actions pinned to
commit SHAs, least-privilege workflow tokens, actionlint and ShellCheck in CI, pull request and issue templates that
keep personal data out of the repository, a changelog, and one source for the version (`MnemeVersion.current`).

## 2. What deliberately does not transfer

- **No telemetry.** ai-gym-coach rules out user telemetry for the same reason edgesense's Prometheus/Grafana loop
  could not move: here it would be watching a person's voice and thoughts. `mneme models quality` is the
  monitoring that remains, computed on the Mac when asked.
- **No cloud.** Azure, Terraform, OIDC deployment and container registries serve a hosted service. Mneme has none,
  and a demo deployment like ai-gym-coach's dashboard has no counterpart: there is nothing to show without
  someone's recordings.
- **No Docker.** A Core ML app runs on macOS only; containers cannot run it. The macOS runner plays the part of the
  reproducible build environment.
- **No training pipeline or experiment registry.** Mneme does not train. It chooses, identifies and evaluates
  published checkpoints, so the registry is `ModelProfile` plus the manifests, and the "training data" record is
  the model fingerprint.
- **No cross-platform parity fixtures.** ai-gym-coach keeps three implementations of its engine in step; Mneme has
  one.
- **No automatic promotion.** The gate refuses; a person changes the default model.

## 3. The model lifecycle

```
ModelProfile ──► explicit download ──► manifest on first use ──► canonical suites ──► gate ──► human decision
(registry)       (huggingface.co)      (SHA-256, fingerprint)    (report.json)       (0/1/2)   (default profile)
```

### 3.1 Registry

`ModelProfile.builtIn` lists the profiles: `fast` (Whisper large-v3 turbo, compressed, 626 MB, the default) and
`accurate` (Whisper large-v3, about 3 GB). Any other WhisperKit variant can be named, and is identified by its
manifest like the built-in ones.

### 3.2 Manifest and fingerprint

WhisperKit downloads a variant by name from the default branch of `argmaxinc/whisperkit-coreml`, so the same name
could deliver other files later. The first time a model loads, Mneme hashes every file (about a second per
gigabyte) and writes `.mneme-manifest.json` next to it. Every later load compares names and sizes, which costs a
directory listing; `mneme models verify` re-hashes everything and exits 1 when anything changed. The fingerprint (the
first 12 hex digits of a SHA-256 over path, size and digest of every file) is recorded:

- in every transcript's provenance (`model_fingerprint`, with `mneme_version`), so the archive knows which model
  files produced each text;
- in every evaluation report, so a number is always tied to the model that produced it.

If the files no longer match their manifest, the engine records the fingerprint as `modified`; `mneme models verify`
lists the differences, and `mneme eval` and `mneme models download` warn about them.

### 3.3 Evaluation suites and data

| Suite | Data | Settings | Measures |
|---|---|---|---|
| `say-reference` | macOS voices: English with many regional accents, plus one sentence per installed language | decode in the reference language | accent robustness alone |
| `say-detect` | the same | language identification over all languages | accents mistaken for another language |
| `codeswitch-sentence` | French, English, German and Arabic sentences joined within a recording, and sentences with embedded English words | identification among fr, en, de, ar, one language per sentence | following a speaker who switches |

The data is generated (`Scripts/make-say-samples.sh`, `Scripts/make-codeswitch-samples.sh`), not committed. A dataset
fingerprint over every item's audio digest, reference text and metadata identifies it in the reports: two runs are
compared only when they measured the same data.

### 3.4 The gate

`mneme eval <manifest> … --gate <baseline.json>` evaluates, writes `report.json` and `gate.md`, and exits:

- **0** when the candidate passes, **1** when it is refused, **2** when the run or the comparison failed.

Absolute bars, always applied: no item may fail to transcribe, and the overall WER must stay at or below 10 %
(`--max-wer`). Relative bars, applied only when the dataset fingerprints match:

- the overall WER may not rise by more than one point (`--tolerance`);
- no accent, region or language group may gain more than one error *and* more than 4 % of its reference words
  (groups are small: one flipped word must not fail the gate, two in a short group must);
- languages written without spaces (Chinese, Japanese, Thai, …) are compared on characters, because for them a
  "word" is a whole sentence;
- the number of items decoded in the wrong language may not increase at all: accents mistaken for another
  language are the failure Mneme exists to prevent. For recordings that switch languages, an item counts as wrong
  unless its segments follow the expected sequence of languages (`"languages": ["en", "fr"]` in the manifest).

When the model, the decoding settings, Mneme's version or the machine differ from the baseline, the gate says so in a
note; a comparison is never silently apples to oranges.

### 3.5 Baselines

`Evaluation/baselines/<suite>.<model>.json` are copies of real runs' `report.json`, produced by
`bash Scripts/model-check.sh baseline` (add `accurate` for the second profile). They are reviewed as a diff and
committed with the reason; they are never edited by hand. A baseline changes when the data, the model or the
pipeline changes on purpose, never to make a gate pass.

### 3.6 Promotion: changing the default model

1. Download the challenger (`mneme models download <variant>`; ask before multi-gigabyte downloads).
2. Run the suites with it against the champion's baselines, for example
   `mneme eval eval/say/manifest.jsonl --model <variant> --gate Evaluation/baselines/say-reference.fast.json`.
   The gate notes that the model differs and compares on the same data.
3. If every suite passes and the speed is acceptable (`report.md` has the real-time factor), change
   `ModelProfile.defaultProfile`, regenerate the baselines with the new champion, and merge both in one pull
   request with the gate output in its description.

### 3.7 Monitoring on the Mac

`mneme models quality` groups the archive's machine transcripts by model and fingerprint: recordings, audio hours,
real-time factor, share of passages flagged as uncertain, and share of recordings in which the user corrected or
confirmed a passage. A model update that recognises worse shows up as a new row with more flags and more
corrections. Transcripts from before fingerprints were recorded appear as `unknown`. Nothing leaves the Mac.

## 4. CI/CD

| Workflow | Runs on | Does |
|---|---|---|
| `ci.yml` | every push and pull request | lint (ShellCheck, Python, JSON, actionlint); on macOS 26: dependencies from `Package.resolved` only, `Scripts/check.sh`, the log and screenshots as artifacts; on `main`: `Mneme.app` built, signed ad hoc, smoke-tested from the bundle and published as an artifact |
| `model-eval.yml` | weekly, on demand, pull requests touching the speech pipeline | real models (cached), `Scripts/model-check.sh gate`, gate results and reports in the job summary |
| `release.yml` | `v*` tags | tag equals `MnemeVersion.current`, full check, app and tool, notarisation when the secrets exist, SHA-256 checksums, build-provenance attestations, GitHub Release |
| Dependabot | weekly | Swift packages and actions, grouped |

Supply chain: third-party actions are pinned to commit SHAs (Dependabot keeps them current), every workflow starts
from `contents: read`, dependency versions come from the lockfile, and release archives carry provenance
attestations (`gh attestation verify Mneme-<version>-macos-arm64.zip --repo Feki-Tech/mneme`).

*(proposed)* Protect `main`: require the `CI` checks to pass before merging, and delete branches once merged (the
ai-gym-coach lesson: stale branches misled work twice in one session).

## 5. Day to day

```bash
bash Scripts/check.sh                          # what CI runs: build, tests, smoke tests
PROPERTY_SEED=42 swift test --filter PropertyTests   # explore other generated inputs

mneme models list                              # profiles, installed folders and fingerprints
mneme models verify                            # re-hash every installed model (exit 1 if changed)
mneme models quality                           # how each model did on your recordings

bash Scripts/model-check.sh gate               # before merging a speech-pipeline change
bash Scripts/model-check.sh baseline           # after an intended change: new baselines to review and commit
```

From the development loop, put `gate` or `baseline` (optionally with `accurate`) in `.logs/request`.

## 6. Current baselines

Recorded on a 13-inch MacBook Pro with M1 (`MacBookPro17,1`), macOS 26.5.2, Mneme 0.1.0; the files hold every
group and setting.

| Suite | Model (fingerprint) | Items | WER | CER | Language errors | Real-time factor |
|---|---|---:|---:|---:|---:|---:|
| `say-reference` | fast (`13d1ce901ca6`) | 37 | 1.1 % | 0.2 % | 0 | 0.28 |
| `say-reference` | accurate (`6989e8ac69c5`) | 37 | 1.1 % | 0.3 % | 0 | 0.68 |
| `say-detect` | fast | 37 | 1.1 % | 0.2 % | 0 | 0.48 |
| `say-detect` | accurate | 37 | 1.1 % | 0.3 % | 0 | 0.89 |
| `codeswitch-sentence` | fast | 14 | 2.5 % | 1.1 % | 0 | 0.32 |
| `codeswitch-sentence` | accurate | 14 | 2.1 % | 1.3 % | 0 | 0.70 |

The clips are a few seconds long, so the real-time factors include the fixed cost of each clip; long recordings run
at 0.14 to 0.18 with the fast model (README, "Speed"). Four of the fast model's six code-switching errors come from a
single English word inside a French sentence ("deadline", heard as "10 de l'île de"); no item was decoded in the
wrong language or sequence of languages.

## 7. Lessons

From Mneme's own history, each found only by running the real model:

1. **Language sampled at fallback temperatures.** WhisperKit re-identified the language at every temperature
   fallback, so a French and Arabic recording came back as English. Two-pass decoding (greedy first, then a retry
   with the language fixed) fixed it; the code-switching suite holds it in place.
2. **The same strategy behaves differently per model.** One language per 30-second window raised large-v3's
   code-switching WER to 36 % (11 % with one language per recording), while one language per sentence brought both
   models to about 2 %. That is why baselines are kept per model and per suite.
3. **A dependency fix that matters is pinned.** Glossary prompts produced empty transcriptions until WhisperKit 1.1.0;
   `Package.swift` accepts any 1.x, so `Package.resolved` pins the version the suites passed with, and a WhisperKit
   update goes through the gate.

Imported from ai-gym-coach and edgesense:

4. **Test against the real thing.** Fixtures verify logic; only the real model verifies the pipeline. Unit tests run
   on every push; the suites run real Whisper models.
5. **A baseline is a measurement, not a target.** Only real runs produce one.
6. **Delete merged branches immediately.**

## 8. Known limits

- The suites use synthetic voices: clean, regular speech. They detect regressions in the pipeline; they do not
  measure accuracy on real accented speakers. `mneme export-verified` turns the user's own corrections into a private
  evaluation set that never leaves the Mac.
- The groups are small (one to four items per accent), which is why the group tolerance counts errors rather than
  percentages.
- On GitHub's runners the voices differ, so the dataset fingerprints differ and the CI gate applies its absolute bars
  only. The runners are virtual machines without the Neural Engine: their speed numbers are not comparable with a
  Mac's.
- The first download of a model is trusted as published (SECURITY.md, S3).
