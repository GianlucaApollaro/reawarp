-- @description reawarp: audio warping (beat detection, warp, tempo map)
-- @version 0.1.4
-- @author Gabriel Schuck
-- @license GPL-3.0-or-later
-- @links
--   GitHub https://github.com/gabrielschuck/reawarp
-- @changelog
--   Spanish translation (by vrivrixd): chosen automatically when REAPER or the system
--   is in Spanish, or by typing es in the Language setting. README in Spanish.

-- reawarp
-- Audio warping for REAPER: detects the beats of a song (including songs with a
-- variable tempo) and fits the item to the project tempo (stretch markers) or
-- makes the project follow the song (tempo map).
--
-- All code lives in this file. Running it directly opens the menu and registers
-- the individual actions in the Action List (files generated in "actions/").
--
-- Sections:
--   1. Analysis engine (pure Lua, no REAPER dependencies)
--      band onset envelope -> global tempo -> local tempo curve ->
--      beat tracking (dynamic programming, Ellis 2007) ->
--      snap to transients -> time signature -> downbeat
--   2. REAPER integration: strings, settings, markers, warp, tempo map
--   3. Entry point
--
-- Beat grid: take markers "RW <bar>.<beat>" at source positions; they follow the
-- audio and can be edited by hand before warping. The song's time signature is
-- stored in the take (P_EXT:reawarp_sig).
--
-- Copyright (C) 2026 Gabriel Schuck
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
-- FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License along with
-- this program (LICENSE). If not, see <https://www.gnu.org/licenses/>.

-- The actions run in a coroutine (see core.run): breath() hands control back
-- to REAPER every 50 ms, so its window keeps responding during long work.
-- Outside a coroutine (tests, or a host without defer) it does nothing.
local now = (reaper and reaper.time_precise) or os.clock
local breath_t = now()
local function breath()
  if now() - breath_t > 0.05 and coroutine.isyieldable() then
    coroutine.yield()
    breath_t = now()
  end
end

---------------------------------------------------------------------------
-- 1. Analysis engine
---------------------------------------------------------------------------
local dsp = (function()
local M = {}

local floor, ceil, abs, exp, log, sqrt, max, min =
  math.floor, math.ceil, math.abs, math.exp, math.log, math.sqrt, math.max, math.min

local function round(x) return floor(x + 0.5) end

-- RBJ cookbook biquad, returns normalized {b0, b1, b2, a1, a2}
function M.biquad(kind, f0, sr, q)
  local w0 = 2 * math.pi * f0 / sr
  local cw, sw = math.cos(w0), math.sin(w0)
  local alpha = sw / (2 * q)
  local b0, b1, b2
  if kind == "lp" then
    b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = b0
  elseif kind == "hp" then
    b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = b0
  else -- band-pass, 0 dB peak
    b0 = alpha; b1 = 0; b2 = -alpha
  end
  local a0 = 1 + alpha
  return { b0 / a0, b1 / a0, b2 / a0, (-2 * cw) / a0, (1 - alpha) / a0 }
end

---------------------------------------------------------------------------
-- 1. Onset envelope
--   read(pos, n) -> table of n mono samples starting at sample pos (0-based)
--   returns: o (onset strength), F (per-band flux, F[1] = bass), env (1 ms peak envelope),
--            envrate (Hz), fps (frames per second)
---------------------------------------------------------------------------
function M.onset_envelope(read, nsamp, sr, hop)
  local f1 = M.biquad("lp", 200, sr, 0.707)
  local f2 = M.biquad("bp", 500, sr, 0.8)
  local f3 = M.biquad("bp", 1600, sr, 0.8)
  local f4 = M.biquad("hp", 3000, sr, 0.707)
  local b01, b11, b21, a11, a21 = f1[1], f1[2], f1[3], f1[4], f1[5]
  local b02, b12, b22, a12, a22 = f2[1], f2[2], f2[3], f2[4], f2[5]
  local b03, b13, b23, a13, a23 = f3[1], f3[2], f3[3], f3[4], f3[5]
  local b04, b14, b24, a14, a24 = f4[1], f4[2], f4[3], f4[4], f4[5]
  local z11, z21, z12, z22, z13, z23, z14, z24 = 0, 0, 0, 0, 0, 0, 0, 0
  local acc1, acc2, acc3, acc4 = 0, 0, 0, 0
  local E1, E2, E3, E4 = {}, {}, {}, {}
  local env, nenv, emax, ecnt = {}, 0, 0, 0
  local sub = max(1, round(sr / 1000))
  local nfr, cnt = 0, 0
  local BLOCK = 32768
  local pos = 0
  while pos < nsamp do
    breath()
    local n = min(BLOCK, nsamp - pos)
    local buf = read(pos, n)
    for i = 1, n do
      local x = buf[i] or 0
      local y = b01 * x + z11; z11 = b11 * x - a11 * y + z21; z21 = b21 * x - a21 * y; acc1 = acc1 + y * y
      y = b02 * x + z12; z12 = b12 * x - a12 * y + z22; z22 = b22 * x - a22 * y; acc2 = acc2 + y * y
      y = b03 * x + z13; z13 = b13 * x - a13 * y + z23; z23 = b23 * x - a23 * y; acc3 = acc3 + y * y
      y = b04 * x + z14; z14 = b14 * x - a14 * y + z24; z24 = b24 * x - a24 * y; acc4 = acc4 + y * y
      if x < 0 then x = -x end
      if x > emax then emax = x end
      ecnt = ecnt + 1
      if ecnt == sub then nenv = nenv + 1; env[nenv] = emax; emax = 0; ecnt = 0 end
      cnt = cnt + 1
      if cnt == hop then
        nfr = nfr + 1
        E1[nfr], E2[nfr], E3[nfr], E4[nfr] = acc1, acc2, acc3, acc4
        acc1, acc2, acc3, acc4 = 0, 0, 0, 0
        cnt = 0
      end
    end
    pos = pos + n
  end

  -- log energy with an 80 dB floor per band, then half-wave rectified flux
  local bands = { E1, E2, E3, E4 }
  local L = {}
  for b = 1, 4 do
    local E, Lb, top = bands[b], {}, -1e9
    for k = 1, nfr do
      local v = 10 * log(E[k] / hop + 1e-12, 10)
      Lb[k] = v
      if v > top then top = v end
    end
    local floor_db = top - 80
    for k = 1, nfr do if Lb[k] < floor_db then Lb[k] = floor_db end end
    L[b] = Lb
  end
  local o, F = {}, { {}, {}, {}, {} }
  o[1] = 0
  for b = 1, 4 do F[b][1] = 0 end
  for k = 2, nfr do
    local s = 0
    for b = 1, 4 do
      local d = L[b][k] - L[b][k - 1]
      if d < 0 then d = 0 end
      F[b][k] = d
      s = s + d
    end
    o[k] = s
  end

  -- detrend (subtract ~1 s moving mean) and normalize by std
  local fps = sr / hop
  local W = max(1, round(fps * 0.5))
  local cs = { [0] = 0 }
  for k = 1, nfr do cs[k] = cs[k - 1] + o[k] end
  local out, ss = {}, 0
  for k = 1, nfr do
    local a, b = max(1, k - W), min(nfr, k + W)
    local v = o[k] - (cs[b] - cs[a - 1]) / (b - a + 1)
    out[k] = v
    ss = ss + v * v
  end
  local sd = sqrt(ss / max(1, nfr - 1))
  if sd > 0 then for k = 1, nfr do out[k] = out[k] / sd end end
  F.low_energy = E1 -- linear bass energy per frame (downbeat accent)
  return out, F, env, sr / sub, fps
end

---------------------------------------------------------------------------
-- autocorrelation helpers
---------------------------------------------------------------------------
local function autocorr(o, a, b, lag)
  local s = 0
  for i = a, b - lag do s = s + o[i] * o[i + lag] end
  return s / max(1, b - a + 1 - lag)
end

local function parabolic(ym1, y0, yp1)
  local den = ym1 - 2 * y0 + yp1
  if den == 0 then return 0 end
  local d = 0.5 * (ym1 - yp1) / den
  if d > 0.5 then d = 0.5 elseif d < -0.5 then d = -0.5 end
  return d
end

---------------------------------------------------------------------------
-- 2. Global tempo. Returns bpm, period (frames)
---------------------------------------------------------------------------
function M.global_tempo(o, fps, minbpm, maxbpm, hint)
  local n = #o
  local lmin = max(2, floor(60 * fps / maxbpm))
  local lmax = min(n - 2, ceil(60 * fps / minbpm))
  local ac = {}
  for lag = lmin - 1, lmax + 1 do breath(); ac[lag] = autocorr(o, 1, n, lag) end
  local center = (hint and hint > 0) and hint or 120
  local sig = (hint and hint > 0) and 0.1 or 1.0
  local best, bl = -1e300, nil
  for lag = lmin, lmax do
    local bpm = 60 * fps / lag
    local w = exp(-0.5 * (log(bpm / center, 2) / sig) ^ 2)
    local v = ac[lag] * w
    local peak = ac[lag] >= ac[lag - 1] and ac[lag] >= ac[lag + 1]
    if peak and v > best then best, bl = v, lag end
  end
  if not bl then bl = round(60 * fps / center) end
  local p = bl + parabolic(ac[bl - 1] or 0, ac[bl] or 0, ac[bl + 1] or 0)
  return 60 * fps / p, p
end

---------------------------------------------------------------------------
-- 3. Local tempo curve. var = allowed relative deviation from global period.
-- Returns per-frame period table.
---------------------------------------------------------------------------
function M.local_periods(o, fps, P, var, win_sec)
  local n = #o
  local W = round((win_sec or 8) * fps)
  local H = max(1, round(fps))
  local lmin = max(2, floor(P * (1 - var)))
  local lmax = ceil(P * (1 + var))
  local cs, ps = {}, {}
  local prev = P
  for c = 1, n, H do
    breath()
    local a, b = max(1, c - floor(W / 2)), min(n, c + floor(W / 2))
    local p = prev
    if b - a > 2 * lmax then
      local ac = {}
      for lag = lmin - 1, lmax + 1 do ac[lag] = autocorr(o, a, b, lag) end
      local best, bl = 0, nil
      for lag = lmin, lmax do
        if ac[lag] > 0 and ac[lag] >= ac[lag - 1] and ac[lag] >= ac[lag + 1] then
          local w = exp(-0.5 * (log(lag / prev) / 0.06) ^ 2)
                  * exp(-0.5 * (log(lag / P) / max(0.02, var)) ^ 2)
          local v = ac[lag] * w
          if v > best then best, bl = v, lag end
        end
      end
      if bl then p = bl + parabolic(ac[bl - 1], ac[bl], ac[bl + 1]) end
    end
    cs[#cs + 1], ps[#ps + 1] = c, p
    prev = p
  end
  -- median filter (5)
  local med = {}
  for i = 1, #ps do
    local w = {}
    for j = max(1, i - 2), min(#ps, i + 2) do w[#w + 1] = ps[j] end
    table.sort(w)
    med[i] = w[floor((#w + 1) / 2)]
  end
  -- interpolate per frame
  local per, j = {}, 1
  for t = 1, n do
    while j < #cs and cs[j + 1] <= t do j = j + 1 end
    if j >= #cs then per[t] = med[#cs]
    else
      local u = (t - cs[j]) / (cs[j + 1] - cs[j])
      per[t] = med[j] + u * (med[j + 1] - med[j])
    end
  end
  return per
end

---------------------------------------------------------------------------
-- 4. Beat tracking by dynamic programming with per-frame period.
-- Returns fractional beat frames (1-based) and the local score.
---------------------------------------------------------------------------
function M.track_beats(o, periods, tightness)
  local n = #o
  -- local score: gaussian smoothing, sigma = median period / 32
  local sorted = {}
  for i = 1, n, 16 do sorted[#sorted + 1] = periods[i] end
  table.sort(sorted)
  local Pm = sorted[floor((#sorted + 1) / 2)] or 40
  local sig = max(0.5, Pm / 32)
  local R = ceil(3 * sig)
  local kern, ksum = {}, 0
  for d = -R, R do kern[d] = exp(-0.5 * (d / sig) ^ 2); ksum = ksum + kern[d] end
  local ls = {}
  for t = 1, n do
    local s = 0
    for d = -R, R do
      local v = o[t + d]
      if v then s = s + v * kern[d] end
    end
    ls[t] = s / ksum
  end

  local cum, back = {}, {}
  for t = 1, n do
    if t % 2048 == 0 then breath() end
    local P = periods[t]
    local lo, hi = t - round(2 * P), t - round(P / 2)
    local best, bi = -1e300, 0
    if hi >= 1 then
      for tau = max(1, lo), hi do
        local l = log((t - tau) / P)
        local sc = cum[tau] - tightness * l * l
        if sc > best then best, bi = sc, tau end
      end
    end
    if bi > 0 then cum[t] = ls[t] + best; back[t] = bi
    else cum[t] = ls[t]; back[t] = 0 end
  end

  -- last beat: last local max of cum above half the median of local maxima
  local maxima = {}
  for t = 2, n - 1 do
    if cum[t] > cum[t - 1] and cum[t] >= cum[t + 1] then maxima[#maxima + 1] = cum[t] end
  end
  table.sort(maxima)
  local thr = 0.5 * (maxima[floor((#maxima + 1) / 2)] or 0)
  local last = n
  for t = n - 1, 2, -1 do
    if cum[t] > cum[t - 1] and cum[t] >= cum[t + 1] and cum[t] >= thr then last = t; break end
  end
  local rev = {}
  local t = last
  while t and t > 0 do rev[#rev + 1] = t; t = back[t] end
  local beats = {}
  for i = #rev, 1, -1 do beats[#beats + 1] = rev[i] end

  -- trim weak leading/trailing beats (silence)
  local ss = 0
  for _, b in ipairs(beats) do ss = ss + ls[b] * ls[b] end
  local th = 0.5 * sqrt(ss / max(1, #beats))
  local a, b = 1, #beats
  while a <= b and ls[beats[a]] < th do a = a + 1 end
  while b >= a and ls[beats[b]] < th do b = b - 1 end
  local out = {}
  for i = a, b do
    local f = beats[i]
    local d = 0
    if f > 1 and f < n then d = parabolic(ls[f - 1], ls[f], ls[f + 1]) end
    out[#out + 1] = f + d
  end
  return out, ls
end

---------------------------------------------------------------------------
-- 5. Snap beat times (sec) to the start of the nearest transient.
---------------------------------------------------------------------------
function M.snap(times, env, envrate, radius)
  local n = #env
  local r = ceil(radius * envrate)
  local out = {}
  for i, t in ipairs(times) do
    local c = floor(t * envrate) + 1
    local best, bj = 0, nil
    for j = max(8, c - r), min(n - 4, c + r) do
      local before = 0
      for k = j - 6, j - 1 do before = before + env[k] end
      before = before / 6
      local after = max(env[j], env[j + 1], env[j + 2], env[j + 3])
      if after > 1.6 * before + 1e-4 then
        local d = (after - before) * (1 - 0.4 * abs(j - c) / r)
        if d > best then best, bj = d, j end
      end
    end
    out[i] = bj and (bj - 1) / envrate or t
  end
  return out
end

---------------------------------------------------------------------------
-- Beat grid smoothing.
--   w == 0  : none
--   w <  0  : constant tempo (global linear fit)
--   w >  0  : local linear fit over +/- w beats
---------------------------------------------------------------------------
local function linfit(times, a, b)
  local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
  for i = a, b do
    n = n + 1; sx = sx + i; sy = sy + times[i]; sxx = sxx + i * i; sxy = sxy + i * times[i]
  end
  local den = n * sxx - sx * sx
  if den == 0 then return 0, times[a] end
  local slope = (n * sxy - sx * sy) / den
  return slope, (sy - slope * sx) / n
end

function M.smooth(times, w)
  local n = #times
  if w == 0 or n < 3 then return times end
  local out = {}
  if w < 0 then
    local s, c = linfit(times, 1, n)
    for i = 1, n do out[i] = c + s * i end
  else
    for i = 1, n do
      local s, c = linfit(times, max(1, i - w), min(n, i + w))
      out[i] = c + s * i
    end
  end
  return out
end

---------------------------------------------------------------------------
-- 6. Meter: beats per bar (3 or 4). Bars repeat, so beat-synchronous rhythm
-- patterns (per band, at 0, 1/3, 1/2, 2/3 of each beat) are most similar at a
-- lag of one or more bars. Returns group, confidence margin.
---------------------------------------------------------------------------
function M.meter(times, F, spf)
  local n = #times
  if n < 20 then return 4, 1 end
  local sd = {}
  for b = 1, 4 do
    local ss = 0
    for k = 1, #F[b] do ss = ss + F[b][k] * F[b][k] end
    sd[b] = sqrt(ss / max(1, #F[b]))
    if sd[b] == 0 then sd[b] = 1 end
  end
  local fr = { 0, 1 / 3, 1 / 2, 2 / 3 }
  local V = {}
  for i = 1, n - 1 do
    local v = {}
    local f0, f1 = times[i] / spf + 1, times[i + 1] / spf + 1
    for b = 1, 4 do
      local Fb = F[b]
      for _, q in ipairs(fr) do
        -- total rise around the position: unlike the peak, it does not depend
        -- on where the onset falls inside an analysis frame (that phase cycles
        -- with the tempo and would fake a periodic pattern)
        local k = round(f0 + q * (f1 - f0))
        local m = 0
        for d = -1, 2 do m = m + (Fb[k + d] or 0) end
        v[#v + 1] = m / sd[b]
      end
    end
    V[i] = v
  end
  -- z-score each dimension across beats; dimensions without a repeating
  -- pattern (noise, pads) then contribute ~0 instead of diluting the result
  local nv, dims = #V, #V[1]
  for j = 1, dims do
    local mu, ss = 0, 0
    for i = 1, nv do mu = mu + V[i][j] end
    mu = mu / nv
    for i = 1, nv do ss = ss + (V[i][j] - mu) ^ 2 end
    local sdj = sqrt(ss / nv)
    for i = 1, nv do V[i][j] = sdj > 1e-9 and (V[i][j] - mu) / sdj or 0 end
  end
  local function R(k)
    local s, c = 0, 0
    for i = 1, nv - k do
      local a, b = V[i], V[i + k]
      for j = 1, dims do s = s + a[j] * b[j] end
      c = c + 1
    end
    return c > 0 and s / (c * dims) or 0
  end
  -- lags that are bar multiples for one meter only (6 and 12 are shared,
  -- and 6 also matches 2-beat patterns common in 4/4)
  local s3 = (R(3) + R(9)) / 2
  local s4 = (R(4) + R(8)) / 2
  -- 4 is far more common: require clear evidence for 3
  if s3 > s4 + 0.05 then return 3, s3 - s4 end
  return 4, s4 - s3
end

---------------------------------------------------------------------------
-- 7. Downbeat phase: which beat index (1..meter) carries the bass accent.
---------------------------------------------------------------------------
function M.downbeat(times, spf, o, low, meter, lowE)
  if meter <= 1 or #times < meter * 2 then return 1 end
  local ss = 0
  for k = 1, #low do ss = ss + low[k] * low[k] end
  local sd = sqrt(ss / max(1, #low))
  if sd == 0 then sd = 1 end
  -- linear bass rise per beat: log flux ignores loudness, so a strong kick on
  -- 1 and a softer one on 3 would look the same
  local rise, rmean = {}, 0
  for i, t in ipairs(times) do
    local k = round(t / spf + 1)
    local before, after = (lowE and lowE[k - 2]) or 0, 0
    for d = 0, 3 do
      local e = lowE and lowE[k + d]
      if e and e > after then after = e end
    end
    rise[i] = max(0, after - before)
    rmean = rmean + rise[i]
  end
  rmean = rmean / max(1, #times)
  if rmean <= 0 then rmean = 1 end
  local sum, cnt = {}, {}
  for p = 1, meter do sum[p], cnt[p] = 0, 0 end
  for i, t in ipairs(times) do
    local k = round(t / spf + 1)
    local acc = 0
    for d = -1, 1 do
      local v = low[k + d]
      if v and v / sd > acc then acc = v / sd end
    end
    local p = (i - 1) % meter + 1
    sum[p] = sum[p] + acc + 0.25 * max(0, o[k] or 0) + rise[i] / rmean
    cnt[p] = cnt[p] + 1
  end
  local v = {}
  for p = 1, meter do v[p] = sum[p] / max(1, cnt[p]) end
  local best, bp = -1, 1
  for p = 1, meter do
    if v[p] > best then best, bp = v[p], p end
  end
  return bp
end

---------------------------------------------------------------------------
-- 8. External beats (from the Beat This! neural detector): fix the
-- metrical level against our own tempo estimate, then use its downbeats for
-- the time signature and the bar phase.
---------------------------------------------------------------------------
local function median(t)
  local c = {}
  for i, v in ipairs(t) do c[i] = v end
  table.sort(c)
  return c[floor((#c + 1) / 2)]
end

local function intervals(b)
  local iv = {}
  for i = 2, #b do iv[#iv + 1] = b[i] - b[i - 1] end
  return iv
end

-- index of the value in sorted list nearest to t, and its distance
local function nearest(list, t)
  local lo, hi = 1, #list
  while lo <= hi do
    local mid = (lo + hi) // 2
    if list[mid] < t then lo = mid + 1 else hi = mid - 1 end
  end
  local best, bi = math.huge, nil
  for _, k in ipairs({ lo - 1, lo }) do
    local v = list[k]
    if v and abs(v - t) < best then best, bi = abs(v - t), k end
  end
  return bi, best
end

-- Put the detector's beats on the attacks. Its beats can sit 10-40 ms off
-- the attacks, by an amount that depends on the song (for some songs early,
-- for most late), so the offset is measured in the audio: the attack
-- strength (rise of the 1 ms peak envelope) averaged over the beats nearby,
-- at each offset from -50 to +50 ms. Then, with snap, each beat moves to the
-- strongest attack within 12 ms of its shifted place, when there is a clear one.
function M.align_attacks(times, env, envrate, snap)
  local n = #env
  if #times < 8 or n < 100 then return times end
  local function lmean(a, z)
    local s, c = 0, 0
    for k = max(1, a), min(n, z) do s = s + env[k]; c = c + 1 end
    return c > 0 and s / c or 0
  end
  local rate = envrate / 1000 -- frames per ms
  local d = {} -- rise strength at each frame: after (0..3 ms) over before (4..12 ms)
  local w3, w4, w12 = max(1, round(3 * rate)), max(1, round(4 * rate)), max(2, round(12 * rate))
  for k = 1, n do
    if k % 8192 == 0 then breath() end
    local v = log((lmean(k, k + w3) + 1e-5) / (lmean(k - w12, k - w4) + 1e-5))
    d[k] = v > 0 and v or 0
  end
  local function at(t) return d[floor(t * envrate + 1.5)] or 0 end
  local R = round(50 * rate)
  local W = 16 -- beats on each side for the local offset
  local nb = #times
  -- offset profile per beat (sum over the window computed with prefix sums)
  local prof = {}
  for o = -R, R do
    breath()
    local col = {}
    local acc = 0
    for i = 1, nb do
      -- the peak of rise strength within 2 ms of the offset, so the profile is smooth
      local t = times[i] + o / envrate
      acc = acc + max(at(t - 1 / envrate), at(t), at(t + 1 / envrate))
      col[i] = acc
    end
    prof[o] = col
  end
  local offs = {}
  for i = 1, nb do
    local a, z = max(1, i - W), min(nb, i + W)
    local best, bo, sum, cnt = -1, 0, 0, 0
    for o = -R, R do
      local v = prof[o][z] - (a > 1 and prof[o][a - 1] or 0)
      sum = sum + v; cnt = cnt + 1
      -- prefer small offsets on ties (the detector is right on average)
      v = v * (1 - 0.1 * abs(o) / R)
      if v > best then best, bo = v, o end
    end
    -- only a clear peak counts
    if best <= 1.3 * sum / cnt then bo = 0 end
    offs[i] = bo
  end
  -- the offset changes slowly: median of 9 beats, so it adds no jitter
  local out = {}
  for i = 1, nb do
    local w = {}
    for k = max(1, i - 4), min(nb, i + 4) do w[#w + 1] = offs[k] end
    local bo = median(w)
    local a, z = max(1, i - W), min(nb, i + W)
    local t = times[i] + bo / envrate
    if snap then
      local r = round(12 * rate)
      local c = floor(t * envrate + 1.5)
      local bk, bv = nil, 0
      for k = c - r, c + r do
        local v = d[k] or 0
        if v > bv then bv, bk = v, k end
      end
      -- a clear attack: well above the typical strength at the beats
      local typ = (prof[bo][z] - (a > 1 and prof[bo][a - 1] or 0)) / (z - a + 1)
      if bk and bv >= 0.8 * typ then t = (bk - 1) / envrate end
    end
    out[i] = t
  end
  return out
end

-- most common number of beats between downbeats (2..8; with with_one, 1
-- too: a downbeat on every beat), nil if too few
function M.downbeat_gap(times, d, with_one)
  local idx = {}
  for _, t in ipairs(d) do
    local j, dist = nearest(times, t)
    if j and dist <= 0.07 then idx[#idx + 1] = j end
  end
  if #idx < 4 then return nil end
  local count, best, bg = {}, 0, nil
  for k = 2, #idx do
    local g = idx[k] - idx[k - 1]
    if g >= (with_one and 1 or 2) and g <= 8 then
      count[g] = (count[g] or 0) + 1
      if count[g] > best then best, bg = count[g], g end
    end
  end
  return bg
end

-- Returns beats, downbeats and, when halving, the dropped beats (real
-- detections, kept so "Double the BPM" can bring them back exactly).
function M.external_beats(ext, ref_bpm)
  local b, d = {}, {}
  for i, v in ipairs(ext.beats or {}) do b[i] = v end
  for i, v in ipairs(ext.downbeats or {}) do d[i] = v end
  table.sort(b)
  table.sort(d)
  local dropped = {}
  if #b < 4 then return b, d, dropped end
  local ratio = 60 / median(intervals(b)) / ref_bpm
  -- never halve bars of an odd number of beats (3/4 at 200 BPM would get
  -- one and a half beats per bar)
  local gap = M.downbeat_gap(b, d)
  if ratio > 1.45 and not (gap and gap % 2 == 1) then
    -- double tempo: keep every other beat, in the phase that holds the
    -- downbeats. A missed or added beat, or a sudden change of tempo, flips
    -- the parity of the indexes, so the count restarts at each downbeat
    -- (one at least two beats after the last one used).
    local reset = {}
    local last
    for i, t in ipairs(b) do
      local _, dist = nearest(d, t)
      if dist and dist <= 0.07 and (not last or i - last >= 2) then reset[i] = true; last = i end
    end
    local first = 1
    for i = 1, #b do if reset[i] then first = i; break end end
    local nb, c = {}, 0
    for i = 1, #b do
      if reset[i] then c = 0 elseif i < first then c = first - i end
      if c % 2 == 0 then nb[#nb + 1] = b[i] else dropped[#dropped + 1] = b[i] end
      c = c + 1
    end
    b = nb
  elseif ratio < 0.69 then
    -- half tempo: add the beats in between
    local nb = {}
    for i = 1, #b - 1 do
      nb[#nb + 1] = b[i]
      nb[#nb + 1] = 0.5 * (b[i] + b[i + 1])
    end
    nb[#nb + 1] = b[#b]
    b = nb
  end
  return b, d, dropped
end

-- Keep the beats on one metrical level along the song. period(t) is the
-- expected beat period at time t (from the built-in local tempo curve).
-- Runs of beats at about half the period (the detector briefly switched to
-- eighth notes) are thinned, keeping the phase of the following, steadier
-- part; gaps of about twice the period or more are filled evenly.
function M.regularize(b, period)
  if #b < 3 then return b end
  local kept = { b[#b] }
  for i = #b - 1, 1, -1 do
    if kept[#kept] - b[i] >= 0.65 * period(b[i]) then kept[#kept + 1] = b[i] end
  end
  local out = {}
  for i = #kept, 1, -1 do
    local t = kept[i]
    local prev = out[#out]
    if prev then
      local k = floor((t - prev) / period(prev) + 0.5)
      if k >= 2 and (t - prev) / period(prev) > 1.6 then
        for j = 1, k - 1 do out[#out + 1] = prev + j * (t - prev) / k end
      end
    end
    out[#out + 1] = t
  end
  return out
end

-- beats per bar from the downbeats (3, or 4 for duple), nil if too few
function M.meter_from_downbeats(times, d)
  local bg = M.downbeat_gap(times, d)
  if not bg then return nil end
  return bg % 3 == 0 and 3 or 4 -- 6 = two bars of 3
end

-- Keep one bar's worth of beats between the downbeats.
-- The neural detector sometimes adds beats (or downbeats) around breaks,
-- fermatas and ornaments; one extra beat shifts every later bar. The
-- downbeats are chosen as a chain of bars of about the expected length
-- with a smooth tempo (dynamic programming over pairs of downbeats); the
-- beats inside each bar are the detections nearest to an even subdivision
-- (or to the local tempo, for a bar ending in a hold), or the subdivision
-- itself when none is near. times: beats on the chosen
-- level (regularized), cand: the detector's beats on that level.
function M.anchor_downbeats(times, cand, downs, meter)
  if #times < 8 or #downs < 4 or not meter or meter < 2 then return times end
  local iv = intervals(times)
  local function period(t)
    local j = nearest(times, t) or 1
    local w = {}
    for k = max(1, j - 12), min(#iv, j + 12) do w[#w + 1] = iv[k] end
    return median(w)
  end
  -- nodes: downbeats on a detected beat of this level (after halving, a
  -- downbeat on a dropped beat is ignored rather than moving the beat phase)
  local node = {}
  for _, d in ipairs(downs) do
    local j, dist = nearest(cand, d)
    if j and dist <= 0.07 and (not node[1] or cand[j] - node[#node] > 0.05) then node[#node + 1] = cand[j] end
  end
  local n = #node
  if n < 4 then return times end

  -- beats a + q * sub (q = 1 .. cnt - 1): the nearest detection, or the target
  local function fill(a, sub, cnt, out)
    local last, e = a, 0
    for q = 1, cnt - 1 do
      local tg = a + q * sub
      local j, dist = nearest(cand, tg)
      local t = (j and dist <= 0.3 * sub and cand[j] > last + 0.4 * sub) and cand[j] or tg
      e = e + min(0.5, (dist or sub) / sub)
      if out then out[#out + 1] = t end
      last = t
    end
    return e / max(1, cnt - 1)
  end

  -- edges i -> j: k even bars, or one bar at the local tempo followed by a
  -- hold (a break or fermata), which keeps the count of beats per bar.
  -- Costs are per edge: minus the bars of time covered (so the chain spans
  -- as much of the song as it can), plus deviations from the expected bar.
  local edges, into = {}, {}
  for i = 1, n do into[i] = {} end
  for i = 1, n - 1 do
    breath()
    local found = false
    for j = i + 1, n do
      local s = node[j] - node[i]
      local p = period(0.5 * (node[i] + node[j]))
      local x = s / (meter * p)
      if x > 4.5 then break end
      local k = max(1, round(x))
      local dev = abs(x / k - 1)
      -- the beats must add up: up to 0.7 beat off in one bar (a ritardando),
      -- half a beat over several bars
      -- several bars may only skip downbeats that are not on one of their bar lines
      local skips_bar = false
      for q = i + 1, j - 1 do
        local f = (node[q] - node[i]) / (s / k)
        if abs(f - round(f)) <= 0.25 then skips_bar = true; break end
      end
      if x >= 0.6 and dev <= 0.22 and abs(s / p - k * meter) <= (k == 1 and 0.7 or 0.5)
          and not (k > 1 and skips_bar) then
        edges[#edges + 1] = { i = i, j = j, k = k, bar = s / k, sub = s / (k * meter), cnt = k * meter,
          cost = -x + 4 * dev + 2 * fill(node[i], s / (k * meter), k * meter) }
        found = true
      end
      -- a bar with another number of beats at the same tempo (the detector
      -- missed or added a downbeat, or the song really has an odd bar)
      local cnt = round(s / p)
      if cnt >= 2 and cnt <= 2 * meter and cnt % meter ~= 0 and abs(s / (cnt * p) - 1) <= 0.12 then
        edges[#edges + 1] = { i = i, j = j, k = 1, bar = meter * p, sub = s / cnt, cnt = cnt,
          cost = -x + 1.5 + 2 * fill(node[i], s / cnt, cnt) }
        found = true
      end
      if x >= 1.15 and x <= 2.2 then
        -- a hold has no detections where the beats would go on at this tempo
        local p0 = period(node[i])
        local ongrid = 0
        for q = meter, floor(s / p0 - 0.5) do
          local _, dist = nearest(cand, node[i] + q * p0)
          if dist and dist <= 0.15 * p0 then ongrid = ongrid + 1 end
        end
        edges[#edges + 1] = { i = i, j = j, k = 1, bar = meter * p0, sub = p0, cnt = meter,
          cost = -x + 0.5 + 1.5 * (x - 1) + 2 * fill(node[i], p0, meter) + 2 * ongrid }
        found = true
      end
    end
    if not found then -- a long break: bridge it to the next downbeat
      local s = node[i + 1] - node[i]
      local x = s / (meter * period(node[i]))
      local k = max(1, round(x))
      edges[#edges + 1] = { i = i, j = i + 1, k = k, bar = s / k, sub = s / (k * meter), cnt = k * meter,
        cost = -x + 2 }
    end
  end
  table.sort(edges, function(a, b) return a.i < b.i or (a.i == b.i and a.j < b.j) end)
  local bestc, bestlast = math.huge, nil
  for _, e in ipairs(edges) do
    e.best, e.prev = e.cost, nil
    for _, p in ipairs(into[e.i]) do
      local c = p.best + e.cost + 3 * abs(log(e.bar / p.bar))
      if c < e.best then e.best, e.prev = c, p end
    end
    into[e.j][#into[e.j] + 1] = e
    if e.best < bestc then bestc, bestlast = e.best, e end
  end
  if not bestlast then return times end
  local chain = {}
  local e = bestlast
  while e do table.insert(chain, 1, e); e = e.prev end
  local a, z = node[chain[1].i], node[chain[#chain].j]

  local out = {}
  local head = period(a)
  for _, t in ipairs(times) do
    if t < a - 0.5 * head then out[#out + 1] = t end
  end
  for _, c in ipairs(chain) do
    out[#out + 1] = node[c.i]
    fill(node[c.i], c.sub, c.cnt, out)
  end
  out[#out + 1] = z
  local tail = period(z)
  for _, t in ipairs(times) do
    if t > z + 0.5 * tail then out[#out + 1] = t end
  end
  return out
end

-- bar phase (1..meter) holding the most downbeats, nil if too few
function M.phase_from_downbeats(times, d, meter)
  local cnt, total = {}, 0
  for p = 1, meter do cnt[p] = 0 end
  for i, t in ipairs(times) do
    local _, dist = nearest(d, t)
    if dist <= 0.07 then
      local p = (i - 1) % meter + 1
      cnt[p] = cnt[p] + 1
      total = total + 1
    end
  end
  if total < 2 then return nil end
  local best, bp = -1, 1
  for p = 1, meter do
    if cnt[p] > best then best, bp = cnt[p], p end
  end
  return bp
end

---------------------------------------------------------------------------
-- Full analysis.
-- opts: min_bpm, max_bpm, bpm_hint, flex (0..100), snap (bool),
--       smooth (int), meter (beats per bar, 0/nil = detect), hop (samples),
--       external ({ beats = {sec...}, downbeats = {sec...} } from another detector)
-- Returns { beats = {sec...}, bpm = global, downbeat = index into beats,
--           bpm_min, bpm_max (local range), meter, meter_conf }
---------------------------------------------------------------------------
function M.analyze(read, nsamp, sr, opts)
  local hop = opts.hop or 128
  local o, F, env, envrate, fps = M.onset_envelope(read, nsamp, sr, hop)
  if #o < fps * 4 then return nil, "err_too_short" end

  local bpm, P = M.global_tempo(o, fps, opts.min_bpm or 60, opts.max_bpm or 180, opts.bpm_hint or 0)
  local spf = hop / sr
  local times, downs, alt
  if opts.external then
    local ref = (opts.bpm_hint and opts.bpm_hint > 0) and opts.bpm_hint or bpm
    times, downs, alt = M.external_beats(opts.external, ref)
    if #times < 4 then return nil, "err_no_pulse" end
    -- local tempo curve at the chosen level, to keep the beats on that level
    local per = M.local_periods(o, fps, median(intervals(times)) / spf, 0.25, 8)
    local cand = times
    times = M.regularize(times, function(t)
      local k = min(#per, max(1, floor(t / spf + 1.5)))
      return per[k] * spf
    end)
    -- beats per bar as the detector counts them (2 for 2/4, unlike the meter)
    -- (not when the downbeats fall on every beat: beats on the bar level)
    local gap = M.downbeat_gap(times, downs, true)
    if gap and gap >= 2 and gap <= 4 and not opts.no_anchor then times = M.anchor_downbeats(times, cand, downs, gap) end
    -- an intro before the music's pulse starts: a few detections followed by a
    -- gap the regularization filled with even beats. Those invented beats do
    -- not match the music; drop the head, so the intro keeps the speed of the
    -- first real beat
    -- (at most 4 beats, then two or more invented ones in a row)
    local lastfill
    local run = 0
    for i = 1, min(#times, 8) do
      local _, dist = nearest(cand, times[i])
      if dist and dist > 0.03 then
        run = run + 1
        if run >= 2 and i - run <= 4 then lastfill = i end
      else
        if lastfill then break end
        run = 0
      end
    end
    if lastfill and lastfill < #times - 8 then
      local head = {}
      for i = lastfill + 1, #times do head[#head + 1] = times[i] end
      times = head
    end
    P = median(intervals(times)) / spf
    bpm = 60 / (P * spf)
  else
    local f = min(1, max(0, (opts.flex or 50) / 100))
    local var = 0.06 + 0.30 * f
    local tightness = 400 * (1 - f) ^ 2 + 20
    local per = M.local_periods(o, fps, P, var, 8)
    local frames = M.track_beats(o, per, tightness)
    if #frames < 4 then return nil, "err_no_pulse" end
    times = {}
    for i, fr in ipairs(frames) do times[i] = (fr - 1) * spf end
  end
  if opts.external then
    -- external (neural) beats: shift them onto the attacks by the offset
    -- measured around each beat (per-beat snapping only with opts.ext_snap)
    if opts.align ~= false then times = M.align_attacks(times, env, envrate, opts.ext_snap) end
  elseif opts.snap ~= false then
    times = M.snap(times, env, envrate, 0.03)
  end

  -- enforce monotonic beats with a minimum gap
  local mingap = 0.4 * P * spf
  local clean = { times[1] }
  for i = 2, #times do
    if times[i] - clean[#clean] >= mingap then clean[#clean + 1] = times[i] end
  end

  clean = M.smooth(clean, opts.smooth or 0)

  if opts.external then bpm = 60 / median(intervals(clean)) end

  local meter, conf = opts.meter, nil
  if (not meter or meter < 1) and downs then meter = M.meter_from_downbeats(clean, downs) end
  if not meter or meter < 1 then meter, conf = M.meter(clean, F, spf) end
  local phase = downs and M.phase_from_downbeats(clean, downs, meter)
    or M.downbeat(clean, spf, o, F[1], meter, F.low_energy)

  -- robust local tempo range: 10th / 90th percentile of beat intervals
  local bp = {}
  for i = 2, #clean do bp[#bp + 1] = 60 / (clean[i] - clean[i - 1]) end
  table.sort(bp)
  local lo, hi = bp[1], bp[#bp]
  if #bp >= 10 then lo, hi = bp[max(1, floor(#bp * 0.1))], bp[ceil(#bp * 0.9)] end

  return { beats = clean, bpm = bpm, downbeat = phase, bpm_min = lo, bpm_max = hi, fps = fps,
           meter = meter, meter_conf = conf, alt = alt }
end

return M
end)()

if REAWARP_TEST == "dsp" then return dsp end

---------------------------------------------------------------------------
-- 2. REAPER integration
---------------------------------------------------------------------------
local core = (function()
local dsp = dsp
local r = reaper

local core = {}
local SECTION = "reawarp"
local IS_WIN = r.GetOS():match("^Win") ~= nil
local SCRIPT_DIR = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*[\\/])") or ""
local BACKEND = SCRIPT_DIR .. "backend/"
local SR = 11025 -- analysis sample rate (the accessor resamples for us)
local EXT_ORIG = "P_EXT:reawarp_orig"
local EXT_SIG = "P_EXT:reawarp_sig"
local EXT_MODE = "P_EXT:reawarp_mode" -- "warp" or "tempo": last one applied to the take
local EXT_ALT = "P_EXT:reawarp_alt" -- beats left out of the grid (source seconds), for "double"
local EXT_PREPOS = "P_EXT:reawarp_prepos"
local EXT_LASTPOS = "P_EXT:reawarp_lastpos"
local EXT_PRELEN = "P_EXT:reawarp_prelen"
local EXT_REF = "P_EXT:reawarp_ref"
local EXT_SYNC = "P_EXT:reawarp_sync"

local function set_alt(take, srcs)
  local t = {}
  for i, v in ipairs(srcs or {}) do t[i] = string.format("%.6f", v) end
  r.GetSetMediaItemTakeInfo_String(take, EXT_ALT, table.concat(t, " "), true)
end

local function get_alt(take)
  local ok, v = r.GetSetMediaItemTakeInfo_String(take, EXT_ALT, "", false)
  local t = {}
  if ok then for x in v:gmatch("%S+") do t[#t + 1] = tonumber(x) end end
  table.sort(t)
  return t
end

local COL_DOWN = r.ColorToNative(230, 60, 60) | 0x1000000
local COL_BEAT = r.ColorToNative(150, 150, 150) | 0x1000000

---------------------------------------------------------------------------
-- Strings. English is the reference; add a table to translate.
-- Language: setting "lang" (auto / en / pt-BR / es). "auto" uses REAPER's language
-- pack when one is active, otherwise the system language.
---------------------------------------------------------------------------
local STRINGS = {}

STRINGS.en = {
  err_too_short = "audio too short to analyze (at least ~4 s)",
  err_no_pulse = "no consistent pulse found",
  err_few_markers = "fewer than 2 beat markers inside the item",
  err_few_beats = "%s: too few beats after the downbeat",
  err_item = "%s: error - %s",
  err_unexpected = "Unexpected error: %s",
  busy = "reawarp is still working on the previous action.",
  working = "reawarp: processing, please wait and do not edit the item until it finishes.",
  cancelled = "reawarp: action cancelled. Undo reverts what it had already changed.",
  select_item = "Select at least one audio item.",

  set_title = "reawarp - Settings",
  set_min_bpm = "Minimum BPM",
  set_max_bpm = "Maximum BPM",
  set_bpm_hint = "Approximate BPM (0 = auto)",
  set_timesig = "Time signature (auto 4/4 3/4 6/8...)",
  set_flex = "Tempo flexibility (0-100)",
  set_every = "Stretch marker every N beats",
  set_smooth = "Smooth grid (0=off; -1=fixed tempo; N)",
  set_snap = "Snap to transients (1=yes 0=no)",
  set_follow = "Item follows tempo changes (1/0)",
  set_fix_sig = "Change project time sig (0=no 1=ask 2=always)",
  set_sync = "Sync other items (0=no 1=grouped 2=all)",
  set_lang = "Language (auto en pt-BR es)",

  set_detector = "Beat detector (auto=Beat This! or builtin)",
  det_note = " Detector: %s.",
  det_builtin = "built-in",
  bt_failed = "Beat This! failed (%s). To repair it, run 'Install the Beat This! detector...' from the reawarp menu again (it reuses what is already downloaded)",
  bt_missing = "Beat This! is not installed",
  bt_required_ask = "reawarp uses the Beat This! beat detector, which is not installed. Install it now?",
  bt_install_first = "install Beat This! first (the installer opened in a new window), then run the action again",
  bt_required = "Beat This! is not installed. Install it from the reawarp menu, or choose 'builtin' as the beat detector in the settings (less reliable)",
  menu_install = "Install the Beat This! detector...",
  menu_uninstall = "Uninstall the Beat This! detector...",
  size_cpu = "0.8 GB",
  install_ok = "Beat This! was installed. It runs on: %s. reawarp now uses it when analyzing.",
  install_fail = "The Beat This! installation failed. It needs an internet connection; you can run it again to retry."
    .. "\n\n" .. "End of the installation report:" .. "\n" .. "%s" .. "\n\n"
    .. "Copy the whole report to the clipboard (to send it with a question)?",
  copied = "The installation report was copied to the clipboard.",
  uninstall_ask = "Uninstall Beat This!? This deletes the folders env, python, uv and models in" .. "\n" .. "%s" .. "\n"
    .. "and frees about %s." .. "\n\n"
    .. "reawarp stays installed. To analyze again, install Beat This! again from the reawarp menu.",
  uninstalled = "Beat This! was uninstalled; about %s were freed.",
  uninstall_left = "Some folders could not be deleted (close any program using them and try again): %s",
  gpu_ask = "An NVIDIA graphics card was found (%s). Install the version of Beat This! that uses it?" .. "\n\n"
    .. "Yes: GPU version. The analysis is about twice as fast, but it downloads about 2.5 GB and uses about 3 GB of disk." .. "\n"
    .. "No: CPU version, about 300 MB." .. "\n"
    .. "You can change this later by running the installer again.",
  install_started = "The Beat This! installer opened in a new window. It downloads about %s and takes a few "
    .. "minutes. When it finishes, reawarp uses Beat This! automatically.",
  install_manual = "Open a terminal and run this installer:\n%s",

  sig_manual = " (from settings)",
  sig_triple = " (detected: triple)",
  sig_duple = " (detected: duple)",
  sig_duple_project = " (detected: duple; same as the project)",

  analyze_line = "%s: %.2f BPM (range %.1f to %.1f), time signature %s%s, %d beats, first downbeat at %s.",
  analyze_help = "\nTake markers 'RW bar.beat' were created. You can move or delete them before warping. "
    .. "If the downbeat is wrong, place the edit cursor on the correct beat 1 and run 'Set downbeat at edit cursor'. "
    .. "If the BPM came out at half or double, set 'Approximate BPM' in the settings and analyze again. "
    .. "If the time signature is wrong, set it in the settings (for example 3/4 or 6/8) and analyze again.",

  ask_sig = "The song is in %s, but the project is in %d/%d at this point.\n\n"
    .. "Insert the time signature %s in the project at the start of the item?\n\n"
    .. "Yes: the project's bars match the song's bars.\n"
    .. "No: the beats stay in time, but the bar lines do not match.",
  sig_inserted = " Time signature %s inserted in the project at %s",
  ask_tempo_map = "The project has a varying tempo map where the item is. Remove it and use a fixed tempo of %.0f BPM?",
  sig_restored = "; %d/%d restored at %s",
  sig_mismatch = " Warning: song in %s, project in %d/%d; the bar lines do not match.",
  warp_line = "%s: %d stretch markers. Original average tempo %.2f BPM, fitted to the project (%.2f BPM, speed %.0f%%). "
    .. "Downbeat at bar %d (%s).%s",
  warp_done = "Warp applied: %s.",
  n_items = "%d items",
  select_two_items = "Select at least two audio items: the first is the reference groove, the others are warped to match it.",
  match_line = "%s: matched to %s (%d stretch markers, %.2f -> %.2f BPM, speed %.0f%%, downbeat at %s).",
  match_done = "Groove matched to %s: %s.",

  tempo_line = "%s: %d tempo markers created from %s (bar %d), time signature %s, average tempo %.2f BPM.\n"
    .. "The item was moved %.3f s to align its downbeat. "
    .. "Note: other items with a beats timebase may have moved.",
  downbeat_set = "%s: beat %d set as beat 1 (%.0f ms from the cursor, time signature %s). Apply the warp or the tempo map again.",
  beat_at = "%s (beat %d of %d, %.1f BPM)",
  beat_moved = "%s: %s moved by %+.0f ms.",
  beat_moved_applied = "%s: %s moved by %+.0f ms, %s applied again.",
  beat_added = "%s: %s added.",
  beat_added_applied = "%s: %s added, %s applied again.",
  beat_deleted = "%s: %s deleted.",
  beat_deleted_applied = "%s: %s deleted, %s applied again.",
  cursor_off = "The edit cursor is not over any selected item.",
  restored = "%d item(s) restored to their original state. (Tempo map changes can be undone with Ctrl+Z.)",
  nothing_restored = "No selected item was modified by reawarp.",

  menu_analyze = "Analyze beats of selected items",
  menu_warp = "Warp: item follows project tempo",
  menu_tempo = "Tempo map: project follows item",
  menu_match = "Match groove: warp items to first item",
  menu_next_beat = "Next beat marker",
  menu_prev_beat = "Previous beat marker",
  menu_move_beat = "Move nearest beat marker to edit cursor",
  menu_add_beat = "Add beat marker at edit cursor",
  menu_del_beat = "Delete nearest beat marker",
  menu_downbeat = "Set downbeat at edit cursor",
  menu_restore = "Restore original items",
  menu_settings = "Settings...",
  menu_retempo = "Change the song's tempo (whole tempo map)...",
  menu_double = "Double the BPM (a beat between every two)",
  menu_halve = "Halve the BPM (every other beat)",

  undo_analyze = "reawarp: analyze beats",
  undo_warp = "reawarp: warp to project tempo",
  undo_tempo = "reawarp: tempo map from item",
  undo_match = "reawarp: match groove to first item",
  undo_next_beat = "reawarp: next beat marker",
  undo_prev_beat = "reawarp: previous beat marker",
  undo_move_beat = "reawarp: move beat marker to cursor",
  undo_add_beat = "reawarp: add beat marker at cursor",
  undo_del_beat = "reawarp: delete nearest beat marker",
  undo_downbeat = "reawarp: set downbeat",
  undo_restore = "reawarp: restore items",
  undo_retempo = "reawarp: change the song's tempo",
  undo_double = "reawarp: double the BPM",
  undo_halve = "reawarp: halve the BPM",
  regrid_done = "%s: %.1f to %.1f BPM.",
  regrid_applied = "%s: %.1f to %.1f BPM, %s applied again.",
  regrid_warp = "%s: the song now plays at %.0f%% of its original speed, at the project tempo (%.1f BPM). Warp applied again.",
  regrid_match = "%s: the item now plays at %.0f%% of its original speed, matched to %s (%.1f BPM).",
  mode_tempo = "tempo map",
  mode_warp = "warp",
  mode_match = "groove match",
  retempo_title = "reawarp - Change tempo",
  retempo_caption = "New average BPM (now %.2f)",
  retempo_done = "Tempo map scaled from %.2f to %.2f BPM (%+.1f%%, %d tempo markers).",
  retempo_none = "There are no tempo markers to change. Without a tempo map, change the project BPM directly.",
  retempo_static = " Warning: the selected item does not follow tempo changes (its timebase is 'time'), so it is no longer in sync.",
}

STRINGS["pt-BR"] = {
  err_too_short = "áudio muito curto para análise (mínimo ~4 s)",
  err_no_pulse = "nenhuma pulsação consistente encontrada",
  err_few_markers = "menos de 2 marcadores de batida dentro do item",
  err_few_beats = "%s: poucas batidas após o tempo forte",
  err_item = "%s: erro - %s",
  err_unexpected = "Erro inesperado: %s",
  busy = "o reawarp ainda está trabalhando na ação anterior.",
  working = "reawarp: processando, aguarde e não edite o item até terminar.",
  cancelled = "reawarp: ação cancelada. Desfazer reverte o que ela já tinha mudado.",
  select_item = "Selecione pelo menos um item de áudio.",

  set_title = "reawarp - Configurações",
  set_min_bpm = "BPM mínimo",
  set_max_bpm = "BPM máximo",
  set_bpm_hint = "BPM aproximado (0 = automático)",
  set_timesig = "Fórmula de compasso (auto 4/4 3/4 6/8...)",
  set_flex = "Flexibilidade do tempo (0-100)",
  set_every = "Stretch marker a cada N tempos",
  set_smooth = "Suavizar grade (0=não; -1=tempo fixo; N)",
  set_snap = "Alinhar ao transiente (1=sim 0=não)",
  set_follow = "Item segue mudanças de tempo (1/0)",
  set_fix_sig = "Ajustar compasso do projeto (0=não 1=perguntar 2=sempre)",
  set_sync = "Sincronizar outros itens (0=não 1=agrupados 2=todos)",
  set_lang = "Idioma (auto en pt-BR es)",

  set_detector = "Detector de batidas (auto=Beat This! ou builtin)",
  det_note = " Detector: %s.",
  det_builtin = "interno",
  bt_failed = "o Beat This! falhou (%s). Para repará-lo, rode de novo 'Instalar o detector Beat This!...' no menu do reawarp (ele reaproveita o que já foi baixado)",
  bt_missing = "o Beat This! não está instalado",
  bt_required_ask = "O reawarp usa o detector de batidas Beat This!, que não está instalado. Instalar agora?",
  bt_install_first = "instale o Beat This! primeiro (o instalador abriu numa nova janela) e rode a ação de novo",
  bt_required = "o Beat This! não está instalado. Instale-o pelo menu do reawarp, ou escolha 'builtin' como detector de batidas nas configurações (menos confiável)",
  menu_install = "Instalar o detector Beat This!...",
  menu_uninstall = "Desinstalar o detector Beat This!...",
  size_cpu = "0,8 GB",
  install_ok = "O Beat This! foi instalado. Ele roda em: %s. O reawarp passa a usá-lo nas análises.",
  install_fail = "A instalação do Beat This! falhou. Ela precisa de conexão com a internet; dá para rodá-la de novo."
    .. "\n\n" .. "Final do relatório da instalação:" .. "\n" .. "%s" .. "\n\n"
    .. "Copiar o relatório completo para a área de transferência (para enviar junto com uma dúvida)?",
  copied = "O relatório da instalação foi copiado para a área de transferência.",
  uninstall_ask = "Desinstalar o Beat This!? Isso apaga as pastas env, python, uv e models em" .. "\n" .. "%s" .. "\n"
    .. "e libera cerca de %s." .. "\n\n"
    .. "O reawarp continua instalado. Para analisar de novo, instale o Beat This! outra vez pelo menu do reawarp.",
  uninstalled = "O Beat This! foi desinstalado; cerca de %s foram liberados.",
  uninstall_left = "Algumas pastas não puderam ser apagadas (feche o que estiver usando essas pastas e tente de novo): %s",
  gpu_ask = "Foi encontrada uma placa de vídeo NVIDIA (%s). Instalar a versão do Beat This! que usa a placa?" .. "\n\n"
    .. "Sim: versão para GPU. A análise fica cerca de duas vezes mais rápida, mas ela baixa cerca de 2,5 GB e ocupa cerca de 3 GB." .. "\n"
    .. "Não: versão para CPU, cerca de 300 MB." .. "\n"
    .. "Dá para mudar depois rodando o instalador de novo.",
  install_started = "O instalador do Beat This! abriu numa nova janela. Ele baixa cerca de %s e leva alguns "
    .. "minutos. Quando terminar, o reawarp passa a usar o Beat This! automaticamente.",
  install_manual = "Abra um terminal e rode este instalador:\n%s",

  sig_manual = " (configurado)",
  sig_triple = " (detectado: ternário)",
  sig_duple = " (detectado: binário)",
  sig_duple_project = " (detectado: binário; mesma fórmula do projeto)",

  analyze_line = "%s: %.2f BPM (variação %.1f a %.1f), compasso %s%s, %d batidas, primeiro tempo forte em %s.",
  analyze_help = "\nMarcadores de take 'RW compasso.tempo' foram criados. Você pode movê-los ou apagá-los antes de aplicar o warp. "
    .. "Se o tempo forte estiver errado, coloque o cursor de edição sobre o tempo 1 correto e use 'Definir tempo forte no cursor de edição' (ação 'Set downbeat at edit cursor'). "
    .. "Se o BPM saiu pela metade ou pelo dobro, ajuste 'BPM aproximado' nas configurações e analise de novo. "
    .. "Se a fórmula de compasso estiver errada, defina-a nas configurações (por exemplo 3/4 ou 6/8) e analise de novo.",

  ask_sig = "A música está em %s, mas o projeto está em %d/%d nesse ponto.\n\n"
    .. "Inserir a fórmula de compasso %s no projeto, no início do item?\n\n"
    .. "Sim: os compassos do projeto coincidem com os da música.\n"
    .. "Não: as batidas ficam no tempo, mas as barras de compasso não coincidem.",
  sig_inserted = " Fórmula %s inserida no projeto em %s",
  ask_tempo_map = "O projeto tem um mapa de tempo variável no trecho do item. Remover e usar tempo fixo de %.0f BPM?",
  sig_restored = "; %d/%d restaurada em %s",
  sig_mismatch = " Atenção: música em %s, projeto em %d/%d; as barras não coincidem.",
  warp_line = "%s: %d stretch markers. Tempo original médio %.2f BPM, ajustado ao projeto (%.2f BPM, velocidade %.0f%%). "
    .. "Tempo forte no compasso %d (%s).%s",
  warp_done = "Warp aplicado: %s.",
  n_items = "%d itens",
  select_two_items = "Selecione pelo menos dois itens de áudio: o primeiro é a referência de groove e os outros serão ajustados a ele.",
  match_line = "%s: ajustado a %s (%d stretch markers, %.2f -> %.2f BPM, velocidade %.0f%%, tempo forte em %s).",
  match_done = "Groove ajustado a %s: %s.",

  tempo_line = "%s: %d marcadores de tempo criados a partir de %s (compasso %d), compasso %s, tempo médio %.2f BPM.\n"
    .. "O item foi deslocado %.3f s para alinhar o tempo forte. "
    .. "Atenção: outros itens com base de tempo em batidas podem ter se movido.",
  downbeat_set = "%s: batida %d definida como tempo 1 (%.0f ms do cursor, compasso %s). Aplique o warp ou o mapa de tempo novamente.",
  beat_at = "%s (batida %d de %d, %.1f BPM)",
  beat_moved = "%s: %s movido em %+.0f ms.",
  beat_moved_applied = "%s: %s movido em %+.0f ms, %s aplicado de novo.",
  beat_added = "%s: %s adicionado.",
  beat_added_applied = "%s: %s adicionado, %s aplicado de novo.",
  beat_deleted = "%s: %s removido.",
  beat_deleted_applied = "%s: %s removido, %s aplicado de novo.",
  cursor_off = "O cursor de edição não está sobre nenhum item selecionado.",
  restored = "%d item(ns) restaurado(s) ao estado original. (Mudanças no mapa de tempo se desfazem com Ctrl+Z.)",
  nothing_restored = "Nenhum item selecionado foi modificado pelo reawarp.",

  menu_analyze = "Analisar batidas dos itens selecionados",
  menu_warp = "Warp: item segue o tempo do projeto",
  menu_tempo = "Mapa de tempo: projeto segue o item",
  menu_match = "Combinar groove: ajustar itens ao primeiro item",
  menu_next_beat = "Próximo marcador de batida",
  menu_prev_beat = "Marcador de batida anterior",
  menu_move_beat = "Mover marcador de batida mais próximo para o cursor de edição",
  menu_add_beat = "Adicionar marcador de batida no cursor de edição",
  menu_del_beat = "Remover marcador de batida mais próximo",
  menu_downbeat = "Definir tempo forte no cursor de edição",
  menu_restore = "Restaurar itens originais",
  menu_settings = "Configurações...",
  menu_retempo = "Alterar o tempo da música (mapa de tempo inteiro)...",
  menu_double = "Dobrar o BPM (uma batida entre cada duas)",
  menu_halve = "BPM pela metade (uma batida sim, outra não)",

  undo_analyze = "reawarp: analisar batidas",
  undo_warp = "reawarp: warp para o tempo do projeto",
  undo_tempo = "reawarp: mapa de tempo a partir do item",
  undo_match = "reawarp: combinar groove com o primeiro item",
  undo_next_beat = "reawarp: próximo marcador de batida",
  undo_prev_beat = "reawarp: marcador de batida anterior",
  undo_move_beat = "reawarp: mover marcador de batida para o cursor",
  undo_add_beat = "reawarp: adicionar marcador de batida no cursor",
  undo_del_beat = "reawarp: remover marcador de batida mais próximo",
  undo_downbeat = "reawarp: definir tempo forte",
  undo_restore = "reawarp: restaurar itens",
  undo_retempo = "reawarp: alterar o tempo da música",
  undo_double = "reawarp: dobrar o BPM",
  undo_halve = "reawarp: BPM pela metade",
  regrid_done = "%s: de %.1f para %.1f BPM.",
  regrid_applied = "%s: de %.1f para %.1f BPM, %s aplicado de novo.",
  regrid_warp = "%s: a música agora toca a %.0f%% da velocidade original, no tempo do projeto (%.1f BPM). Warp aplicado de novo.",
  regrid_match = "%s: o item agora toca a %.0f%% da velocidade original, ajustado a %s (%.1f BPM).",
  mode_tempo = "mapa de tempo",
  mode_warp = "warp",
  mode_match = "combinar groove",
  retempo_title = "reawarp - Alterar o tempo",
  retempo_caption = "Novo BPM médio (atual %.2f)",
  retempo_done = "Mapa de tempo alterado de %.2f para %.2f BPM (%+.1f%%, %d marcadores de tempo).",
  retempo_none = "Não há marcadores de tempo para alterar. Sem mapa de tempo, mude o BPM do projeto diretamente.",
  retempo_static = " Atenção: o item selecionado não acompanha mudanças de tempo (base de tempo 'time'), então deixou de estar sincronizado.",
}

STRINGS.es = {
  err_too_short = "el audio es demasiado corto para analizarlo (se necesitan al menos ~4 s)",
  err_no_pulse = "no se encontró un pulso regular",
  err_few_markers = "hay menos de 2 marcadores de pulso dentro del ítem",
  err_few_beats = "%s: hay muy pocos pulsos después del tiempo fuerte",
  err_item = "%s: error - %s",
  err_unexpected = "Error inesperado: %s",
  busy = "reawarp todavía está procesando la acción anterior.",
  working = "reawarp: procesando. Espere y no edite el ítem hasta que termine.",
  cancelled = "reawarp: acción cancelada. Con Deshacer se revierte lo que ya se había cambiado.",
  select_item = "Seleccione al menos un ítem de audio.",

  set_title = "reawarp - Ajustes",
  set_min_bpm = "BPM mínimo",
  set_max_bpm = "BPM máximo",
  set_bpm_hint = "BPM aproximado (0 = automático)",
  set_timesig = "Compás (auto 4/4 3/4 6/8...)",
  set_flex = "Flexibilidad de tempo (0-100)",
  set_every = "Un stretch marker cada N pulsos",
  set_smooth = "Suavizar cuadrícula (0=no; -1=tempo fijo; N)",
  set_snap = "Ajustar a transitorios (1=sí 0=no)",
  set_follow = "El ítem sigue los cambios de tempo (1/0)",
  set_fix_sig = "Cambiar compás del proyecto (0=no 1=preguntar 2=siempre)",
  set_sync = "Sincronizar otros ítems (0=no 1=agrupados 2=todos)",
  set_lang = "Idioma (auto en pt-BR es)",

  set_detector = "Detector de pulsos (auto=Beat This! o builtin)",
  det_note = " Detector: %s.",
  det_builtin = "integrado",
  bt_failed = "Beat This! falló (%s). Para repararlo, vuelva a ejecutar 'Instalar el detector Beat This!...' desde el menú de reawarp (aprovecha lo que ya se descargó)",
  bt_missing = "Beat This! no está instalado",
  bt_required_ask = "reawarp usa el detector de pulsos Beat This!, que no está instalado. ¿Desea instalarlo ahora?",
  bt_install_first = "primero instale Beat This! (el instalador se abrió en una ventana nueva) y luego vuelva a ejecutar la acción",
  bt_required = "Beat This! no está instalado. Instálelo desde el menú de reawarp o elija 'builtin' como detector de pulsos en los ajustes (es menos fiable)",
  menu_install = "Instalar el detector Beat This!...",
  menu_uninstall = "Desinstalar el detector Beat This!...",
  size_cpu = "0,8 GB",
  install_ok = "Beat This! se instaló correctamente. Se ejecuta en: %s. A partir de ahora reawarp lo usará en los análisis.",
  install_fail = "La instalación de Beat This! falló. Requiere conexión a internet; puede volver a ejecutarla para intentarlo de nuevo."
    .. "\n\n" .. "Final del registro de instalación:" .. "\n" .. "%s" .. "\n\n"
    .. "¿Copiar el registro completo al portapapeles (para adjuntarlo a una consulta)?",
  copied = "El registro de instalación se copió al portapapeles.",
  uninstall_ask = "¿Desinstalar Beat This!? Se eliminarán las carpetas env, python, uv y models de" .. "\n" .. "%s" .. "\n"
    .. "y se liberarán unos %s." .. "\n\n"
    .. "reawarp seguirá instalado. Para volver a analizar, instale de nuevo Beat This! desde el menú de reawarp.",
  uninstalled = "Beat This! se desinstaló; se liberaron unos %s.",
  uninstall_left = "No se pudieron eliminar algunas carpetas (cierre cualquier programa que las esté usando y vuelva a intentarlo): %s",
  gpu_ask = "Se detectó una tarjeta gráfica NVIDIA (%s). ¿Instalar la versión de Beat This! que la aprovecha?" .. "\n\n"
    .. "Sí: versión para GPU. El análisis es aproximadamente el doble de rápido, pero descarga unos 2,5 GB y ocupa unos 3 GB en disco." .. "\n"
    .. "No: versión para CPU, de unos 300 MB." .. "\n"
    .. "Puede cambiarlo más adelante volviendo a ejecutar el instalador.",
  install_started = "El instalador de Beat This! se abrió en una ventana nueva. Descarga unos %s y tarda algunos "
    .. "minutos. Cuando termine, reawarp usará Beat This! automáticamente.",
  install_manual = "Abra una terminal y ejecute este instalador:\n%s",

  sig_manual = " (según los ajustes)",
  sig_triple = " (detectado: ternario)",
  sig_duple = " (detectado: binario)",
  sig_duple_project = " (detectado: binario; igual que el del proyecto)",

  analyze_line = "%s: %.2f BPM (rango de %.1f a %.1f), compás %s%s, %d pulsos, primer tiempo fuerte en %s.",
  analyze_help = "\nSe crearon marcadores de toma 'RW compás.pulso'. Puede moverlos o eliminarlos antes de aplicar el warp. "
    .. "Si el tiempo fuerte es incorrecto, coloque el cursor de edición sobre el pulso 1 correcto y ejecute 'Fijar el tiempo fuerte en el cursor de edición' (acción 'Set downbeat at edit cursor'). "
    .. "Si el BPM salió a la mitad o al doble, indique un 'BPM aproximado' en los ajustes y vuelva a analizar. "
    .. "Si el compás es incorrecto, indíquelo en los ajustes (por ejemplo 3/4 o 6/8) y vuelva a analizar.",

  ask_sig = "La canción está en %s, pero en este punto el proyecto está en %d/%d.\n\n"
    .. "¿Insertar el compás %s en el proyecto al inicio del ítem?\n\n"
    .. "Sí: los compases del proyecto coincidirán con los de la canción.\n"
    .. "No: los pulsos quedan a tiempo, pero las líneas de compás no coinciden.",
  sig_inserted = " Compás %s insertado en el proyecto en %s",
  ask_tempo_map = "El proyecto tiene un mapa de tempo variable en la zona del ítem. ¿Eliminarlo y usar un tempo fijo de %.0f BPM?",
  sig_restored = "; %d/%d restaurado en %s",
  sig_mismatch = " Atención: la canción está en %s y el proyecto en %d/%d; las líneas de compás no coinciden.",
  warp_line = "%s: %d stretch markers. Tempo medio original %.2f BPM, ajustado al proyecto (%.2f BPM, velocidad %.0f%%). "
    .. "Tiempo fuerte en el compás %d (%s).%s",
  warp_done = "Warp aplicado: %s.",
  n_items = "%d ítems",
  select_two_items = "Seleccione al menos dos ítems de audio: el primero es la referencia de groove y los demás se ajustarán a él.",
  match_line = "%s: ajustado a %s (%d stretch markers, %.2f -> %.2f BPM, velocidad %.0f%%, tiempo fuerte en %s).",
  match_done = "Groove ajustado a %s: %s.",

  tempo_line = "%s: se crearon %d marcadores de tempo a partir de %s (compás n.º %d), compás %s, tempo medio %.2f BPM.\n"
    .. "El ítem se movió %.3f s para alinear su tiempo fuerte. "
    .. "Nota: es posible que otros ítems con base de tiempo en pulsos se hayan movido.",
  downbeat_set = "%s: el pulso %d es ahora el pulso 1 (a %.0f ms del cursor, compás %s). Vuelva a aplicar el warp o el mapa de tempo.",
  beat_at = "%s (pulso %d de %d, %.1f BPM)",
  beat_moved = "%s: %s movido %+.0f ms.",
  beat_moved_applied = "%s: %s movido %+.0f ms; se volvió a aplicar el %s.",
  beat_added = "%s: %s añadido.",
  beat_added_applied = "%s: %s añadido; se volvió a aplicar el %s.",
  beat_deleted = "%s: %s eliminado.",
  beat_deleted_applied = "%s: %s eliminado; se volvió a aplicar el %s.",
  cursor_off = "El cursor de edición no está sobre ningún ítem seleccionado.",
  restored = "%d ítem(s) volvieron a su estado original. (Los cambios en el mapa de tempo se pueden deshacer con Ctrl+Z.)",
  nothing_restored = "reawarp no modificó ninguno de los ítems seleccionados.",

  menu_analyze = "Analizar los pulsos de los ítems seleccionados",
  menu_warp = "Warp: el ítem sigue el tempo del proyecto",
  menu_tempo = "Mapa de tempo: el proyecto sigue al ítem",
  menu_match = "Igualar groove: ajustar ítems al primer ítem",
  menu_next_beat = "Siguiente marcador de pulso",
  menu_prev_beat = "Marcador de pulso anterior",
  menu_move_beat = "Mover el marcador de pulso más cercano al cursor de edición",
  menu_add_beat = "Añadir marcador de pulso en el cursor de edición",
  menu_del_beat = "Eliminar el marcador de pulso más cercano",
  menu_downbeat = "Fijar el tiempo fuerte en el cursor de edición",
  menu_restore = "Restaurar los ítems originales",
  menu_settings = "Ajustes...",
  menu_retempo = "Cambiar el tempo de la canción (todo el mapa de tempo)...",
  menu_double = "Duplicar el BPM (un pulso entre cada dos)",
  menu_halve = "Reducir el BPM a la mitad (un pulso de cada dos)",

  undo_analyze = "reawarp: analizar pulsos",
  undo_warp = "reawarp: warp al tempo del proyecto",
  undo_tempo = "reawarp: mapa de tempo desde el ítem",
  undo_match = "reawarp: igualar groove al primer ítem",
  undo_next_beat = "reawarp: siguiente marcador de pulso",
  undo_prev_beat = "reawarp: marcador de pulso anterior",
  undo_move_beat = "reawarp: mover marcador de pulso al cursor",
  undo_add_beat = "reawarp: añadir marcador de pulso en el cursor",
  undo_del_beat = "reawarp: eliminar marcador de pulso más cercano",
  undo_downbeat = "reawarp: fijar el tiempo fuerte",
  undo_restore = "reawarp: restaurar ítems",
  undo_retempo = "reawarp: cambiar el tempo de la canción",
  undo_double = "reawarp: duplicar el BPM",
  undo_halve = "reawarp: reducir el BPM a la mitad",
  regrid_done = "%s: de %.1f a %.1f BPM.",
  regrid_applied = "%s: de %.1f a %.1f BPM; se volvió a aplicar el %s.",
  regrid_warp = "%s: la canción ahora suena al %.0f%% de su velocidad original, al tempo del proyecto (%.1f BPM). Se volvió a aplicar el warp.",
  regrid_match = "%s: el ítem ahora suena al %.0f%% de su velocidad original, ajustado a %s (%.1f BPM).",
  mode_tempo = "mapa de tempo",
  mode_warp = "warp",
  mode_match = "igualar groove",
  retempo_title = "reawarp - Cambiar el tempo",
  retempo_caption = "Nuevo BPM medio (actual: %.2f)",
  retempo_done = "Mapa de tempo escalado de %.2f a %.2f BPM (%+.1f%%, %d marcadores de tempo).",
  retempo_none = "No hay marcadores de tempo que cambiar. Sin mapa de tempo, cambie directamente el BPM del proyecto.",
  retempo_static = " Atención: el ítem seleccionado no sigue los cambios de tempo (su base de tiempo es 'time'), por lo que ya no está sincronizado.",
}

local L = STRINGS.en

-- Translated string (txt); with extra arguments it is used as a format string.
local function txt(key, ...)
  local str = L[key] or STRINGS.en[key] or key
  if select("#", ...) > 0 then return string.format(str, ...) end
  return str
end

-- "auto": REAPER language pack if active, else the system locale
local function detect_lang()
  local name = ""
  local f = r.get_ini_file and io.open(r.get_ini_file(), "r")
  if f then
    for line in f:lines() do
      local lp = line:match("^langpack=(.*)$")
      if lp then name = lp:lower(); break end
    end
    f:close()
  end
  if name == "" or name == "<>" then
    local ok, prev = pcall(os.setlocale)
    if ok then
      local ok2, sys = pcall(os.setlocale, "")
      pcall(os.setlocale, prev) -- restore: number formatting depends on it
      name = (ok2 and sys or ""):lower()
    end
  end
  if name:match("^pt") or name:match("portug") or name:match("brazil") then return "pt-BR" end
  if name == "es" or name:match("^es[_%-%.]") or name:match("spanish") or name:match("espa") then return "es" end
  return "en"
end

-- STRINGS table for a code ("pt-BR", "pt", "en"...), matching by prefix
local function find_lang(code)
  code = tostring(code or ""):lower()
  if code == "" then return nil end
  for k, t in pairs(STRINGS) do
    local kl = k:lower()
    if kl == code or kl:sub(1, #code) == code or code:sub(1, #kl) == kl then return t end
  end
end

local function set_lang(code)
  code = tostring(code or "auto")
  if code:lower() == "auto" then code = detect_lang() end
  L = find_lang(code) or STRINGS.en
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
local FIELDS = {
  { "min_bpm", 60, "set_min_bpm" },
  { "max_bpm", 180, "set_max_bpm" },
  { "bpm_hint", 0, "set_bpm_hint" },
  { "timesig", "auto", "set_timesig" },
  { "flex", 50, "set_flex" },
  { "every", 1, "set_every" },
  { "smooth", 0, "set_smooth" },
  { "snap", 1, "set_snap" },
  { "follow", 1, "set_follow" },
  { "fix_sig", 1, "set_fix_sig" },
  { "sync", 0, "set_sync" },
  { "detector", "auto", "set_detector" },
  { "lang", "auto", "set_lang" },
}

local function field_value(f, raw)
  if type(f[2]) == "string" then
    raw = raw and raw:gsub("^%s+", ""):gsub("%s+$", "") or ""
    return raw ~= "" and raw or f[2]
  end
  return tonumber(raw and (raw:gsub("%s", ""))) or f[2]
end

function core.load_settings()
  local s = {}
  for _, f in ipairs(FIELDS) do s[f[1]] = field_value(f, r.GetExtState(SECTION, f[1])) end
  return s
end

function core.save_settings(s)
  for _, f in ipairs(FIELDS) do r.SetExtState(SECTION, f[1], tostring(s[f[1]]), true) end
end

-- "4/4", "3/4", "6/8"... -> { num, den, group = beats per bar, qn = quarter notes per beat }
-- Compound meters (6/8, 9/8, 12/8) count dotted-quarter beats.
local function parse_sig(str)
  local n, d = tostring(str or ""):match("^%s*(%d+)%s*/%s*(%d+)%s*$")
  n, d = tonumber(n), tonumber(d)
  if not n or not d or n < 1 or d < 1 then return nil end
  if d == 8 and n > 3 and n % 3 == 0 then return { num = n, den = d, group = n // 3, qn = 1.5 } end
  return { num = n, den = d, group = n, qn = 4 / d }
end

local function sig_str(g) return g.num .. "/" .. g.den end

-- 2/4, 4/4 and 2/2 cannot be told apart reliably from audio, and their bar
-- lines coincide every 4 quarter notes: treat them as interchangeable.
local function duple(num, den) return (num == 2 or num == 4) and (den == 2 or den == 4) end
local function sig_compatible(sig, pnum, pden)
  return (sig.num == pnum and sig.den == pden) or (duple(sig.num, sig.den) and duple(pnum, pden))
end

function core.settings_dialog(s)
  local caps, vals = {}, {}
  for _, f in ipairs(FIELDS) do
    caps[#caps + 1] = txt(f[3])
    vals[#vals + 1] = tostring(s[f[1]])
  end
  local ok, csv = r.GetUserInputs(txt("set_title"), #FIELDS,
    table.concat(caps, ",") .. ",extrawidth=80", table.concat(vals, ","))
  if not ok then return false end
  local i = 0
  for v in (csv .. ","):gmatch("([^,]*),") do
    i = i + 1
    local f = FIELDS[i]
    if f then s[f[1]] = field_value(f, v) end
  end
  if s.timesig:lower() == "auto" or not parse_sig(s.timesig) then s.timesig = "auto" end
  local det = s.detector:lower()
  if det ~= "builtin" and det ~= "beat_this" then s.detector = "auto" else s.detector = det end
  local lang = s.lang:lower()
  if lang ~= "auto" and not find_lang(lang) then s.lang = "auto" end
  s.every = math.max(1, math.floor(s.every))
  s.smooth = math.floor(s.smooth)
  s.sync = (s.sync == 1 or s.sync == 2) and s.sync or 0
  if s.min_bpm >= s.max_bpm then s.min_bpm, s.max_bpm = 60, 180 end
  core.save_settings(s)
  return true
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function msg(text) r.ShowMessageBox(text, "reawarp", 0) end

local function tstr(t) return r.format_timestr_pos(t, "", 0) end

local function escape(s) return (s:gsub("\\", "\\\\"):gsub("\r", "\\r"):gsub("\n", "\\n")) end
local function unescape(s)
  return (s:gsub("\\(.)", function(c) return c == "n" and "\n" or c == "r" and "\r" or c end))
end

local function selected_takes()
  local list = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local item = r.GetSelectedMediaItem(0, i)
    local take = r.GetActiveTake(item)
    if take and not r.TakeIsMIDI(take) then
      list[#list + 1] = { item = item, take = take, name = r.GetTakeName(take) }
    end
  end
  return list
end

-- Song time signature: manual setting > stored analysis > 4/4
local function take_sig(take, s)
  local m = parse_sig(s.timesig)
  if m then return m end
  local ok, v = r.GetSetMediaItemTakeInfo_String(take, EXT_SIG, "", false)
  return (ok and parse_sig(v)) or parse_sig("4/4")
end

local function stretch_markers(take)
  local t = {}
  for i = 0, r.GetTakeNumStretchMarkers(take) - 1 do
    local _, pos, src = r.GetTakeStretchMarker(take, i)
    t[#t + 1] = { pos = pos, src = src }
  end
  return t
end

-- Item time (sec from item start) -> source seconds relative to the item start,
-- honoring playrate and stretch markers. Only differences of srcpos are used, so
-- it does not depend on how REAPER offsets stretch-marker source positions.
local function item_to_rel_src(take, t)
  local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local sm = stretch_markers(take)
  if #sm == 0 then return t * rate end
  local base = sm[1].src - sm[1].pos * rate
  if t <= sm[1].pos then return sm[1].src + (t - sm[1].pos) * rate - base end
  for i = 1, #sm - 1 do
    local a, b = sm[i], sm[i + 1]
    if t <= b.pos then
      local u = b.pos > a.pos and (t - a.pos) / (b.pos - a.pos) or 0
      return a.src + u * (b.src - a.src) - base
    end
  end
  local z = sm[#sm]
  return z.src + (t - z.pos) * rate - base
end

-- Inverse of item_to_rel_src: source seconds relative to item start -> item
-- time (seconds from item start), honoring playrate and stretch markers.
local function rel_src_to_item(take, rel_src)
  local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local sm = stretch_markers(take)
  if #sm == 0 then return rel_src / rate end
  local base = sm[1].src - sm[1].pos * rate
  local src = rel_src + base
  if src <= sm[1].src then return sm[1].pos + (src - sm[1].src) / rate end
  for i = 1, #sm - 1 do
    local a, b = sm[i], sm[i + 1]
    if src <= b.src then
      local u = b.src > a.src and (src - a.src) / (b.src - a.src) or 0
      return a.pos + u * (b.pos - a.pos)
    end
  end
  local z = sm[#sm]
  return z.pos + (src - z.src) / rate
end

local function item_guid(item)
  local ok, g = r.GetSetMediaItemInfo_String(item, "GUID", "", false)
  return (ok and g ~= "") and g or nil
end

local function find_take_by_guid(guid)
  if not guid or guid == "" or not r.CountMediaItems then return nil end
  for i = 0, r.CountMediaItems(0) - 1 do
    local item = r.GetMediaItem(0, i)
    if item and item_guid(item) == guid then
      local take = r.GetActiveTake(item)
      if take and not r.TakeIsMIDI(take) then
        return { item = item, take = take, name = r.GetTakeName(take) }
      end
    end
  end
  return nil
end

-- Save the item's full state the first time reawarp touches it.
local function remember_original(item)
  local ok, v = r.GetSetMediaItemInfo_String(item, EXT_ORIG, "", false)
  if ok and v ~= "" then return end
  local _, chunk = r.GetItemStateChunk(item, "", false)
  r.GetSetMediaItemInfo_String(item, EXT_ORIG, escape(chunk), true)
end

local function unwarped_pos(item)
  local cur = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local okp, pre = r.GetSetMediaItemInfo_String(item, EXT_PREPOS, "", false)
  local okl, last = r.GetSetMediaItemInfo_String(item, EXT_LASTPOS, "", false)
  pre, last = okp and tonumber(pre), okl and tonumber(last)
  if pre and last and math.abs(cur - last) < 1e-4 then return pre, last end
  return cur, cur
end

local function unwarped_len(item, take)
  if take and not r.TakeIsMIDI(take) then
    return item_to_rel_src(take, r.GetMediaItemInfo_Value(item, "D_LENGTH"))
  end
  local okl, prelen = r.GetSetMediaItemInfo_String(item, EXT_PRELEN, "", false)
  return (okl and tonumber(prelen)) or r.GetMediaItemInfo_Value(item, "D_LENGTH")
end

local function set_lastpos(item, pos)
  r.GetSetMediaItemInfo_String(item, EXT_LASTPOS, string.format("%.9f", pos), true)
end

local function set_prepos(item, pos)
  r.GetSetMediaItemInfo_String(item, EXT_PREPOS, string.format("%.9f", pos), true)
end

-- Bring the item and take back to natural speed and pre-warp position:
-- playrate 1, no stretch markers, same source window.
local function neutralize(item, take, keep_pos)
  local tb = r.GetMediaItemInfo_Value(item, "C_BEATATTACHMODE")
  if tb ~= 0 then r.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", 0) end
  local cur = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local pos, last = cur, cur
  if not keep_pos then
    pos, last = unwarped_pos(item)
    r.SetMediaItemInfo_Value(item, "D_POSITION", pos)
    set_prepos(item, pos)
  end
  if take and not r.TakeIsMIDI(take) then
    local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local natlen = item_to_rel_src(take, len)
    local n = r.GetTakeNumStretchMarkers(take)
    if n > 0 then r.DeleteTakeStretchMarkers(take, 0, n) end
    r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 1)
    r.SetMediaItemInfo_Value(item, "D_LENGTH", natlen)
  else
    local okl, prelen = r.GetSetMediaItemInfo_String(item, EXT_PRELEN, "", false)
    local natlen = okl and tonumber(prelen)
    if natlen and natlen > 0 then
      if take then r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 1) end
      r.SetMediaItemInfo_Value(item, "D_LENGTH", natlen)
    else
      local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
      r.GetSetMediaItemInfo_String(item, EXT_PRELEN, string.format("%.9f", len), true)
    end
  end
  if tb ~= 0 then r.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", tb) end
  r.UpdateItemInProject(item)
  return pos, last
end

-- Collect unlocked follower items overlapping [min_t, max_t] according to s.sync
-- (0 = off, 1 = same item group as guide_item, 2 = all overlapping), neutralize
-- them, and freeze their timebase to Time (0) while the guide item is processed.
local function collect_followers(guide_item, s, min_t, max_t, keep_pos)
  local mode = s and s.sync or 0
  if mode ~= 1 and mode ~= 2 then return {} end
  local gid = r.GetMediaItemInfo_Value(guide_item, "I_GROUPID") or 0
  if mode == 1 and gid == 0 then return {} end
  local gguid = item_guid(guide_item) or "1"
  local list = {}
  local total = r.CountMediaItems and r.CountMediaItems(0) or 0
  for i = 0, total - 1 do
    local other = r.GetMediaItem(0, i)
    if other and other ~= guide_item then
      local lock = r.GetMediaItemInfo_Value(other, "C_LOCK") or 0
      local ogid = r.GetMediaItemInfo_Value(other, "I_GROUPID") or 0
      if (math.floor(lock) & 1) == 0 and (mode == 2 or ogid == gid) then
        local take = r.GetActiveTake(other)
        local pos = keep_pos and r.GetMediaItemInfo_Value(other, "D_POSITION") or unwarped_pos(other)
        local len = unwarped_len(other, take)
        if pos < max_t - 1e-6 and pos + len > min_t + 1e-6 then
          remember_original(other)
          r.GetSetMediaItemInfo_String(other, EXT_SYNC, gguid, true)
          local tb = r.GetMediaItemInfo_Value(other, "C_BEATATTACHMODE")
          r.SetMediaItemInfo_Value(other, "C_BEATATTACHMODE", 0)
          neutralize(other, take, keep_pos)
          pos = r.GetMediaItemInfo_Value(other, "D_POSITION")
          len = r.GetMediaItemInfo_Value(other, "D_LENGTH")
          list[#list + 1] = {
            item = other, take = take, pos = pos, len = len,
            timebase = tb, is_midi = take and r.TakeIsMIDI(take) or false,
          }
        end
      end
    end
  end
  return list
end

---------------------------------------------------------------------------
-- RW take markers
---------------------------------------------------------------------------
local function rw_markers(take)
  local list = {}
  for i = 0, r.GetNumTakeMarkers(take) - 1 do
    local src, name = r.GetTakeMarker(take, i)
    if src >= 0 and name:match("^RW %-?%d+%.%d+") then
      list[#list + 1] = { idx = i, src = src, name = name, edited = name:match("%*$") ~= nil }
    end
  end
  table.sort(list, function(a, b) return a.src < b.src end)
  return list
end

local function clear_rw_markers(take)
  for i = r.GetNumTakeMarkers(take) - 1, 0, -1 do
    local _, name = r.GetTakeMarker(take, i)
    if name:match("^RW") then r.DeleteTakeMarker(take, i) end
  end
end

local function label(j, down, group, edited)
  local rel = j - down
  local beat = rel % group + 1
  local s = string.format("RW %d.%d", rel // group + 1, beat)
  if edited then s = s .. " *" end
  return s, beat == 1 and COL_DOWN or COL_BEAT
end

-- Rename markers so that list[down] is bar 1 beat 1 (renaming keeps indices).
local function relabel(take, list, down, group)
  for j, m in ipairs(list) do
    local name, col = label(j, down, group, m.edited)
    if name ~= m.name then
      r.SetTakeMarker(take, m.idx, name, m.src, col)
      m.name = name
    end
  end
end

-- Index of the downbeat to anchor on: first marker labelled "<bar>.1" with bar >= 1.
local function downbeat_index(list)
  local fallback
  for j, m in ipairs(list) do
    local bar, beat = m.name:match("^RW (%-?%d+)%.(%d+)")
    if beat == "1" then
      if tonumber(bar) >= 1 then return j end
      fallback = fallback or j
    end
  end
  return fallback or 1
end

---------------------------------------------------------------------------
-- Optional Beat This! backend (backend/, installed by install_beat_this.*)
---------------------------------------------------------------------------
local function native(path) return IS_WIN and (path:gsub("/", "\\")) or path end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

-- Read samples from an accessor. GetAudioAccessorSamples fails (returns
-- nothing, the buffer stays silent) when called from a coroutine, so inside
-- the action's coroutine the read is handed to core.run, which does it in the
-- main state and resumes with the result.
local function direct_read(acc, sr, nch, t, n, buf)
  if r.AudioAccessorStateChanged and r.AudioAccessorStateChanged(acc) then r.AudioAccessorUpdate(acc) end
  return r.GetAudioAccessorSamples(acc, sr, nch, t, n, buf)
end
local function read_samples(acc, sr, nch, t, n, buf)
  if coroutine.isyieldable() then return coroutine.yield({ read = { acc, sr, nch, t, n, buf } }) end
  return direct_read(acc, sr, nch, t, n, buf)
end

local function backend_python()
  local p = BACKEND .. (IS_WIN and "env/Scripts/python.exe" or "env/bin/python")
  return file_exists(p) and p or nil
end

local function source_channels(src)
  if not src then return 1 end
  local nch = r.GetMediaSourceNumChannels(src)
  if nch < 1 and r.GetMediaSourceParent then
    local p = r.GetMediaSourceParent(src)
    if p then nch = r.GetMediaSourceNumChannels(p) end
  end
  return math.max(1, nch)
end

-- mono 16-bit WAV of the accessor's audio at sr (downmixing all channels)
local function write_wav(path, acc, t0, t1, nch, sr)
  local f = io.open(path, "wb")
  if not f then return false end
  local n = math.floor((t1 - t0) * sr)
  f:write("RIFF", string.pack("<I4", 36 + 2 * n), "WAVEfmt ",
    string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, sr, 2 * sr, 2, 16), "data", string.pack("<I4", 2 * n))
  local BLK = math.max(256, math.min(4096, math.floor(65536 / nch)))
  local buf = r.new_array(BLK * nch)
  local fmt = "<" .. string.rep("i2", BLK)
  local ints = {}
  local scale = nch == 2 and 0.5 or (1 / math.sqrt(nch))
  for pos = 0, n - 1, BLK do
    breath()
    local m = math.min(BLK, n - pos)
    buf.clear()
    read_samples(acc, sr, nch, t0 + pos / sr, m, buf)
    local t = buf.table(1, m * nch)
    if nch == 1 then
      for i = 1, m do
        local v = t[i]
        if v > 1 then v = 1 elseif v < -1 then v = -1 end
        ints[i] = math.floor(v * 32767 + 0.5)
      end
    elseif nch == 2 then
      for i = 1, m do
        local v = 0.5 * (t[2 * i - 1] + t[2 * i])
        if v > 1 then v = 1 elseif v < -1 then v = -1 end
        ints[i] = math.floor(v * 32767 + 0.5)
      end
    else
      local base = 0
      for i = 1, m do
        local s = 0
        for c = 1, nch do s = s + t[base + c] end
        base = base + nch
        local v = s * scale
        if v > 1 then v = 1 elseif v < -1 then v = -1 end
        ints[i] = math.floor(v * 32767 + 0.5)
      end
    end
    f:write(m == BLK and string.pack(fmt, table.unpack(ints, 1, m))
      or string.pack("<" .. string.rep("i2", m), table.unpack(ints, 1, m)))
  end
  f:close()
  return true
end

-- Beats and downbeats from Beat This!, in seconds from t0.
-- Returns nil when not installed, or nil + message when it fails.
-- the result file of the backend: res, or nil + error, or nil when not complete yet
local function read_bt_output(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local res, err, complete = { beats = {}, downbeats = {} }, nil, false
  for line in f:lines() do
    local key, rest = line:match("^(%a+)%s*(.*)$")
    if key == "error" then err = rest; complete = true
    elseif res[key or ""] then
      for v in rest:gmatch("%S+") do res[key][#res[key] + 1] = tonumber(v) end
      if key == "downbeats" then complete = true end
    end
  end
  f:close()
  if not complete then return nil end
  if err then return nil, err end
  return res
end

local function run_beat_this(acc, t0, t1, nch)
  local py = backend_python()
  if not py then return nil end
  -- temporary files outside REAPER's folder (it may be synced to the cloud)
  local tmp = (os.getenv("TEMP") or os.getenv("TMPDIR") or (not IS_WIN and "/tmp") or BACKEND):gsub("[\\/]$", "")
  local base = string.format("%s/reawarp_%d_%d", tmp, os.time(), math.random(1e6))
  local wav, out, fail, run = base .. ".wav", base .. ".txt", base .. ".fail", base .. ".txt.run"
  if not write_wav(wav, acc, t0, t1, nch, 22050) then return nil, "cannot write " .. wav end
  local function q(x) return '"' .. native(x) .. '"' end
  local args = table.concat({ q(py), q(BACKEND .. "reawarp_beat_this.py"), q(wav), q(out) }, " ")
  local res, err
  if coroutine.isyieldable() and r.defer and not core.sync then
    -- in the background: REAPER keeps responding while it runs.
    local launch
    if IS_WIN then
      -- pythonw: no console window over REAPER. Without a shell around it, a
      -- Python that does not start is noticed by the missing .run file, which
      -- the backend writes first thing.
      local pyw = py:gsub("python%.exe$", "pythonw.exe")
      launch = args:gsub('^"[^"]*"', function() return q(file_exists(pyw) and pyw or py) end, 1)
    else
      launch = string.format("/bin/sh -c '%s || echo backend did not start > %s'", args, q(fail))
    end
    r.ExecProcess(launch, -1)
    local start = r.time_precise()
    while true do
      coroutine.yield()
      res, err = read_bt_output(out)
      if res or err then break end
      local waited = r.time_precise() - start
      if file_exists(fail) or (waited > 60 and not file_exists(run)) then
        res, err = read_bt_output(out) -- finished just now?
        if not (res or err) then err = "Beat This! did not start (" .. native(py) .. ")" end
        break
      end
      if waited > 600 then err = "timeout"; break end
    end
  else
    local ret = r.ExecProcess(args, 600000) or ""
    res, err = read_bt_output(out)
    if not (res or err) then err = (ret:gsub("%s+", " ")):sub(1, 200) end
  end
  os.remove(wav)
  os.remove(out)
  os.remove(fail)
  os.remove(run)
  if err then return nil, err end
  if not res or #res.beats < 4 then return nil, "no beats" end
  return res
end

-- name of the NVIDIA graphics card, if any (Windows and Linux: macOS uses the
-- GPU of Apple silicon with the standard PyTorch)
local function nvidia_gpu()
  if not IS_WIN and (r.GetOS():match("^OSX") or r.GetOS():match("^macOS")) then return nil end
  local out = r.ExecProcess("nvidia-smi --query-gpu=name --format=csv,noheader", 5000) or ""
  local code, rest = out:match("^(%-?%d+)%s*\n(.*)$")
  if code ~= "0" then return nil end
  local name = rest:match("^%s*([^\r\n]-)%s*[\r\n]") or rest:match("^%s*(.-)%s*$")
  return name ~= "" and name or nil
end

local function is_mac() return r.GetOS():match("^OSX") or r.GetOS():match("^macOS") end

-- text to the clipboard: SWS when installed, else the system's own tool
local function copy_to_clipboard(text)
  if r.CF_SetClipboard then r.CF_SetClipboard(text); return end
  local tmp = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("[\\/]$", "") .. "/reawarp_clip.txt"
  local f = io.open(tmp, "wb")
  if not f then return end
  f:write(text)
  f:close()
  if IS_WIN then
    r.ExecProcess(string.format('cmd.exe /c clip < "%s"', native(tmp)), 10000)
  elseif is_mac() then
    os.execute(string.format('pbcopy < "%s"', tmp))
  else
    os.execute(string.format('(wl-copy < "%s" || xclip -selection clipboard < "%s" || xsel -b < "%s") 2>/dev/null',
      tmp, tmp, tmp))
  end
  os.remove(tmp)
end

-- The installer writes install_status.txt when it ends ("ok <device>" or
-- "fail") and the details to install.log: this shows the result in a dialog.
local function watch_installer()
  local status, logf = BACKEND .. "install_status.txt", BACKEND .. "install.log"
  local start = (r.time_precise or os.clock)()
  local function poll()
    local f = io.open(status, "r")
    if f then
      local line = f:read("l") or ""
      f:close()
      os.remove(status)
      if line:match("^ok") then
        msg(txt("install_ok", line:match("^ok%s+(%S+)") or "cpu"))
      else
        local full = ""
        local lf = io.open(logf, "r")
        if lf then full = lf:read("a") or ""; lf:close() end
        local lines = {}
        for l in full:gmatch("[^\r\n]+") do lines[#lines + 1] = l end
        local tail = table.concat(lines, "\n", math.max(1, #lines - 14))
        if r.ShowMessageBox(txt("install_fail", tail), "reawarp", 4) == 6 then
          copy_to_clipboard(full)
          if r.osara_outputMessage then r.osara_outputMessage(txt("copied")) else msg(txt("copied")) end
        end
      end
      return
    end
    if (r.time_precise or os.clock)() - start < 7200 and r.defer then r.defer(poll) end
  end
  if r.defer then r.defer(poll) end
end

-- Opens the installer in a terminal window, which closes by itself at the end
-- (reawarp then shows the result). With an NVIDIA card, asks first whether to
-- install the (much larger) GPU version. nil when cancelled.
local function open_installer()
  local script = BACKEND .. (IS_WIN and "install_beat_this.bat" or "install_beat_this.sh")
  if not file_exists(script) then return txt("install_manual", native(script)) end
  local kind, size = "cpu", "300 MB"
  local gpu = nvidia_gpu()
  if gpu then
    local a = r.ShowMessageBox(txt("gpu_ask", gpu), "reawarp", 3) -- 6 yes, 7 no, 2 cancel
    if a == 2 then return nil end
    if a == 6 then kind, size = "gpu", "2.5 GB" end
  end
  os.remove(BACKEND .. "install_status.txt")
  if IS_WIN then
    r.ExecProcess(string.format('cmd.exe /c start "reawarp" "%s" %s auto', native(script), kind), -1)
  elseif is_mac() then
    -- Terminal cannot pass arguments: the script reads them from this file
    local f = io.open(BACKEND .. "install_args.txt", "w")
    if f then f:write(kind, " auto\n"); f:close() end
    os.execute(string.format('chmod +x "%s"; open -a Terminal "%s"', script, script))
  else
    local ok = os.execute(string.format('chmod +x "%s"; (x-terminal-emulator -e "%s" %s auto || xterm -e "%s" %s auto) &',
      script, script, kind, script, kind))
    if not ok then return txt("install_manual", script .. " " .. kind) end
  end
  watch_installer()
  return txt("install_started", size)
end

local BT_DIRS = { "env", "python", "uv", "models", "uvcache" }

local function dir_exists(path)
  local parent, name = path:match("^(.*)[\\/]([^\\/]+)$")
  r.EnumerateSubdirectories(parent, -1) -- REAPER caches the listing: read it again
  for i = 0, math.huge do
    local d = r.EnumerateSubdirectories(parent, i)
    if not d then return false end
    if d == name then return true end
  end
end

local function bt_installed()
  for _, d in ipairs(BT_DIRS) do
    if dir_exists(BACKEND .. d) then return true end
  end
  return false
end

-- about how much the installed Beat This! uses (the GPU build is much larger)
local function bt_size()
  for _, v in ipairs({ "env/Lib/site-packages/torch/version.py", "env/lib/python3.12/site-packages/torch/version.py" }) do
    local f = io.open(BACKEND .. v, "r")
    if f then
      local t = f:read("a") or ""
      f:close()
      if t:match("cuda[^\n]-=%s*['\"]%d") then return "3 GB" end
      return txt("size_cpu")
    end
  end
  return txt("size_cpu")
end

local function uninstall_beat_this()
  if not bt_installed() then return txt("bt_missing") end
  local size = bt_size()
  if r.ShowMessageBox(txt("uninstall_ask", native(BACKEND), size), "reawarp", 4) ~= 6 then return nil end
  for _, d in ipairs(BT_DIRS) do
    local path = BACKEND .. d
    if dir_exists(path) then
      if IS_WIN then
        r.ExecProcess(string.format('cmd.exe /c rmdir /s /q "%s"', native(path)), 600000)
      else
        os.execute(string.format('rm -rf "%s"', path))
      end
    end
  end
  os.remove(BACKEND .. "install.log")
  os.remove(BACKEND .. "install_status.txt")
  local left = {}
  for _, d in ipairs(BT_DIRS) do
    if dir_exists(BACKEND .. d) then left[#left + 1] = d end
  end
  if #left > 0 then return txt("uninstall_left", table.concat(left, ", ")) end
  return txt("uninstalled", size)
end

---------------------------------------------------------------------------
-- Analysis
---------------------------------------------------------------------------
local function analyze(it, s)
  local item, take = it.item, it.take
  -- Beat This! is required unless the user chose the built-in detector: the
  -- built-in one loses the beat in music without a clear kick/snare pattern.
  -- Asked once per run, before the item is touched.
  if tostring(s.detector or "auto"):lower() ~= "builtin" and not backend_python() then
    if s._bt_install == nil then
      s._bt_install = r.ShowMessageBox(txt("bt_required_ask"), "reawarp", 4) == 6
      if s._bt_install and not open_installer() then s._bt_install = false end
    end
    return nil, s._bt_install and txt("bt_install_first") or txt("bt_required")
  end
  remember_original(item)
  neutralize(item, take)

  local acc = r.CreateTakeAudioAccessor(take)
  local t0 = r.GetAudioAccessorStartTime(acc)
  local t1 = r.GetAudioAccessorEndTime(acc)
  local ipos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  -- take accessors normally use item-relative time; guard against project time
  local item_off = (ipos > 1e-6 and math.abs(t0 - ipos) < 1e-6) and 0 or t0
  local src = r.GetMediaItemTake_Source(take)
  local nch = source_channels(src)
  local nsamp = math.floor((t1 - t0) * SR)
  local sub_blk = math.max(512, math.min(32768, math.floor(65536 / nch)))
  local buf = r.new_array(sub_blk * nch)
  local scale = nch == 2 and 0.5 or (1 / math.sqrt(nch))

  local function read(pos, n)
    if nch == 1 and n <= sub_blk then
      buf.clear()
      read_samples(acc, SR, 1, t0 + pos / SR, n, buf)
      return buf.table(1, n)
    end
    local out = {}
    local done = 0
    while done < n do
      breath()
      local m = math.min(sub_blk, n - done)
      buf.clear()
      read_samples(acc, SR, nch, t0 + (pos + done) / SR, m, buf)
      local t = buf.table(1, m * nch)
      if nch == 1 then
        for i = 1, m do out[done + i] = t[i] end
      elseif nch == 2 then
        for i = 1, m do out[done + i] = 0.5 * (t[2 * i - 1] + t[2 * i]) end
      else
        local base = 0
        for i = 1, m do
          local sum = 0
          for c = 1, nch do sum = sum + t[base + c] end
          base = base + nch
          out[done + i] = sum * scale
        end
      end
      done = done + m
    end
    return out
  end

  -- Beat This! (checked above). If it fails, stop: falling back to the built-in
  -- detector without the user noticing gives beats that can drift onto off-beats.
  local ext
  local det = tostring(s.detector or "auto"):lower()
  if det ~= "builtin" then
    local okb, e1, e2 = pcall(run_beat_this, acc, t0, t1, nch)
    local ext_err
    if okb then ext, ext_err = e1, e2 else ext_err = tostring(e1) end
    if not ext then
      r.DestroyAudioAccessor(acc)
      return nil, txt("bt_failed", ext_err or txt("bt_missing"))
    end
  end

  local manual = parse_sig(s.timesig)
  local ok, res, err = pcall(dsp.analyze, read, nsamp, SR, {
    min_bpm = s.min_bpm, max_bpm = s.max_bpm, bpm_hint = s.bpm_hint, flex = s.flex,
    snap = s.snap ~= 0, smooth = s.smooth, meter = manual and manual.group or 0, external = ext,
  })
  r.DestroyAudioAccessor(acc)
  if not ok then return nil, tostring(res) end
  if not res then return nil, txt(err) end
  res.detector = ext and "Beat This!" or txt("det_builtin")

  local sig = manual or parse_sig(res.meter == 3 and "3/4" or "4/4")
  if not manual and res.meter ~= 3 then
    -- duple: follow the project's 2/4, 4/4 or 2/2
    local pnum, pden = r.TimeMap_GetTimeSigAtTime(0, ipos)
    if duple(pnum, pden) then sig = parse_sig(pnum .. "/" .. pden) end
  end
  res.sig_note = manual and txt("sig_manual")
    or res.meter == 3 and txt("sig_triple")
    or (sig.num == 4 and sig.den == 4) and txt("sig_duple")
    or txt("sig_duple_project")
  r.GetSetMediaItemTakeInfo_String(take, EXT_SIG, sig_str(sig), true)
  res.sig = sig

  local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  clear_rw_markers(take)
  for j, b in ipairs(res.beats) do
    local name, col = label(j, res.downbeat, sig.group)
    r.SetTakeMarker(take, -1, name, offs + item_off + b, col)
  end
  local alt = {}
  for i, b in ipairs(res.alt or {}) do alt[i] = offs + item_off + b end
  set_alt(take, alt)
  res.down_time = ipos + item_off + res.beats[res.downbeat]
  return res
end

-- Beat grid of a neutralized take, in item time. Analyzes if there are no markers.
local function beat_grid(it, s, keep_pos)
  local take = it.take
  local list = rw_markers(take)
  if #list < 4 then
    local res, err = analyze(it, s)
    if not res then return nil, err end
    list = rw_markers(take)
  else
    remember_original(it.item)
    neutralize(it.item, take, keep_pos)
  end
  local sig = take_sig(take, s)
  relabel(take, list, downbeat_index(list), sig.group)

  local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local len = r.GetMediaItemInfo_Value(it.item, "D_LENGTH")
  local kept = {}
  for _, m in ipairs(list) do
    local t = m.src - offs
    if t >= -1e-6 and t <= len + 1e-6 then m.t = math.max(0, t); kept[#kept + 1] = m end
  end
  if #kept < 2 then return nil, txt("err_few_markers") end
  local times, edited = {}, {}
  for j, m in ipairs(kept) do
    times[j] = m.t
    if m.edited then edited[j] = true end
  end
  return { t = times, edited = edited, down = downbeat_index(kept), len = len, sig = sig }
end

local function effective_mode(item, take)
  local _, mode = r.GetSetMediaItemTakeInfo_String(take, EXT_MODE, "", false)
  if mode ~= "" then return mode end
  if r.GetTakeNumStretchMarkers(take) > 0 then return "warp" end
  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local cnt = 0
  for i = 0, r.CountTempoTimeSigMarkers(0) - 1 do
    local _, tp = r.GetTempoTimeSigMarker(0, i)
    if tp >= pos - 1e-6 and tp <= pos + len + 1e-6 then
      cnt = cnt + 1
      if cnt >= 2 then return "tempo" end
    end
  end
  return ""
end

local function pick_beat_item(items, cur, allow_outside)
  local best, best_score
  local function score_list(require_inside)
    for _, cand in ipairs(items) do
      local p = r.GetMediaItemInfo_Value(cand.item, "D_POSITION")
      local l = r.GetMediaItemInfo_Value(cand.item, "D_LENGTH")
      if not require_inside or (cur >= p - 1e-6 and cur <= p + l + 1e-6) then
        local has_rw = #rw_markers(cand.take) > 0 and 2 or 0
        local has_mode = effective_mode(cand.item, cand.take) ~= "" and 1 or 0
        local sc = has_rw + has_mode
        if not best_score or sc > best_score then
          best, best_score = cand, sc
        end
      end
    end
  end
  score_list(true)
  if not best and allow_outside then score_list(false) end
  return best
end

-- Beat grid of a reference take in current project time, without moving or
-- neutralizing the reference item if it already has RW markers.
local function ref_beat_grid(ref, s)
  local take = ref.take
  local list = rw_markers(take)
  if #list < 4 then
    local res, err = analyze(ref, s)
    if not res then return nil, err end
    list = rw_markers(take)
  end
  local sig = take_sig(take, s)
  relabel(take, list, downbeat_index(list), sig.group)

  local pos = r.GetMediaItemInfo_Value(ref.item, "D_POSITION")
  local len = r.GetMediaItemInfo_Value(ref.item, "D_LENGTH")
  local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local kept = {}
  for _, m in ipairs(list) do
    local t = rel_src_to_item(take, m.src - offs)
    if t >= -1e-6 and t <= len + 1e-6 then
      m.T = pos + math.max(0, t)
      kept[#kept + 1] = m
    end
  end
  if #kept < 2 then return nil, txt("err_few_markers") end
  local times = {}
  for j, m in ipairs(kept) do times[j] = m.T end
  return { T = times, down = downbeat_index(kept), sig = sig }
end

---------------------------------------------------------------------------
-- Project grid helpers
---------------------------------------------------------------------------
local function bar_time(m) return r.TimeMap2_beatsToTime(0, 0, m) end

local function nearest_bar(T)
  local _, m = r.TimeMap2_timeToBeats(0, T)
  local a, b = bar_time(m), bar_time(m + 1)
  if T - a <= b - T then return a, m end
  return b, m + 1
end

local function bar_at_or_after(T)
  local _, m = r.TimeMap2_timeToBeats(0, T)
  local t = bar_time(m)
  if t < T - 1e-6 then t = bar_time(m + 1) end
  return t
end

-- Set a time signature at T (a bar line) keeping the tempo there.
local function set_sig_at(T, num, den)
  for i = 0, r.CountTempoTimeSigMarkers(0) - 1 do
    local _, tp, _, _, bpm, _, _, lin = r.GetTempoTimeSigMarker(0, i)
    if math.abs(tp - T) < 1e-6 then
      r.SetTempoTimeSigMarker(0, i, tp, -1, -1, bpm, num, den, lin)
      return
    end
  end
  local _, _, tempo = r.TimeMap_GetTimeSigAtTime(0, T)
  r.SetTempoTimeSigMarker(0, -1, T, -1, -1, tempo, num, den, false)
end

-- Set the tempo at T (a bar line), keeping or setting the time signature there.
local function set_tempo_at(T, bpm, num, den)
  for i = 0, r.CountTempoTimeSigMarkers(0) - 1 do
    local _, tp, _, _, _, onum, oden = r.GetTempoTimeSigMarker(0, i)
    if math.abs(tp - T) < 1e-6 then
      if num == 0 and onum > 0 then num, den = onum, oden end
      r.SetTempoTimeSigMarker(0, i, tp, -1, -1, bpm, num, den, false)
      return
    end
  end
  r.SetTempoTimeSigMarker(0, -1, T, -1, -1, bpm, num, den, false)
end

local function markers_after(T)
  for i = 0, r.CountTempoTimeSigMarkers(0) - 1 do
    local _, tp = r.GetTempoTimeSigMarker(0, i)
    if tp > T + 1e-6 then return true end
  end
  return false
end

-- Ask (once per run) whether to change the project's time signature.
-- A warp follows the project tempo; a varying tempo map left over where the
-- item is (e.g. from an earlier "Tempo map from item") would make the warped
-- song vary with it. Ask (once per run) to replace it with the tempo in effect
-- before the item. Markers that only change the time signature don't count.
local function offer_fixed_tempo(s, t0, t1)
  local lo, hi, idx = math.huge, -math.huge, {}
  for i = 0, r.CountTempoTimeSigMarkers(0) - 1 do
    local _, tp, _, _, bpm = r.GetTempoTimeSigMarker(0, i)
    if tp > t0 - 1e-6 and tp <= t1 + 1e-6 then
      idx[#idx + 1] = i
      lo, hi = math.min(lo, bpm), math.max(hi, bpm)
    end
  end
  if #idx < 2 or hi - lo < 0.5 then return end
  local _, _, fixed = r.TimeMap_GetTimeSigAtTime(0, math.max(0, t0 - 1e-3))
  if s._fixed_tempo == nil then
    s._fixed_tempo = r.ShowMessageBox(txt("ask_tempo_map", fixed), "reawarp", 4) == 6
  end
  if not s._fixed_tempo then return end
  for k = #idx, 1, -1 do
    local i = idx[k]
    local _, tp, _, _, _, num, den, lin = r.GetTempoTimeSigMarker(0, i)
    if tp <= 1e-6 then
      r.SetTempoTimeSigMarker(0, i, tp, -1, -1, fixed, num, den, lin) -- keep the project start
    else
      r.DeleteTempoTimeSigMarker(0, i)
    end
  end
  r.UpdateTimeline()
end

local function want_sig_change(s, sig, pnum, pden)
  if s.fix_sig == 0 then return false end
  if s.fix_sig == 2 then return true end
  if s._fix == nil then
    s._fix = r.ShowMessageBox(txt("ask_sig", sig_str(sig), pnum, pden, sig_str(sig)), "reawarp", 4) == 6
  end
  return s._fix
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------
local A = {}

function A.analyze(items, s)
  local out = {}
  for _, it in ipairs(items) do
    local res, err = analyze(it, s)
    if res then
      out[#out + 1] = txt("analyze_line",
        it.name, res.bpm, res.bpm_min, res.bpm_max, sig_str(res.sig),
        res.sig_note, #res.beats, tstr(res.down_time))
        .. txt("det_note", res.detector)
    else
      out[#out + 1] = txt("err_item", it.name, err)
    end
  end
  local spoken = table.concat(out, "\n")
  out[#out + 1] = txt("analyze_help")
  return table.concat(out, "\n"), spoken
end

function A.warp(items, s)
  local out, failed = {}, false
  for _, it in ipairs(items) do
    local item, take = it.item, it.take
    local timebase = r.GetMediaItemInfo_Value(item, "C_BEATATTACHMODE")
    r.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", 0)
    local g, err = beat_grid(it, s)
    if not g then
      r.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", timebase)
      out[#out + 1] = txt("err_item", it.name, err)
      failed = true
    else
      -- the item (and any follower items) must not follow the tempo changes
      -- made here (removing a tempo map, inserting a time signature); their
      -- timebase is set at the end
      local P0 = r.GetMediaItemInfo_Value(item, "D_POSITION")
      local okl, lastp = r.GetSetMediaItemInfo_String(item, EXT_LASTPOS, "", false)
      lastp = (okl and tonumber(lastp)) or P0
      local lo_p, hi_p = math.min(P0, lastp), math.max(P0, lastp)
      local earlier = false
      for i = 0, r.CountTempoTimeSigMarkers(0) - 1 do
        local _, tp = r.GetTempoTimeSigMarker(0, i)
        if tp > 1e-6 and tp < lo_p - 1e-6 then earlier = true; break end
      end
      local min_song = earlier and bar_time(select(2, r.TimeMap2_timeToBeats(0, lo_p))) or 0
      local followers = #items == 1 and collect_followers(item, s, math.min(lo_p, min_song), hi_p + g.len) or {}
      local min_u = 0
      for _, f in ipairs(followers) do
        f.u0 = f.pos - P0
        f.u1 = f.u0 + f.len
        if f.u0 < min_u then min_u = f.u0 end
      end

      local d, sig = g.down, g.sig
      local used = {}
      for j = 1, #g.t do
        if (j - d) % s.every == 0 or (g.edited and g.edited[j]) then used[#used + 1] = j end
      end
      if #used < 2 then used = { 1, #g.t } end

      offer_fixed_tempo(s, lo_p, hi_p + g.len)

      -- anchor the downbeat on the nearest bar, moving later if any item would start before 0
      local Abar, m = nearest_bar(P0 + g.t[d])
      local T, X, slope_head
      local u1, u2 = used[1], used[2]
      for _ = 1, 256 do
        local qnA = r.TimeMap2_timeToQN(0, Abar)
        T = {}
        for _, j in ipairs(used) do T[j] = r.TimeMap2_QNToTime(0, qnA + (j - d) * sig.qn) end
        -- audio before the first beat gets the same stretch as the first beat
        -- interval (at rate 1 it would play slower, then jump in speed)
        slope_head = (T[u2] - T[u1]) / (g.t[u2] - g.t[u1])
        local head = g.t[u1] * slope_head
        X = T[u1] - head
        if X + min_u * slope_head >= 0 then break end
        m = m + 1
        Abar = bar_time(m)
      end

      -- match the project's bars to the song (same tempo, so T does not change)
      local pnum, pden = r.TimeMap_GetTimeSigAtTime(0, Abar)
      local old_sig
      if not sig_compatible(sig, pnum, pden) and want_sig_change(s, sig, pnum, pden) then
        local later = markers_after(Abar)
        set_sig_at(Abar, sig.num, sig.den)
        old_sig = { pnum, pden, later }
      end

      -- source position of item start (REAPER computes it for a marker at pos 0)
      local idx = r.SetTakeStretchMarker(take, -1, 0)
      local _, _, s0 = r.GetTakeStretchMarker(take, idx)
      r.DeleteTakeStretchMarkers(take, idx)

      local last, prev = used[#used], used[#used - 1]
      local slope_tail = (T[last] - T[prev]) / (g.t[last] - g.t[prev])
      local tail = (g.len - g.t[last]) * slope_tail
      local newlen = (T[last] - X) + tail
      r.SetMediaItemInfo_Value(item, "D_POSITION", X)
      r.SetMediaItemInfo_Value(item, "D_LENGTH", newlen)
      set_lastpos(item, X)
      if g.t[used[1]] > 1e-3 then r.SetTakeStretchMarker(take, -1, 0, s0) end
      for _, j in ipairs(used) do r.SetTakeStretchMarker(take, -1, T[j] - X, s0 + g.t[j]) end
      if g.len - g.t[last] > 1e-3 then r.SetTakeStretchMarker(take, -1, newlen, s0 + g.len) end

      r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
      r.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", s.follow ~= 0 and 1 or timebase)
      r.GetSetMediaItemTakeInfo_String(take, EXT_MODE, "warp", true)
      r.UpdateItemInProject(item)

      -- piecewise-linear warp map W(u): natural seconds from P0 -> warped project time
      local function W(u)
        if u <= g.t[u1] then return T[u1] + (u - g.t[u1]) * slope_head end
        if u >= g.t[last] then return T[last] + (u - g.t[last]) * slope_tail end
        local lo, hi = 1, #used - 1
        while lo < hi do
          local mid = (lo + hi + 1) // 2
          if g.t[used[mid]] <= u then lo = mid else hi = mid - 1 end
        end
        local a, b = used[lo], used[lo + 1]
        return T[a] + (u - g.t[a]) * (T[b] - T[a]) / (g.t[b] - g.t[a])
      end

      for _, f in ipairs(followers) do
        local Xf = W(f.u0)
        local newlen_f = W(f.u1) - Xf
        r.SetMediaItemInfo_Value(f.item, "D_POSITION", Xf)
        r.SetMediaItemInfo_Value(f.item, "D_LENGTH", newlen_f)
        set_lastpos(f.item, Xf)
        if f.take and not f.is_midi then
          local idx_f = r.SetTakeStretchMarker(f.take, -1, 0)
          local _, _, s0_f = r.GetTakeStretchMarker(f.take, idx_f)
          r.DeleteTakeStretchMarkers(f.take, idx_f)
          r.SetTakeStretchMarker(f.take, -1, 0, s0_f)
          for _, j in ipairs(used) do
            local u = g.t[j]
            if u > f.u0 + 1e-3 and u < f.u1 - 1e-3 then
              r.SetTakeStretchMarker(f.take, -1, T[j] - Xf, s0_f + (u - f.u0))
            end
          end
          r.SetTakeStretchMarker(f.take, -1, newlen_f, s0_f + f.len)
          r.SetMediaItemTakeInfo_Value(f.take, "B_PPITCH", 1)
        elseif f.take and f.is_midi and newlen_f > 1e-6 then
          r.SetMediaItemTakeInfo_Value(f.take, "D_PLAYRATE", f.len / newlen_f)
        end
        r.SetMediaItemInfo_Value(f.item, "C_BEATATTACHMODE", s.follow ~= 0 and 1 or f.timebase)
        r.UpdateItemInProject(f.item)
      end

      local sig_note = ""
      if old_sig then
        sig_note = txt("sig_inserted", sig_str(sig), tstr(Abar))
        if not old_sig[3] then
          local back = bar_at_or_after(X + newlen)
          set_sig_at(back, old_sig[1], old_sig[2])
          sig_note = sig_note .. txt("sig_restored", old_sig[1], old_sig[2], tstr(back))
        end
        sig_note = sig_note .. "."
      elseif not sig_compatible(sig, pnum, pden) then
        sig_note = txt("sig_mismatch", sig_str(sig), pnum, pden)
      end

      local src_bpm = 60 * (#g.t - 1) * sig.qn / (g.t[#g.t] - g.t[1])
      local _, _, proj_bpm = r.TimeMap_GetTimeSigAtTime(0, Abar)
      out[#out + 1] = txt("warp_line",
        it.name, #used, src_bpm, proj_bpm, 100 * proj_bpm / src_bpm, m + 1, tstr(T[d] or Abar), sig_note)
    end
  end
  -- success is silent (spoken by OSARA when present); errors open a dialog
  local short = not failed and txt("warp_done", #items == 1 and items[1].name or txt("n_items", #items)) or nil
  return table.concat(out, "\n"), short
end

function A.tempo(items, s)
  local it = items[1]
  local item = it.item
  local keep_pos = s._keep_tempo_pos or (effective_mode(item, it.take) == "tempo" and #rw_markers(it.take) >= 4)
  -- the item keeps its time position while we rewrite the tempo map; its
  -- timebase is set back afterwards
  local timebase = r.GetMediaItemInfo_Value(item, "C_BEATATTACHMODE")
  r.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", 0)
  local g, err = beat_grid(it, s, keep_pos)
  if not g then
    r.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", timebase)
    return txt("err_item", it.name, err)
  end
  local d, sig = g.down, g.sig
  local qn, group = sig.qn, sig.group
  local P0 = r.GetMediaItemInfo_Value(item, "D_POSITION")

  -- beats that get a tempo marker: every N beats in phase with the downbeat,
  -- including the pickup beats before it (plus any manually moved beats)
  local used = {}
  for j = 1, #g.t do
    if (j - d) % s.every == 0 or (g.edited and g.edited[j]) then used[#used + 1] = j end
  end
  if #used < 2 then
    r.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", timebase)
    return txt("err_few_beats", it.name)
  end
  local j0 = used[1]

  -- The new tempo starts before the music, so the intro, pickup and count-in
  -- bars already have its tempo: from the project start when no tempo marker
  -- precedes the item, otherwise from the bar line at or before the item start
  -- (keeping whatever comes earlier, e.g. another song).
  local okl, lastp = r.GetSetMediaItemInfo_String(item, EXT_LASTPOS, "", false)
  lastp = (okl and tonumber(lastp)) or P0
  local lo_p, hi_p = math.min(P0, lastp), math.max(P0, lastp)
  local earlier = false
  for i = 0, r.CountTempoTimeSigMarkers(0) - 1 do
    local _, tp = r.GetTempoTimeSigMarker(0, i)
    if tp > 1e-6 and tp < lo_p - 1e-6 then earlier = true end
  end
  local mR = 0
  if earlier then _, mR = r.TimeMap2_timeToBeats(0, lo_p) end
  local R = bar_time(mR)
  local pnum, pden = r.TimeMap_GetTimeSigAtTime(0, R)

  -- collect all follower items in the song's range and freeze their timebase
  -- to Time (0) before touching any tempo markers
  local followers = collect_followers(item, s, math.min(lo_p, R), hi_p + g.len, keep_pos)
  local min_u = 0
  for _, f in ipairs(followers) do
    local u0 = f.pos - P0
    if u0 < min_u then min_u = u0 end
  end

  local old_N
  if keep_pos and not s._downbeat_changed then
    local qnR = r.TimeMap2_timeToQN(0, R)
    local qn1 = r.TimeMap2_timeToQN(0, P0 + g.t[j0])
    old_N = math.floor((qn1 - qnR) / qn + 0.5)
  end

  -- remove the existing tempo markers after R that cover the item
  local to = hi_p + g.len + 1.0
  for i = r.CountTempoTimeSigMarkers(0) - 1, 0, -1 do
    local _, tp = r.GetTempoTimeSigMarker(0, i)
    if tp > R + 1e-6 and tp <= to + 1e-6 then r.DeleteTempoTimeSigMarker(0, i) end
  end
  r.UpdateTimeline()

  -- song tempo at its start (median of the first intervals)
  local iv = {}
  for k = 1, math.min(4, #used - 1) do
    local a, b = used[k], used[k + 1]
    iv[#iv + 1] = 60 * (b - a) * qn / (g.t[b] - g.t[a])
  end
  table.sort(iv)
  local bpm0 = iv[math.floor((#iv + 1) / 2)]
  local sig_num, sig_den = 0, 0
  if not sig_compatible(sig, pnum, pden) then sig_num, sig_den = sig.num, sig.den end
  set_tempo_at(R, bpm0, sig_num, sig_den)
  r.UpdateTimeline()

  -- move the item (less than half a bar) so its downbeat lands on a bar line of
  -- the new grid; the first marked beat must come at least half a beat after R.
  -- When updating an existing tempo map (keep_pos), keep the item where it is
  -- so moved take markers move the tempo markers directly without shifting audio.
  local beat0 = 60 * qn / bpm0
  local newP = P0
  if not (keep_pos and not s._downbeat_changed and P0 + min_u >= 0 and P0 + g.t[j0] >= R + 0.5 * beat0) then
    local Tcur = P0 + g.t[d]
    local Abar, m = nearest_bar(Tcur)
    newP = P0 + (Abar - Tcur)
    for _ = 1, 256 do
      if newP + min_u >= 0 and newP + g.t[j0] >= R + 0.5 * beat0 then break end
      m = m + 1
      Abar = bar_time(m)
      newP = P0 + (Abar - Tcur)
    end
  end
  local delta = newP - P0
  r.SetMediaItemInfo_Value(item, "D_POSITION", newP)
  set_prepos(item, newP)
  set_lastpos(item, newP)
  for _, f in ipairs(followers) do
    local nf = f.pos + delta
    r.SetMediaItemInfo_Value(f.item, "D_POSITION", nf)
    set_prepos(f.item, nf)
    set_lastpos(f.item, nf)
  end

  -- From R to the first marked beat: a whole number of beats, in phase with the
  -- bar (R is a bar line and the downbeat must land on one too).
  local P1 = newP + g.t[j0]
  local want = (j0 - d) % group
  local N = (old_N and old_N >= 1 and (old_N - want) % group == 0) and old_N
    or (math.floor(((P1 - R) / beat0 - want) / group + 0.5) * group + want)
  if N < 1 then N = N + group end
  set_tempo_at(R, 60 * N * qn / (P1 - R), sig_num, sig_den)
  r.UpdateTimeline()

  -- one marker per used beat, with the tempo of the interval to the next one
  local bpm
  for k, j in ipairs(used) do
    local nxt = used[k + 1]
    if nxt then bpm = 60 * (nxt - j) * qn / (g.t[nxt] - g.t[j]) end
    r.SetTempoTimeSigMarker(0, -1, newP + g.t[j], -1, -1, bpm, 0, 0, false)
  end
  r.UpdateTimeline()

  -- now that the map matches the item, let it (and all follower items) follow
  -- later tempo changes like a warped item (beats: position, length, rate)
  r.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", s.follow ~= 0 and 1 or timebase)
  -- following a tempo change changes the item's rate: keep its pitch
  if s.follow ~= 0 then r.SetMediaItemTakeInfo_Value(it.take, "B_PPITCH", 1) end
  r.GetSetMediaItemTakeInfo_String(it.take, EXT_MODE, "tempo", true)
  r.UpdateItemInProject(item)
  for _, f in ipairs(followers) do
    r.SetMediaItemInfo_Value(f.item, "C_BEATATTACHMODE", s.follow ~= 0 and 1 or f.timebase)
    if s.follow ~= 0 and f.take and not f.is_midi then
      r.SetMediaItemTakeInfo_Value(f.take, "B_PPITCH", 1)
    end
    r.UpdateItemInProject(f.item)
  end

  local avg = 60 * (#g.t - j0) * qn / (g.t[#g.t] - g.t[j0])
  return txt("tempo_line",
    it.name, #used + 1, tstr(R), mR + 1, sig_str(sig), avg, delta)
end

-- Warp items[2..#items] so their beats lock onto the beats of items[1] (the
-- reference groove), without modifying items[1] or the project's tempo map.
function A.match(items, s)
  if #items < 2 then return txt("select_two_items") end
  local ref = items[1]
  local rg, rerr = ref_beat_grid(ref, s)
  if not rg then return txt("err_item", ref.name, rerr) end
  local R_t, nR = rg.T, #rg.T
  local group_r = rg.sig.group
  local k_head = math.min(5, nR)
  local p_head = (R_t[k_head] - R_t[1]) / math.max(1, k_head - 1)
  local k_tail = math.max(1, nR - 4)
  local p_tail = (R_t[nR] - R_t[k_tail]) / math.max(1, nR - k_tail)
  local function ref_time(idx)
    if idx >= 1 and idx <= nR then return R_t[idx] end
    if idx < 1 then return R_t[1] + (idx - 1) * p_head end
    return R_t[nR] + (idx - nR) * p_tail
  end
  local rguid = item_guid(ref.item) or ""

  local out, failed = {}, false
  for k = 2, #items do
    local it = items[k]
    local item, take = it.item, it.take
    local timebase = r.GetMediaItemInfo_Value(item, "C_BEATATTACHMODE")
    r.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", 0)
    local g, err = beat_grid(it, s)
    if not g then
      r.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", timebase)
      out[#out + 1] = txt("err_item", it.name, err)
      failed = true
    else
      local P0 = r.GetMediaItemInfo_Value(item, "D_POSITION")
      local d, sig = g.down, g.sig
      local used = {}
      for j = 1, #g.t do
        if (j - d) % s.every == 0 or (g.edited and g.edited[j]) then used[#used + 1] = j end
      end
      if #used < 2 then used = { 1, #g.t } end

      -- find the beat of the reference item nearest to this item's first used beat
      local u1, u2 = used[1], used[2]
      local target_u1 = P0 + g.t[u1]
      local best_dist, a_ref = math.huge, 1
      for idx = -64, nR + 64 do
        local dist = math.abs(ref_time(idx) - target_u1)
        if dist < best_dist then best_dist, a_ref = dist, idx end
      end

      local T = {}
      for _, j in ipairs(used) do T[j] = ref_time(a_ref + (j - u1)) end
      local head = g.t[u1] * (T[u2] - T[u1]) / (g.t[u2] - g.t[u1])
      local X = T[u1] - head

      local idx = r.SetTakeStretchMarker(take, -1, 0)
      local _, _, s0 = r.GetTakeStretchMarker(take, idx)
      r.DeleteTakeStretchMarkers(take, idx)

      local last, prev = used[#used], used[#used - 1]
      local tail = (g.len - g.t[last]) * (T[last] - T[prev]) / (g.t[last] - g.t[prev])
      local newlen = (T[last] - X) + tail
      -- keep the item at P0 (where the user placed it) and stretch its beats
      -- and length to follow the reference groove from that point
      r.SetMediaItemInfo_Value(item, "D_POSITION", P0)
      r.SetMediaItemInfo_Value(item, "D_LENGTH", newlen)
      set_lastpos(item, P0)
      if g.t[u1] > 1e-3 then r.SetTakeStretchMarker(take, -1, 0, s0) end
      for _, j in ipairs(used) do r.SetTakeStretchMarker(take, -1, T[j] - X, s0 + g.t[j]) end
      if g.len - g.t[last] > 1e-3 then r.SetTakeStretchMarker(take, -1, newlen, s0 + g.len) end

      r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
      r.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", s.follow ~= 0 and 1 or timebase)
      r.GetSetMediaItemTakeInfo_String(take, EXT_MODE, "match", true)
      r.GetSetMediaItemTakeInfo_String(take, EXT_REF, rguid, true)
      r.UpdateItemInProject(item)

      local src_bpm = 60 * (#g.t - 1) * sig.qn / (g.t[#g.t] - g.t[1])
      local ref_bpm = 60 * (last - u1) * rg.sig.qn / (T[last] - T[u1])
      local down_t = P0 + ((T[d] or ref_time(a_ref + (d - u1))) - X)
      out[#out + 1] = txt("match_line",
        it.name, ref.name, #used, src_bpm, ref_bpm, 100 * ref_bpm / src_bpm, tstr(down_t))
    end
  end
  local n_targets = #items - 1
  local short = not failed and txt("match_done",
    ref.name, n_targets == 1 and items[2].name or txt("n_items", n_targets)) or nil
  return table.concat(out, "\n"), short
end

-- Change the tempo of a song that has a tempo map: REAPER's project BPM only
-- changes the tempo up to the next marker, so scale every marker by the same
-- factor instead, keeping each one on its bar and beat. Range: the selected
-- item (from the marker in effect at its start to its end), or the whole
-- project when no item is selected.
function A.retempo(items, s)
  local n = r.CountTempoTimeSigMarkers(0)
  if n == 0 then return txt("retempo_none") end
  local it = items[1]
  local t0, t1
  if it then
    t0 = r.GetMediaItemInfo_Value(it.item, "D_POSITION")
    t1 = t0 + r.GetMediaItemInfo_Value(it.item, "D_LENGTH")
  else
    local _, last = r.GetTempoTimeSigMarker(0, n - 1)
    t0, t1 = 0, math.max(last, 1e-3)
  end
  local first, last
  for i = 0, n - 1 do
    local _, tp = r.GetTempoTimeSigMarker(0, i)
    if tp <= t0 + 1e-6 then first = i end
    if tp <= t1 + 1e-6 then last = i end
  end
  first = first or 0
  if not last or last < first then return txt("retempo_none") end

  local avg = 60 * (r.TimeMap2_timeToQN(0, t1) - r.TimeMap2_timeToQN(0, t0)) / (t1 - t0)
  local ok, val = r.GetUserInputs(txt("retempo_title"), 1, txt("retempo_caption", avg), string.format("%.2f", avg))
  if not ok then return nil end
  local new = tonumber((val:gsub(",", ".")))
  if not new or new <= 0 then return nil end
  local f = new / avg

  local note = ""
  if it then
    if s.follow ~= 0 then
      r.SetMediaItemInfo_Value(it.item, "C_BEATATTACHMODE", 1)
      r.SetMediaItemTakeInfo_Value(it.take, "B_PPITCH", 1)
    elseif r.GetMediaItemInfo_Value(it.item, "C_BEATATTACHMODE") == 0 then
      note = txt("retempo_static")
    end
  end
  if s.follow ~= 0 and r.CountMediaItems then
    for i = 0, r.CountMediaItems(0) - 1 do
      local other = r.GetMediaItem(0, i)
      if other and (not it or other ~= it.item) then
        local lock = r.GetMediaItemInfo_Value(other, "C_LOCK") or 0
        if (math.floor(lock) & 1) == 0 then
          local pos = r.GetMediaItemInfo_Value(other, "D_POSITION")
          local len = r.GetMediaItemInfo_Value(other, "D_LENGTH")
          if pos < t1 - 1e-6 and pos + len > t0 + 1e-6 then
            r.SetMediaItemInfo_Value(other, "C_BEATATTACHMODE", 1)
            local take = r.GetActiveTake(other)
            if take and not r.TakeIsMIDI(take) then
              r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
            end
          end
        end
      end
    end
  end
  for i = first, last do
    local _, _, mp, bp, bpm, num, den, lin = r.GetTempoTimeSigMarker(0, i)
    r.SetTempoTimeSigMarker(0, i, -1, mp, bp, bpm * f, num, den, lin)
  end
  r.UpdateTimeline()
  if r.CountMediaItems then
    for i = 0, r.CountMediaItems(0) - 1 do
      local m = r.GetMediaItem(0, i)
      if m then set_lastpos(m, r.GetMediaItemInfo_Value(m, "D_POSITION")) end
    end
  end
  return txt("retempo_done", avg, new, (f - 1) * 100, last - first + 1) .. note
end

-- Double or halve the BPM of what follows: the user's way to pick the metrical
-- level when the detector chose the other one (e.g. a fast waltz at half
-- tempo). It works on the beat grid (the RW markers), keeping beat 1 in place,
-- and applies again the tempo map or warp the item already has from reawarp.
--   tempo map, or nothing applied yet: the grid (and so the project BPM) doubles
--   warp: the song follows the fixed project tempo, so "double" must make the
--         song play twice as fast: the grid is halved instead (and vice versa)
local function regrid(items, s, double)
  local done = {}
  for n, it in ipairs(items) do
    local take = it.take
    local list = rw_markers(take)
    if #list < 4 then
      local res, err = analyze(it, s)
      if not res then return txt("err_item", it.name, err) end
      list = rw_markers(take)
    end
    local sig = take_sig(take, s)
    local d = downbeat_index(list)
    local function avg(srcs) return 60 * (#srcs - 1) * sig.qn / (srcs[#srcs] - srcs[1]) end
    local _, mode = r.GetSetMediaItemTakeInfo_String(take, EXT_MODE, "", false)
    local grid_double = double
    if mode == "warp" or mode == "match" then grid_double = not double end
    local old = {}
    for j, m in ipairs(list) do old[j] = m.src end

    local new, nd, left = {}, 1, {}
    if grid_double then
      -- between two beats: a beat the detector found there (dropped when the
      -- analysis halved, or by "Halve the BPM"), else the midpoint
      local alt, k = get_alt(take), 1
      for j = 1, #old do
        new[#new + 1] = old[j]
        if j == d then nd = #new end
        local a, b = old[j], old[j + 1]
        if b then
          while alt[k] and alt[k] <= a + 0.25 * (b - a) do k = k + 1 end
          local x = alt[k]
          if x and x < b - 0.25 * (b - a) then new[#new + 1] = x; k = k + 1
          else new[#new + 1] = 0.5 * (a + b) end
        end
      end
    else
      for j = 1, #old do
        if (j - d) % 2 == 0 then
          new[#new + 1] = old[j]
          if j == d then nd = #new end
        else
          left[#left + 1] = old[j]
        end
      end
    end
    set_alt(take, left)
    if #new < 2 then return txt("err_item", it.name, txt("err_few_markers")) end

    clear_rw_markers(take)
    for j, src in ipairs(new) do
      local name, col = label(j, nd, sig.group)
      r.SetTakeMarker(take, -1, name, src, col)
    end

    if mode == "tempo" and n == 1 then
      A.tempo({ it }, s)
      done[#done + 1] = txt("regrid_applied", it.name, avg(old), avg(new), txt("mode_tempo"))
    elseif mode == "warp" then
      A.warp({ it }, s)
      local pos = r.GetMediaItemInfo_Value(it.item, "D_POSITION")
      local pq = r.TimeMap2_timeToQN(0, pos)
      local pbpm = 60 * (r.TimeMap2_timeToQN(0, pos + 30) - pq) / 30
      done[#done + 1] = txt("regrid_warp", it.name, 100 * pbpm / avg(new), pbpm)
    elseif mode == "match" then
      local _, rguid = r.GetSetMediaItemTakeInfo_String(take, EXT_REF, "", false)
      local ref_it = find_take_by_guid(rguid) or (#items >= 2 and n > 1 and items[1]) or nil
      if ref_it and ref_it.item ~= it.item then
        A.match({ ref_it, it }, s)
        local rg = ref_beat_grid(ref_it, s)
        local rbpm = rg and (60 * (#rg.T - 1) * rg.sig.qn / (rg.T[#rg.T] - rg.T[1])) or avg(new)
        done[#done + 1] = txt("regrid_match", it.name, 100 * rbpm / avg(new), ref_it.name, rbpm)
      else
        done[#done + 1] = txt("regrid_done", it.name, avg(old), avg(new))
      end
    else
      done[#done + 1] = txt("regrid_done", it.name, avg(old), avg(new))
    end
  end
  local text = table.concat(done, "\n")
  return text, text
end

function A.double(items, s) return regrid(items, s, true) end
function A.halve(items, s) return regrid(items, s, false) end

function A.downbeat(items, s)
  local cur = r.GetCursorPosition()
  local it = pick_beat_item(items, cur, false)
  if not it then return txt("cursor_off") end
  local item, take = it.item, it.take
  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local list = rw_markers(take)
  if #list == 0 then
    local res, err = analyze(it, s)
    if not res then return txt("err_item", it.name, err) end
    list = rw_markers(take)
  end
  local scur = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") + item_to_rel_src(take, cur - pos)
  local best, bj = math.huge, 1
  for j, m in ipairs(list) do
    local dd = math.abs(m.src - scur)
    if dd < best then best, bj = dd, j end
  end
  local sig = take_sig(take, s)
  relabel(take, list, bj, sig.group)

  local mode = effective_mode(item, take)
  if mode == "tempo" then
    s._downbeat_changed = true
    A.tempo({ it }, s)
    s._downbeat_changed = nil
  elseif mode == "warp" then
    A.warp({ it }, s)
  elseif mode == "match" then
    local _, rguid = r.GetSetMediaItemTakeInfo_String(take, EXT_REF, "", false)
    local ref_it = find_take_by_guid(rguid) or (#items >= 2 and items[1] ~= it and items[1]) or nil
    if ref_it and ref_it.item ~= it.item then A.match({ ref_it, it }, s) end
  end
  return txt("downbeat_set",
    it.name, bj, best * 1000, sig_str(sig))
end

-- Jump the edit cursor to the next (dir = 1) or previous (dir = -1) RW beat
-- marker on the selected item, and announce the bar.beat and local BPM.
local function step_beat(items, s, dir)
  local cur = r.GetCursorPosition()
  local it = pick_beat_item(items, cur, true) or items[1]
  local item, take = it.item, it.take
  local list = rw_markers(take)
  if #list == 0 then
    local res, err = analyze(it, s)
    if not res then return txt("err_item", it.name, err) end
    list = rw_markers(take)
  end
  local sig = take_sig(take, s)
  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local kept = {}
  for _, m in ipairs(list) do
    local t = rel_src_to_item(take, m.src - offs)
    if t >= -1e-6 and t <= len + 1e-6 then
      m.T = pos + math.max(0, t)
      kept[#kept + 1] = m
    end
  end
  if #kept == 0 then return txt("err_item", it.name, txt("err_few_markers")) end

  local target = dir > 0 and #kept or 1
  if dir > 0 then
    for j = 1, #kept do
      if kept[j].T > cur + 1e-4 then target = j; break end
    end
  else
    for j = #kept, 1, -1 do
      if kept[j].T < cur - 1e-4 then target = j; break end
    end
  end

  local m = kept[target]
  if r.SetEditCurPos then r.SetEditCurPos(m.T, true, true) end
  local a = kept[math.max(1, target - 1)]
  local b = kept[math.min(#kept, target + 1)]
  local dt = b.T - a.T
  local nbeats = math.max(1, math.min(#kept, target + 1) - math.max(1, target - 1))
  local bpm = dt > 1e-6 and (60 * nbeats * sig.qn / dt) or 0
  local clean_name = (m.name:gsub(" %*$", ""))
  local out = txt("beat_at", clean_name, target, #kept, bpm)
  return out, out
end

function A.next_beat(items, s) return step_beat(items, s, 1) end
function A.prev_beat(items, s) return step_beat(items, s, -1) end

-- Move the RW beat marker nearest the edit cursor to the edit cursor position,
-- and reapply the warp, tempo map or groove match if already active.
function A.move_beat(items, s)
  local cur = r.GetCursorPosition()
  local it = pick_beat_item(items, cur, false)
  if not it then return txt("cursor_off") end
  local item, take = it.item, it.take
  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  remember_original(item)
  local mode = effective_mode(item, take)
  local list = rw_markers(take)
  if #list == 0 then
    local res, err = analyze(it, s)
    if not res then return txt("err_item", it.name, err) end
    list = rw_markers(take)
    pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  end
  local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local scur = offs + item_to_rel_src(take, cur - pos)
  local best, bj = math.huge, 1
  for j, m in ipairs(list) do
    local dd = math.abs(m.src - scur)
    if dd < best then best, bj = dd, j end
  end
  local min_src = list[bj - 1] and (list[bj - 1].src + 0.02) or offs
  local max_src = list[bj + 1] and (list[bj + 1].src - 0.02) or math.huge
  local new_src = math.max(min_src, math.min(max_src, scur))
  local old_T = pos + rel_src_to_item(take, list[bj].src - offs)
  local new_T = pos + rel_src_to_item(take, new_src - offs)
  local diff_ms = (new_T - old_T) * 1000

  local sig = take_sig(take, s)
  local d = downbeat_index(list)
  local name, col = label(bj, d, sig.group, true)
  local clean_name = (name:gsub(" %*$", ""))
  r.SetTakeMarker(take, list[bj].idx, name, new_src, col)
  r.UpdateItemInProject(item)

  local out
  if mode == "tempo" then
    s._keep_tempo_pos = true
    A.tempo({ it }, s)
    s._keep_tempo_pos = nil
    out = txt("beat_moved_applied", it.name, clean_name, diff_ms, txt("mode_tempo"))
  elseif mode == "warp" then
    A.warp({ it }, s)
    out = txt("beat_moved_applied", it.name, clean_name, diff_ms, txt("mode_warp"))
  elseif mode == "match" then
    local _, rguid = r.GetSetMediaItemTakeInfo_String(take, EXT_REF, "", false)
    local ref_it = find_take_by_guid(rguid) or (#items >= 2 and items[1] ~= it and items[1]) or nil
    if ref_it and ref_it.item ~= it.item then
      A.match({ ref_it, it }, s)
      out = txt("beat_moved_applied", it.name, clean_name, diff_ms, txt("mode_match"))
    else
      out = txt("beat_moved", it.name, clean_name, diff_ms)
    end
  else
    out = txt("beat_moved", it.name, clean_name, diff_ms)
  end
  return out, out
end

function A.add_beat(items, s)
  local cur = r.GetCursorPosition()
  local it = pick_beat_item(items, cur, false)
  if not it then return txt("cursor_off") end
  local item, take = it.item, it.take
  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  remember_original(item)
  local mode = effective_mode(item, take)
  local list = rw_markers(take)
  if #list == 0 then
    local res, err = analyze(it, s)
    if not res then return txt("err_item", it.name, err) end
    list = rw_markers(take)
    pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  end
  local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local scur = math.max(offs, offs + item_to_rel_src(take, cur - pos))

  local near_j
  for j, m in ipairs(list) do
    if math.abs(m.src - scur) < 0.02 then near_j = j; break end
  end
  if near_j then
    local nm = list[near_j].name:match("%*$") and list[near_j].name or (list[near_j].name .. " *")
    r.SetTakeMarker(take, list[near_j].idx, nm, scur, COL_BEAT)
  else
    r.SetTakeMarker(take, -1, "RW 0.0 *", scur, COL_BEAT)
  end

  list = rw_markers(take)
  local sig = take_sig(take, s)
  local d = downbeat_index(list)
  relabel(take, list, d, sig.group)
  r.UpdateItemInProject(item)

  list = rw_markers(take)
  local best, bj = math.huge, 1
  for j, m in ipairs(list) do
    local dd = math.abs(m.src - scur)
    if dd < best then best, bj = dd, j end
  end
  local clean_name = (list[bj].name:gsub(" %*$", ""))

  local out
  if mode == "tempo" then
    s._keep_tempo_pos = true
    A.tempo({ it }, s)
    s._keep_tempo_pos = nil
    out = txt("beat_added_applied", it.name, clean_name, txt("mode_tempo"))
  elseif mode == "warp" then
    A.warp({ it }, s)
    out = txt("beat_added_applied", it.name, clean_name, txt("mode_warp"))
  elseif mode == "match" then
    local _, rguid = r.GetSetMediaItemTakeInfo_String(take, EXT_REF, "", false)
    local ref_it = find_take_by_guid(rguid) or (#items >= 2 and items[1] ~= it and items[1]) or nil
    if ref_it and ref_it.item ~= it.item then
      A.match({ ref_it, it }, s)
      out = txt("beat_added_applied", it.name, clean_name, txt("mode_match"))
    else
      out = txt("beat_added", it.name, clean_name)
    end
  else
    out = txt("beat_added", it.name, clean_name)
  end
  return out, out
end

function A.del_beat(items, s)
  local cur = r.GetCursorPosition()
  local it = pick_beat_item(items, cur, false)
  if not it then return txt("cursor_off") end
  local item, take = it.item, it.take
  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  remember_original(item)
  local mode = effective_mode(item, take)
  local list = rw_markers(take)
  if #list == 0 then
    local res, err = analyze(it, s)
    if not res then return txt("err_item", it.name, err) end
    list = rw_markers(take)
    pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  end
  if #list <= 2 then return txt("err_item", it.name, txt("err_few_markers")) end

  local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local scur = offs + item_to_rel_src(take, cur - pos)
  local best, bj = math.huge, 1
  for j, m in ipairs(list) do
    local dd = math.abs(m.src - scur)
    if dd < best then best, bj = dd, j end
  end
  local old_name = (list[bj].name:gsub(" %*$", ""))
  local d = downbeat_index(list)
  r.DeleteTakeMarker(take, list[bj].idx)

  list = rw_markers(take)
  local new_d = (bj < d) and (d - 1) or math.min(d, #list)
  if list[bj - 1] then list[bj - 1].edited = true end
  if list[bj] then list[bj].edited = true end
  local sig = take_sig(take, s)
  relabel(take, list, new_d, sig.group)
  r.UpdateItemInProject(item)

  local out
  if mode == "tempo" then
    s._keep_tempo_pos = true
    A.tempo({ it }, s)
    s._keep_tempo_pos = nil
    out = txt("beat_deleted_applied", it.name, old_name, txt("mode_tempo"))
  elseif mode == "warp" then
    A.warp({ it }, s)
    out = txt("beat_deleted_applied", it.name, old_name, txt("mode_warp"))
  elseif mode == "match" then
    local _, rguid = r.GetSetMediaItemTakeInfo_String(take, EXT_REF, "", false)
    local ref_it = find_take_by_guid(rguid) or (#items >= 2 and items[1] ~= it and items[1]) or nil
    if ref_it and ref_it.item ~= it.item then
      A.match({ ref_it, it }, s)
      out = txt("beat_deleted_applied", it.name, old_name, txt("mode_match"))
    else
      out = txt("beat_deleted", it.name, old_name)
    end
  else
    out = txt("beat_deleted", it.name, old_name)
  end
  return out, out
end

function A.restore(items)
  local n, seen, guides, groups = 0, {}, {}, {}
  local function restore_one(item)
    if not item or seen[item] then return end
    seen[item] = true
    local ok, v = r.GetSetMediaItemInfo_String(item, EXT_ORIG, "", false)
    if ok and v ~= "" then
      r.SetItemStateChunk(item, unescape(v), false)
      n = n + 1
    end
  end
  for _, it in ipairs(items) do
    local g = item_guid(it.item)
    if g then guides[g] = true end
    local gid = r.GetMediaItemInfo_Value(it.item, "I_GROUPID") or 0
    if gid ~= 0 then groups[gid] = true end
    restore_one(it.item)
  end
  if r.CountMediaItems then
    for i = 0, r.CountMediaItems(0) - 1 do
      local other = r.GetMediaItem(0, i)
      if other and not seen[other] then
        local ok, sg = r.GetSetMediaItemInfo_String(other, EXT_SYNC, "", false)
        local ogid = r.GetMediaItemInfo_Value(other, "I_GROUPID") or 0
        if (ok and sg ~= "" and guides[sg]) or (ogid ~= 0 and groups[ogid]) then
          restore_one(other)
        end
      end
    end
  end
  return n > 0 and txt("restored", n) or txt("nothing_restored")
end

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------
local function popup(entries, checked)
  local parts = {}
  for i, e in ipairs(entries) do
    local t = e:gsub("|", "/"):gsub("&", "&&")
    if t:match("^[#!<>]") then t = " " .. t end
    parts[#parts + 1] = (checked == i and "!" or "") .. t
  end
  local x, y = r.GetMousePosition()
  gfx.init("reawarp", 0, 0, 0, x, y)
  gfx.x, gfx.y = gfx.screentoclient(x, y)
  local c = gfx.showmenu(table.concat(parts, "|"))
  gfx.quit()
  return c
end

local MAIN = {
  { "analyze", "menu_analyze" },
  { "warp", "menu_warp" },
  { "tempo", "menu_tempo" },
  { "match", "menu_match" },
  { "retempo", "menu_retempo" },
  { "double", "menu_double" },
  { "halve", "menu_halve" },
  { "next_beat", "menu_next_beat" },
  { "prev_beat", "menu_prev_beat" },
  { "move_beat", "menu_move_beat" },
  { "add_beat", "menu_add_beat" },
  { "del_beat", "menu_del_beat" },
  { "downbeat", "menu_downbeat" },
  { "restore", "menu_restore" },
  { "settings", "menu_settings" },
  { "install", "menu_install" },
  { "uninstall", "menu_uninstall" }, -- only listed when Beat This! is installed
}

---------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------

-- Results are spoken through OSARA when it is installed (dialogs are kept
-- for questions); without OSARA they are shown in a dialog.
local function report(text, spoken)
  if r.osara_outputMessage then r.osara_outputMessage(spoken or text) else msg(text) end
end

function core.run(action)
  local s = core.load_settings()
  set_lang(s.lang)
  if action == "menu" then
    local names, list = {}, {}
    for _, m in ipairs(MAIN) do
      if m[1] ~= "uninstall" or bt_installed() then list[#list + 1] = m; names[#names + 1] = txt(m[2]) end
    end
    local c = popup(names)
    if c == 0 then return end
    action = list[c][1]
  end
  if action == "settings" then core.settings_dialog(s); return end
  if action == "install" then
    local m = open_installer()
    if m then report(m) end
    return
  end

  local clock = r.time_precise or os.clock
  -- one action at a time: a running one refreshes this on every step
  local busy = tonumber(r.GetExtState("reawarp", "busy"))
  if busy and clock() - busy >= 0 and clock() - busy < 3 then report(txt("busy")); return end
  if action == "uninstall" then
    local m = uninstall_beat_this()
    if m then msg(m) end
    return
  end

  local items = selected_takes()
  if #items == 0 and action ~= "retempo" then report(txt("select_item")); return end

  -- The action runs in a coroutine resumed by defer: the long parts (reading
  -- the audio, Beat This!, the analysis) give REAPER its window back every
  -- 50 ms instead of freezing it. Running the same action again cancels it.
  if r.set_action_options then r.set_action_options(1) end
  -- "please wait" (the analysis shows its report in a dialog at the end; the
  -- song tempo action asks for the new BPM first, so it has no notice)
  local fast = action == "retempo" or action == "next_beat" or action == "prev_beat"
    or action == "move_beat" or action == "add_beat" or action == "del_beat"
  if r.osara_outputMessage and not fast then r.osara_outputMessage(txt("working")) end
  local no_undo = false
  if action == "next_beat" or action == "prev_beat" then
    local it = pick_beat_item(items, r.GetCursorPosition(), true)
    if not it or #rw_markers(it.take) > 0 then no_undo = true end
  end
  if not no_undo then r.Undo_BeginBlock() end
  local co = coroutine.create(function() return A[action](items, s) end)
  local finished = false
  local function close()
    finished = true
    r.DeleteExtState("reawarp", "busy", false)
    r.UpdateArrange()
    r.UpdateTimeline()
    if not no_undo then r.Undo_EndBlock(txt("undo_" .. action), -1) end
  end
  if r.atexit then
    r.atexit(function()
      if not finished then close(); report(txt("cancelled")) end
    end)
  end
  local function step()
    r.SetExtState("reawarp", "busy", tostring(clock()), false)
    r.PreventUIRefresh(1)
    local ok, result, spoken = coroutine.resume(co)
    -- audio reads asked by the coroutine (see read_samples), served here
    while ok and coroutine.status(co) ~= "dead" and type(result) == "table" and result.read do
      ok, result, spoken = coroutine.resume(co, direct_read(table.unpack(result.read)))
    end
    r.PreventUIRefresh(-1)
    if coroutine.status(co) ~= "dead" then return false end
    close()
    if not ok then report(txt("err_unexpected", tostring(result)))
    elseif result ~= nil then
      -- the analysis report is read in a dialog (it explains what to check next)
      if action == "analyze" then msg(result) else report(result, spoken) end
    end -- nil: cancelled in a dialog
    return true
  end
  if r.defer and not core.sync then
    local function loop() if not step() then r.defer(loop) end end
    loop()
  else
    repeat until step()
  end
end

---------------------------------------------------------------------------
-- Action List entries. REAPER maps one action to one file, so each action is
-- a two-line file (generated in "actions/") that runs this file with
-- REAWARP_ACTION set. Running reawarp.lua itself opens the menu.
---------------------------------------------------------------------------
local ACTION_FILES = {
  { "analyze", "reawarp - Analyze beats.lua" },
  { "warp", "reawarp - Warp item to project tempo.lua" },
  { "tempo", "reawarp - Tempo map from item.lua" },
  { "match", "reawarp - Match groove to first item.lua" },
  { "retempo", "reawarp - Change song tempo.lua" },
  { "double", "reawarp - Double BPM.lua" },
  { "halve", "reawarp - Halve BPM.lua" },
  { "next_beat", "reawarp - Next beat marker.lua" },
  { "prev_beat", "reawarp - Previous beat marker.lua" },
  { "move_beat", "reawarp - Move nearest beat marker to edit cursor.lua" },
  { "add_beat", "reawarp - Add beat marker at edit cursor.lua" },
  { "del_beat", "reawarp - Delete nearest beat marker.lua" },
  { "downbeat", "reawarp - Set downbeat at edit cursor.lua" },
  { "restore", "reawarp - Restore original items.lua" },
  { "settings", "reawarp - Settings.lua" },
}

function core.install_actions(main_path)
  local dir = main_path:match("^(.*[\\/])") or ""
  local sub = dir .. "actions"
  r.RecursiveCreateDirectory(sub, 0)
  for i, a in ipairs(ACTION_FILES) do
    local path = sub .. "/" .. a[2]
    local body = "-- Generated by reawarp.lua. Do not edit: all the code is in reawarp.lua.\n"
      .. 'REAWARP_ACTION = "' .. a[1] .. '"\n'
      .. 'dofile(debug.getinfo(1, "S").source:match("^@?(.*[\\\\/])") .. "../reawarp.lua")\n'
    local f = io.open(path, "r")
    local cur = f and f:read("a")
    if f then f:close() end
    if cur ~= body then
      f = assert(io.open(path, "w"))
      f:write(body)
      f:close()
    end
    r.AddRemoveReaScript(true, 0, path, i == #ACTION_FILES)
  end
end

return core
end)()

---------------------------------------------------------------------------
-- 3. Entry point
---------------------------------------------------------------------------
if REAWARP_TEST then return core end

local action = REAWARP_ACTION
REAWARP_ACTION = nil
if not action then
  core.install_actions((debug.getinfo(1, "S").source:gsub("^@", "")))
  action = "menu"
end
core.run(action)
