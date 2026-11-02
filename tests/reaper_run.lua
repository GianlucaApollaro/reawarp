-- reawarp :: tests/reaper_run.lua
-- Real-REAPER test runner. Expects globals set by a small launcher script:
--   RW_MAIN  = path to reawarp.lua
--   RW_OUT   = report file path
--   RW_CASES = { { file=, proj_bpm=, proj_num=, proj_den=, pos=, answer=6|7, mode="warp"|"tempo", settings={...} }, ... }
-- Runs in a NEW project tab, one case per defer cycle, then closes the tab without
-- saving (run it with a watcher that answers "No" to REAPER's save prompts).

REAWARP_TEST = "dsp"
local dsp = dofile(RW_MAIN)
REAWARP_TEST = "core"
local core = dofile(RW_MAIN)
REAWARP_TEST = nil
-- optional: measure with another version's detector (RW_MEASURE), to compare versions fairly
local mdsp = dsp
if RW_MEASURE then
  REAWARP_TEST = "dsp"
  mdsp = dofile(RW_MEASURE)
  REAWARP_TEST = nil
end
local r = reaper

local out = io.open(RW_OUT, "w")
local function log(fmt, ...)
  out:write(string.format(fmt, ...), "\n")
  out:flush()
end

-- capture dialogs instead of showing them
local msgs, answer = {}, 6
r.osara_outputMessage = function(t) msgs[#msgs + 1] = "[OSARA, sem diálogo] " .. t end
r.ShowMessageBox = function(t, _, kind)
  msgs[#msgs + 1] = "[DIÁLOGO] " .. t
  if kind == 4 then return answer end
  return 1
end

local current_settings
core.load_settings = function()
  local s = {}
  for k, v in pairs(current_settings) do s[k] = v end
  return s
end

local function defaults(over)
  local s = {
    min_bpm = 60, max_bpm = 180, bpm_hint = 0, timesig = "auto", flex = 50, every = 1,
    smooth = 0, snap = 1, follow = 1, fix_sig = 1, pitchmode = -1, stretchflags = 0,
  }
  for k, v in pairs(over or {}) do s[k] = v end
  return s
end

local function sig_list()
  local t = {}
  for i = 0, r.CountTempoTimeSigMarkers(0) - 1 do
    local _, tp, mp, bp, bpm, num, den = r.GetTempoTimeSigMarker(0, i)
    if num > 0 then t[#t + 1] = string.format("%.3fs:%d/%d@%.2f", tp, num, den, bpm) end
  end
  return table.concat(t, " ")
end

local function reset_project(c)
  for i = r.CountTracks(0) - 1, 0, -1 do r.DeleteTrack(r.GetTrack(0, i)) end
  for i = r.CountTempoTimeSigMarkers(0) - 1, 0, -1 do r.DeleteTempoTimeSigMarker(0, i) end
  r.SetTempoTimeSigMarker(0, -1, 0, -1, -1, c.proj_bpm, c.proj_num, c.proj_den, false)
  r.UpdateTimeline()
end

-- re-analyze the audio as heard in the project (track accessor = after warp)
local function grid_check(track, item, beat_qn)
  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local acc = r.CreateTrackAudioAccessor(track)
  local SR = 11025
  local buf = r.new_array(32768 * 2)
  local function read(p, n)
    buf.clear()
    r.GetAudioAccessorSamples(acc, SR, 2, pos + p / SR, n, buf)
    local t = buf.table(1, n * 2)
    local o = {}
    for i = 1, n do o[i] = 0.5 * (t[2 * i - 1] + t[2 * i]) end
    return o
  end
  local _, _, pbpm = r.TimeMap_GetTimeSigAtTime(0, pos + len / 2)
  local res = dsp.analyze(read, math.floor(len * SR), SR,
    { min_bpm = 40, max_bpm = 240, bpm_hint = pbpm / beat_qn, flex = 50, meter = 4 })
  r.DestroyAudioAccessor(acc)
  if not res then return "grid: análise falhou" end
  local devs, early = {}, {}
  for i, b in ipairs(res.beats) do
    local T = pos + b
    local q = r.TimeMap2_timeToQN(0, T) / beat_qn
    local dq = q - math.floor(q + 0.5)
    local qlen = r.TimeMap2_QNToTime(0, r.TimeMap2_timeToQN(0, T) + beat_qn) - T
    devs[#devs + 1] = math.abs(dq * qlen * 1000)
    if i <= 16 then early[#early + 1] = string.format("%.0f", devs[#devs]) end
  end
  local early_txt = table.concat(early, " ")
  table.sort(devs)
  local within = 0
  for _, d in ipairs(devs) do if d <= 25 then within = within + 1 end end
  return string.format("grid: bpm ouvido %.2f (projeto %.2f), desvio das batidas mediana %.1f ms, p90 %.1f ms, %d%% a <=25 ms\n"
      .. "início: primeira batida ouvida em %.3fs; desvios das 16 primeiras (ms): %s",
    res.bpm, pbpm, devs[math.floor(#devs / 2) + 1] or -1, devs[math.floor(#devs * 0.9) + 1] or -1,
    math.floor(100 * within / math.max(1, #devs)), pos + (res.beats[1] or 0), early_txt)
end

-- where the reawarp beat markers (RW) land in the project, through the stretch markers
local function beat_markers_grid(item, take)
  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local sm = {}
  for i = 0, r.GetTakeNumStretchMarkers(take) - 1 do
    local _, p_, s_ = r.GetTakeStretchMarker(take, i)
    sm[#sm + 1] = { pos = p_, src = s_ }
  end
  local s0 = #sm > 0 and (sm[1].src - sm[1].pos * rate) or offs
  local function to_item(sp)
    if #sm == 0 then return (sp - s0) / rate end
    if sp <= sm[1].src then return sm[1].pos + (sp - sm[1].src) / rate end
    for i = 1, #sm - 1 do
      if sp <= sm[i + 1].src then
        return sm[i].pos + (sp - sm[i].src) * (sm[i + 1].pos - sm[i].pos) / (sm[i + 1].src - sm[i].src)
      end
    end
    return sm[#sm].pos + (sp - sm[#sm].src) / rate
  end
  local d, n1, ondown = {}, 0, 0
  for i = 0, r.GetNumTakeMarkers(take) - 1 do
    local src, name = r.GetTakeMarker(take, i)
    if name:match("^RW %-?%d+%.%d+") then
      local T = pos + to_item(s0 + (src - offs))
      local q = r.TimeMap2_timeToQN(0, T)
      local frac = q - math.floor(q + 0.5)
      d[#d + 1] = math.abs(frac) * 60000 / select(3, r.TimeMap_GetTimeSigAtTime(0, T))
      if name:match("%.1$") then
        n1 = n1 + 1
        local bib = r.TimeMap2_timeToBeats(0, T)
        if bib < 0.02 or bib > select(1, r.TimeMap_GetTimeSigAtTime(0, T)) - 0.02 then ondown = ondown + 1 end
      end
    end
  end
  table.sort(d)
  return string.format("marcadores de batida: %d, distância até a batida do projeto mediana %.1f ms, máx %.1f ms; tempos 1 em barra: %d/%d",
    #d, d[math.floor(#d / 2) + 1] or -1, d[#d] or -1, ondown, n1)
end

local function run_case(c)
  msgs = {}
  answer = c.answer or 6
  current_settings = defaults(c.settings)
  reset_project(c)
  r.InsertTrackAtIndex(0, false)
  local tr = r.GetTrack(0, 0)
  r.SetOnlyTrackSelected(tr)
  r.SetEditCurPos(c.pos or 1.37, false, false)
  if r.InsertMedia(c.file, 0) == 0 then log("ERRO: não inseriu %s", c.file); return end
  local item = r.GetTrackMediaItem(tr, 0)
  r.SelectAllMediaItems(0, false)
  r.SetMediaItemSelected(item, true)
  if c.max_len then r.SetMediaItemInfo_Value(item, "D_LENGTH", math.min(c.max_len, r.GetMediaItemInfo_Value(item, "D_LENGTH"))) end
  local take = r.GetActiveTake(item)

  log("=== %s | projeto %d/%d %.0f BPM | modo %s | resposta %s", c.file:match("[^\\/]+$"), c.proj_num, c.proj_den, c.proj_bpm,
    c.mode or "warp", (c.answer or 6) == 6 and "sim" or "não")
  log("item em %.3fs, %.1fs", r.GetMediaItemInfo_Value(item, "D_POSITION"), r.GetMediaItemInfo_Value(item, "D_LENGTH"))

  -- item-level stretch settings that the warp must leave alone
  if c.pitchmode == "auto" then -- first available non-default algorithm
    for i = 1, 63 do
      local ok, name = r.EnumPitchShiftModes(i)
      if not ok then break end
      if name and name ~= "" then c.pitchmode = i << 16; log("algoritmo do item: %s", name); break end
    end
  end
  if c.pitchmode then r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", c.pitchmode) end
  if c.stretchflags then r.SetMediaItemTakeInfo_Value(take, "I_STRETCHFLAGS", c.stretchflags) end
  local pm0, sf0 = r.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE"), r.GetMediaItemTakeInfo_Value(take, "I_STRETCHFLAGS")

  if not c.skip_analyze then
    local t0 = os.clock()
    core.run("analyze")
    log("análise (%.1fs): %s", os.clock() - t0, (msgs[#msgs] or ""):match("^[^\n]*"))
  else
    log("sem análise prévia (%d marcadores de take)", r.GetNumTakeMarkers(take))
  end
  local _, sig = r.GetSetMediaItemTakeInfo_String(take, "P_EXT:reawarp_sig", "", false)
  local n1, d1 = r.TimeMap_GetTimeSigAtTime(0, 5)
  log("compasso salvo no take: %s | projeto após análise: %d/%d | marcadores tempo/compasso: %s", sig, n1, d1, sig_list())
  local first = {}
  for i = 0, math.min(19, r.GetNumTakeMarkers(take) - 1) do
    local src, name = r.GetTakeMarker(take, i)
    first[#first + 1] = string.format("%s@%.3f", name, src)
  end
  log("primeiros marcadores: %s", table.concat(first, " "))

  msgs = {}
  if c.stub then
    dofile(c.stub) -- the generated Action List file, exactly as REAPER runs it
  else
    core.run(c.mode or "warp")
  end
  for _, m in ipairs(msgs) do log("saída: %s", (m:gsub("\n+", " / "))) end
  if c.mode ~= "tempo" then
    local _, sig2 = r.GetSetMediaItemTakeInfo_String(take, "P_EXT:reawarp_sig", "", false)
    sig = sig2
  end
  log("I_PITCHMODE %d -> %d | I_STRETCHFLAGS %d -> %d | marcadores RW: %d", pm0,
    r.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE"), sf0, r.GetMediaItemTakeInfo_Value(take, "I_STRETCHFLAGS"),
    r.GetNumTakeMarkers(take))
  log("projeto depois: %s | item em %.3fs, %.1fs, %d stretch markers", sig_list(),
    r.GetMediaItemInfo_Value(item, "D_POSITION"), r.GetMediaItemInfo_Value(item, "D_LENGTH"), r.GetTakeNumStretchMarkers(take))
  if c.mode == "tempo" then
    local tm = {}
    for i = 0, math.min(9, r.CountTempoTimeSigMarkers(0) - 1) do
      local _, tp, _, _, bpm = r.GetTempoTimeSigMarker(0, i)
      local bib, meas = r.TimeMap2_timeToBeats(0, tp)
      tm[#tm + 1] = string.format("%.3fs %.2fBPM (compasso %d, tempo %.2f)", tp, bpm, meas + 1, bib + 1)
    end
    local ipos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    log("primeiros marcadores de tempo: %s | item começa em %.3fs", table.concat(tm, "; "), ipos)
  end
  if c.dump_sm then
    local f = io.open(c.dump_sm, "w")
    for i = 0, r.GetTakeNumStretchMarkers(take) - 1 do
      local _, p_, s_ = r.GetTakeStretchMarker(take, i)
      f:write(string.format("%.9f %.9f", r.GetMediaItemInfo_Value(item, "D_POSITION") + p_, s_), string.char(10))
    end
    f:close()
  end
  local ns = r.GetTakeNumStretchMarkers(take)
  if ns >= 4 then
    local function seg(j)
      local _, p1, s1 = r.GetTakeStretchMarker(take, j)
      local _, p2, s2 = r.GetTakeStretchMarker(take, j + 1)
      return string.format("%.3f", (s2 - s1) / (p2 - p1))
    end
    log("velocidade dos trechos: início %s %s %s ... fim %s %s %s", seg(0), seg(1), seg(2), seg(ns - 4), seg(ns - 3), seg(ns - 2))
  end
  if (c.mode or "warp") == "warp" then
    local beat_qn = (sig:match("^%d+/8$") and tonumber(sig:match("^(%d+)")) % 3 == 0 and tonumber(sig:match("^(%d+)")) > 3) and 1.5 or 1
    log("%s", grid_check(tr, item, beat_qn))
  else
    log("%s", grid_check(tr, item, 1))
  end
  for _, act in ipairs(c.after or {}) do
    msgs = {}
    core.run(act)
    for _, m in ipairs(msgs) do log("%s: %s", act, (m:gsub("%s+", " "))) end
    local mk = {}
    for i = 0, math.min(7, r.GetNumTakeMarkers(take) - 1) do
      local src, name = r.GetTakeMarker(take, i)
      mk[#mk + 1] = string.format("%s@%.3f", name, src)
    end
    log("%s: marcadores %s", act, table.concat(mk, " "))
    local tm = {}
    for i = 0, math.min(6, r.CountTempoTimeSigMarkers(0) - 1) do
      local _, tp, _, _, bpm = r.GetTempoTimeSigMarker(0, i)
      local bib, meas = r.TimeMap2_timeToBeats(0, tp)
      tm[#tm + 1] = string.format("%.3fs %.1fBPM (c%d t%.0f)", tp, bpm, meas + 1, bib + 1)
    end
    log("%s: tempo %s | item em %.3fs", act, table.concat(tm, "; "), r.GetMediaItemInfo_Value(item, "D_POSITION"))
    local rates = {}
    for i = 0, r.GetTakeNumStretchMarkers(take) - 2 do
      local _, p1, s1 = r.GetTakeStretchMarker(take, i)
      local _, p2, s2 = r.GetTakeStretchMarker(take, i + 1)
      if p2 > p1 then rates[#rates + 1] = (s2 - s1) / (p2 - p1) end
    end
    table.sort(rates)
    local _, _, pb = r.TimeMap_GetTimeSigAtTime(0, r.GetMediaItemInfo_Value(item, "D_POSITION") + 10)
    log("%s: tempo do projeto %.2f BPM, velocidade mediana da música %.3f, playrate %.3f", act, pb,
      rates[math.floor(#rates / 2) + 1] or 1, r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"))
    log("%s", grid_check(tr, item, 1))
  end
  if c.retempo_action then
    -- reawarp's "Change song tempo" action, answering its dialog with a new BPM
    local real = r.GetUserInputs
    r.GetUserInputs = function(_, _, caption) msgs[#msgs + 1] = "[PERGUNTA] " .. caption; return true, tostring(c.retempo_action) end
    msgs = {}
    core.run("retempo")
    r.GetUserInputs = real
    for _, m in ipairs(msgs) do log("alterar tempo: %s", (m:gsub("%s+", " "))) end
    log("item: base de tempo %d, preserve pitch %d, playrate %.3f, em %.3fs", r.GetMediaItemInfo_Value(item, "C_BEATATTACHMODE"),
      r.GetMediaItemTakeInfo_Value(take, "B_PPITCH"), r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"), r.GetMediaItemInfo_Value(item, "D_POSITION"))
    log("%s", grid_check(tr, item, 1))
  end
  if c.retempo then
    -- the user changes the project tempo afterwards: every marker keeps its bar
    -- and beat, at retempo times the BPM. A following item must stay on the grid.
    log("base de tempo do item: %d", r.GetMediaItemInfo_Value(item, "C_BEATATTACHMODE"))
    for i = 0, r.CountTempoTimeSigMarkers(0) - 1 do
      local _, _, mp, bp, bpm, num, den, lin = r.GetTempoTimeSigMarker(0, i)
      r.SetTempoTimeSigMarker(0, i, -1, mp, bp, bpm * c.retempo, num, den, lin)
    end
    r.UpdateTimeline()
    log("depois de mudar o tempo do projeto x%.2f: item em %.3fs, %.1fs, playrate %.3f", c.retempo,
      r.GetMediaItemInfo_Value(item, "D_POSITION"), r.GetMediaItemInfo_Value(item, "D_LENGTH"),
      r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"))
    log("%s", grid_check(tr, item, 1))
  end
  log("")
end

-- new project tab
local NEW_TAB, CLOSE_TAB = 40859, 40860
if r.CF_GetCommandText then
  log("comandos: %s / %s", r.CF_GetCommandText(0, NEW_TAB), r.CF_GetCommandText(0, CLOSE_TAB))
end
r.Main_OnCommand(NEW_TAB, 0)
log("reawarp teste real | REAPER %s | %s", r.GetAppVersion(), os.date())

local i = 0
local function step()
  i = i + 1
  local c = RW_CASES[i]
  if not c then
    -- the test tab is never saved: the launcher's watcher answers "No" to the prompt
    r.Main_OnCommand(CLOSE_TAB, 0)
    log("FIM")
    out:close()
    return
  end
  local ok, err = pcall(run_case, c)
  if not ok then log("ERRO no caso %d: %s\n", i, tostring(err)) end
  r.defer(step)
end
r.defer(step)
