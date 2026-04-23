"""
Train the "Hey Aira" wake-word model on Modal.com.

Usage (from the repo root):

    # Smoke test — run the whole pipeline with a tiny dataset (~20–30 min).
    modal run training/modal_train.py::run --config training/configs/hey_aira_test.yaml

    # Production overnight run (~8–14 h on an A100).
    modal run training/modal_train.py::run --config training/configs/hey_aira.yaml

    # When the run finishes, pull the ONNX back to the app's Resources/:
    modal run training/modal_train.py::fetch

Everything else (Piper VITS checkpoint, ACAV100M features, background noise,
RIRs) is downloaded once into a Modal volume and reused on every subsequent
run. The first training run therefore takes longer than later ones.

Design notes
------------
- Two volumes: `hey-aira-cache` for the ~16 GB of shared training data, and
  `hey-aira-output` for each run's output directory. The cache is read-write
  from every function (setup writes, train reads), the output volume holds
  the final `.onnx`.
- The LiveKit trainer drives everything through a single `run` CLI command:
  setup → generate → augment → train → export → eval. We invoke it via
  `subprocess` inside the Modal function so Modal doesn't need to know about
  the internal phases.
- GPU default is A100-40GB; override with `--gpu a10g` if you want to trade
  ~2× wall-clock time for ~1/3 the cost.
- We pin `livekit-wakeword` to the exact commit vendored as a submodule at
  `Vendor/livekit-wakeword` so the trained ONNX stays compatible with the
  Swift package the app links against.
"""

from __future__ import annotations

import pathlib
import subprocess

import modal

# Pin to the submodule commit so the trainer and the Swift runtime agree on
# every architectural detail. Update this when you bump the submodule.
LIVEKIT_WAKEWORD_REV = "515152ac7a445e242d1f962c3cf67bb77e07d059"

APP_NAME = "hey-aira-training"
CACHE_VOLUME = "hey-aira-cache"
OUTPUT_VOLUME = "hey-aira-output"

app = modal.App(APP_NAME)

image = (
    modal.Image.debian_slim(python_version="3.11")
    # Matches LiveKit's upstream SkyPilot reference (skypilot/train.yaml) —
    # these are the deps their augment/generate pipeline actually needs.
    .apt_install(
        "espeak-ng",       # phonemizer used by Piper VITS
        "ffmpeg",          # audio I/O
        "sox",             # used by the augment-phase DSP chain
        "libsndfile1",     # soundfile backend
        "portaudio19-dev", # pulled in by the listener extra (harmless here)
        "git",             # pip needs it to clone the LiveKit repo
        "curl",
    )
    # Torch wheels are big; pin CPU+CUDA support via the PyTorch index.
    .pip_install(
        "torch>=2.5,<2.8",
        "torchaudio>=2.5,<2.8",
        extra_index_url="https://download.pytorch.org/whl/cu124",
    )
    .pip_install(
        f"livekit-wakeword[train,export,eval] @ "
        f"git+https://github.com/livekit/livekit-wakeword.git@{LIVEKIT_WAKEWORD_REV}",
    )
    # NLTK / cmudict data the phonemizer reaches for at first use.
    .run_commands(
        "python -m nltk.downloader -d /usr/share/nltk_data cmudict averaged_perceptron_tagger",
    )
    # Ship our parallel-augmentation patch into the image. The upstream
    # `_augment_directory` in livekit-wakeword is a single-threaded Python
    # loop; `patches/parallel_augment.py` monkey-patches it with a
    # `multiprocessing.Pool` version so the 32-CPU allocation actually
    # earns its keep (10–20× real speedup).
    .add_local_file(
        "training/patches/parallel_augment.py",
        remote_path="/patches/parallel_augment.py",
        copy=True,
    )
)

cache_volume = modal.Volume.from_name(CACHE_VOLUME, create_if_missing=True)
output_volume = modal.Volume.from_name(OUTPUT_VOLUME, create_if_missing=True)

CACHE_MOUNT = "/cache"
OUTPUT_MOUNT = "/output"

# ---------------------------------------------------------------------------
# Main training entrypoint
# ---------------------------------------------------------------------------


@app.function(
    image=image,
    # L40S matches LiveKit's own skypilot/train.yaml reference. It's Ada
    # Lovelace (newer than A100 Ampere), often faster for small models, and
    # priced similarly on Modal. Override with gpu="A100-40GB" or "A10G" if
    # you have a reason.
    gpu="L40S",
    # Critical: Modal's default is ~0.125 cores, which starves the augment
    # phase (all-CPU audio DSP: reverb, SNR, mixing) and wastes GPU-hours
    # sitting idle. LiveKit's reference requests 8+; 32 cuts augment time
    # roughly in half vs 16 with negligible extra cost.
    cpu=32.0,
    # 48 GiB gives 1.5 GiB per core — plenty for parallel audio workers
    # during augmentation without hitting Modal's default memory cap.
    memory=48 * 1024,
    # (No ephemeral_disk override — Modal's default is plenty because both
    # the 16 GB dataset cache and all run outputs live on persistent
    # Volumes, not the container's scratch disk. Setting ephemeral_disk
    # requires a 512 GiB minimum per Modal's API, which we don't need.)
    volumes={CACHE_MOUNT: cache_volume, OUTPUT_MOUNT: output_volume},
    # Leave a fat margin — a cold production run is ~6 h on L40S + 16 CPU.
    timeout=60 * 60 * 20,
)
def train(
    config_yaml: str,
    run_setup: bool = True,
    resume_from: str = "generate",
    inject_user_clips: bool = False,
) -> str:
    """Execute the full training pipeline on Modal.

    ``config_yaml`` is the *contents* of the YAML file (not a path), so the
    caller can ship a local file directly without having to upload it into
    the Modal image beforehand.

    The config's `data_dir` and `output_dir` fields are rewritten to point
    inside the mounted volumes — anything the user set there locally is
    ignored so we always land data in the right place.
    """
    import os
    import shutil

    import yaml

    cfg = yaml.safe_load(config_yaml) or {}
    model_name = cfg.get("model_name") or "wakeword"
    cfg["data_dir"] = CACHE_MOUNT
    cfg["output_dir"] = OUTPUT_MOUNT

    # Augmentation paths reference the data dir; retarget them too.
    aug = cfg.setdefault("augmentation", {})
    aug["background_paths"] = [f"{CACHE_MOUNT}/backgrounds"]
    aug["rir_paths"] = [f"{CACHE_MOUNT}/rirs"]

    work_dir = pathlib.Path("/tmp/run")
    work_dir.mkdir(parents=True, exist_ok=True)
    config_path = work_dir / "config.yaml"
    with config_path.open("w") as f:
        yaml.safe_dump(cfg, f)

    print(f"[hey-aira] model_name={model_name}")
    print(f"[hey-aira] cache  volume → {CACHE_MOUNT}")
    print(f"[hey-aira] output volume → {OUTPUT_MOUNT}")
    print("[hey-aira] effective config:")
    print(config_path.read_text())

    # One-time setup: downloads Piper VITS checkpoint, ACAV100M features,
    # background noise clips, and room impulse responses into /cache.
    # Subsequent runs skip this (the files are already there).
    if run_setup:
        need_setup = not (
            (pathlib.Path(CACHE_MOUNT) / "backgrounds").exists()
            and (pathlib.Path(CACHE_MOUNT) / "rirs").exists()
        )
        if need_setup:
            print("[hey-aira] setup: downloading external datasets into /cache")
            _run(["livekit-wakeword", "setup", "--config", str(config_path)])
            cache_volume.commit()
        else:
            print("[hey-aira] setup: cache already populated, skipping download")

    # Pipeline stages. `resume_from` lets a caller skip earlier stages when
    # a prior run already produced those artifacts on the /output volume —
    # e.g. resume_from="augment" reuses the generated TTS clips from a
    # cancelled run and only reruns augment/train/export/eval.
    stages = ["generate", "augment", "train", "export", "eval"]
    if resume_from not in stages:
        raise ValueError(
            f"resume_from must be one of {stages}, got {resume_from!r}"
        )
    skip_until = stages.index(resume_from)
    for stage in stages[skip_until:]:
        print(f"[hey-aira] stage: {stage}")
        if stage == "augment":
            # If fine-tuning, copy the user voice clips (uploaded via
            # `modal volume put hey-aira-output training/voice/clips user_clips`)
            # into positive_train/ at indices starting after the synthetic set,
            # RIGHT BEFORE augment runs so they pick up the parallel DSP
            # pipeline + feature extraction identically to the synthetic ones.
            if inject_user_clips:
                _inject_user_clips(model_name)
                output_volume.commit()

            # Use our monkey-patched, multiprocessing-pool version instead
            # of the single-threaded upstream CLI.
            _run(["python", "/patches/parallel_augment.py", str(config_path)])
        else:
            _run(["livekit-wakeword", stage, str(config_path)])

    onnx_src = pathlib.Path(OUTPUT_MOUNT) / model_name / f"{model_name}.onnx"
    if not onnx_src.exists():
        # Some versions write to the model directory root — fall back to any
        # .onnx in the output dir so we still succeed.
        fallbacks = list((pathlib.Path(OUTPUT_MOUNT) / model_name).glob("*.onnx"))
        if not fallbacks:
            raise RuntimeError(f"no ONNX produced under {OUTPUT_MOUNT}/{model_name}")
        onnx_src = fallbacks[0]

    canonical = pathlib.Path(OUTPUT_MOUNT) / f"{model_name}.onnx"
    shutil.copy2(onnx_src, canonical)
    output_volume.commit()

    size_kb = canonical.stat().st_size / 1024
    print(f"[hey-aira] ✅ done — {canonical} ({size_kb:.0f} KB)")
    return str(canonical)


# ---------------------------------------------------------------------------
# Local entrypoints — the things you invoke with `modal run …::name`
# ---------------------------------------------------------------------------


@app.local_entrypoint()
def run(
    config: str = "training/configs/hey_aira.yaml",
    skip_setup: bool = False,
    resume_from: str = "generate",
):
    """Kick off a training run. `config` is a path on your local machine.

    `resume_from` defaults to "generate" (run the full pipeline). Set it to
    "augment" to reuse TTS clips from a cancelled prior run, or later
    stages ("train", "export", "eval") to resume even further along.
    """
    config_path = pathlib.Path(config)
    if not config_path.exists():
        raise SystemExit(f"config not found: {config_path}")
    yaml_text = config_path.read_text()
    remote_path = train.remote(
        yaml_text,
        run_setup=not skip_setup,
        resume_from=resume_from,
    )
    print(f"\nFinished. Remote path: {remote_path}")
    print("Run `modal run training/modal_train.py::fetch` to download it.")


@app.local_entrypoint()
def finetune(
    config: str = "training/configs/hey_aira_finetune.yaml",
    skip_setup: bool = False,
):
    """Full-pipeline training with your voice clips added as positives.

    Pre-requisite: run
        modal volume put hey-aira-output training/voice/clips user_clips

    once to upload the clips from training/voice/clips/ onto the Modal
    `hey-aira-output` volume at `/output/user_clips/`. This entrypoint then
    copies them into positive_train/ at indices 25000+ right before the
    augment stage, so they get augmented + feature-extracted alongside the
    synthetic TTS positives.
    """
    config_path = pathlib.Path(config)
    if not config_path.exists():
        raise SystemExit(f"config not found: {config_path}")
    yaml_text = config_path.read_text()
    remote_path = train.remote(
        yaml_text,
        run_setup=not skip_setup,
        resume_from="generate",
        inject_user_clips=True,
    )
    print(f"\nFinished. Remote path: {remote_path}")
    print("Run `./training/fetch_model.sh` to download it into the app.")


@app.function(
    image=image,
    volumes={OUTPUT_MOUNT: output_volume},
    timeout=300,
)
def _read_onnx(model_name: str) -> bytes:
    path = pathlib.Path(OUTPUT_MOUNT) / f"{model_name}.onnx"
    if not path.exists():
        raise FileNotFoundError(f"{path} — did the training run finish?")
    return path.read_bytes()


@app.local_entrypoint()
def fetch(model_name: str = "hey_aira", dest: str = "HandsFree/Resources/hey_aira.onnx"):
    """Pull the trained ONNX out of the Modal volume and into the app.

    Defaults drop the file exactly where WakeWordEngine.swift expects it.
    """
    data = _read_onnx.remote(model_name)
    dest_path = pathlib.Path(dest)
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    dest_path.write_bytes(data)
    print(f"Wrote {len(data) / 1024:.0f} KB → {dest_path}")
    print("Next: update WakeWordEngine.swift bundledClassifierName/wakePhrase, then rebuild.")


@app.local_entrypoint()
def shell():
    """Drop into a container for ad-hoc debugging (volumes mounted)."""
    _debug_shell.remote()


@app.function(
    image=image,
    gpu="A10G",
    volumes={CACHE_MOUNT: cache_volume, OUTPUT_MOUNT: output_volume},
    timeout=3600,
)
def _debug_shell():
    import os
    print("cache /cache contents:")
    _run(["ls", "-lh", CACHE_MOUNT], check=False)
    print("output /output contents:")
    _run(["ls", "-lh", OUTPUT_MOUNT], check=False)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _inject_user_clips(model_name: str) -> int:
    """Copy user voice clips from /output/user_clips/ into
    /output/<model_name>/positive_train/ at indices continuing after the
    synthetic TTS clips (so the augment + feature extraction stages treat
    them as additional positives).

    Returns the number of clips copied. Called from inside the train
    function, running in the Modal container with the output volume mounted.
    """
    import shutil

    src_dir = pathlib.Path(OUTPUT_MOUNT) / "user_clips"
    dst_dir = pathlib.Path(OUTPUT_MOUNT) / model_name / "positive_train"

    if not src_dir.exists():
        print(f"[finetune] WARNING: {src_dir} not found — did you run "
              f"`modal volume put hey-aira-output training/voice/clips user_clips`?")
        return 0

    dst_dir.mkdir(parents=True, exist_ok=True)

    user_clips = sorted(src_dir.glob("*.wav"))
    if not user_clips:
        print(f"[finetune] WARNING: no .wav files found in {src_dir}")
        return 0

    # Start indexing after whatever synthetic clips are already there.
    existing = sorted(dst_dir.glob("clip_*.wav"))
    next_idx = 25000  # safe floor past the synthetic set
    if existing:
        last_stem = existing[-1].stem  # "clip_024999"
        try:
            last_idx = int(last_stem.rsplit("_", 1)[-1])
            next_idx = max(next_idx, last_idx + 1)
        except (ValueError, IndexError):
            pass

    for i, src in enumerate(user_clips):
        dst = dst_dir / f"clip_{next_idx + i:06d}.wav"
        shutil.copy2(src, dst)

    print(f"[finetune] injected {len(user_clips)} user voice clips "
          f"into {dst_dir.name}/ at indices {next_idx}-{next_idx + len(user_clips) - 1}")
    return len(user_clips)


def _run(cmd: list[str], *, check: bool = True) -> None:
    """subprocess.run wrapper that streams stdout/stderr live. The LiveKit
    trainer prints its own rich progress; we just forward it."""
    print(f"[hey-aira] $ {' '.join(cmd)}")
    result = subprocess.run(cmd, check=check)
    if check and result.returncode != 0:
        raise RuntimeError(f"command failed with exit {result.returncode}: {cmd}")
