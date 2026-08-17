-- demo: the walkthrough finale's stand-in numbers (2026-08-10, user's ask).
--
-- The tour fires on FIRST OPEN, which means an empty library — so its last stop
-- opened the Loudness panel onto six dashes, which explains nothing. This
-- module invents one sound's worth of measurements so that panel has something
-- to describe: a short game one-shot, loud where a reference usually is.
--
-- It is DRAWING DATA ONLY, and that is the whole safety story. It is never put
-- on `state.selected`, never enters the library, and nothing can act on it: the
-- app still knows nothing is armed, so play, trim, drag-to-timeline and the
-- preset buttons all stay dead of their own accord rather than by being
-- specially disabled. `demo.active` is asked first, and the match window passes
-- this record where it would pass a real sound — for READING only (its `show`
-- vs `sel` split).
--
-- A matching demo WAVEFORM was built and then deliberately removed the next day
-- (user's call, after seeing it live): the waveform is the one part of the tool
-- you can click, seek, drag out and set span handles on, so a fake one invites
-- gestures that silently do nothing — and it appeared mid-tour, which read as
-- something arriving out of nowhere. Numbers can only be read, so a stand-in
-- there can't be prodded into failing. `prototypes/proto_demo_sound.lua` still
-- draws the retired waveform if the question is ever reopened.
--
-- Pure Lua, no reaper.*.

local wt = require("core.walkthrough")

local demo = {}

demo.NAME = "Whoosh_Transition_01.wav"

-- A mastered SFX one-shot's numbers. The low integrated value against the high
-- short-term one is exactly what a two-second sound measures, so the panel
-- reads as a real analysis rather than as six round placeholders.
demo.SOUND = {
  id = "##demo", -- can never collide with a library id (those are plain numbers)
  name = demo.NAME,
  duration = 2.4,
  trim_db = 0,
  lufs_s_max = -11.2,
  lufs_m_max = -9.4,
  lufs_i     = -16.8,
  true_peak  = -0.5,
  peak       = -0.7,
  rms        = -19.3,
}

-- Whether the stand-in may be shown at all. FOUR conditions, all required: the
-- tour is running, this stop is one that needs a sound to make sense
-- (`stop.demo` — the finale), and the user has nothing of their own anywhere:
-- no library sounds, no pins, nothing armed. The moment they add anything,
-- their own sound takes over and the demo never appears again.
function demo.active(ws, has_sounds, has_pins, has_selection)
  if has_sounds or has_pins or has_selection then return false end
  local cur = wt.current(ws)
  return type(cur) == "table" and cur.demo == true
end

return demo
