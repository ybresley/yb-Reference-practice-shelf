-- holders: what live work is attached to a sound, and how to make all of it let
-- go at once.
--
-- At any moment up to five things can be holding one sound: the audio playing it,
-- the memory of where it was paused (in either window — see the pause memory
-- below), a waveform being read off it, a loudness pass measuring it, and
-- reference mode's marks saying it is the armed reference.
-- Deleting a sound, unpinning it, or walking away from the whole library has to
-- make EVERY one of them let go first — a source left open holds the file for the
-- rest of the REAPER session, and a mark left behind names a record that no
-- longer exists.
--
-- That sequence used to be hand-written at four separate places, each with a
-- different subset of the list, and the copies had already drifted: two of the
-- four forgot the pause memory. So the list lives here once, with its order, and
-- a caller only says WHICH sounds it is letting go of — a predicate over the id.
-- What is held, in what order it is dropped, and what a refused change has to
-- hand back are this module's business, not the caller's.
--
-- It sits at the service layer beside library_service/pins_service: it calls the
-- preview/peaks/loudness adapters rather than REAPER itself, and it reads and
-- writes the one shared `state` table the entry script owns.

local preview  = require("preview")
local peaks    = require("peaks")
local loudness = require("loudness")

local holders = {}

--------------------------------------------------------------- predicates

-- Pins carry their own id prefix ("p1" vs the library's "s1"), and that one
-- distinction is what every release site turns on: leaving a project drops the
-- pins, switching library folder drops the library sounds, a delete or an unpin
-- drops exactly one id.
--
-- All three answer FALSE for nil, which is what makes an idle holder invisible to
-- a release: "whatever is currently nothing" must never match.
function holders.is_pin(id)
  return type(id) == "string" and id:sub(1, 1) == "p"
end

function holders.is_library(id)
  return type(id) == "string" and id:sub(1, 1) ~= "p"
end

function holders.is_id(wanted)
  return function(id) return wanted ~= nil and id == wanted end
end

--------------------------------------------------------------- waveform requests

-- The last sound id each waveform slot ASKED peaks for (not what it holds). peaks
-- owns exactly ONE build job, so the two slots have to queue: the defer loop hands
-- out requests one at a time and this remembers what has already been asked, so a
-- file that cannot be opened is tried once rather than every frame. Exactly two
-- entries, ever.
--
-- It lives here because the rule that governs it is a release rule: a build that
-- gets cancelled must not leave its id marked as already-asked, or the slot still
-- waiting on that envelope would never get another try. Keeping the marks beside
-- the cancel is what stops the two drifting apart again.
local wave_asked = { main = nil, browse = nil }

function holders.wave_asked(slot) return wave_asked[slot] end
function holders.mark_wave(slot, id) wave_asked[slot] = id end
function holders.forget_wave(slot) wave_asked[slot] = nil end

--------------------------------------------------------------- the pause memory

-- Every slot that can remember a pause. "main" is the working view (and
-- reference mode); "browse" is the Library. Both windows carry a transport, so
-- both can park a position.
local PAUSE_SLOTS = { "main", "browse" }

-- ONE REMEMBERED PAUSE PER SLOT, not one for the tool (2026-08-12, when the
-- Library got its own transport). There is only ever one sound audible, but the
-- two windows keep their places independently: a reference paused at 0:30 in the
-- working view has to still be sitting at 0:30 after the user has opened the
-- Library, auditioned something else and paused THAT at 0:10. A single shared
-- record made the second pause overwrite the first, which silently destroys the
-- place the user was keeping in the sound they are actually working on.
--
-- Each slot holds `{ at, sound_id, length }` or nothing. `length` is a SNAPSHOT
-- taken when the pause was made, never a later read of `state.preview.length`:
-- that field follows whatever the one shared preview is sounding right now, so a
-- paused playhead reading it would end up scaling by another sound's duration.

-- This slot's remembered pause, whatever sound it belongs to.
function holders.pause_of(state, slot)
  return state.preview.paused[slot]
end

-- ...and the question every caller actually asks: is THIS sound the one this
-- slot has paused? Answering it here is what stops each call site re-writing the
-- id comparison (and its nil cases) by hand.
function holders.paused_on(state, slot, id)
  local p = state.preview.paused[slot]
  if p and id ~= nil and p.sound_id == id then return p end
  return nil
end

-- Remember where `id` was left, for this slot only.
function holders.set_pause(state, slot, id, at, length)
  state.preview.paused[slot] = { at = at or 0, sound_id = id, length = length or 0 }
end

-- Forget one slot's remembered pause. Its own function because the memory
-- outlives the shared preview fields, so the places that must drop it are not
-- the same places that stop audio.
function holders.clear_pause(state, slot)
  state.preview.paused[slot] = nil
end

--------------------------------------------------------------- one holder at a time

-- Tell the engine to stop sounding and put the shared preview fields back to
-- idle — and NOTHING else. Separate from stop_playback because stopping the
-- audio and forgetting where a slot was paused are two different acts: a
-- release that isn't the working view's (stop_browse_audition, below) needs
-- exactly this part, and so does the preview holder, whose matching pauses the
-- pause holder clears per slot.
function holders.stop_audio(state)
  preview.stop()
  state.preview.playing  = false
  state.preview.sound_id = nil
  state.preview.slot     = nil
  state.preview.trim_db  = 0
  state.preview.position = 0
end

-- A full stop for one slot: whatever is sounding stops, and that slot's
-- remembered pause goes with it — there is nothing left to resume. The slot is
-- required, and it is what keeps one window's Stop button from wiping the other
-- window's place in a sound.
function holders.stop_playback(state, slot)
  holders.stop_audio(state)
  holders.clear_pause(state, slot)
end

-- Stop the Library's own audition, and only that. The working view's
-- reference sounds through the exact same shared preview fields, so this
-- checks the "browse" tag before touching anything at all — closing the
-- Library must never interrupt a main-slot reference the user left playing.
--
-- Deliberately clears NO pause, the browse slot's included. The main slot's was
-- never this function's to touch and now cannot be reached from here anyway; the
-- browse one is KEPT on purpose (2026-08-12), so reopening the Library finds the
-- audition still parked where the user paused it — the same promise the working
-- view's playhead makes. Closing a window is not a stop.
function holders.stop_browse_audition(state)
  if state.preview.slot ~= "browse" then return end
  holders.stop_audio(state)
end

-- The working view's selection, dropped. Nothing is selected afterwards on
-- purpose: silently jumping the selection to a neighbouring row would start
-- auditioning a sound nobody asked for.
--
-- Separate from `release` rather than part of it, because the two do not always
-- happen together: a delete must let go of the file BEFORE it tries to move it,
-- but must only forget the selection once the delete actually succeeded.
function holders.forget_selection(state, matches)
  if not matches(state.selected_id) then return end
  state.selected_id, state.selected, state.selected_tech = nil, nil, nil
  state.waveform = { sound_id = nil, channels = {} }
end

-- The browser's own selection, which is always a LIBRARY id — never a pin.
function holders.forget_browse(state, matches)
  if not matches(state.browse_id) then return end
  state.browse_id, state.browse, state.browse_info = nil, nil, nil
  state.browse_waveform = { sound_id = nil, channels = {} }
end

--------------------------------------------------------------- the holder list

-- Every place a sound can be held, in the order they let go. The order is
-- deliberate: the audible holder first (it is the only one the user can hear),
-- then the memory of it, then the two background readers keeping the file open,
-- and last the marks that merely describe what was armed.
--
-- `ids` reads whichever sound ids this holder is attached to right now (up to
-- two); `let_go(state, token, matches)` releases it, notes in the token anything
-- a refused change would have to restart, and — where a holder has more than one
-- place to let go of (the two pause slots) — uses `matches` to drop only the
-- places that actually hold this sound.
--
-- SHUTDOWN DOES NOT COME THROUGH HERE. The atexit handler and the frame loop's
-- close both release everything by hand, because there the order is inverted —
-- reference.cleanup() runs FIRST, since a master left muted is the only failure
-- that harms the user — and `state` is about to be thrown away regardless. If a
-- holder that owns a REAPER resource is ever added to this list, add it to those
-- two lines in the entry script too.
local HOLDERS = {
  {
    -- Audio only: the pause holder below drops the remembered positions, and it
    -- drops exactly the ones belonging to the sound being released. Stopping the
    -- audio must not also wipe a pause on some OTHER sound that happens to be
    -- parked at the time.
    name = "preview",
    ids  = function(state) return state.preview.sound_id end,
    let_go = function(state) holders.stop_audio(state) end,
  },
  {
    -- A PAUSED sound has no `sound_id` at all, so the preview check above cannot
    -- see it. This is the holder the hand-written copies kept forgetting. Both
    -- slots are checked, and only the ones actually holding this sound let go.
    name = "pause",
    ids  = function(state)
      local p = state.preview.paused
      return p.main and p.main.sound_id, p.browse and p.browse.sound_id
    end,
    let_go = function(state, _, matches)
      for i = 1, #PAUSE_SLOTS do
        local slot = PAUSE_SLOTS[i]
        local p = state.preview.paused[slot]
        if p and matches(p.sound_id) then holders.clear_pause(state, slot) end
      end
    end,
  },
  {
    name = "waveform",
    ids  = function() return peaks.pending() end,
    let_go = function(_, token)
      token.drawing = peaks.pending()
      peaks.cancel()
    end,
  },
  {
    -- Loudness only ever runs on LIBRARY sounds, so no caller has to remember to
    -- skip this for pins: a pin predicate simply never matches the id being
    -- measured. The module knowing that fact is what removed it from four call
    -- sites that each had to remember it separately.
    name = "loudness",
    ids  = function() return loudness.current() end,
    let_go = function(_, token)
      token.measuring = loudness.current()
      loudness.cancel()
    end,
  },
  {
    -- `latched` is deliberately NOT touched. Losing the armed reference while
    -- latched leaves the tool latched at NO TARGET, because auto-unlatching would
    -- surprise-blast project audio the user has muted (see toggle_reference), and
    -- the recovery journal that promises to un-mute is reference.lua's alone.
    name = "reference",
    ids  = function(state) return state.reference.sound_id, state.reference.failed_id end,
    let_go = function(state)
      local ref = state.reference
      ref.active, ref.sound_id, ref.failed_id = false, nil, nil
    end,
  },
}

local function held_by(h, state, matches)
  local a, b = h.ids(state)
  return matches(a) or matches(b)
end

-- Who, if anyone, is holding this sound right now — the holder's name, or nil.
-- Reads the same list `release` walks, so the answer can never disagree with what
-- a release would actually do.
function holders.holding(state, id)
  local matches = holders.is_id(id)
  for i = 1, #HOLDERS do
    if held_by(HOLDERS[i], state, matches) then return HOLDERS[i].name end
  end
  return nil
end

-- Make every holder of a matching sound let go. Returns a token describing the
-- background work that was interrupted — hand it to `restore` if the change this
-- was clearing the way for ends up refused.
function holders.release(state, matches)
  local token = { wave = { main = wave_asked.main, browse = wave_asked.browse } }
  for i = 1, #HOLDERS do
    local h = HOLDERS[i]
    if held_by(h, state, matches) then h.let_go(state, token, matches) end
  end
  -- Both "already asked" marks go on every release, not only when a build was
  -- actually cancelled: after a release the slots may well want a different
  -- envelope, and a stale mark is exactly what stops one being built. Clearing a
  -- mark that did not need it costs at most one retry of a file that will not
  -- open — always the safe direction to err in.
  wave_asked.main, wave_asked.browse = nil, nil
  return token
end

-- Put back what `release` interrupted, for the paths where the change it made
-- room for was refused and the sound is still there. `path_of(id)` says where a
-- sound's audio is; a build whose file can no longer be named is simply not
-- restarted.
--
-- The measurement goes to the FRONT of the queue: it was already running, so it
-- keeps its place rather than dropping in behind a whole import.
function holders.restore(state, token, path_of)
  if not token then return end
  wave_asked.main, wave_asked.browse = token.wave.main, token.wave.browse
  if token.measuring then table.insert(state.analysis_queue, 1, token.measuring) end
  if token.drawing then
    local path = path_of and path_of(token.drawing)
    if path then peaks.request(token.drawing, path) end
  end
end

return holders
