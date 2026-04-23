# Training a wake word for Hands-Free

Everything here is about producing one file: `<model_name>.onnx` (~900 KB). Copy
it into [`HandsFree/Resources/`](../HandsFree/Resources/), flip two strings in
[`WakeWordEngine.swift`](../HandsFree/Core/WakeWordEngine.swift), rebuild, and
you're shipping your own wake word. No runtime Python, no internet, no API key.

---

## Which path should you pick?

| Path | What it produces | When to use it |
|---|---|---|
| **[Voice fine-tune](#path-a--voice-fine-tune-recommended)** | A model tuned to **your specific voice** | You want a real working wake word for yourself or a small team |
| **[Generic](#path-b--generic-synthetic-only-training)** | A model trained on 900+ synthetic TTS voices | You're shipping to many users whose voices you can't record |

The generic path is what LiveKit's reference setup does. It works for their
packaged "Hey LiveKit" model because they also blended in real recordings in
their training — which we can't reproduce here. **For a custom wake phrase the
voice fine-tune path is what actually produces something usable.** We learned
this the expensive way: our first two generic-only runs peaked at ~0.08 confidence
on real voice vs ~0.56 with the fine-tune.

---

## Path A — Voice fine-tune (recommended)

End-to-end: **~30 min recording + ~90 min Modal compute ≈ $3 cost**.

### 1. Record yourself saying the wake phrase

Tooling lives in [`voice/`](voice/). One-time setup:

```bash
brew install sox
```

Record a single ~5 min take with natural pauses between utterances:

```bash
./training/voice/record.sh
```

The script prints a recipe — aim for ~100 utterances mixing these variations:
normal / fast / slow / quiet / loud / tired / excited, and a mix of
mic distances (close, arm's length, across room). Recording auto-stops after
5 s of silence.

If you want multiple takes targeting gaps (e.g. "I forgot to record quiet voice"):

```bash
./training/voice/record.sh quiet   # tag subsequent takes
./training/voice/record.sh moving
```

All takes land in `training/voice/raw/`.

### 2. Split the take into individual clips

```bash
./training/voice/split.sh
```

Defaults: processes **all** raw takes, splits on 0.3% RMS silence, drops clips
under 0.25 s or over 3.0 s, peak-normalizes to −3 dB, forces 16 kHz mono int16,
renumbers to `clip_001.wav` through `clip_NNN.wav`.

If quiet utterances are getting dropped, lower the silence threshold:

```bash
SILENCE_THRESHOLD=0.1% ./training/voice/split.sh
```

**0.1% was what worked for the Hands-Free v0.3.0 Hey Aira model** — the Mac
built-in mic picks up normal speech at low RMS.

More env var overrides available in the script comments:

| Env var | Default | When to change |
|---|---|---|
| `SILENCE_THRESHOLD` | `0.3%` | Lower for quiet voices |
| `SILENCE_DURATION` | `0.5` s | Raise if clips get chopped mid-phrase |
| `MIN_CLIP_SEC` | `0.25` | Lower for very fast wake phrases |
| `MAX_CLIP_SEC` | `3.0` | Raise if your wake phrase is longer |

### 3. Review (optional but recommended)

```bash
./training/voice/review.sh
```

Plays each clip sequentially with its filename. Delete obviously-bad ones:

```bash
rm training/voice/clips/clip_042.wav
```

A few imperfect clips (slight mispronunciations, background noise, even
double-utterances like "Hey Aira Hey Aira") won't hurt — they add realistic
variation. Only delete clips that **don't contain the wake phrase at all**.

### 4. Clean between takes if you want to redo

```bash
./training/voice/clean.sh          # wipe clips/, keep raw takes
./training/voice/clean.sh --raw    # wipe raw takes
./training/voice/clean.sh --all    # wipe everything
```

### 5. Upload clips to Modal and kick off the fine-tune

One-time on a fresh Modal account:

```bash
modal token new
modal volume create hey-aira-output
```

Then every time you want to run:

```bash
modal volume put --force hey-aira-output training/voice/clips user_clips
modal run --detach training/modal_train.py::finetune
```

The `finetune` entrypoint:

1. Uploads the Modal image (~1 min)
2. Runs `setup` (16 GB dataset download — cached on subsequent runs)
3. Runs `generate` (25k synthetic TTS clips + 25k adversarial negatives, ~30 min on L40S)
4. **Injects your user clips into `positive_train/` at indices 25000+** — so training sees both synthetic voices AND your actual voice
5. Runs `augment` (parallel, ~15 min)
6. Runs feature extraction (parallel, ~15 min)
7. Trains 60k steps with `max_negative_weight: 1500` (~10 min)
8. Exports + evaluates

Watch the log for `[finetune] injected NNN user voice clips into positive_train/` — that's your confirmation the voice mixing worked.

### 6. Pull the model into the app

```bash
./training/fetch_model.sh
```

Writes `hey_aira.onnx` into `HandsFree/Resources/`. Then:

1. Edit [`WakeWordEngine.swift:17-21`](../HandsFree/Core/WakeWordEngine.swift#L17):
   ```swift
   static let bundledClassifierName = "hey_aira"
   static let wakePhrase = "Hey Aira"
   ```
2. `xcodegen generate`
3. `xcodebuild -project HandsFree.xcodeproj -scheme HandsFree -configuration Release build`
4. Launch: `open ~/Library/Developer/Xcode/DerivedData/HandsFree-*/Build/Products/Release/HandsFree.app`
5. Settings → Wake word → toggle on + test

Adjust **Sensitivity** in Settings if needed. 0.50 is the default; lower to 0.40
in noisy environments, raise to 0.60 if false triggers bug you.

### 7. Iterate if needed

A single fine-tune is ~$3. If the model misses attempts, you can:

- **Add more training clips** targeting the missing style (e.g. 20 more "tired voice" clips), re-upload with `--force`, re-run `finetune`
- **Lower the Sensitivity slider in Settings** — this doesn't need a new model
- **Drop `max_negative_weight` to 1000** in `configs/hey_aira_finetune.yaml` and re-train — lets the model output higher confidence

---

## Path B — Generic synthetic-only training

This is here for completeness — if you're shipping to strangers whose voices
you can't record. Expect the model to be less reliable than a voice-tuned one.

```bash
# Same prerequisites as Path A (modal token, create volume)
modal run --detach training/modal_train.py::run --config training/configs/hey_aira.yaml
```

Takes ~3–4 h on L40S, costs ~$6–8.

For faster iteration on the phonetic-neighbor list without a full re-run, use
the **budget** config with parallelized stages — reuses cached TTS if available:

```bash
modal run --detach training/modal_train.py::run --config training/configs/hey_aira_budget.yaml --resume-from augment
```

---

## What's in here

| File / folder | Purpose |
|---|---|
| [`modal_train.py`](modal_train.py) | Modal app — image, volumes, `run` / `finetune` / `fetch` / `shell` entrypoints |
| [`patches/parallel_augment.py`](patches/parallel_augment.py) | Monkey-patches LiveKit's single-threaded augment + feature-extraction loops to use `multiprocessing.Pool` — ~90× speedup on 32-CPU containers |
| [`configs/hey_aira_finetune.yaml`](configs/hey_aira_finetune.yaml) | Voice fine-tune config (Path A, **default**) |
| [`configs/hey_aira_budget.yaml`](configs/hey_aira_budget.yaml) | Production-quality generic run with speed tweaks |
| [`configs/hey_aira.yaml`](configs/hey_aira.yaml) | LiveKit-reference production config |
| [`configs/hey_aira_test.yaml`](configs/hey_aira_test.yaml) | 500-step smoke test — validates pipeline in ~15 min, produces an unusable model |
| [`voice/record.sh`](voice/record.sh) | Sox-based voice recording |
| [`voice/split.sh`](voice/split.sh) | Silence-based auto-split + normalize |
| [`voice/review.sh`](voice/review.sh) | Sequential clip playback for QA |
| [`voice/clean.sh`](voice/clean.sh) | Clean up `clips/` and/or `raw/` |
| [`fetch_model.sh`](fetch_model.sh) | Pulls finished `.onnx` into `HandsFree/Resources/` |

---

## Cost and time reference (Modal, L40S + 32 CPU)

All numbers are with the parallel patches applied. Setup (16 GB dataset
download) is one-time per Modal account.

| Stage | Voice fine-tune | Generic budget |
|---|---|---|
| Setup (cold) | 10–15 min | 10–15 min |
| Generate (25k pos + 25k neg) | 25–30 min | 25–30 min |
| Inject user clips | <1 sec | — |
| Augment (parallel, rounds=2) | 10–15 min | 10–15 min |
| Features (parallel) | 15–20 min | 15–20 min |
| Train | 10 min (60k steps) | 20 min (100k steps) |
| Export + eval | 5 min | 5 min |
| **Total (cold)** | **~75–95 min** | **~85–105 min** |
| **Cost (cold)** | **~$2.50–3.50** | **~$3.00–4.00** |

Warm runs (cached dataset, cached generate) are ~20 min faster.

---

## Why parallel patches matter

LiveKit's upstream `_augment_directory` and `extract_features_from_directory`
are single-threaded Python for-loops — on a 32-CPU Modal container, they pin
one core while the other 31 sit idle. At 2–3 clips/sec, augmentation of 50k
clips takes ~7 hours, and feature extraction on CPU-pinned ONNX sessions is
another ~4 hours.

Our `training/patches/parallel_augment.py` monkey-patches both with
`multiprocessing.Pool` at runtime. Measured speedups on live Modal runs:

- Augmentation: 2.3 clips/sec → 210 clips/sec (**~90× speedup**)
- Feature extraction: 3.5 clips/sec → ~60–100 clips/sec per worker × 32 workers

A draft upstream PR tracks this fix:
- [livekit/livekit-wakeword#??](https://github.com/livekit/livekit-wakeword) — see `training/patches/` for the reference implementation.

---

## Troubleshooting

**"0.125 CPU cores" / augmentation grinding at 2 clips/sec**: the parallel
patch didn't apply. Check that `modal_train.py` still runs `/patches/parallel_augment.py`
for the augment stage (not the upstream CLI).

**Generate reusing old clips with wrong phrases**: when `target_phrases` or
`custom_negative_phrases` changes, wipe the stale splits before re-running:

```bash
modal volume rm --recursive hey-aira-output hey_aira/negative_train
modal volume rm --recursive hey-aira-output hey_aira/negative_test
```

Positive_train can be left alone if the target phrase is unchanged.

**Model loads but scores stay near 0 on real voice**: that's TTS-domain-shift,
and fine-tuning with your voice (Path A) is the fix. Don't waste more Modal
credits on generic retrains — the ceiling is ~0.08 confidence without real
voice in training.

**Out of Modal credit mid-run**: the pipeline resumes cleanly. Add credit, then:

```bash
modal run --detach training/modal_train.py::run \
  --config training/configs/hey_aira_finetune.yaml \
  --resume-from <stage>   # whichever stage the log last logged
```

Valid stages: `generate`, `augment`, `train`, `export`, `eval`.

**Clips recorded at 48 kHz instead of 16 kHz**: `split.sh` now forces 16 kHz
mono int16 on output regardless of input rate. For old clip sets:

```bash
for f in training/voice/clips/clip_*.wav; do
    sox "$f" -r 16000 -c 1 -b 16 "${f}.tmp" && mv "${f}.tmp" "$f"
done
```

**RunPod instead of Modal**: RunPod is pay-as-you-go with $10 minimum top-up
and L40S at $0.86/hr (vs Modal's $1.95/hr). Porting requires a Dockerfile
that installs `espeak-ng ffmpeg sox libsndfile1 portaudio19-dev` plus
`livekit-wakeword[train,export,eval]`, then running the same scripts inside
the pod. Not documented here yet — happy path is Modal.

---

## Reference

- [LiveKit wake-word repo](https://github.com/livekit/livekit-wakeword) (vendored
  at `Vendor/livekit-wakeword/`, commit `515152a`)
- Upstream docs:
  [`training.md`](../Vendor/livekit-wakeword/docs/training.md),
  [`data-generation.md`](../Vendor/livekit-wakeword/docs/data-generation.md),
  [`export-and-inference.md`](../Vendor/livekit-wakeword/docs/export-and-inference.md)
- LiveKit's own SkyPilot reference: [`skypilot/train.yaml`](../Vendor/livekit-wakeword/skypilot/train.yaml) — L40S:1, cpus: 8+, memory: 32+ (we mirror this on Modal).
