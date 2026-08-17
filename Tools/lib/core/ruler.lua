-- ruler: tick/label placement for the working view's time ruler (waveform
-- ruler brief, 2026-08-05 — the settled design; docs/RESEARCH.md's "Waveform
-- time ruler" pass is the general research it started from, not what's built
-- here). Pure Lua, zero reaper.* calls: handed a sound's duration, the pixel
-- width it has to fill, and a text-measuring function, it answers "where do
-- the ticks go and what do they say" — nothing about HOW to draw them
-- (colour, font, DrawList calls) lives here; that's lib/ui/waveform.lua's job.
--
-- The cadence is STRICTLY EVEN (user's explicit call, overriding the more
-- common "always label the end" ruler convention from RESEARCH.md): major
-- ticks land at k*step for k=0,1,2,... while k*step <= duration, full stop.
-- The final partial interval past the last major is left unticked rather than
-- getting a synthesised end-of-file tick.

local ruler = {}

-- The fixed step ladder (seconds) a ruler is allowed to use, ascending. `div`
-- is how many minor subdivisions its OWN major interval gets. Looked up per
-- step rather than derived from the step's magnitude because the ladder isn't
-- a regular 1-2-5 geometric series — 15 and 30 are quarter/half-unit steps
-- whose leading digit (as written in their own unit: "15", "30") is '1'/'3',
-- not '2' — so only a step whose in-unit numeral actually leads with '2'
-- (0.2s, 2s, 2 min, 2 h) gets 4 divisions; deriving that from log10(step)
-- would mis-classify 15 and 30 (their mantissa rounds to 2 under a plain
-- order-of-magnitude test, which is a different, wrong answer).
local STEPS = {
  { s = 0.1,   div = 5 },
  { s = 0.2,   div = 4 },
  { s = 0.5,   div = 5 },
  { s = 1,     div = 5 },
  { s = 2,     div = 4 },
  { s = 5,     div = 5 },
  { s = 10,    div = 5 },
  { s = 15,    div = 5 },
  { s = 30,    div = 5 },
  { s = 60,    div = 5 },   -- 1 min
  { s = 120,   div = 4 },   -- 2 min
  { s = 300,   div = 5 },   -- 5 min
  { s = 600,   div = 5 },   -- 10 min
  { s = 900,   div = 5 },   -- 15 min
  { s = 1800,  div = 5 },   -- 30 min
  { s = 3600,  div = 5 },   -- 1 h
  { s = 7200,  div = 4 },   -- 2 h
  { s = 18000, div = 5 },   -- 5 h
}

-- ~12px of breathing room a step's widest label must clear before that step
-- is usable — the user's spec value, not derived from the tokens.md spacing
-- scale (this module is pure core and can't require ui.theme; 12 happens to
-- already be on that scale, so it isn't a magic number in spirit either).
local LABEL_PAD_PX = 12

-- Tolerance for k*step <= duration comparisons, so float error (3*0.1 landing
-- a hair over 0.3) can never drop or add a tick that should/shouldn't be there.
local EPS = 1e-9

-- Every label on the ladder is built from the same handful of leading digits
-- (1/2/5, plus the odd 15/30 quarter/half-unit) with fixed-width zero-padded
-- fields, so a LARGER value never prints SHORTER than a smaller one — the
-- highest-value major at a given step (the last one, k_max) is therefore
-- always that step's widest label, with or without the suffix. That is what
-- lets choose_step() measure one candidate label per step instead of the
-- whole tick run a fine step over a long duration could otherwise imply.
local function format_major(t, duration_sec, is_last)
  local label
  if duration_sec < 1 then
    label = tostring(math.floor(t * 1000 + 0.5))
    if is_last then label = label .. "ms" end
  elseif duration_sec < 10 then
    label = string.format("%.1f", t)
    if is_last then label = label .. "s" end
  elseif duration_sec < 60 then
    label = tostring(math.floor(t + 0.5))
    if is_last then label = label .. "s" end
  elseif duration_sec < 3600 then
    local total = math.floor(t + 0.5)
    local mm = math.floor(total / 60)
    local ss = total - mm * 60
    label = string.format("%d:%02d", mm, ss) -- colon formats: no suffix, ever
  else
    local total = math.floor(t + 0.5)
    local hh = math.floor(total / 3600)
    local rem = total - hh * 3600
    local mm = math.floor(rem / 60)
    local ss = rem - mm * 60
    label = string.format("%d:%02d:%02d", hh, mm, ss)
  end
  return label
end

-- The smallest step whose majors fit without crowding, so the ruler is as
-- fine-grained as the panel honestly allows — chosen by measuring, never by
-- guessing from the duration/width shape. Falls back to the ladder's coarsest
-- step if even that would crowd (an extreme duration-vs-width ratio); build()
-- still guarantees the zero tick regardless of which step lands here.
local function choose_step(duration_sec, width_px, measure)
  local px_per_sec = width_px / duration_sec
  for _, step in ipairs(STEPS) do
    local spacing = step.s * px_per_sec
    local k_max = math.floor(duration_sec / step.s + EPS)
    local last_label = format_major(k_max * step.s, duration_sec, true)
    if spacing >= measure(last_label) + LABEL_PAD_PX then
      return step
    end
  end
  return STEPS[#STEPS]
end

-- Build the full tick list for one (duration, width) pair. `measure(text)`
-- must answer the pixel width that text would draw at — the caller measures
-- under the exact font the ticks will be labelled in (waveform.lua's
-- small-font push); specs pass a fake with a fixed per-character width.
--
-- Returns an array of { x, t, label, major }, x/t both ascending, x in
-- panel-local pixels (0 at the left edge — the caller offsets by its own
-- screen position), label nil on minors. Empty for a zero/negative duration
-- or width: nothing to draw, not even a zero tick — that is a "no sound
-- loaded" state, different from "sound too short / panel too narrow", which
-- still gets one (a real, positive duration always survives k=0).
function ruler.build(duration_sec, width_px, measure)
  if not duration_sec or duration_sec <= 0 or not width_px or width_px <= 0 then
    return {}
  end

  local step = choose_step(duration_sec, width_px, measure)
  local px_per_sec = width_px / duration_sec
  local k_max = math.floor(duration_sec / step.s + EPS)
  local minor_gap = (step.s * px_per_sec) / step.div
  local minors_on = minor_gap >= 4 -- < 4px: suppress minors entirely, majors stay

  local ticks = {}
  for k = 0, k_max do
    local t = k * step.s
    local is_last = (k == k_max)
    ticks[#ticks + 1] = {
      x = t * px_per_sec, t = t, major = true,
      label = format_major(t, duration_sec, is_last),
    }
    -- Minors only fill intervals between two REAL majors (k < k_max): the
    -- trailing partial interval past the last major has no major of its own
    -- to subdivide toward, and strict cadence means it stays unticked too.
    if minors_on and k < k_max then
      for i = 1, step.div - 1 do
        local mt = t + i * (step.s / step.div)
        ticks[#ticks + 1] = { x = mt * px_per_sec, t = mt, major = false }
      end
    end
  end
  return ticks
end

-- The hover readout: one notch finer than the tick labels, same
-- duration-driven regime choice, but no unit suffix anywhere (the tooltip's
-- context already makes the unit obvious) and no ms regime — even a
-- sub-second file reads its hover time in seconds.
function ruler.hover_label(t_seconds, duration_sec)
  local t = t_seconds or 0
  if t < 0 then t = 0 end
  duration_sec = duration_sec or 0

  if duration_sec < 10 then
    return string.format("%.2f", t)
  elseif duration_sec < 60 then
    return string.format("%.1f", t)
  elseif duration_sec < 3600 then
    -- Rounded to whole tenths BEFORE splitting into minutes/seconds so a
    -- value like 59.96s can't format as the impossible "0:60.0".
    local tenths = math.floor(t * 10 + 0.5)
    local mm = math.floor(tenths / 600)
    local ss_tenths = tenths - mm * 600
    return string.format("%d:%04.1f", mm, ss_tenths / 10)
  else
    local total = math.floor(t + 0.5)
    local hh = math.floor(total / 3600)
    local rem = total - hh * 3600
    local mm = math.floor(rem / 60)
    local ss = rem - mm * 60
    return string.format("%d:%02d:%02d", hh, mm, ss)
  end
end

return ruler
