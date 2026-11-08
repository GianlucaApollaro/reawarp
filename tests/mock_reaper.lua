-- Minimal fake `reaper` API for exercising reawarp.lua outside REAPER.
-- One project at constant tempo (bpm, 4/4); items hold mono source audio at SR.
local M = {}

function M.new(opts)
  local bpm = opts.bpm or 120
  local spq = 60 / bpm -- seconds per quarter note
  local P = { ext = {}, items = {}, sel = {}, tempo = {}, cursor = 0, messages = {} }
  local r = {}

  function r.GetOS() return "Win64" end
  function r.ColorToNative(a, b, c) return a | (b << 8) | (c << 16) end
  function r.GetExtState(s, k) return P.ext[s .. k] or "" end
  function r.SetExtState(s, k, v) P.ext[s .. k] = v end
  function r.DeleteExtState(s, k) P.ext[s .. k] = nil end
  function r.osara_outputMessage(t) P.messages[#P.messages + 1] = t end
  function r.ShowMessageBox(t, _, kind)
    P.messages[#P.messages + 1] = t
    if kind == 4 then P.asked = (P.asked or 0) + 1; return P.answer or 6 end
    return 1
  end
  function r.format_timestr_pos(t) return string.format("%.3f", t) end
  function r.Undo_BeginBlock() end
  function r.Undo_EndBlock() end
  function r.PreventUIRefresh() end
  function r.UpdateArrange() end
  function r.UpdateTimeline() end
  function r.UpdateItemInProject() end
  function r.GetCursorPosition() return P.cursor end
  function r.SetEditCurPos(t) P.cursor = t end

  function r.CountMediaItems() return #P.items end
  function r.GetMediaItem(_, i) return P.items[i + 1] end
  function r.CountSelectedMediaItems() return #P.sel end
  function r.GetSelectedMediaItem(_, i) return P.sel[i + 1] end
  function r.GetActiveTake(item) return item.take end
  function r.TakeIsMIDI() return false end
  function r.GetTakeName(t) return t.name end
  function r.GetMediaItemTake_Source(t) return t.src end
  function r.GetMediaSourceNumChannels() return 1 end

  function r.GetMediaItemInfo_Value(it, k) return it[k] end
  function r.SetMediaItemInfo_Value(it, k, v) it[k] = v; return true end
  function r.GetMediaItemTakeInfo_Value(t, k) return t[k] end
  function r.SetMediaItemTakeInfo_Value(t, k, v) t[k] = v; return true end
  function r.GetSetMediaItemInfo_String(it, k, v, set)
    if set then it.ext[k] = v; return true, v end
    return it.ext[k] ~= nil, it.ext[k] or ""
  end
  function r.GetSetMediaItemTakeInfo_String(t, k, v, set)
    if set then t.ext[k] = v; return true, v end
    return t.ext[k] ~= nil, t.ext[k] or ""
  end
  function r.GetItemStateChunk(it) return true, "<ITEM\nPOSITION " .. it.D_POSITION .. "\n>" end
  function r.SetItemStateChunk(it, chunk) it.restored = chunk; it.ext = {}; return true end

  -- stretch markers: srcpos absolute in source seconds; sorted by pos
  local function sort_sm(t) table.sort(t.sm, function(a, b) return a.pos < b.pos end) end
  local function map(t, pos) -- item time -> source (absolute)
    local rate, sm = t.D_PLAYRATE, t.sm
    if #sm == 0 then return t.D_STARTOFFS + pos * rate end
    if pos <= sm[1].pos then return sm[1].src + (pos - sm[1].pos) * rate end
    for i = 1, #sm - 1 do
      local a, b = sm[i], sm[i + 1]
      if pos <= b.pos then return a.src + (pos - a.pos) / (b.pos - a.pos) * (b.src - a.src) end
    end
    return sm[#sm].src + (pos - sm[#sm].pos) * rate
  end
  M.map = map
  function r.GetTakeNumStretchMarkers(t) return #t.sm end
  function r.GetTakeStretchMarker(t, i) local m = t.sm[i + 1]; return i, m.pos, m.src end
  function r.SetTakeStretchMarker(t, idx, pos, src)
    src = src or map(t, pos)
    if idx >= 0 then t.sm[idx + 1] = { pos = pos, src = src } else t.sm[#t.sm + 1] = { pos = pos, src = src } end
    sort_sm(t)
    for i, m in ipairs(t.sm) do if m.pos == pos then return i - 1 end end
  end
  function r.DeleteTakeStretchMarkers(t, idx, n)
    for _ = 1, n or 1 do table.remove(t.sm, idx + 1) end
    return n or 1
  end

  -- take markers (source positions)
  function r.GetNumTakeMarkers(t) return #t.tm end
  function r.GetTakeMarker(t, i) local m = t.tm[i + 1]; if not m then return -1, "", 0 end; return m.src, m.name, m.col end
  function r.SetTakeMarker(t, idx, name, src, col)
    if idx >= 0 then t.tm[idx + 1] = { src = src or t.tm[idx + 1].src, name = name, col = col }
    else t.tm[#t.tm + 1] = { src = src, name = name, col = col } end
    table.sort(t.tm, function(a, b) return a.src < b.src end)
    return idx
  end
  function r.DeleteTakeMarker(t, i) table.remove(t.tm, i + 1); return true end

  -- audio accessor on the natural (rate 1, unstretched) take
  function r.CreateTakeAudioAccessor(t) return { take = t } end
  function r.DestroyAudioAccessor() end
  function r.GetAudioAccessorStartTime() return 0 end
  function r.GetAudioAccessorEndTime(acc) return acc.take.item.D_LENGTH end
  function r.new_array(n)
    local a = { n = n, d = {} }
    function a.clear() a.d = {} end
    function a.table(o, c) local out = {}; for i = 1, c do out[i] = a.d[o + i - 1] or 0 end; return out end
    return a
  end
  function r.GetAudioAccessorSamples(acc, sr, nch, t0, n, buf)
    local t = acc.take
    local s = t.src.samples
    for i = 1, n do
      local srcpos = map(t, t0 + (i - 1) / sr)
      buf.d[i] = s[math.floor(srcpos * t.src.sr + 0.5) + 1] or 0
    end
    return 1
  end

  -- Tempo map: piecewise-constant tempo from the markers (the project tempo
  -- applies before the first one). Time-signature markers start a new bar.
  local function tmarkers()
    local t = {}
    for _, mk in ipairs(P.tempo) do t[#t + 1] = mk end
    table.sort(t, function(x, y) return x.t < y.t end)
    if #t == 0 or t[1].t > 1e-9 then table.insert(t, 1, { t = 0, bpm = bpm, num = 4, den = 4, base = true }) end
    if not t[1].num or t[1].num == 0 then t[1].num, t[1].den = 4, 4 end
    return t
  end
  local function qn_at(t)
    local mk, q = tmarkers(), 0
    for i, m in ipairs(mk) do
      local nt = mk[i + 1] and mk[i + 1].t or math.huge
      if t <= nt then return q + (t - m.t) * m.bpm / 60 end
      q = q + (nt - m.t) * m.bpm / 60
    end
  end
  local function time_at_qn(qq)
    local mk, q = tmarkers(), 0
    for i, m in ipairs(mk) do
      local nt = mk[i + 1] and mk[i + 1].t or math.huge
      local dq = (nt - m.t) * m.bpm / 60
      if qq <= q + dq then return m.t + (qq - q) * 60 / m.bpm end
      q = q + dq
    end
  end
  local function sig_segments()
    local segs = {}
    for _, m in ipairs(tmarkers()) do
      if m.num and m.num > 0 then
        local q = qn_at(m.t)
        local last = segs[#segs]
        if last and q <= last.q + 1e-9 then
          last.num, last.den = m.num, m.den
        else
          local ms = 0
          if last then ms = last.m + math.ceil((q - last.q) / (last.num * 4 / last.den) - 1e-9) end
          segs[#segs + 1] = { q = q, num = m.num, den = m.den, m = ms }
        end
      end
    end
    return segs
  end
  local function seg_at_qn(q)
    local segs = sig_segments()
    local g = segs[1]
    for _, x in ipairs(segs) do if x.q <= q + 1e-9 then g = x end end
    return g
  end
  local function tempo_at(t)
    local b = bpm
    for _, m in ipairs(tmarkers()) do if m.t <= t + 1e-9 then b = m.bpm end end
    return b
  end
  function r.TimeMap2_timeToQN(_, t) return qn_at(t) end
  function r.TimeMap2_QNToTime(_, q) return time_at_qn(q) end
  function r.TimeMap2_timeToBeats(_, t)
    local q = qn_at(t)
    local g = seg_at_qn(q)
    local barq = g.num * 4 / g.den
    local k = math.floor((q - g.q) / barq + 1e-9)
    return (q - g.q - k * barq) / (4 / g.den), g.m + k, g.num, q, g.den
  end
  function r.TimeMap2_beatsToTime(_, tpos, m)
    m = m or 0
    local segs = sig_segments()
    local g = segs[1]
    for _, x in ipairs(segs) do if x.m <= m then g = x end end
    return time_at_qn(g.q + (m - g.m) * g.num * 4 / g.den + tpos * 4 / g.den)
  end
  function r.TimeMap_GetTimeSigAtTime(_, t)
    local g = seg_at_qn(qn_at(t))
    return g.num, g.den, tempo_at(t)
  end
  function r.Master_GetTempo() return bpm end
  function r.SetCurrentBPM(_, b) bpm = b end
  function r.CountTempoTimeSigMarkers() return #P.tempo end
  function r.GetTempoTimeSigMarker(_, i) local m = P.tempo[i + 1]; return true, m.t, 0, 0, m.bpm, m.num or 0, m.den or 0, false end
  function r.DeleteTempoTimeSigMarker(_, i) table.remove(P.tempo, i + 1); return true end
  function r.SetTempoTimeSigMarker(_, idx, t, _, _, b, num, den)
    local mk = { t = t, bpm = b, num = num, den = den }
    if idx >= 0 then P.tempo[idx + 1] = mk else P.tempo[#P.tempo + 1] = mk end
    table.sort(P.tempo, function(x, y) return x.t < y.t end)
    return true
  end

  function M.add_item(pos, src, offs, len, name)
    local take = { ext = { GUID = "{MOCK-" .. tostring(#P.items + 1) .. "}" }, name = name or "song", src = src, D_PLAYRATE = 1, D_STARTOFFS = offs or 0, sm = {}, tm = {} }
    local item = { take = take, D_POSITION = pos, D_LENGTH = len, ext = {}, C_BEATATTACHMODE = -1 }
    take.item = item
    take.P_ITEM = item
    P.items[#P.items + 1] = item
    P.sel[#P.sel + 1] = item
    return item
  end

  M.P = P
  return r
end

-- stub gfx for menus
gfx = { init = function() end, quit = function() end, screentoclient = function(x, y) return x, y end,
        showmenu = function() return 0 end }

return M
