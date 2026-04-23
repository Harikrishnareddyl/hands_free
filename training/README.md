# Training the "Hey Aira" wake word

Everything here is about producing one file: `hey_aira.onnx` (~1 MB). Once you
have it, copy it into [`HandsFree/Resources/`](../HandsFree/Resources/) and
flip two strings in
[`WakeWordEngine.swift`](../HandsFree/Core/WakeWordEngine.swift) — the app
picks it up on the next build. No runtime Python, no internet, no API key.

Training runs on [Modal](https://modal.com) because it needs a GPU and ~16 GB
of external datasets. Modal handles provisioning, caching, and teardown for
us; you just invoke the script from your laptop.

## What's in here

| File                                | Purpose |
|-------------------------------------|---------|
| [`modal_train.py`](modal_train.py)                     | Modal app — defines the image, volumes, and entrypoints. |
| [`configs/hey_aira.yaml`](configs/hey_aira.yaml)       | Production config (~8–14 h on A100). |
| [`configs/hey_aira_test.yaml`](configs/hey_aira_test.yaml) | Smoke-test config (~20–30 min). Not usable in the app — only validates the pipeline. |
| [`fetch_model.sh`](fetch_model.sh) | Pulls the finished `.onnx` out of Modal into `HandsFree/Resources/`. |

## Prerequisites

1. Modal account and CLI logged in — you said you're already done with this (`modal token new`).
2. PyPI / GitHub reachable from Modal (it is, by default).
3. ~$5 of Modal credit for the overnight A100 run. Smoke test is cents.

That's it. Nothing to install locally — Modal builds the whole image remotely.

## The commands

All invocations are from the **repo root**, not from inside this folder.

### 1. Smoke test first (strongly recommended)

Validates the Modal image, dataset downloads, and every training phase with a
tiny dataset. Takes 20–30 minutes. The resulting model is intentionally bad —
the point is to catch environment problems in 30 min instead of 10 hours.

```bash
modal run training/modal_train.py::run --config training/configs/hey_aira_test.yaml
```

If that finishes with `✅ done — /output/hey_aira_test.onnx (…KB)`, you're good.

### 2. Production run (overnight)

```bash
modal run --detach training/modal_train.py::run --config training/configs/hey_aira.yaml
```

The first run will download:
- Piper VITS TTS checkpoint (~166 MB)
- ACAV100M audio features (~16 GB)
- Background noise clips
- Room impulse responses

These land in a persistent Modal volume (`hey-aira-cache`) — the *next* run
skips the download entirely. If for some reason you need to re-run without
re-downloading, pass `--skip-setup`.

`modal run` streams live logs. You can close the laptop (Modal keeps running)
and check back with:

```bash
modal app logs hey-aira-training
```

### 3. Pull the model back

Once the run finishes:

```bash
./training/fetch_model.sh
```

This runs `modal run training/modal_train.py::fetch` under the hood and
writes the ONNX to `HandsFree/Resources/hey_aira.onnx`. It reminds you of the
two-line Swift edit to activate it.

### 4. Ship it

In [`WakeWordEngine.swift:17-20`](../HandsFree/Core/WakeWordEngine.swift#L17):

```swift
static let bundledClassifierName = "hey_aira"
static let wakePhrase = "Hey Aira"
```

Then:

```bash
xcodegen generate
xcodebuild -project HandsFree.xcodeproj -scheme HandsFree -configuration Debug build
```

You can delete `HandsFree/Resources/hey_livekit.onnx` at this point — or keep
it around as a backup trigger.

## How long does it take?

Rough wall-clock on a single **A100-40GB** (the default):

| Stage                         | Time  | Notes |
|-------------------------------|-------|-------|
| Cold setup (datasets + image) | 10–30 min | First run only; cached forever after. |
| Generate synthetic audio      | 2–3 h | 25k positives + 25k adversarial negatives through Piper VITS. |
| Augment + feature-extract     | 1–2 h | Reverb, noise, SNR, then frozen embedder. |
| Train (3 phases, ~120k steps) | 4–6 h | Phase 1 = 100k, phase 2/3 = 10k each. |
| Export + eval                 | 5–15 min | ONNX conversion + DET/FPPH curves. |
| **Total (cold, prod)**        | **~9–13 h** | Fine to start at midnight, done by late morning. |
| **Total (warm, prod)**        | **~7–11 h** | Subsequent runs, no downloads. |
| **Total (smoke test)**        | **20–30 min** | Cold first time; ~10 min warm. |

On an **A10G** (cheaper, ~1/3 the price), roughly double everything. Override
via `--gpu a10g` — worth it if you're iterating on the negative-phrase list
and don't care about overnight turnaround.

## If something goes wrong

- **Run crashes midway** — just re-run the same command. Modal volumes are
  persistent, the cache sticks around, and the LiveKit trainer writes
  intermediate artifacts to `/output` as it goes. Partial completion is
  generally safe to repeat.
- **`livekit-wakeword` version drift** — the pin at the top of
  [`modal_train.py`](modal_train.py) (`LIVEKIT_WAKEWORD_REV`) matches the git
  submodule under `Vendor/livekit-wakeword/`. If you bump the submodule, bump
  that constant too so the Swift runtime and the ONNX stay compatible.
- **Model triggers too often in the app** — raise `triggerThreshold` in
  [`WakeWordEngine.swift`](../HandsFree/Core/WakeWordEngine.swift) from 0.75
  toward 0.85. The trainer's eval output shows a DET curve you can use to
  pick a calibrated value.
- **Model doesn't trigger on you** — you're outside the synthetic voice
  distribution. Re-train with your own voice added via the `voice_cloning`
  option (see LiveKit docs), or lower the threshold to 0.60 as a band-aid.
- **Debug inside the container**: `modal run training/modal_train.py::shell`
  spawns a function with both volumes mounted so you can poke at the
  filesystem and re-run subcommands manually.

## Reference

- [LiveKit wake-word repo](https://github.com/livekit/livekit-wakeword) —
  we're pinned to commit `515152a`; see the `Vendor/livekit-wakeword/`
  submodule.
- Trainer docs:
  [`training.md`](../Vendor/livekit-wakeword/docs/training.md),
  [`data-generation.md`](../Vendor/livekit-wakeword/docs/data-generation.md),
  [`export-and-inference.md`](../Vendor/livekit-wakeword/docs/export-and-inference.md).
