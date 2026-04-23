"""Parallel drop-in replacement for livekit-wakeword's augment stage.

The upstream `_augment_directory` in
`livekit/wakeword/data/augment.py` is a single-threaded Python for-loop.
Because of the GIL, adding CPU cores on Modal does nothing for the DSP
throughput — each clip is processed sequentially on a single core while the
other N-1 cores sit idle.

This wrapper:
    1. Defines a parallel version of `_augment_directory` that uses
       `multiprocessing.Pool` so each worker runs in its own Python process
       (sidesteps the GIL and actually uses every core we paid for).
    2. Monkey-patches it into the `augment` module *before* calling the same
       `run_augment()` + `run_extraction()` entrypoints the CLI uses, so the
       behavior is byte-for-byte identical otherwise.
    3. Invokes the normal feature extraction afterwards to match what
       `livekit-wakeword augment` would do.

Usage (same signature as the CLI command we're replacing):

    python training/patches/parallel_augment.py <config.yaml>

Run on a 32-CPU Modal container, the audio DSP stage drops from ~7 h to
~15–25 min for a 25k-positive / 25k-negative dataset. No submodule edits,
no CLI fork — just a function swap on an already-installed package.
"""

from __future__ import annotations

import os
import re
import sys
from multiprocessing import Pool, get_context
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# Worker-side state. Each Pool worker initializes its own `AudioAugmentor`
# (for augmentation) or ONNX sessions (for feature extraction) via the
# Pool's initializer so we never have to pickle parent-side instances.
# ---------------------------------------------------------------------------

_worker_augmentor = None
_worker_mel = None
_worker_emb = None


def _init_worker(
    background_files: list[str],
    rir_files: list[str],
    sample_rate: int,
) -> None:
    """Runs once per Pool worker. Rebuilds an AudioAugmentor from the
    already-expanded file lists — the upstream `__init__` globs a directory
    which we want to skip (the parent already did it)."""
    global _worker_augmentor
    from livekit.wakeword.data.augment import AudioAugmentor

    aug = AudioAugmentor.__new__(AudioAugmentor)
    aug.sample_rate = sample_rate
    aug.background_files = [Path(p) for p in background_files]
    aug.rir_files = [Path(p) for p in rir_files]
    aug._per_sample_aug = None   # lazy-built on first augment_clip()
    _worker_augmentor = aug


def _augment_one(job: tuple) -> None:
    """Process a single clip. Mirrors the body of the upstream loop at
    `augment.py:208-242` exactly — only the transport is different.
    """
    import soundfile as sf

    (
        wav_path_str,
        is_positive,
        round_idx,
        target_length,
        sample_rate,
    ) = job

    wav_path = Path(wav_path_str)
    augmentor = _worker_augmentor
    if augmentor is None:
        # Shouldn't happen — workers are initialized in _init_worker — but
        # fail loudly rather than silently producing wrong data.
        raise RuntimeError("Pool worker missing AudioAugmentor instance")

    audio, _sr = sf.read(str(wav_path))
    if audio.ndim > 1:
        audio = audio[:, 0]
    audio = audio.astype(np.float32)

    audio = augmentor.augment_clip(audio)
    audio = augmentor.apply_rir(audio)
    audio = augmentor.mix_with_background(audio)

    if round_idx == 0:
        if is_positive:
            from livekit.wakeword.data.augment import align_clip_to_end
            audio = align_clip_to_end(audio, target_length)
        else:
            if len(audio) < target_length:
                padded = np.zeros(target_length, dtype=np.float32)
                start = (target_length - len(audio)) // 2
                padded[start : start + len(audio)] = audio
                audio = padded
            elif len(audio) > target_length:
                start = (len(audio) - target_length) // 2
                audio = audio[start : start + target_length]

    orig_stem = re.sub(r"_r\d+$", "", wav_path.stem)
    out_path = wav_path.with_name(f"{orig_stem}_r{round_idx}.wav")
    sf.write(str(out_path), audio, sample_rate)


# ---------------------------------------------------------------------------
# Parallel replacement for livekit.wakeword.data.augment._augment_directory
# ---------------------------------------------------------------------------


def _parallel_augment_directory(
    clip_dir: Path,
    augmentor,               # AudioAugmentor — we only read its paths/sr
    is_positive: bool,
    target_duration_s: float = 2.0,
    sample_rate: int = 16000,
    round_idx: int = 0,
) -> None:
    from tqdm import tqdm

    target_length = int(target_duration_s * sample_rate)

    if round_idx == 0:
        src_re = re.compile(r"^clip_\d{6}\.wav$")
    else:
        src_re = re.compile(rf"^clip_\d{{6}}_r{round_idx - 1}\.wav$")

    wav_files = sorted(p for p in clip_dir.glob("*.wav") if src_re.match(p.name))
    if not wav_files:
        return

    n_workers = min(os.cpu_count() or 8, 32)
    chunksize = max(1, len(wav_files) // (n_workers * 16))

    # `fork` is faster to spawn than `spawn` and lets workers inherit any
    # already-imported modules. On Linux (Modal's containers are Linux) it's
    # the safe default and matches how most PyTorch/audio libraries expect
    # multiprocessing to behave.
    ctx = get_context("fork")

    # Workers don't need the fully-expanded file lists as Path objects —
    # strings survive pickling/forking without any surprises.
    bg_files = [str(p) for p in augmentor.background_files]
    rir_files = [str(p) for p in augmentor.rir_files]

    tasks = [
        (str(p), is_positive, round_idx, target_length, sample_rate)
        for p in wav_files
    ]

    with ctx.Pool(
        processes=n_workers,
        initializer=_init_worker,
        initargs=(bg_files, rir_files, augmentor.sample_rate),
    ) as pool:
        for _ in tqdm(
            pool.imap_unordered(_augment_one, tasks, chunksize=chunksize),
            total=len(tasks),
            desc=f"Augmenting {clip_dir.name} r{round_idx} ({n_workers}-way)",
            unit="clip",
        ):
            pass


# ---------------------------------------------------------------------------
# Parallel feature extraction (same pattern, but per-worker state is a pair
# of ONNX sessions for mel + speech embedding).
#
# Upstream `extract_features_from_directory` (features.py:31) is another
# single-threaded for-loop; worse, both ONNX sessions are hard-coded to
# `CPUExecutionProvider`. On a 32-CPU container that gives ~3.5 clips/sec.
# Wrapping in a Pool where each worker runs ONE-threaded ONNX (to avoid
# 32×N thread explosion) gets us ~60–100 clips/sec.
# ---------------------------------------------------------------------------


def _init_feature_worker(mel_path: str, emb_path: str) -> None:
    """Runs once per Pool worker. Builds its own ONNX sessions and forces
    each session to a single intra-op thread — otherwise 32 workers × the
    default auto-detect would spawn ~1000 threads and thrash."""
    global _worker_mel, _worker_emb

    import onnxruntime as ort
    from livekit.wakeword.models.feature_extractor import (
        MelSpectrogramFrontend,
        SpeechEmbedding,
    )

    opts = ort.SessionOptions()
    opts.intra_op_num_threads = 1
    opts.inter_op_num_threads = 1

    # MelSpectrogramFrontend / SpeechEmbedding build their own sessions in
    # __init__ without exposing SessionOptions. Build the sessions first,
    # then swap them in on fresh instances via __new__.
    mel = MelSpectrogramFrontend.__new__(MelSpectrogramFrontend)
    mel._onnx_session = ort.InferenceSession(
        mel_path, sess_options=opts, providers=["CPUExecutionProvider"]
    )
    mel._input_name = mel._onnx_session.get_inputs()[0].name

    emb = SpeechEmbedding.__new__(SpeechEmbedding)
    emb._session = ort.InferenceSession(
        emb_path, sess_options=opts, providers=["CPUExecutionProvider"]
    )
    emb._input_name = emb._session.get_inputs()[0].name

    _worker_mel = mel
    _worker_emb = emb


def _extract_features_one(wav_path_str: str) -> np.ndarray:
    """Mirrors the body of the upstream loop at features.py:55-63 —
    audio → mel → embeddings → pad/truncate to N_EMBEDDING_TIMESTEPS."""
    import soundfile as sf
    from livekit.wakeword.data.features import _pad_or_truncate

    assert _worker_mel is not None and _worker_emb is not None, "worker not initialized"

    audio, _sr = sf.read(wav_path_str)
    if audio.ndim > 1:
        audio = audio[:, 0]
    audio = audio.astype(np.float32)

    mel = _worker_mel(audio)
    embeddings = _worker_emb.extract_embeddings(mel)
    return _pad_or_truncate(embeddings[0])   # (16, 96)


def _parallel_extract_features_from_directory(
    clip_dir: Path,
    mel_frontend,       # upstream passes one — we ignore, workers build their own
    speech_embedding,   # same
) -> np.ndarray:
    """Parallel drop-in for livekit.wakeword.data.features.extract_features_from_directory."""
    from tqdm import tqdm
    from livekit.wakeword.data.features import N_EMBEDDING_TIMESTEPS
    from livekit.wakeword.resources import get_embedding_model_path, get_mel_model_path

    _aug_re = re.compile(r"^clip_\d{6}_r\d+\.wav$")
    wav_files = sorted(p for p in clip_dir.glob("*.wav") if _aug_re.match(p.name))
    if not wav_files:
        return np.zeros((0, N_EMBEDDING_TIMESTEPS, 96), dtype=np.float32)

    n_workers = min(os.cpu_count() or 8, 32)
    chunksize = max(1, len(wav_files) // (n_workers * 16))
    ctx = get_context("fork")

    mel_path = str(get_mel_model_path())
    emb_path = str(get_embedding_model_path())

    task_args = [str(p) for p in wav_files]

    features: list[np.ndarray] = []
    with ctx.Pool(
        processes=n_workers,
        initializer=_init_feature_worker,
        initargs=(mel_path, emb_path),
    ) as pool:
        # Use `map` (ordered) to preserve the sorted-by-filename order the
        # upstream loop relied on — downstream feature files expect
        # deterministic per-clip ordering across splits.
        for feat in tqdm(
            pool.imap(_extract_features_one, task_args, chunksize=chunksize),
            total=len(task_args),
            desc=f"Features {clip_dir.name} ({n_workers}-way)",
            unit="clip",
        ):
            features.append(feat)

    return np.stack(features, axis=0)   # (N, 16, 96)


# ---------------------------------------------------------------------------
# Entrypoint: monkey-patch and delegate to the upstream stage functions.
# ---------------------------------------------------------------------------


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: parallel_augment.py <config.yaml>", file=sys.stderr)
        return 2

    config_path = sys.argv[1]

    # Import AFTER we're ready — imports have side effects (logger setup,
    # audio backend probing) and we want a clean error if livekit-wakeword
    # isn't installed yet.
    import livekit.wakeword.data.augment as _aug_mod
    import livekit.wakeword.data.features as _feat_mod
    from livekit.wakeword.config import load_config
    from livekit.wakeword.data.augment import run_augment
    from livekit.wakeword.data.features import run_extraction

    n_workers = min(os.cpu_count() or 8, 32)

    # Swap in the parallel augment version. `run_augment` looks up
    # `_augment_directory` via module namespace (augment.py:167) so this
    # replacement takes effect immediately.
    _aug_mod._augment_directory = _parallel_augment_directory
    print(f"[parallel_augment] patched _augment_directory → Pool({n_workers})")

    # Same pattern for feature extraction: `run_extraction` calls
    # `extract_features_from_directory` via module namespace (features.py:97).
    _feat_mod.extract_features_from_directory = _parallel_extract_features_from_directory
    print(f"[parallel_augment] patched extract_features_from_directory → Pool({n_workers})")

    config = load_config(config_path)

    print(f"[parallel_augment] run_augment for model_name={config.model_name}")
    run_augment(config)

    print(f"[parallel_augment] run_extraction (feature extraction through frozen embedder)")
    run_extraction(config)

    print("[parallel_augment] done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
