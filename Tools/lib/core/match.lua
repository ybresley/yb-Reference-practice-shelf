-- match: the arithmetic behind "match this sound to a loudness target" — the
-- working view's target button and its match window (DESIGN.md "Loudness tools
-- & working-view additions", decided 2026-08-06).
--
-- Pure Lua. No reaper.*, no ImGui, no disk access. The UI shows what a match
-- WOULD set and reports the click; this module owns the numbers, so the trim a
-- preset row previews and the trim the click sets can never disagree.
--
-- Matching is arithmetic, not analysis: trim = target − stored measurement,
-- instant at click time. Both sides of any comparison come from the same
-- engine (REAPER's CalculateNormalization — the 23 Jul decision), which is why
-- this file never needs to know how a number was measured.

local analysis = require("core.analysis")

local match = {}

-- (A true-peak ceiling of −1 dBTP used to cap every match. Removed at the
-- user's ask, 2026-08-08: a reference library is for listening, not delivery,
-- and a match that quietly set less than the target was the wrong trade. The
-- trim now goes exactly where the arithmetic says; the fader's own range is
-- the only limit left.)

-- What the trim fader can hold. A match can only set what the fader can show —
-- the fader stays the one honest readout of what is in force.
--
-- Asymmetric since 2026-08-07 (user's call, brief pages 3 and 4): the fader is
-- tapered and its bottom IS silence, so no CUT can be out of reach any more,
-- and only the boost side can still fall short. +24 was kept over a proposed
-- +12 because quiet material genuinely needs it — a −38 LUFS ambience matched
-- to −16 wants +22, with 34 dB of true-peak headroom to spare.
match.TRIM_MAX = 24
-- Silence, as a finite number. An actual -inf would poison every sum it landed
-- in (preview gain, the waveform's scale); at −120 dB the audio is 1 millionth
-- of an amplitude — silent by any measure — and the arithmetic stays real.
match.TRIM_SILENCE = -120

-- The factory presets (the design brief's mock). The user's own list lives in
-- ExtState and replaces these entirely once edited.
match.DEFAULT_PRESETS = {
  { unit = "lufs_m_max", value = -16 },
  { unit = "lufs_m_max", value = -20 },
  { unit = "lufs_i",     value = -23 },
  { unit = "true_peak",  value = -1 },
}

-- A target's unit IS a stored measurement's field name — one vocabulary, owned
-- by core/analysis.lua, so a unit can never name a number we don't store.
function match.is_unit(name)
  return analysis.is_field(name)
end

-- The preset list is user-editable but BOUNDED — the UI iterates it every
-- frame the window is open, and a popup taller than eight rows of presets
-- stops being a quick pick anyway.
match.PRESET_MAX = 8

-- How a unit names itself in user-facing text ("-16 LUFS-M") — shared by the
-- match window and the status line, so the two can never disagree.
match.UNIT_LABELS = {
  lufs_i = "LUFS-I", lufs_m_max = "LUFS-M", lufs_s_max = "LUFS-S",
  true_peak = "dBTP", peak = "dBFS", rms = "RMS",
}

function match.label(unit)
  return match.UNIT_LABELS[unit] or tostring(unit)
end

local function is_real_number(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- The trim that brings `sound` to `value` in `unit`. Returns (trim, limited)
-- where `limited` is nil when the full match fits and "range" when the fader's
-- own limit clamped it — only ever its BOOST end in practice, now that the cut
-- end runs to silence. Returns (nil, reason) when there is nothing to compute:
-- "unmeasured" (the sound has no number in that unit — not analysed yet, or
-- silence) or "bad_target" (a unit or value that isn't real).
function match.trim_for(sound, unit, value)
  if not match.is_unit(unit) or not is_real_number(value) then
    return nil, "bad_target"
  end
  local measured = sound and sound[unit]
  if not is_real_number(measured) then return nil, "unmeasured" end

  local trim, limited = value - measured, nil
  if trim > match.TRIM_MAX then
    trim, limited = match.TRIM_MAX, "range"
  elseif trim < match.TRIM_SILENCE then
    trim, limited = match.TRIM_SILENCE, "range"
  end
  return trim, limited
end

-- "Match all pins to target": write every pin's trim once (the one-shot bulk
-- action — the live "play at target" mode was REJECTED, don't resurrect it).
-- Mutates the pin records; persisting is the caller's job, in one save.
-- Returns (set, limited, skipped) counts so the caller can say exactly what
-- happened — a pin with no measurement in the target's unit is skipped, never
-- silently left half-matched.
function match.bulk(pin_list, unit, value)
  local set, limited, skipped = 0, 0, 0
  for _, p in ipairs(pin_list) do
    local trim, lim = match.trim_for(p, unit, value)
    if trim then
      p.trim_db = trim
      set = set + 1
      if lim then limited = limited + 1 end
    else
      skipped = skipped + 1
    end
  end
  return set, limited, skipped
end

--------------------------------------------------------------- persistence text
-- The preset list and the remembered target are app preferences (like the
-- loudness column's unit), so they live in ExtState — which is line-based ini
-- text. One line each, no JSON: "unit=value;unit=value" for the list,
-- "unit=value" for the target. Garbage entries are dropped rather than raised
-- on: a broken preference must cost the preference, not the tool (the same
-- stance the loudness-unit fallback takes).

-- An emptied list is a real, rememberable state — the user deleted every
-- preset — and GetExtState can't tell "" from "never stored", so it gets a
-- sentinel of its own.
local EMPTY = "-"

function match.encode_presets(list)
  if #list == 0 then return EMPTY end
  local parts = {}
  for _, p in ipairs(list) do
    parts[#parts + 1] = p.unit .. "=" .. tostring(p.value)
  end
  return table.concat(parts, ";")
end

local function decode_entry(text)
  local unit, num = text:match("^([%w_]+)=(%-?%d+%.?%d*)$")
  local value = tonumber(num)
  if match.is_unit(unit) and is_real_number(value) then
    return { unit = unit, value = value }
  end
  return nil
end

-- nil / unparseable → a fresh copy of the defaults (never the shared table:
-- the caller edits its list in place).
function match.decode_presets(text)
  if type(text) ~= "string" or text == "" then return match.default_presets() end
  if text == EMPTY then return {} end
  local out = {}
  for entry in text:gmatch("[^;]+") do
    -- The bound holds on the way IN too: hand-edited ExtState must not reopen
    -- with a list the UI would never have let the user build.
    if #out >= match.PRESET_MAX then break end
    out[#out + 1] = decode_entry(entry)
  end
  if #out == 0 then return match.default_presets() end
  return out
end

function match.default_presets()
  local out = {}
  for i, p in ipairs(match.DEFAULT_PRESETS) do
    out[i] = { unit = p.unit, value = p.value }
  end
  return out
end

function match.encode_target(target)
  if not target then return nil end
  return target.unit .. "=" .. tostring(target.value)
end

-- nil when nothing (or garbage) is stored — there is simply no remembered
-- target yet, which the UI treats as "no bulk match available".
function match.decode_target(text)
  if type(text) ~= "string" or text == "" then return nil end
  return decode_entry(text)
end

return match
