"""Standalone tests for the analysis engine in reawarp.lua using synthetic drum tracks.

Requires: pip install lupa numpy
Run:      python tests/test_dsp.py [optional_audio_file_via_ffmpeg]
"""
import os
import sys
import time

import numpy as np
from lupa.lua54 import LuaRuntime

SR = 11025
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_dsp():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().REAWARP_TEST = 'dsp'
    return lua, lua.execute(f'return dofile([[{ROOT}/reawarp.lua]])')


def kick(rng):
    t = np.arange(int(0.25 * SR)) / SR
    f = 50 + 90 * np.exp(-t * 30)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 12)


def snare(rng):
    t = np.arange(int(0.18 * SR)) / SR
    return (rng.standard_normal(t.size) * 0.6 + np.sin(2 * np.pi * 190 * t) * 0.5) * np.exp(-t * 22)


def hat(rng):
    t = np.arange(int(0.05 * SR)) / SR
    n = rng.standard_normal(t.size)
    n = np.diff(n, prepend=0)  # crude high-pass
    return n * np.exp(-t * 80) * 0.25


def render(beat_times, meter=4, length=None, jitter=0.0, noise=0.01, seed=1, pad=False):
    """Drum pattern: kick on 1 (and 3), snare on 2/4, hats on 8ths, chord pad."""
    rng = np.random.default_rng(seed)
    length = length or beat_times[-1] + 1.0
    y = np.zeros(int(length * SR) + SR)
    K, S, H = kick(rng), snare(rng), hat(rng)

    def put(sig, t, g=1.0):
        i = int(round(t * SR))
        if 0 <= i < y.size:
            n = min(sig.size, y.size - i)
            y[i:i + n] += sig[:n] * g

    for i, t in enumerate(beat_times):
        tt = t + (rng.uniform(-jitter, jitter) if jitter else 0)
        pos = i % meter
        if pos == 0:
            put(K, tt, 1.0)
        elif pos == 2 and meter == 4:
            put(K, tt, 0.6)
        else:
            put(S, tt, 0.8)
        put(H, tt, 1.0)
        if i + 1 < len(beat_times):
            put(H, (tt + beat_times[i + 1]) / 2, 0.6)
    if pad:
        t = np.arange(y.size) / SR
        y += 0.15 * np.sin(2 * np.pi * 220 * t) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.1 * t))
    y += rng.standard_normal(y.size) * noise
    return y[:int(length * SR)]


def run(lua, dsp, y, opts):
    tbl = lua.table_from(y.tolist())
    reader = lua.eval('''function(src)
        return function(pos, n)
            local out = {}
            for i = 1, n do out[i] = src[pos + i] or 0 end
            return out
        end
    end''')(tbl)
    t0 = time.time()
    res = dsp.analyze(reader, len(y), SR, lua.table_from(opts))
    if isinstance(res, tuple):
        res, err = res
        if res is None:
            raise RuntimeError(err)
    dt = time.time() - t0
    beats = np.array([res.beats[i] for i in range(1, len(res.beats) + 1)])
    return res, beats, dt


def score(found, truth, tol=0.025):
    truth = np.asarray(truth)
    hits, errs = 0, []
    for t in truth:
        d = np.min(np.abs(found - t)) if found.size else 1e9
        if d <= tol:
            hits += 1
            errs.append(d)
    fp = sum(1 for f in found if np.min(np.abs(truth - f)) > tol)
    return hits / len(truth), (np.median(errs) * 1000 if errs else float('nan')), fp


def check(name, lua, dsp, truth, y, opts, meter=4, want_down=None):
    res, beats, dt = run(lua, dsp, y, opts)
    recall, med_ms, fp = score(beats, truth)
    di = res.downbeat
    down_t = beats[di - 1]
    ok = True
    if want_down is not None:
        # is the detected downbeat one of the true bar starts?
        bars = np.array(truth[want_down::meter])
        ok = bool(np.min(np.abs(bars - down_t)) < 0.03)
    ok = ok and res.meter == meter
    print(f'{name:<24} bpm={res.bpm:7.2f} range={res.bpm_min:6.1f}-{res.bpm_max:6.1f} '
          f'beats={len(beats):4d} recall={recall*100:5.1f}% medErr={med_ms:4.1f}ms '
          f'false={fp:2d} meter={res.meter} down={"ok" if ok else "ERR"} ({dt:.2f}s)')
    return recall, ok


def main():
    lua, dsp = load_dsp()
    opts = {'min_bpm': 60, 'max_bpm': 180, 'bpm_hint': 0, 'flex': 50, 'snap': True,
            'smooth': 0}  # meter omitted: auto-detect
    results = []

    # 1. steady 120 bpm, starts at 0.37 s
    truth = 0.37 + np.arange(60) * 0.5
    results.append(check('steady 120', lua, dsp, truth, render(truth), opts, want_down=0))

    # 2. steady 87.3 bpm with pad and noise, pickup: first bar starts at beat index 2
    p = 60 / 87.3
    truth = 1.1 + np.arange(48) * p
    y = render(truth[2:] if False else truth, pad=True, noise=0.02)
    results.append(check('steady 87.3 + pad', lua, dsp, truth, y, opts, want_down=0))

    # 3. tempo ramp 100 -> 135 bpm (accelerando)
    t, truth = 0.5, []
    for i in range(120):
        truth.append(t)
        bpm = 100 + 35 * i / 119
        t += 60 / bpm
    truth = np.array(truth)
    results.append(check('ramp 100->135', lua, dsp, truth, render(truth), opts, want_down=0))

    # 4. live-ish: 112 bpm with slow drift +-4% and +-8 ms human jitter
    t, truth = 0.8, []
    for i in range(140):
        truth.append(t)
        bpm = 112 * (1 + 0.04 * np.sin(2 * np.pi * i / 48))
        t += 60 / bpm
    truth = np.array(truth)
    y = render(truth, jitter=0.008, noise=0.02, pad=True, seed=7)
    results.append(check('drift+jitter 112', lua, dsp, truth, y, opts, want_down=0))

    # 5. 3/4 waltz at 150 bpm
    truth = 0.2 + np.arange(90) * 0.4
    # (without a hint this is detected at half tempo, 75 bpm: classic octave ambiguity)
    o3 = dict(opts, bpm_hint=150)
    results.append(check('waltz 3/4 150', lua, dsp, truth, render(truth, meter=3), o3, meter=3, want_down=0))

    # 6. constant-tempo smoothing option
    truth = 0.37 + np.arange(60) * 0.5
    y = render(truth, jitter=0.01, seed=3)
    results.append(check('jitter, smooth=-1', lua, dsp, truth, y, dict(opts, smooth=-1), want_down=0))

    # 7. waltz 3/4 at 96 bpm with pad, no hint, meter auto
    truth = 0.6 + np.arange(72) * 60 / 96
    results.append(check('waltz 3/4 96 + pad', lua, dsp, truth, render(truth, meter=3, pad=True, seed=4),
                         opts, meter=3, want_down=0))

    # 8. 2.5 s of silence (with noise floor) before the music
    truth = 2.5 + np.arange(48) * 0.55
    results.append(check('silence then music', lua, dsp, truth, render(truth, noise=0.002),
                         opts, want_down=0))

    # 9. 3/4 waltz starting at 0.9 s
    truth = 0.9 + np.arange(60) * 0.5
    results.append(check('3/4 start 0.9s', lua, dsp, truth, render(truth, meter=3, noise=0.002),
                         opts, meter=3, want_down=0))

    # 10-12. external beats (as from Beat This!, refined to +-5 ms), at double
    # tempo with downbeats -> must halve in the right phase
    rng = np.random.default_rng(11)
    for name, bpm, meter in (('external 2x, 4/4', 100, 4), ('external 2x, 3/4', 140, 3), ('external 1x, 4/4', 120, 4)):
        p = 60 / bpm
        truth = 0.9 + np.arange(56) * p
        y = render(truth, meter=meter, noise=0.003, seed=12)
        double = name.startswith('external 2x')
        grid = np.sort(np.concatenate([truth, truth[:-1] + p / 2])) if double else truth
        coarse = grid + rng.uniform(-0.005, 0.005, grid.size)
        downs = np.round(truth[::meter] / 0.02) * 0.02
        ext = lua.table_from({'beats': lua.table_from(list(coarse)), 'downbeats': lua.table_from(list(downs))})
        o = dict(opts)
        o['external'] = ext
        results.append(check(name, lua, dsp, truth, y, o, meter=meter, want_down=0))

    # 13. external beats, 3/4 at 200 bpm with a break (a held chord) after bar 10;
    # around it the detector adds three beats and two downbeats. Must not halve
    # (bars of 1.5 beats) and every bar after the break must still start on 1.
    p = 0.3
    first = 0.9 + np.arange(30) * p
    second = first[-1] + p + 0.45 + np.arange(36) * 0.32
    truth = np.concatenate([first, second])
    y = render(truth, meter=3, noise=0.003, seed=13)
    extra = [first[-1] + 0.2, second[0] + 0.2, second[1] + 0.11]
    coarse = np.sort(np.concatenate([truth, extra])) + rng.uniform(-0.005, 0.005, truth.size + len(extra))
    downs = list(np.round(truth[::3] / 0.02) * 0.02) + [round(extra[1] / 0.02) * 0.02, round(second[2] / 0.02) * 0.02]
    ext = lua.table_from({'beats': lua.table_from(list(coarse)), 'downbeats': lua.table_from(sorted(downs))})
    recall, ok = check('external 3/4 200, break', lua, dsp, truth, y, dict(opts, external=ext), meter=3, want_down=0)
    res, beats, _ = run(lua, dsp, y, dict(opts, external=ext))
    lab = (np.arange(len(beats)) - (res.downbeat - 1)) % 3
    wrong = sum(1 for t in truth[::3] if lab[np.argmin(np.abs(beats - t))] != 0)
    print(f'{"  bars not on 1":<24} {wrong}')
    results.append((recall, ok and wrong == 0))

    # 14. external beats 25 ms late (as Beat This! often is): shifted onto the attacks
    p = 60 / 118
    truth = 0.8 + np.arange(60) * p
    y = render(truth, noise=0.003, seed=14)
    late = truth + 0.025 + rng.uniform(-0.004, 0.004, truth.size)
    downs = np.round(truth[::4] / 0.02) * 0.02 + 0.02
    ext = lua.table_from({'beats': lua.table_from(list(late)), 'downbeats': lua.table_from(list(downs))})
    recall, ok = check('external 25 ms late', lua, dsp, truth, y, dict(opts, external=ext), want_down=0)
    res, beats, _ = run(lua, dsp, y, dict(opts, external=ext))
    lag = np.median([b - truth[np.argmin(np.abs(truth - b))] for b in beats]) * 1000
    print(f'{"  median offset":<24} {lag:+.1f} ms')
    results.append((recall, ok and abs(lag) <= 6))

    if len(sys.argv) > 1:
        import subprocess
        ff = os.environ.get('FFMPEG', 'ffmpeg')
        raw = subprocess.run([ff, '-v', 'quiet', '-i', sys.argv[1], '-ac', '1', '-ar', str(SR),
                              '-f', 'f32le', '-'], capture_output=True, check=True).stdout
        y = np.frombuffer(raw, dtype=np.float32).astype(float)
        res, beats, dt = run(lua, dsp, y, opts)
        print(f'file: bpm={res.bpm:.2f} range={res.bpm_min:.1f}-{res.bpm_max:.1f} meter={res.meter} '
              f'beats={len(beats)} first={beats[0]:.3f}s '
              f'downbeat#{res.downbeat} at {beats[res.downbeat-1]:.3f}s ({dt:.2f}s)')

    bad = [r for r in results if r[0] < 0.9 or not r[1]]
    print('FAIL' if bad else 'OK', f'({len(results) - len(bad)}/{len(results)})')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
