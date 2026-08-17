-- preview: the audio-preview adapter and a sibling to reaper_api — one of the only
-- modules allowed to call reaper.*/SWS. It owns the live preview (SWS CF_Preview)
-- plus the PCM sources behind it, so auto-audition can switch sounds fast without
-- ever leaking or overlapping playback.
--
-- Routing: I_OUTCHAN = 0 sends the preview to the first hardware output, which
-- passes through Monitor FX (verified — same engine as REAPER's Media Explorer
-- preview). That routing IS the point of the tool, so it isn't configurable here.
--
-- MONO MONITORING (2026-08-07). One preview is ONE playback, and it reaches ONE
-- pair of outputs — so listening in mono is not a flag on a single preview but
-- TWO previews of the same file, playing at once:
--
--   I_OUTCHAN 1024 = sum this source to mono, send it to output 1
--   I_OUTCHAN 1025 = sum this source to mono, send it to output 2
--
-- Both together put the same mono sum in both speakers, which is what a mono
-- check is. The &1024 bit is a REAL sum, not a channel pick — proved in REAPER
-- with a generated two-tone file (300 Hz left, 900 Hz right): played together,
-- both pitches came out of both speakers, which a channel pick cannot do. See
-- docs/RESEARCH.md, "Rate / pitch / mono on the preview path".
--
-- Everything below therefore works on a LIST of parts rather than a single
-- handle. Every operation fans out; every part is released. That is the whole
-- risk of this design — release one part and leak the other and the tool holds a
-- file open forever — which is why preview.lua carries a spec
-- (tests/preview_spec.lua) under the adapter rule.
--
-- EVERY ROUTE PLAYS AT ONCE; THE MODE ONLY CHOOSES WHAT YOU HEAR (2026-08-07,
-- second pass). The first build created the parts a mode needed and destroyed
-- the rest, so switching mono mid-playback stopped the audio and started it
-- again — an audible gap with a hard edge either side. The user reported the
-- click and was right to: "doing this in a plugin or in REAPER does not cause
-- this", because a plugin never restarts anything; it changes what it does to
-- the signal already flowing.
--
-- So all three routes are created and played TOGETHER, and the mono button is a
-- volume change on parts that never stop. Nothing restarts, so there is no gap
-- to hear, and because every part started on the same call they stay locked to
-- each other — which also means switching can't jump the playhead.
--
-- The cost is honest and small: three preview objects and three PCM sources for
-- one sound instead of one of each. This tool plays a single reference at a
-- time, and a streaming decoder is cheap next to a click every time the user
-- checks mono. It also REMOVED code — no rebuild, no remembering the path and
-- loop state to restart from.

local preview = {}

-- The fixed routes. `mono` says which monitoring mode a route belongs to; the
-- other routes are held at silence rather than stopped.
--   0    = first hardware output pair => through Monitor FX
--   1024 = sum to mono -> output 1        1025 = sum to mono -> output 2
local ROUTES = {
  { outchan = 0,    mono = false },
  { outchan = 1024, mono = true  },
  { outchan = 1025, mono = true  },
}

-- The live preview: one part per route while anything is playing. Module-local
-- so there is exactly one place that starts, stops and releases handles —
-- nothing outside this module can hold one.
local live = {
  parts  = {},  -- { { handle = CF_Preview, src = PCM_source, route = ROUTES[i] }, ... }
  length = 0,   -- REAL source length in seconds (playhead scale) — read from the
                -- file, not the library record, so a file replaced on disk still
                -- gets a truthful playhead
  mono   = false, -- the monitoring MODE: survives stop/start, like a user setting
  db     = 0,     -- the level the AUDIBLE parts play at; silent parts sit at 0
}

-- dB -> linear gain for D_VOLUME (0 dB = 1.0). Volume only ever needs a real
-- meaning at the moment we hand it to the engine, so the conversion lives here.
local function db_to_gain(db)
  return 10 ^ ((db or 0) / 20)
end

-- This part's handle if the engine still has it, else nil — and it FORGETS a
-- handle the engine has freed, so nothing below can touch it twice.
--
-- Every operation goes through here rather than reading p.handle directly
-- (Codex, 2026-08-07). A non-looping preview frees itself the moment it reaches
-- the end and tells nobody; poll() notices, but the frame loop polls BEFORE it
-- draws and handles user actions AFTER, so a sound that ends inside that window
-- would be Stop()ped — or written to — through a stale handle by the very next
-- click. Asking costs one cheap call and makes each operation safe on its own
-- instead of depending on how recently poll() ran.
--
-- GetValue is the sanctioned probe: it is what poll() has always used to detect
-- the engine having freed a preview.
local function handle_of(p)
  if not p.handle then return nil end
  if reaper.CF_Preview_GetValue(p.handle, "D_POSITION") then return p.handle end
  p.handle = nil
  return nil
end

-- Release every part. Stop() also destroys the preview object, so we must not
-- touch (or re-Stop) a handle after; the sources are ours to destroy separately
-- (CF_CreatePreview does not take ownership of them). A part the engine already
-- freed only needs its source dropped.
local function release()
  for i = 1, #live.parts do
    local p = live.parts[i]
    local h = handle_of(p)
    if h then reaper.CF_Preview_Stop(h) end
    if p.src then reaper.PCM_Source_Destroy(p.src) end
    live.parts[i] = nil
  end
  live.length = 0
end

-- What a route should be playing at right now: the real level if it belongs to
-- the current monitoring mode, silence if it doesn't. One function so the mono
-- switch and the volume fader can never disagree about a part's level.
local function gain_for(route)
  if route.mono ~= live.mono then return 0 end
  return db_to_gain(live.db)
end

local function apply_gains()
  for i = 1, #live.parts do
    local p = live.parts[i]
    local h = handle_of(p)
    if h then reaper.CF_Preview_SetValue(h, "D_VOLUME", gain_for(p.route)) end
  end
end

-- Undo a half-built start. Its own function because the partial-failure path is
-- exactly where a leak hides: the second source failing must not strand the
-- first, which is already open and not yet in live.parts.
local function discard(built)
  for i = 1, #built do
    if built[i].handle then reaper.CF_Preview_Stop(built[i].handle) end
    if built[i].src then reaper.PCM_Source_Destroy(built[i].src) end
  end
end

-- Build every part fully, THEN start them back to back. Anything done between
-- the Play calls widens the gap between players of the same file, and the two
-- mono parts carry the same signal to opposite speakers — an offset there combs
-- when they meet in the room.
local function start(path, db, loop, position)
  release()
  live.db = db or 0
  local built = {}
  for i = 1, #ROUTES do
    local route = ROUTES[i]
    local src = reaper.PCM_Source_CreateFromFile(path)
    if not src then discard(built) return false end
    local h = reaper.CF_CreatePreview(src)
    if not h then
      reaper.PCM_Source_Destroy(src)
      discard(built)
      return false
    end
    reaper.CF_Preview_SetValue(h, "I_OUTCHAN", route.outchan)
    reaper.CF_Preview_SetValue(h, "B_LOOP", loop and 1 or 0)
    reaper.CF_Preview_SetValue(h, "D_VOLUME", gain_for(route))
    if position and position > 0 then
      reaper.CF_Preview_SetValue(h, "D_POSITION", position)
    end
    built[i] = { handle = h, src = src, route = route }
  end
  for i = 1, #built do reaper.CF_Preview_Play(built[i].handle) end

  live.parts = built
  live.length = reaper.GetMediaSourceLength(built[1].src) or 0
  return true
end

-- Start previewing a file. Stops and releases any current preview FIRST, so there
-- is never more than one sound playing. opts: { db, loop, position }.
-- Returns true on success, false if the file couldn't be opened as audio.
function preview.play(path, opts)
  opts = opts or {}
  return start(path, opts.db, opts.loop, opts.position)
end

function preview.stop()
  release()
end

-- Turn mono monitoring on or off. A MODE, not a per-playback option: it is
-- remembered while nothing plays, so the next sound starts in whatever the user
-- last chose.
--
-- Mid-playback this is JUST a volume change — every route is already playing, so
-- nothing stops, nothing starts, and there is no gap or edge to hear. That is
-- the whole reason the parts are built the way they are (see the module header).
function preview.set_mono(on)
  on = on and true or false
  if on == live.mono then return end
  live.mono = on
  apply_gains()
end

function preview.is_mono() return live.mono end

-- Live-adjust the playing preview's volume (dB). No-op when nothing plays.
-- Goes through the same gain rule as the mono switch, so the silent routes stay
-- silent instead of being dragged up by the fader.
function preview.set_volume_db(db)
  live.db = db or 0
  apply_gains()
end

function preview.set_loop(on)
  local v = on and 1 or 0
  for i = 1, #live.parts do
    local h = handle_of(live.parts[i])
    if h then reaper.CF_Preview_SetValue(h, "B_LOOP", v) end
  end
end

function preview.seek(position)
  local pos = position or 0
  for i = 1, #live.parts do
    local h = handle_of(live.parts[i])
    if h then reaper.CF_Preview_SetValue(h, "D_POSITION", pos) end
  end
end

-- The playing file's real length in seconds (0 when idle). The caller scales its
-- playhead by this, not by the library record's stored duration — the two disagree
-- when a file has been replaced on disk since import.
function preview.length() return live.length end

-- Current playback position in seconds, or nil if the preview is gone. Read from
-- the FIRST part only: every part plays the same file from the same spot, and
-- one authority means the playhead can never flicker between two answers. The
-- first part is the stereo route, which is silent in mono but still playing —
-- position doesn't care about volume.
-- GetValue's first return is a validity flag; the second is the value.
function preview.position()
  local p = live.parts[1]
  if not p then return nil end
  local h = handle_of(p)
  if not h then return nil end
  local ok, pos = reaper.CF_Preview_GetValue(h, "D_POSITION")
  if not ok then return nil end
  return pos
end

-- Call once per frame. A non-looping preview destroys its own handle when it
-- reaches the end, and GetValue then reports invalid — that's how we detect the
-- end without any callback (SWS previews have none).
--
-- With two parts they finish within a buffer of each other, so a part that has
-- gone is marked (handle = nil, never Stop()ped — the engine already freed it)
-- and the end is only reported once EVERY part is done. Reporting on the first
-- would strand the other still sounding.
function preview.poll()
  if #live.parts == 0 then return false end
  local alive = 0
  for i = 1, #live.parts do
    -- handle_of forgets a handle the engine has freed, so this both counts and
    -- disarms — nothing later can Stop() what has already gone.
    if handle_of(live.parts[i]) then alive = alive + 1 end
  end
  if alive > 0 then return false end
  release()
  return true
end

return preview
