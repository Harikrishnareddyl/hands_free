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
    .apt_install(
        "espeak-ng",       # phonemizer used by Piper VITS
        "ffmpeg",          # audio I/O
        "portaudio19-dev", # pulled in by the listener extra (harmless here)
        "libsndfile1",     # soundfile backend
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
    gpu="A100-40GB",
    volumes={CACHE_MOUNT: cache_volume, OUTPUT_MOUNT: output_volume},
    # Leave a fat margin — a cold production run is ~14 h.
    timeout=60 * 60 * 20,
)
def train(config_yaml: str, run_setup: bool = True) -> str:
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

    # Full pipeline in one shot: generate → augment → train → export → eval.
    _run(["livekit-wakeword", "run", str(config_path)])

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
def run(config: str = "training/configs/hey_aira.yaml", skip_setup: bool = False):
    """Kick off a training run. `config` is a path on your local machine."""
    config_path = pathlib.Path(config)
    if not config_path.exists():
        raise SystemExit(f"config not found: {config_path}")
    yaml_text = config_path.read_text()
    remote_path = train.remote(yaml_text, run_setup=not skip_setup)
    print(f"\nFinished. Remote path: {remote_path}")
    print("Run `modal run training/modal_train.py::fetch` to download it.")


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


def _run(cmd: list[str], *, check: bool = True) -> None:
    """subprocess.run wrapper that streams stdout/stderr live. The LiveKit
    trainer prints its own rich progress; we just forward it."""
    print(f"[hey-aira] $ {' '.join(cmd)}")
    result = subprocess.run(cmd, check=check)
    if check and result.returncode != 0:
        raise RuntimeError(f"command failed with exit {result.returncode}: {cmd}")
