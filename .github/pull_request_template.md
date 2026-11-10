## What changes

<!-- One or two sentences: what and why. -->

## Checks

- [ ] `bash Scripts/check.sh` passes locally (build, unit and property tests, CLI and app smoke tests)
- [ ] CI is green
- [ ] Speech pipeline touched (WhisperKit version, `Sources/MnemeSpeech`, windowing, language handling, sanitiser)?
      Then `bash Scripts/model-check.sh gate` passes on the Mac that holds the baselines, and the gate output is pasted below
- [ ] A baseline changed on purpose? It comes from a real run (`bash Scripts/model-check.sh baseline`), never from a hand edit, and the reason is stated here
- [ ] User-visible change? `CHANGELOG.md` has a line under "Unreleased"

## Privacy

- [ ] No recordings, transcripts or personal notes in this pull request, its logs or its screenshots
- [ ] Nothing new leaves the Mac: no telemetry, no new network calls (model downloads stay explicit)

## Gate output (if applicable)

```
```
