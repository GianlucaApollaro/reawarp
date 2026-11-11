"""End-to-end test of reawarp.lua against tests/mock_reaper.lua.

Song: 100 bpm drums (downbeat every 4 beats), project: 120 bpm 4/4.
"""
import os
import sys

import numpy as np
from lupa.lua54 import LuaRuntime

sys.path.insert(0, os.path.dirname(__file__))
from test_dsp import SR, render  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def setup(builtin=True):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f'package.path = [[{ROOT}/tests/?.lua;]] .. package.path')
    mock = lua.execute('return (require("mock_reaper"))')
    r = mock.new(lua.table_from({'bpm': 120}))
    if builtin:
        mock.P.ext['reawarpdetector'] = 'builtin'   # the simulator has no Beat This! backend
    lua.globals().reaper = r
    lua.globals().REAWARP_TEST = 'core'
    core = lua.execute(f'return dofile([[{ROOT}/reawarp.lua]])')
    return lua, mock, r, core


def lua_list(t):
    return [t[i] for i in range(1, len(t) + 1)]


def main():
    fails = []
    truth = 0.8 + np.arange(64) * 0.6  # 100 bpm in source seconds, truth[0] is a downbeat
    y = render(truth, noise=0.01, pad=True)

    # ---------- warp ----------
    lua, mock, r, core = setup()
    src = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
    offs = 0.5
    item = mock.add_item(3.1, src, offs, 30.0, 'song')
    core.run('analyze')
    take = item.take
    names = [(m.src, m.name) for m in lua_list(take.tm)]
    print('analyze:', len(names), 'markers, first:', names[:3])
    print('  msg:', mock.P.messages[1].split('\n')[0])
    core.run('warp')
    print('  msg:', mock.P.messages[2])
    X = item.D_POSITION
    sm = [(m.pos, m.src) for m in lua_list(take.sm)]
    grid_err, n_on_beats = [], 0
    for pos, s in sm:
        k = np.argmin(np.abs(truth - s))
        if abs(truth[k] - s) < 0.03:
            n_on_beats += 1
            T = X + pos
            grid_err.append(abs(T / 0.5 - round(T / 0.5)) * 0.5)
            if k % 4 == 0 and abs(T / 2.0 - round(T / 2.0)) * 2.0 > 0.003:
                fails.append(f'downbeat source {s:.3f} lands at {T:.3f}, not on a bar')
    print(f'warp: X={X:.3f} len={item.D_LENGTH:.3f} markers={len(sm)} on_beats={n_on_beats} '
          f'max_grid_err={max(grid_err)*1000:.2f}ms')
    if n_on_beats < 40 or max(grid_err) > 0.003:
        fails.append('warp markers not on project grid')
    # length check: whole source window preserved
    span = sm[-1][1] - sm[0][1]
    if abs((sm[0][1] - offs) - 0) > 1e-6 and sm[0][0] == 0:
        fails.append('first marker source mismatch')
    print(f'  source span covered by markers: {span:.3f}s (natural item length 30.000)')
    # pitch / timebase
    print('  B_PPITCH', take.B_PPITCH, 'I_PITCHMODE', take.I_PITCHMODE, 'C_BEATATTACHMODE', item.C_BEATATTACHMODE)

    # re-warp must be idempotent
    core.run('warp')
    sm2 = [(m.pos, m.src) for m in lua_list(take.sm)]
    if len(sm2) != len(sm) or max(abs(a[0] - b[0]) + abs(a[1] - b[1]) for a, b in zip(sm, sm2)) > 1e-9:
        fails.append('re-warp not idempotent')

    # set downbeat at cursor: put cursor on the project time of source beat #6 (index 5)
    k = 5
    s5 = truth[k]
    pos5 = next(p for p, s in sm if abs(s - s5) < 0.03)
    mock.P.cursor = X + pos5 + 0.01
    core.run('downbeat')
    print('downbeat msg:', lua_list(mock.P.messages)[-1])
    lab = {round(m.src, 2): m.name for m in lua_list(take.tm)}
    nm = lab[min(lab, key=lambda q: abs(q - s5))]
    if not nm.endswith('.1'):
        fails.append(f'cursor downbeat not relabelled: {nm}')
    core.run('warp')
    X = item.D_POSITION
    T5 = X + next(m.pos for m in lua_list(take.sm) if abs(m.src - s5) < 0.03)
    print(f'  after re-warp, source beat 6 at {T5:.3f}s (bar line? {abs(T5/2 - round(T5/2)) < 1e-3})')
    if abs(T5 / 2 - round(T5 / 2)) > 1e-3:
        fails.append('new downbeat not on bar')

    # restore
    core.run('restore')
    print('restore msg:', lua_list(mock.P.messages)[-1])

    # ---------- tempo map ----------
    # The project tempo must follow the song from the bar where the item starts,
    # so pickup beats and the intro are on the grid too (not only from beat 1 on).
    # A: the item starts with a downbeat. B: two pickup beats first. Both start
    # the tempo at the project start. C: an earlier tempo marker (another song)
    # must be kept, so the new tempo starts at the bar of the item start.
    for name, offs, earlier in (('downbeat first', 0.0, False), ('2-beat pickup', truth[2] - 0.3, False),
                                ('earlier marker kept', 0.0, True)):
        lua, mock, r, core = setup()
        if earlier:
            r.SetTempoTimeSigMarker(0, -1, 1.0, -1, -1, 130.0, 0, 0, False)
        src = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
        item = mock.add_item(3.1, src, offs, 30.0, 'song')
        core.run('tempo')
        print(f'tempo ({name}):', lua_list(mock.P.messages)[-1].split(chr(10))[0])
        tm = sorted((m.t, m.bpm) for m in lua_list(mock.P.tempo))
        newP = item.D_POSITION
        if earlier:
            if not tm or tm[0] != (1.0, 130.0):
                fails.append(f'tempo ({name}): earlier marker changed: {tm[:2]}')
            tm = tm[1:]
        elif tm[0][0] != 0:
            fails.append(f'tempo ({name}): tempo does not start at the project start ({tm[0][0]:.3f})')
        R, bpmR = tm[0]
        beats_in_bar, _, _, _, _ = r.TimeMap2_timeToBeats(0, R)
        print(f'  first marker {R:.3f}s at {bpmR:.2f} BPM (item now at {newP:.3f}), {len(tm)} markers')
        if R > newP + 1e-6 or abs(beats_in_bar) > 1e-6:
            fails.append(f'tempo ({name}): tempo does not start on the bar at/before the item ({R})')
        if abs(bpmR - 100) > 2:
            fails.append(f'tempo ({name}): tempo before the music is {bpmR:.2f}, not ~100')
        worst, worst_down = 0, 0
        for k, ts in enumerate(truth):
            t_item = ts - offs
            if t_item < 0 or t_item > 30:
                continue
            T = newP + t_item
            q = r.TimeMap2_timeToQN(0, T)
            worst = max(worst, abs(q - round(q)) * 0.6)  # in seconds at 100 BPM
            if k % 4 == 0:
                bib, _, _, _, _ = r.TimeMap2_timeToBeats(0, T)
                worst_down = max(worst_down, min(bib, 4 - bib) * 0.6)
        print(f'  max beat error {worst * 1000:.1f} ms, max downbeat-to-bar error {worst_down * 1000:.1f} ms')
        if worst > 0.01 or worst_down > 0.01:
            fails.append(f'tempo ({name}): beats off the grid ({worst * 1000:.1f} / {worst_down * 1000:.1f} ms)')

    # ---------- 3/4 song into a 4/4 project ----------
    truth3 = 1.0 + np.arange(60) * 0.5          # 120 bpm, bar = 3 beats, truth3[0] downbeat
    y3 = render(truth3, meter=3, noise=0.002)
    for answer in (6, 7):
        lua, mock, r, core = setup()
        mock.P.answer = answer
        src = lua.table_from({'sr': SR, 'samples': lua.table_from(y3.tolist())})
        item = mock.add_item(2.3, src, 0.0, 31.0, 'valsa')
        core.run('analyze')
        print('3/4 analyze:', ' | '.join(x.strip() for x in lua_list(mock.P.messages)[0].split(chr(10))[:2]))
        core.run('warp')
        print('  warp msg:', lua_list(mock.P.messages)[-1])
        X = item.D_POSITION
        sm = [(m.pos, m.src) for m in lua_list(item.take.sm)]
        sigs = [(m.t, m.num, m.den) for m in lua_list(mock.P.tempo) if m.num]
        # speed: project is 120 bpm like the song, so beats stay 0.5 s apart
        on = sorted(X + q for q, s_ in sm if np.min(np.abs(truth3 - s_)) < 0.03)
        spacing = np.median(np.diff(on))
        if abs(spacing - 0.5) > 1e-3:
            fails.append(f'3/4 warp changed speed: spacing {spacing:.4f}')
        if answer == 6:
            if not sigs or sigs[0][1:] != (3, 4):
                fails.append(f'3/4 signature not inserted: {sigs}')
            else:
                A = sigs[0][0]
                bad = [X + q for q, s_ in sm if np.min(np.abs(truth3[::3] - s_)) < 0.03
                       and abs((X + q - A) / 1.5 - round((X + q - A) / 1.5)) > 1e-3]
                if bad:
                    fails.append(f'3/4 downbeats off the 3/4 bars: {bad[:3]}')
                if len(sigs) < 2 or sigs[1][1:] != (4, 4) or sigs[1][0] < X + item.D_LENGTH - 1e-6:
                    fails.append(f'4/4 not restored after item: {sigs}')
            print(f'  yes: signatures {sigs}, asked={mock.P.asked}')
        elif sigs:
            fails.append('signature inserted although user said no')
        else:
            print(f'  no: no signature change, beat spacing {spacing:.3f}s')

    # ---------- double / halve the BPM on a tempo-mapped waltz ----------
    lua, mock, r, core = setup()
    src = lua.table_from({'sr': SR, 'samples': lua.table_from(y3.tolist())})
    item = mock.add_item(2.3, src, 0.0, 31.0, 'valsa')
    core.run('tempo')
    def state():
        tm = sorted((m.t, m.bpm) for m in lua_list(mock.P.tempo))
        rw = sorted((m.src, m.name) for m in lua_list(item.take.tm) if m.name.startswith('RW '))
        first1 = next(t for t, n in rw if n.endswith('.1') and not n.startswith('RW 0') and not n.startswith('RW -'))
        return np.median([b for _, b in tm]), len(rw), first1, item.D_POSITION
    b0, n0, d0, p0 = state()
    core.run('double')
    b1, n1, d1, p1 = state()
    print(f'double: {b0:.1f} -> {b1:.1f} BPM, markers {n0} -> {n1}, beat 1 at {d0:.3f} -> {d1:.3f}, item {p0:.3f} -> {p1:.3f}')
    print('  msg:', lua_list(mock.P.messages)[-1])
    core.run('halve')
    b2, n2, d2, p2 = state()
    print(f'halve:  {b1:.1f} -> {b2:.1f} BPM, markers {n1} -> {n2}, beat 1 at {d1:.3f} -> {d2:.3f}')
    if abs(b1 / b0 - 2) > 0.05 or abs(b2 - b0) > 1 or abs(d1 - d0) > 1e-6 or abs(d2 - d0) > 1e-6 or n1 < 2 * n0 - 2:
        fails.append('double/halve wrong')

    # ---------- double / halve with a warp: they act on the song's speed ----------
    # (the project tempo stays; "halve" makes a song that plays too fast play at half speed)
    lua, mock, r, core = setup()
    src = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
    item = mock.add_item(3.1, src, 0.0, 30.0, 'song')
    core.run('warp')
    def speed():
        sm = [(m.pos, m.src) for m in lua_list(item.take.sm)]
        rates = [(b[1] - a[1]) / (b[0] - a[0]) for a, b in zip(sm, sm[1:]) if b[0] > a[0]]
        _, _, bpm = r.TimeMap_GetTimeSigAtTime(0, item.D_POSITION + 5)
        return np.median(rates), bpm
    s0, b0 = speed()
    core.run('halve')
    s1, b1 = speed()
    core.run('double')
    s2, b2 = speed()
    print(f'warp halve/double: project {b0:.0f} -> {b1:.0f} -> {b2:.0f} BPM, song speed {s0:.3f} -> {s1:.3f} -> {s2:.3f}')
    print('  msg:', lua_list(mock.P.messages)[-2])
    if abs(b1 - b0) > 0.01 or abs(b2 - b0) > 0.01 or abs(s1 / s0 - 0.5) > 0.01 or abs(s2 - s0) > 0.01:
        fails.append('warp halve/double did not act on the song speed')

    # ---------- warp over a leftover tempo map: ask, then use a fixed tempo ----------
    for answer in (6, 7):
        lua, mock, r, core = setup()
        mock.P.answer = answer
        src = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
        item = mock.add_item(0.0, src, 0.0, 30.0, 'song')
        r.SetTempoTimeSigMarker(0, -1, 0.0, -1, -1, 120.0, 4, 4, False)
        t_ = 2.0
        for k in range(40):                      # a varying map, like a leftover tempo map
            r.SetTempoTimeSigMarker(0, -1, t_, -1, -1, 104.0 + 6 * (k % 2), 0, 0, False)
            t_ += 0.57
        asked0 = mock.P.asked or 0
        core.run('warp')
        tm = lua_list(mock.P.tempo)
        asked = (mock.P.asked or 0) - asked0
        print(f'warp over tempo map, answer {"yes" if answer == 6 else "no"}: asked {asked}x, {len(tm)} tempo markers left')
        if asked != 1 or (answer == 6 and len(tm) != 1) or (answer == 7 and len(tm) < 40):
            fails.append('warp over a tempo map: wrong question/result')
    # re-warping a waltz (only time-signature markers, same tempo) must not ask
    lua, mock, r, core = setup()
    src = lua.table_from({'sr': SR, 'samples': lua.table_from(y3.tolist())})
    item = mock.add_item(2.3, src, 0.0, 31.0, 'valsa')
    core.run('warp')
    asked0 = mock.P.asked or 0
    core.run('warp')
    again = (mock.P.asked or 0) - asked0
    print(f're-warp waltz: {again} question(s)')
    if again != 0:
        fails.append('re-warping a waltz asked a question')

    # ---------- Beat This! required: not installed -> ask, touch nothing ----------
    for answer in (6, 7):
        lua, mock, r, core = setup(builtin=False)
        mock.P.answer = answer
        opened = []
        # count only the installer (the NVIDIA check runs nvidia-smi: none here)
        r.ExecProcess = lambda cmd, timeout: ('1\n' if 'nvidia-smi' in cmd else opened.append(cmd) or '')
        src = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
        item = mock.add_item(1.0, src, 0.0, 20.0, 'song')
        core.run('warp')
        msg = lua_list(mock.P.messages)[-1]
        touched = len(lua_list(item.take.tm)) + len(lua_list(item.take.sm))
        print(f'no Beat This!, answer {"yes" if answer == 6 else "no"}: asked {mock.P.asked}x, installer opened {len(opened)}x, '
              f'item touched {touched}, msg: {msg[:80]}')
        if mock.P.asked != 1 or touched or len(opened) != (1 if answer == 6 else 0):
            fails.append('Beat This! requirement: wrong flow')

    # ---------- groove match: target keeps its start position P0 ----------
    lua, mock, r, core = setup()
    src_ref = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})       # 100 BPM
    src_tgt = lua.table_from({'sr': SR, 'samples': lua.table_from(y3.tolist())})      # 120 BPM
    ref_item = mock.add_item(0.0, src_ref, 0.0, 30.0, 'drums')
    tgt_item = mock.add_item(6.0, src_tgt, 0.0, 20.0, 'loop')
    core.run('match')
    print('match msg:', lua_list(mock.P.messages)[-1])
    if abs(tgt_item.D_POSITION - 6.0) > 1e-6:
        fails.append(f'match moved target item from 6.0 to {tgt_item.D_POSITION:.3f}')
    if len(lua_list(tgt_item.take.sm)) < 10:
        fails.append('match did not create stretch markers on target item')

    # ---------- follower items sync on warp + restore (opt-in via sync setting) ----------
    # Default sync=0: unselected overlapping item must NOT be touched or restored
    lua, mock, r, core = setup()
    src_g = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
    guide = mock.add_item(2.0, src_g, 0.0, 25.0, 'guide')
    other = mock.add_item(4.0, src_g, 0.0, 15.0, 'unrelated')
    mock.P.sel = lua.table_from([guide])
    core.run('warp')
    if len(lua_list(other.take.sm)) != 0:
        fails.append('sync=0 touched unselected overlapping item')
    # sync=1 (grouped items): only items in the same group follow and restore
    lua, mock, r, core = setup()
    mock.P.ext['reawarpsync'] = '1'
    src_g = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
    guide = mock.add_item(2.0, src_g, 0.0, 25.0, 'guide')
    grouped = mock.add_item(4.0, src_g, 0.0, 15.0, 'vocal')
    ungrouped = mock.add_item(4.0, src_g, 0.0, 15.0, 'fx')
    guide.I_GROUPID = 7
    grouped.I_GROUPID = 7
    mock.P.sel = lua.table_from([guide])
    core.run('warp')
    if len(lua_list(grouped.take.sm)) == 0 or len(lua_list(ungrouped.take.sm)) != 0:
        fails.append('sync=1 did not sync exclusively grouped items')
    core.run('restore')
    if not grouped.restored or not guide.restored or ungrouped.restored:
        fails.append('restore with sync=1 did not restore exclusively guide and grouped follower')

    # ---------- loop starting on its first beat: no stretch marker inside the attack ----------
    # (every beat, and automatic markers: the beats after the head must stay on the grid too)
    for every in ('1', '0'):
        lua, mock, r, core = setup()
        mock.P.ext['reawarpevery'] = every
        src_l = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
        lp = mock.add_item(1.0, src_l, truth[0] - 0.004, 24.0, 'loop')
        # the beats as the analysis would mark them (the simulator's built-in
        # detector misses a beat 4 ms into the item)
        for k in range(40):
            lp.take.tm[k + 1] = lua.table_from({'src': truth[k], 'name': f'RW {k // 4 + 1}.{k % 4 + 1}', 'col': 0})
        core.run('warp')
        sm = [(m.pos, m.src) for m in lua_list(lp.take.sm)]
        # the head plays at rate 1 (untouched by the stretching) past the attack
        head_rate = (sm[1][1] - sm[0][1]) / sm[1][0] if len(sm) > 1 else 0
        inside = [p for p, _ in sm if 1e-3 < p < 0.04] + ([] if abs(head_rate - 1) < 1e-6 else ['head not at rate 1'])
        # where each beat plays, in project time, and how far from the 120 bpm grid
        errs = []
        for src_t in truth[:40]:
            lo = max(k for k in range(len(sm)) if sm[k][1] <= src_t + 1e-9)
            a, b = sm[lo], sm[min(lo + 1, len(sm) - 1)]
            tt = lp.D_POSITION + a[0] + (src_t - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
            errs.append(abs(tt / 0.5 - round(tt / 0.5)) * 0.5)
        print(f'loop on its first beat (every {every}): first markers {[round(p, 4) for p, _ in sm[:3]]}, '
              f'{len(sm)} markers, beats up to {max(errs)*1000:.1f} ms from the grid')
        if inside or max(errs) > 0.002:
            fails.append(f'loop (every {every}): stretch marker inside the first attack, or beats off the grid')

    # ---------- tempo map with two selected items: the second is warped to the new map ----------
    lua, mock, r, core = setup()
    truth_b = 0.5 + np.arange(56) * 0.5                       # another song, 120 bpm
    y_b = render(truth_b, noise=0.01, pad=True)
    src_a = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
    src_b = lua.table_from({'sr': SR, 'samples': lua.table_from(y_b.tolist())})
    first = mock.add_item(1.0, src_a, 0.0, 30.0, 'song')
    second = mock.add_item(3.0, src_b, 0.0, 25.0, 'other')
    core.run('tempo')
    sm = [(m.pos, m.src) for m in lua_list(second.take.sm)]
    qerr = []
    for pos, s_ in sm:
        if np.min(np.abs(truth_b - s_)) < 0.03:
            q = r.TimeMap2_timeToQN(0, second.D_POSITION + pos)
            qerr.append(abs(q - round(q)))
    n_tm = len(lua_list(mock.P.tempo))
    print(f'tempo map + second item: {n_tm} tempo markers, second item {len(sm)} stretch markers, '
          f'beats off the grid by up to {max(qerr) if qerr else -1:.3f} beat')
    if n_tm < 10 or len(qerr) < 30 or max(qerr) > 0.02:
        fails.append('tempo map: the second selected item did not follow the new tempo map')

    # ---------- automatic stretch markers (every N = 0): only where the tempo changes ----------
    # steady 100 bpm for 32 beats, a ritardando to 80 bpm over 16 beats, then steady 80 bpm
    per = [0.6] * 32 + list(np.linspace(0.6, 0.75, 16)) + [0.75] * 32
    tb = 0.8 + np.concatenate([[0], np.cumsum(per)])
    yb = render(tb, noise=0.01, pad=True)
    for every in ('1', '0'):
        lua, mock, r, core = setup()
        mock.P.ext['reawarpevery'] = every
        src_b = lua.table_from({'sr': SR, 'samples': lua.table_from(yb.tolist())})
        it_b = mock.add_item(2.0, src_b, 0.0, tb[-1] + 0.5, 'rit')
        for k in range(len(tb)):
            it_b.take.tm[k + 1] = lua.table_from({'src': tb[k], 'name': f'RW {k // 4 + 1}.{k % 4 + 1}', 'col': 0})
        core.run('warp')
        sm = [(m.pos, m.src) for m in lua_list(it_b.take.sm)]
        # where every beat plays (project time), and how far from the 120 bpm grid
        errs = []
        for src_t in tb:
            lo = max(k for k in range(len(sm)) if sm[k][1] <= src_t + 1e-9)
            a, b = sm[lo], sm[min(lo + 1, len(sm) - 1)]
            tt = it_b.D_POSITION + a[0] + ((src_t - a[1]) * (b[0] - a[0]) / (b[1] - a[1]) if b[1] > a[1] else 0)
            errs.append(abs(tt / 0.5 - round(tt / 0.5)) * 0.5)
        print(f'stretch markers every {every}: {len(sm)} markers for {len(tb)} beats, '
              f'beats up to {max(errs)*1000:.1f} ms from the grid')
        if every == '0' and (len(sm) > 30 or max(errs) > 0.0125):
            fails.append('automatic stretch markers: too many markers or a beat off the grid')

    # ---------- tempo map from a ritardando song + a steady loop, automatic markers ----------
    # the loop is warped onto the varying tempo map: its beats must follow the map
    lua, mock, r, core = setup()
    mock.P.ext['reawarpevery'] = '0'
    src_s = lua.table_from({'sr': SR, 'samples': lua.table_from(yb.tolist())})
    src_l = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
    song = mock.add_item(2.0, src_s, 0.0, tb[-1] + 0.5, 'rit')
    loop = mock.add_item(2.0, src_l, truth[0] - 0.004, 36.0, 'loop')
    for k in range(len(tb)):
        song.take.tm[k + 1] = lua.table_from({'src': tb[k], 'name': f'RW {k // 4 + 1}.{k % 4 + 1}', 'col': 0})
    for k in range(60):
        loop.take.tm[k + 1] = lua.table_from({'src': truth[k], 'name': f'RW {k // 4 + 1}.{k % 4 + 1}', 'col': 0})
    core.run('tempo')

    def loop_check(label):
        sm = [(m.pos, m.src) for m in lua_list(loop.take.sm)]
        devs = []
        for src_t in truth[:60]:
            if src_t > sm[-1][1]:
                break
            lo = max(k for k in range(len(sm)) if sm[k][1] <= src_t + 1e-9)
            a, b = sm[lo], sm[min(lo + 1, len(sm) - 1)]
            tt = loop.D_POSITION + a[0] + ((src_t - a[1]) * (b[0] - a[0]) / (b[1] - a[1]) if b[1] > a[1] else 0)
            q = r.TimeMap2_timeToQN(0, tt)
            qlen = r.TimeMap2_QNToTime(0, round(q) + 1) - r.TimeMap2_QNToTime(0, round(q))
            devs.append(abs(q - round(q)) * qlen)
        head_rate = (sm[1][1] - sm[0][1]) / sm[1][0]
        print(f'loop {label}: {len(sm)} markers, head rate {head_rate:.3f}, '
              f'beats up to {max(devs)*1000:.1f} ms from the grid ({len(devs)} beats)')
        if max(devs) > 0.0125 or abs(head_rate - 1) > 1e-6:
            fails.append(f'loop {label}: beats off the grid, or its attack stretched')

    loop_check('on a ritardando tempo map (auto markers)')
    # then "Change song tempo" on the song: the loop is warped again onto the new map
    mock.P.sel = lua.table_from([song])
    r.GetUserInputs = lua.eval('function() return true, "110" end')
    core.run('retempo')
    loop_check('after changing the song tempo')

    # ---------- shift beats by half a beat (the detector marked the off-beats) ----------
    def src_to_proj(item, src_t):
        sm = [(m.pos, m.src) for m in lua_list(item.take.sm)]
        lo = max(k for k in range(len(sm)) if sm[k][1] <= src_t + 1e-9)
        a, b = sm[lo], sm[min(lo + 1, len(sm) - 1)]
        return item.D_POSITION + a[0] + ((src_t - a[1]) * (b[0] - a[0]) / (b[1] - a[1]) if b[1] > a[1] else 0)

    # case 1: an intro marked on the off-beats (half a beat early: a jump of 1.5 beat at beat 17)
    # case 2: beats 25..36 marked on the off-beats (half a beat late), fixed with a time selection
    # case 3: beats 25..35 on the off-beats and the beat after them missing (a jump of 1.5
    # beat at both edges), as Beat This! did in a song: the missing beat must be put back
    for case in ('intro', 'intro, cursor a beat late', 'intro, cursor two beats early', 'selection',
                 'selection, a beat missing'):
        lua, mock, r, core = setup()
        src_x = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
        sh = mock.add_item(1.0, src_x, 0.0, 38.0, 'song')
        marks = list(truth[:60])
        if case.startswith('intro'):
            for k in range(16):
                marks[k] = truth[k] - 0.3
            marks = marks[1:]      # the first off-beat would be before the item
        else:
            for k in range(24, 36):
                marks[k] = truth[k] + 0.3
            if case.endswith('missing'):
                del marks[35]
        for k, src_t in enumerate(marks):
            sh.take.tm[k + 1] = lua.table_from({'src': src_t, 'name': f'RW {k // 4 + 1}.{k % 4 + 1}', 'col': 0})
        core.run('warp')
        if case.startswith('intro'):
            # where the beats become right (or near it)
            at = {'intro': truth[16] - 0.05, 'intro, cursor a beat late': truth[16] + 0.1,
                  'intro, cursor two beats early': truth[14] - 0.1}[case]
            mock.P.cursor = src_to_proj(sh, at)
        else:
            mock.P.ts0, mock.P.ts1 = src_to_proj(sh, truth[24] + 0.15), src_to_proj(sh, truth[35] + 0.45)
        core.run('shift')
        print('  msg:', lua_list(mock.P.messages)[-1])
        offs_ms = []
        for src_t in truth[1:60]:
            if src_t < 38.0:
                tt = src_to_proj(sh, src_t)
                offs_ms.append(abs(tt / 0.5 - round(tt / 0.5)) * 500)
        print(f'shift half a beat ({case}): beats up to {max(offs_ms):.1f} ms from the grid')
        if max(offs_ms) > 3:
            fails.append(f'shift half a beat ({case}): beats still off the grid')
        nb = round((src_to_proj(sh, truth[48]) - src_to_proj(sh, truth[8])) / 0.5)
        if nb != 40:
            fails.append(f'shift half a beat ({case}): {nb} beats between beats 8 and 48, not 40')
        if case.endswith('missing') and round(src_to_proj(sh, truth[48]) / 2.0, 3) % 1 != 0:
            fails.append(f'shift half a beat ({case}): the bars after the stretch moved')

    # no jump at the edges: nothing changes
    lua, mock, r, core = setup()
    src_x = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
    sh = mock.add_item(1.0, src_x, 0.0, 38.0, 'song')
    for k in range(60):
        sh.take.tm[k + 1] = lua.table_from({'src': truth[k], 'name': f'RW {k // 4 + 1}.{k % 4 + 1}', 'col': 0})
    core.run('warp')
    before = [m.src for m in lua_list(sh.take.tm)]
    mock.P.cursor = src_to_proj(sh, truth[16]) - 0.05
    core.run('shift')
    if [m.src for m in lua_list(sh.take.tm)] != before:
        fails.append('shift half a beat: changed beats that had no jump')
    print('  no jump:', lua_list(mock.P.messages)[-1])

    # ---------- project tempo from item (fixed tempo, no tempo map) ----------
    for with_map in (False, True):
        lua, mock, r, core = setup()
        src_l = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
        # a 100 bpm loop of 4 bars (16 beats), starting 4 ms before its first beat
        lp = mock.add_item(1.3, src_l, truth[0] - 0.004, 16 * 0.6, 'loop')
        for k in range(16):
            lp.take.tm[k + 1] = lua.table_from({'src': truth[k], 'name': f'RW {k // 4 + 1}.{k % 4 + 1}', 'col': 0})
        if with_map:
            for tp, b in ((0.0, 120), (3.0, 110), (5.0, 130)):
                r.SetTempoTimeSigMarker(0, -1, tp, -1, -1, b, 4, 4, False)
        core.run('bpm')
        bpm_now = r.TimeMap_GetTimeSigAtTime(0, lp.D_POSITION + 1)[2]
        beat_pos, bar = r.TimeMap2_timeToBeats(0, lp.D_POSITION + 0.004)[0:2]
        off = min(beat_pos, 4 - beat_pos) * 60 / bpm_now
        n_tm = len(lua_list(mock.P.tempo))
        print(f'project tempo from item (tempo map before: {with_map}): {bpm_now:.3f} BPM, '
              f'{n_tm} tempo markers, downbeat {off*1000:.1f} ms from bar {bar + 1}, '
              f'stretch markers {len(lua_list(lp.take.sm))}, rate {lp.take.D_PLAYRATE}')
        if abs(bpm_now - 100) > 0.01 or off > 0.002 or len(lua_list(lp.take.sm)) or n_tm > 1:
            fails.append(f'project tempo from item (tempo map before: {with_map}) is wrong')

    # ---------- change song tempo: other items follow only per "Sync other items" ----------
    for sync, want in ((0, 0), (2, 1)):
        lua, mock, r, core = setup()
        mock.P.ext['reawarpsync'] = str(sync)
        src_s = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
        song = mock.add_item(2.0, src_s, 0.0, 25.0, 'song')
        loop = mock.add_item(6.0, src_s, 0.0, 8.0, 'loop')
        mock.P.sel = lua.table_from([song])
        core.run('tempo')
        loop.C_BEATATTACHMODE = 0
        r.GetUserInputs = lua.eval('function() return true, "130" end')
        core.run('retempo')
        print(f'retempo sync={sync}: loop timebase {loop.C_BEATATTACHMODE}')
        if loop.C_BEATATTACHMODE != want:
            fails.append(f'retempo with sync={sync} set the loop timebase to {loop.C_BEATATTACHMODE}')

    # ---------- beat marker navigation and editing (next/prev/move/add/del) ----------
    lua, mock, r, core = setup()
    src_t = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
    it_t = mock.add_item(0.0, src_t, 0.0, 25.0, 'live')
    core.run('tempo')
    p_after_tempo = it_t.D_POSITION
    mock.P.cursor = p_after_tempo + 0.1
    undos_before = mock.P.undos or 0
    core.run('next_beat')
    c1 = mock.P.cursor
    core.run('next_beat')
    c2 = mock.P.cursor
    core.run('prev_beat')
    c3 = mock.P.cursor
    if (mock.P.undos or 0) != undos_before:
        fails.append('next_beat/prev_beat added entries to undo history')
    if not (c2 > c1 and abs(c3 - c1) < 1e-6):
        fails.append(f'next_beat/prev_beat cursor mismatch: {c1:.3f}, {c2:.3f}, {c3:.3f}')
    # move_beat by +25 ms: tempo marker must move to new cursor and item must not shift
    target_t = c1 + 0.025
    mock.P.cursor = target_t
    core.run('move_beat')
    tm_times = [m.t for m in lua_list(mock.P.tempo)]
    if abs(it_t.D_POSITION - p_after_tempo) > 1e-6 or min(abs(t - target_t) for t in tm_times) > 1e-4:
        fails.append('move_beat did not update tempo marker in place')
    # add_beat at midpoint between c1 and c2, then del_beat it
    n_tm_before = len(lua_list(it_t.take.tm))
    mock.P.cursor = 0.5 * (target_t + c2)
    core.run('add_beat')
    n_tm_added = len(lua_list(it_t.take.tm))
    core.run('del_beat')
    n_tm_deleted = len(lua_list(it_t.take.tm))
    if n_tm_added != n_tm_before + 1 or n_tm_deleted != n_tm_before:
        fails.append(f'add_beat/del_beat marker count mismatch: {n_tm_before} -> {n_tm_added} -> {n_tm_deleted}')

    # ---------- quantize to a MIDI item ----------
    # hits played off the grid (up to 30 ms early or late); the MIDI item on the
    # upper track has a note on each grid position, except one (the hit there
    # must just follow) and plus one where nothing was played
    rng = np.random.default_rng(3)
    grid = 1.0 + np.arange(24) * 0.5
    played = grid + rng.uniform(-0.03, 0.03, grid.size)
    yq = np.zeros(int(14 * SR))
    burst = rng.normal(0, 0.5, int(0.08 * SR)) * np.exp(-np.arange(int(0.08 * SR)) / (0.015 * SR))
    for t in played:
        i = int(round(t * SR))
        yq[i:i + burst.size] += burst
    yq += rng.normal(0, 0.002, yq.size)
    lua, mock, r, core = setup()
    mock.P.ext['reawarpq_strength'] = '100'
    mock.P.ext['reawarpq_window'] = '40'
    notes = [{'s': g, 'e': g + 0.25} for k, g in enumerate(grid) if k != 9] + [{'s': 13.0, 'e': 13.25}]
    mock.add_midi(2.0, 14.0, lua.table_from([lua.table_from(n) for n in notes]))
    srcq = lua.table_from({'sr': SR, 'samples': lua.table_from(yq.tolist())})
    aq = mock.add_item(2.0, srcq, 0.0, 13.5, 'drums')
    core.run('quantize')
    print('quantize msg:', lua_list(mock.P.messages)[-1])
    errs = []
    for k, t in enumerate(played):
        T = aq.D_POSITION + mock.map_inv(aq.take, t)
        if k == 9:
            if not (2.0 + grid[8] < T < 2.0 + grid[10]):
                fails.append(f'quantize: the hit with no note left its place ({T:.3f})')
        else:
            errs.append(abs(T - (2.0 + grid[k])) * 1000)
    print(f'quantize: hits up to {max(errs):.1f} ms from their notes '
          f'(before: up to {np.max(np.abs(played - grid)) * 1000:.0f} ms)')
    if max(errs) > 3:
        fails.append('quantize: hits not on their notes')

    # swing: straight eighths and sixteenths in the audio, MIDI notes on the beat
    # and at 2/3 of it (a triplet shuffle): the eighth of the half beat goes to
    # 2/3, the beat stays, the sixteenths in between just follow
    yq = np.zeros(int(14 * SR))
    eighths = 2.0 + np.arange(40) * 0.25            # project = source here (item at 0)
    sixteenths = 2.125 + np.arange(40) * 0.25
    for t, g in [(t, 1.0) for t in eighths] + [(t, 0.4) for t in sixteenths]:
        i = int(round(t * SR))
        yq[i:i + burst.size] += burst * g
    yq += rng.normal(0, 0.002, yq.size)
    lua, mock, r, core = setup()
    mock.P.ext['reawarpq_strength'] = '100'   # exact (the default, 75, keeps part of the feel)
    notes = []
    for b in range(4, 23):   # beats at 0.5 s, from 2.0 s
        notes += [{'s': b * 0.5, 'e': b * 0.5 + 0.1}, {'s': b * 0.5 + 0.5 * 2 / 3, 'e': b * 0.5 + 0.4}]
    mock.add_midi(0.0, 14.0, lua.table_from([lua.table_from(n) for n in notes]))
    srcq = lua.table_from({'sr': SR, 'samples': lua.table_from(yq.tolist())})
    aq = mock.add_item(0.0, srcq, 0.0, 13.5, 'loop')
    core.run('quantize')
    print('swing msg:', lua_list(mock.P.messages)[-1])
    errs = []
    for t in eighths:
        if 2.0 <= t < 11.2:
            want = t if abs(t / 0.5 - round(t / 0.5)) < 1e-6 else t - 0.25 + 0.5 * 2 / 3
            errs.append(abs(mock.map_inv(aq.take, t) - want) * 1000)
    print(f'swing: eighths up to {max(errs):.1f} ms from the triplet positions')
    if max(errs) > 5:
        fails.append('quantize swing: eighths not on the triplet positions')

    # long-short opening: one note per beat for two bars of two beats (1.667 +
    # 0.333 beat), then the triplet figure: the short note takes the audio of
    # the second beat, not of a half beat
    lua, mock, r, core = setup()
    mock.P.ext['reawarpq_strength'] = '100'
    notes = []
    for b in (4, 6):
        notes += [{'s': b * 0.5, 'e': b * 0.5 + 0.4}, {'s': b * 0.5 + 0.5 * 5 / 3, 'e': b * 0.5 + 0.95}]
    for b in range(8, 23):
        notes += [{'s': b * 0.5, 'e': b * 0.5 + 0.1}, {'s': b * 0.5 + 0.5 * 2 / 3, 'e': b * 0.5 + 0.4}]
    mock.add_midi(0.0, 14.0, lua.table_from([lua.table_from(n) for n in notes]))
    srcq = lua.table_from({'sr': SR, 'samples': lua.table_from(yq.tolist())})
    aq = mock.add_item(0.0, srcq, 0.0, 13.5, 'loop')
    core.run('quantize')
    errs = []
    for t, want in ((2.5, 2.0 + 0.5 * 5 / 3), (3.5, 3.0 + 0.5 * 5 / 3), (4.25, 4.0 + 0.5 * 2 / 3), (5.0, 5.0)):
        errs.append(abs(mock.map_inv(aq.take, t) - want) * 1000)
    print(f'long-short: second beats up to {max(errs):.1f} ms from the short notes')
    if max(errs) > 5:
        fails.append('quantize long-short: the short notes did not take the second beat')
    # quantizing again starts from the item before the quantize (same result)
    core.run('quantize')
    errs2 = [abs(mock.map_inv(aq.take, t) - want) * 1000
             for t, want in ((2.5, 2.0 + 0.5 * 5 / 3), (3.5, 3.0 + 0.5 * 5 / 3), (4.25, 4.0 + 0.5 * 2 / 3))]
    if max(errs2) > 5:
        fails.append(f'quantize twice: the second run went on top of the first ({max(errs2):.0f} ms)')

    # sync = 2 (all overlapping items) leaves MIDI items out: a quantize
    # reference must not be stretched by the warp of a new song
    lua, mock, r, core = setup()
    mock.P.ext['reawarpsync'] = '2'
    mi = mock.add_midi(1.0, 10.0, lua.table_from([lua.table_from({'s': 0.5, 'e': 0.6})]))
    mock.P.sel = lua.table_from([])
    src = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
    song = mock.add_item(0.0, src, 0.0, 30.0, 'song')
    core.run('warp')
    if abs(mi.D_POSITION - 1.0) > 1e-9 or abs(mi.D_LENGTH - 10.0) > 1e-9 or abs(mi.take.D_PLAYRATE - 1) > 1e-9:
        fails.append('sync=2: the warp changed a MIDI item')
    # sync = 3 includes it
    lua, mock, r, core = setup()
    mock.P.ext['reawarpsync'] = '3'
    mi = mock.add_midi(1.0, 10.0, lua.table_from([lua.table_from({'s': 0.5, 'e': 0.6})]))
    mock.P.sel = lua.table_from([])
    src = lua.table_from({'sr': SR, 'samples': lua.table_from(y.tolist())})
    song = mock.add_item(0.0, src, 0.0, 30.0, 'song')
    core.run('warp')
    if abs(mi.D_LENGTH - 10.0) < 1e-6 and abs(mi.take.D_PLAYRATE - 1) < 1e-6:
        fails.append('sync=3: the MIDI item did not follow the warp')
    print('sync=2 with a MIDI item:', lua_list(mock.P.messages)[-1])

    print('FAIL:\n  ' + '\n  '.join(fails) if fails else 'OK')
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
