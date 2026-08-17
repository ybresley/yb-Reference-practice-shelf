-- span: the start/end points a sound can carry (DESIGN.md "Loudness tools &
-- working-view additions", 2026-08-06) — two handles on the working view's
-- waveform that frame the stretch play, REF playback and the loop run through,
-- remembered per sound exactly like the trim (library record + pin snapshot,
-- fields `span_start` / `span_end` in seconds).
--
-- Pure Lua. The UI turns mouse positions into seconds and playback asks where
-- to start and stop; this module owns the clamping rules, so a dragged handle
-- and a stored record can never disagree about what a legal span is.

local span = {}

-- The smallest stretch the two handles may frame (seconds). Below this a span
-- is a click, not a selection — and a zero-width span would give playback
-- nothing to play (the same rule pins.validate enforces on stored data).
span.MIN = 0.05

-- Stored to the millisecond: finer is inaudible and would fill the saved
-- records with float noise (the loudness fields' two-decimal reasoning).
local function round_ms(v)
  return math.floor(v * 1000 + 0.5) / 1000
end

-- The stretch playback actually runs, as (start_s, end_s) against the REAL
-- length of the audio: an absent handle means "the file's own edge", and a
-- stored value beyond the file (replaced on disk since it was set) clamps
-- rather than aiming playback past the end.
function span.range(sound, length)
  if type(length) ~= "number" or length <= 0 then return 0, 0 end
  local s0 = sound and sound.span_start or 0
  local s1 = sound and sound.span_end or length
  if s1 > length then s1 = length end
  if s0 < 0 then s0 = 0 end
  -- A degenerate pair (both handles clamped into collision) falls back to the
  -- start of what remains rather than a backwards stretch.
  if s0 >= s1 then s0 = math.max(0, s1 - span.MIN) end
  return s0, s1
end

-- Move one handle ("start" or "finish"), keeping the pair a legal span.
-- `seconds` nil resets the handle (the shared right-click/double-click
-- gesture); a handle dragged to its own extreme also stores nil, so a
-- full-width span leaves the record exactly as clean as one never touched.
-- Returns the value actually stored (nil when the handle cleared).
function span.set(sound, which, seconds, length)
  if type(length) ~= "number" or length <= 0 then return nil end
  if which == "start" then
    if seconds == nil then
      sound.span_start = nil
      return nil
    end
    local limit = (sound.span_end or length) - span.MIN
    if seconds > limit then seconds = limit end
    if seconds <= 0 then
      sound.span_start = nil
      return nil
    end
    sound.span_start = round_ms(seconds)
    return sound.span_start
  else
    if seconds == nil then
      sound.span_end = nil
      return nil
    end
    local floor_at = (sound.span_start or 0) + span.MIN
    if seconds < floor_at then seconds = floor_at end
    if seconds >= length then
      sound.span_end = nil
      return nil
    end
    sound.span_end = round_ms(seconds)
    return sound.span_end
  end
end

return span
