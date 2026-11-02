"""reawarp beat detector backend, using Beat This! (CPJKU, ISMIR 2024).

Usage:
  python reawarp_beat_this.py INPUT.wav OUTPUT.txt [CHECKPOINT]
  python reawarp_beat_this.py --download [CHECKPOINT]

INPUT.wav is a mono or stereo 16-bit PCM file written by reawarp. OUTPUT.txt gets
two lines of times in seconds:
  beats <t1> <t2> ...
  downbeats <t1> <t2> ...
On failure, OUTPUT.txt gets a line "error <message>" and the exit code is 1.

The model is stored next to this file (models/), so removing the backend folder
removes everything.

Copyright (C) 2026 Gabriel Schuck. GPL-3.0-or-later (see LICENSE).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault("TORCH_HOME", os.path.join(HERE, "models"))

DEFAULT_CHECKPOINT = "final0"


def read_wav(path):
    import wave

    import numpy as np

    with wave.open(path, "rb") as w:
        sr, nch, width, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        raw = w.readframes(n)
    if width != 2:
        raise ValueError(f"expected 16-bit PCM, got {8 * width}-bit")
    y = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if nch > 1:
        y = y.reshape(-1, nch).mean(axis=1)
    return y, sr


def refine(times, logits, fps=50):
    """Sub-frame beat times: parabolic interpolation of the logit peak.

    The model works on 20 ms frames; at fast tempos that rounding alone makes
    consecutive beat intervals vary by several percent.
    """
    import numpy as np

    lg = logits.detach().float().cpu().numpy().ravel() if hasattr(logits, "detach") else np.ravel(logits)
    out = []
    for t in times:
        k = int(round(t * fps))
        if 0 < k < len(lg) - 1:
            a, b, c = lg[k - 1], lg[k], lg[k + 1]
            den = a - 2 * b + c
            if den < 0:
                t = (k + max(-0.5, min(0.5, 0.5 * (a - c) / den))) / fps
        out.append(float(t))
    return out


def main(argv):
    if len(argv) >= 1 and argv[0] == "--download":
        from beat_this.inference import load_checkpoint

        load_checkpoint(argv[1] if len(argv) > 1 else DEFAULT_CHECKPOINT)
        print("model ready")
        return 0
    if len(argv) < 2:
        print(__doc__)
        return 2
    src, dst = argv[0], argv[1]
    checkpoint = argv[2] if len(argv) > 2 else DEFAULT_CHECKPOINT
    try:
        import torch
        from beat_this.inference import Audio2Frames, Postprocessor

        torch.set_num_threads(max(1, os.cpu_count() or 1))
        y, sr = read_wav(src)
        beat_logits, down_logits = Audio2Frames(checkpoint_path=checkpoint, device="cpu")(y, sr)
        beats, downbeats = Postprocessor(type="minimal")(beat_logits, down_logits)
        beats = refine(beats, beat_logits)
        downbeats = [min(beats, key=lambda b: abs(b - d)) for d in downbeats] if len(beats) else []
        with open(dst, "w", encoding="utf-8") as f:
            f.write("beats " + " ".join(f"{t:.6f}" for t in beats) + "\n")
            f.write("downbeats " + " ".join(f"{t:.6f}" for t in downbeats) + "\n")
        return 0
    except Exception as e:  # report to reawarp, which falls back to its own detector
        with open(dst, "w", encoding="utf-8") as f:
            f.write("error " + f"{type(e).__name__}: {e}".replace("\n", " ") + "\n")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
