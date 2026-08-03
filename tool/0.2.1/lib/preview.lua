-- preview: the audio-preview adapter and a sibling to reaper_api — one of the only
-- modules allowed to call reaper.*/SWS. It owns AT MOST ONE live preview (SWS
-- CF_Preview) plus the PCM source behind it, so auto-audition can switch sounds
-- fast without ever leaking or overlapping playback.
--
-- Routing: I_OUTCHAN = 0 sends the preview to the first hardware output, which
-- passes through Monitor FX (verified — same engine as REAPER's Media Explorer
-- preview). That routing IS the point of the tool, so it isn't configurable here.

local preview = {}

local HW_OUT = 0 -- first hardware output => through Monitor FX

-- The single live preview. Module-local so there is exactly one place that starts,
-- stops, and releases a handle — nothing outside this module can hold one.
local live = {
  handle = nil, -- CF_Preview object, or nil when nothing is playing
  src    = nil, -- PCM_source we created and therefore must destroy ourselves
  length = 0,   -- REAL source length in seconds (playhead scale) — read from the
                -- file, not the library record, so a file replaced on disk still
                -- gets a truthful playhead
}

-- dB -> linear gain for D_VOLUME (0 dB = 1.0). Volume only ever needs a real
-- meaning at the moment we hand it to the engine, so the conversion lives here.
local function db_to_gain(db)
  return 10 ^ ((db or 0) / 20)
end

-- Release the current preview and its source. Stop() also destroys the preview
-- object, so we must not touch the handle after; the source is ours to destroy
-- separately (CF_CreatePreview does not take ownership of it).
local function release()
  if live.handle then
    reaper.CF_Preview_Stop(live.handle)
    live.handle = nil
  end
  if live.src then
    reaper.PCM_Source_Destroy(live.src)
    live.src = nil
  end
  live.length = 0
end

-- Start previewing a file. Stops and releases any current preview FIRST, so there
-- is never more than one playing. opts: { db, loop, position }.
-- Returns true on success, false if the file couldn't be opened as audio.
function preview.play(path, opts)
  release()
  opts = opts or {}
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return false end
  local h = reaper.CF_CreatePreview(src)
  if not h then
    reaper.PCM_Source_Destroy(src)
    return false
  end
  reaper.CF_Preview_SetValue(h, "I_OUTCHAN", HW_OUT)
  reaper.CF_Preview_SetValue(h, "B_LOOP", opts.loop and 1 or 0)
  reaper.CF_Preview_SetValue(h, "D_VOLUME", db_to_gain(opts.db))
  if opts.position and opts.position > 0 then
    reaper.CF_Preview_SetValue(h, "D_POSITION", opts.position)
  end
  reaper.CF_Preview_Play(h)
  live.handle, live.src = h, src
  live.length = reaper.GetMediaSourceLength(src) or 0
  return true
end

function preview.stop()
  release()
end

-- Live-adjust the playing preview's volume (dB). No-op when nothing plays.
function preview.set_volume_db(db)
  if live.handle then
    reaper.CF_Preview_SetValue(live.handle, "D_VOLUME", db_to_gain(db))
  end
end

function preview.set_loop(on)
  if live.handle then
    reaper.CF_Preview_SetValue(live.handle, "B_LOOP", on and 1 or 0)
  end
end

function preview.seek(position)
  if live.handle then
    reaper.CF_Preview_SetValue(live.handle, "D_POSITION", position or 0)
  end
end

-- The playing file's real length in seconds (0 when idle). The caller scales its
-- playhead by this, not by the library record's stored duration — the two disagree
-- when a file has been replaced on disk since import.
function preview.length() return live.length end

-- Current playback position in seconds, or nil if the preview is gone. GetValue's
-- first return is a validity flag; the second is the value.
function preview.position()
  if not live.handle then return nil end
  local ok, pos = reaper.CF_Preview_GetValue(live.handle, "D_POSITION")
  if not ok then return nil end
  return pos
end

-- Call once per frame. A non-looping preview destroys its own handle when it
-- reaches the end, and GetValue then reports invalid — that's how we detect the
-- end without any callback (SWS previews have none). On that frame we release our
-- source and return true so the UI can drop back to the stopped state.
function preview.poll()
  if not live.handle then return false end
  local ok = reaper.CF_Preview_GetValue(live.handle, "D_POSITION")
  if ok then return false end
  live.handle = nil -- already freed by the engine; do NOT Stop() a dead handle
  if live.src then
    reaper.PCM_Source_Destroy(live.src)
    live.src = nil
  end
  live.length = 0
  return true
end

return preview
