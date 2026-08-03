-- reaper_api: the ONLY module that calls REAPER/SWS functions (the ui/ layer is
-- the one exception — it may call reaper.ImGui_* because drawing is its job, and
-- nothing else on reaper.*). Keeping every REAPER-specific call in one place is
-- what lets the rest of the code stay pure and unit-testable.

local reaper_api = {}

local SEP = package.config:sub(1, 1) -- "\" on Windows, "/" elsewhere — never hard-coded

-- Join path segments with the OS separator.
function reaper_api.join(...)
  return table.concat({ ... }, SEP)
end

-- Is this dock id one of REAPER's FLOATING dockers? (2026-07-30)
--
-- Dragging a docked window's tab out of a docker makes REAPER put it in a
-- floating docker — a separate window with our tool as a tab inside it, which
-- the user never wants. That state is indistinguishable from a normal dock by
-- ImGui alone (both are negative ids), so it takes REAPER's own answer: a dock
-- id of ~index, and DockGetPosition reporting 4 (0 bottom, 1 left, 2 top,
-- 3 right, 4 floating). Lives here because DockGetPosition is a plain reaper.*
-- call, which the ui/ layer is not allowed to make.
function reaper_api.is_floating_docker(dock_id)
  if not reaper.DockGetPosition then return false end   -- REAPER < 6.02
  local n = math.tointeger(dock_id)
  if not n or n >= 0 then return false end              -- 0 = floating window, >0 = an ImGui node
  return reaper.DockGetPosition(~n) == 4
end

-- REAPER's dockers as a pick-list for the "Dock window in Docker" menu (2026-07-30):
-- one entry per docker attached to REAPER's window, labelled by the side it sits
-- on and numbered when several share a side. This exists because the drag route
-- means hitting a ~32px strip with no visual cue of its own — picking from a list
-- needs no aim at all.
--
-- Floating dockers are left out deliberately: landing in one is refused (see
-- is_floating_docker), so offering it would look like the menu did nothing.
function reaper_api.dockers()
  local out = {}
  if not reaper.DockGetPosition then return out end     -- REAPER < 6.02
  local sides = { [0] = "Bottom", [1] = "Left", [2] = "Top", [3] = "Right" }
  local counts = {}
  for i = 0, 15 do                                      -- REAPER has 16 dockers
    local side = sides[reaper.DockGetPosition(i)]        -- nil for invalid (-1) or floating (4)
    if side then
      counts[side] = (counts[side] or 0) + 1
      local label = side
      if counts[side] > 1 then label = side .. " " .. counts[side] end
      out[#out + 1] = { dock_id = ~i, label = label }
    end
  end
  return out
end

-- Which add-ons are present. ImGui is required to draw anything at all; SWS is
-- required for preview playback; js_ReaScriptAPI is optional (nicer multi-file
-- picker). Feature-detected so a missing one becomes a friendly screen, not a
-- crash.
function reaper_api.check_deps()
  return {
    imgui      = reaper.APIExists("ImGui_CreateContext"),
    imgui_drop = reaper.APIExists("ImGui_AcceptDragDropPayloadFiles"),
    sws        = reaper.APIExists("CF_CreatePreview"),
    -- Also SWS, but detected separately: dragging to the timeline needs the
    -- mouse-context calls specifically, and it works with or without preview. All
    -- three are checked — a partial or older install that had only the first would
    -- otherwise pass here and then fail mid-drag.
    drag_out   = reaper.APIExists("BR_GetMouseCursorContext")
      and reaper.APIExists("BR_GetMouseCursorContext_Track")
      and reaper.APIExists("BR_GetMouseCursorContext_Position"),
    js         = reaper.APIExists("JS_Dialog_BrowseForOpenFiles"),
    -- Also js_ReaScriptAPI, detected on its own: the Settings page offers the OS
    -- folder picker only when this exact call exists, else a type-a-path field.
    folder_picker = reaper.APIExists("JS_Dialog_BrowseForFolder"),
  }
end

-- Default library folder, under REAPER's user-data folder — never the script's
-- install folder (a ReaPack update overwrites that). User-changeable later.
function reaper_api.default_library_dir()
  return reaper_api.join(reaper.GetResourcePath(), "Data", "yb_Reference")
end

local EXT_SECTION = "yb_Reference"
local EXT_LIBDIR  = "library_dir"
local EXT_MASTER  = "master_db"
local EXT_LOUD    = "loud_unit"
local EXT_BROWSER_GEOM = "browser_geom"
local EXT_LAYOUT  = "layout_mode"

-- The active library folder: a user-chosen location if one has been stored
-- (via the Settings page), otherwise the default.
function reaper_api.library_dir()
  local stored = reaper.GetExtState(EXT_SECTION, EXT_LIBDIR)
  if stored ~= nil and stored ~= "" then return stored end
  return reaper_api.default_library_dir()
end

-- Remember the user's chosen library folder (persisted, like the other prefs).
function reaper_api.set_library_dir(path)
  reaper.SetExtState(EXT_SECTION, EXT_LIBDIR, path, true)
end

-- OS folder picker (needs js_ReaScriptAPI — feature-detected; the Settings page
-- shows a type-a-path fallback when it's absent). Returns the chosen folder, or
-- nil when cancelled/unavailable.
function reaper_api.browse_for_folder(title, initial)
  if reaper.APIExists("JS_Dialog_BrowseForFolder") then
    local rv, folder = reaper.JS_Dialog_BrowseForFolder(title, initial or "")
    if rv == 1 and folder and folder ~= "" then return folder end
  end
  return nil
end

-- Create a folder and any missing parents. Safe to call when it already exists.
function reaper_api.ensure_dir(path)
  reaper.RecursiveCreateDirectory(path, 0)
end

-- Master preview volume (dB) is an app preference, not library data, so it lives
-- in ExtState (persisted flag = true). Defaults to 0 dB on first run.
function reaper_api.get_master_db()
  local v = tonumber(reaper.GetExtState(EXT_SECTION, EXT_MASTER))
  return v or 0
end

function reaper_api.set_master_db(db)
  reaper.SetExtState(EXT_SECTION, EXT_MASTER, tostring(db), true)
end

-- Which measurement the Loudness column shows. Also an app preference (it's a way
-- of looking at the library, not part of it), so it lives beside the master volume.
-- Returns the stored name as-is; the caller decides whether it still means anything.
function reaper_api.get_loud_unit()
  local v = reaper.GetExtState(EXT_SECTION, EXT_LOUD)
  return v ~= "" and v or nil
end

function reaper_api.set_loud_unit(field)
  reaper.SetExtState(EXT_SECTION, EXT_LOUD, field, true)
end

-- Which working-view arrangement to use: "auto" (pick from the room measured
-- each frame), "stacked", or "column". An app preference like the master volume,
-- so it lives in ExtState. Defaults to "auto"; anything unrecognised in the
-- stored value is treated as "auto" rather than trusted, so a hand-edited or
-- future value can't leave the layout in a state this build can't draw.
local LAYOUT_MODES = { auto = true, stacked = true, column = true }

function reaper_api.get_layout_mode()
  local v = reaper.GetExtState(EXT_SECTION, EXT_LAYOUT)
  return LAYOUT_MODES[v] and v or "auto"
end

function reaper_api.set_layout_mode(mode)
  reaper.SetExtState(EXT_SECTION, EXT_LAYOUT, LAYOUT_MODES[mode] and mode or "auto", true)
end

-- The browser popup's remembered position + size (Phase 5.7 Stage 3), so it reopens
-- where it was left rather than re-centring every run. Stored as one "x,y,w,h"
-- string (persisted, like the other app prefs). Returns nil when unset OR when the
-- stored text doesn't parse as four numbers — a caller must treat nil exactly like
-- "never saved" (falls back to the default size, no position).
function reaper_api.get_browser_geom()
  local v = reaper.GetExtState(EXT_SECTION, EXT_BROWSER_GEOM)
  if v == "" then return nil end
  local x, y, w, h = v:match("^(-?%d+),(-?%d+),(%d+),(%d+)$")
  x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
  if not (x and y and w and h) then return nil end
  return { x = x, y = y, w = w, h = h }
end

function reaper_api.set_browser_geom(x, y, w, h)
  reaper.SetExtState(EXT_SECTION, EXT_BROWSER_GEOM,
    string.format("%d,%d,%d,%d", x, y, w, h), true)
end

-- Show a file in the OS file browser (opens its containing folder with the file
-- selected). Used by the "Show library folder" button so the user can find the
-- library and its trash without hunting through REAPER's settings folders.
--
-- Prefers SWS's CF_LocateInExplorer (clean, no console flash). Falls back to
-- Windows Explorer directly when SWS isn't present. Returns true if it could try,
-- false if there's no way to on this setup — the caller then says so rather than
-- looking like the button did nothing.
function reaper_api.reveal_file(path)
  if reaper.APIExists("CF_LocateInExplorer") then
    reaper.CF_LocateInExplorer(path)
    return true
  end
  if SEP == "\\" then
    -- /select, opens the folder and highlights the file. Quotes handle spaces.
    os.execute('explorer /select,"' .. path .. '"')
    return true
  end
  return false
end

-- Show the drag cursor for this frame — called every frame while a drag to the
-- timeline is in flight, because REAPER re-asserts its own cursor constantly (a
-- one-off set would flicker back immediately). Two honest states, the way OS
-- drag-and-drop behaves:
--
--   can drop  -> our OWN cursor image (assets/cursors/drag_copy.cur): the arrow
--                with a sheet-and-plus badge, the same grammar Windows uses for
--                a file drag that will COPY — which is exactly what the user
--                sees dragging INTO the tool (2026-08-02). It has to be a cursor
--                rather than something we paint: a badge drawn into a following
--                window would trail the pointer at our redraw rate, and a badge
--                that lags behind the arrow reads as broken.
--   can't     -> Windows' own NO-ENTRY circle (32648), which already IS the OS
--                drag cursor for a refusal, so there is nothing to improve.
--
-- Falls back to the plain HAND (32649) if the cursor file can't be loaded, and
-- does nothing at all without js_ReaScriptAPI. Handles are loaded once each
-- (false = tried and unavailable); LoadCursorFromFile caches by path itself, but
-- the local cache keeps it to one call per session rather than one per frame.
local drag_cursors = {}
local drag_copy_file

-- Told once at startup where the cursor file lives (the entry script owns the
-- script root; this module must not go looking for it).
function reaper_api.set_drag_cursor_file(path)
  drag_copy_file = path
end

local function numbered_cursor(id)
  if drag_cursors[id] == nil then
    drag_cursors[id] = reaper.JS_Mouse_LoadCursor(id) or false
  end
  return drag_cursors[id] or nil
end

local function copy_cursor()
  if drag_cursors.copy == nil then
    drag_cursors.copy = false
    if drag_copy_file and reaper.APIExists("JS_Mouse_LoadCursorFromFile") then
      drag_cursors.copy = reaper.JS_Mouse_LoadCursorFromFile(drag_copy_file) or false
    end
  end
  return drag_cursors.copy or nil
end

function reaper_api.show_drag_cursor(can_drop)
  if not reaper.APIExists("JS_Mouse_SetCursor") then return end
  local cur
  if can_drop then
    cur = copy_cursor() or numbered_cursor(32649)
  else
    cur = numbered_cursor(32648)
  end
  if cur then reaper.JS_Mouse_SetCursor(cur) end
end

-- Native REAPER message box. Works even when SWS and ImGui are absent, so it's
-- the right tool for the setup guides that must appear before (or instead of) the
-- ImGui window.
function reaper_api.message(text, title)
  reaper.ShowMessageBox(text, title or "yb_Reference", 0)
end

--------------------------------------------------------------- files & audio

-- Audio extensions we accept on import (v1 = common file types REAPER reads).
-- Lowercased keys; anything not here is ignored by the drop/orphan scan.
reaper_api.AUDIO_EXTS = {
  wav = true, aiff = true, aif = true, flac = true, mp3 = true,
  ogg = true, w64 = true, wv = true, m4a = true, rex = true,
}

local function ext_of(name)
  local e = name:match("%.([^%.]+)$")
  return e and e:lower() or nil
end

-- True if a filename looks like one of our accepted audio types.
function reaper_api.is_audio_file(name)
  local e = ext_of(name)
  return e ~= nil and reaper_api.AUDIO_EXTS[e] == true
end

-- Size of a file in bytes, or nil if it can't be opened. Used for dedup (same
-- source basename + size => likely the same file re-added).
function reaper_api.file_size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  return size
end

-- Copy a file byte-for-byte. Streamed in chunks so a large sound doesn't load
-- whole into memory. Returns true, or false + message. On any failure the partial
-- destination is removed so a crash mid-copy can't leave a truncated sound the
-- record would later point at (the record is only written AFTER a clean copy).
--
-- Refuses an existing destination outright. Every caller has already chosen a
-- collision-free name, so anything found here is a name the collision check could
-- not see — two names Windows folds to the same file (its Unicode case rules go
-- far beyond Lua's byte-wise lower()) — and opening it "wb" would empty the
-- victim before a single byte arrived. A refusal loses nothing.
function reaper_api.copy_file(src, dest)
  if reaper_api.path_exists(dest) then
    return false, "a file that Windows considers the same name already exists (" .. dest .. ")"
  end
  local inp, ierr = io.open(src, "rb")
  if not inp then return false, "cannot read source: " .. tostring(ierr) end
  local out, oerr = io.open(dest, "wb")
  if not out then inp:close(); return false, "cannot create destination: " .. tostring(oerr) end
  while true do
    -- A read returns nil at the end of the file AND on a read error, so the two
    -- have to be told apart: treating a failed read as "finished" would leave a
    -- truncated copy that every later step reports as a success.
    local chunk, rerr = inp:read(1024 * 1024)
    if not chunk then
      if rerr then
        inp:close(); out:close(); os.remove(dest)
        return false, "read failed: " .. tostring(rerr)
      end
      break
    end
    local ok, werr = out:write(chunk)
    if not ok then
      inp:close(); out:close(); os.remove(dest)
      return false, "write failed: " .. tostring(werr)
    end
  end
  inp:close()
  local closed, cerr = out:close() -- close is where a full disk actually surfaces
  if not closed then
    os.remove(dest)
    return false, "could not finish writing (disk full?): " .. tostring(cerr)
  end
  return true
end

-- Is there already something at this path? Opening it answers for anything we can
-- read; renaming a name to itself answers for the rest (that can only succeed if
-- something is there), which catches a folder, or a file we may see but not read.
function reaper_api.path_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return os.rename(path, path) == true
end

-- Move a file. os.rename is instant when both ends are on the same drive, which is
-- the normal case here (the trash folder lives inside the library folder). If it
-- refuses — a library folder on a different drive, a lock — fall back to copying
-- and then deleting the original. Returns true, or false + message.
--
-- If the copy lands but the original won't delete, this still reports success: the
-- file HAS arrived, and the leftover is picked up as an orphan by the startup sweep.
-- Reporting failure there would be worse — the caller would abandon a move that in
-- fact happened, leaving two copies AND the record still pointing at the old one.
function reaper_api.move_file(src, dest)
  -- Refuse outright if something is already there. os.rename won't overwrite, but
  -- the copy fallback opens the destination for writing and would empty it before
  -- reading a single byte — turning a safe refusal into a destroyed file.
  if reaper_api.path_exists(dest) then
    return false, "there is already a file at " .. dest
  end

  if os.rename(src, dest) then return true end
  local copied, err = reaper_api.copy_file(src, dest)
  if not copied then return false, err end
  os.remove(src)
  return true
end

-- Every file directly inside a folder (non-recursive, no sub-folders). Returns
-- filenames, not full paths.
function reaper_api.list_files(dir)
  local out = {}
  local i = 0
  while true do
    local name = reaper.EnumerateFiles(dir, i)
    if not name then break end
    out[#out + 1] = name
    i = i + 1
  end
  return out
end

-- Just the audio ones (the library keeps sounds flat in its folder).
function reaper_api.list_audio_files(dir)
  local out = {}
  for _, name in ipairs(reaper_api.list_files(dir)) do
    if reaper_api.is_audio_file(name) then out[#out + 1] = name end
  end
  return out
end

-- Read a sound file's duration (seconds) and channel count without importing it.
-- Creates a throwaway PCM source and destroys it. Returns { duration, channels }
-- or nil if the file couldn't be opened as audio.
function reaper_api.probe_audio(path)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local duration = reaper.GetMediaSourceLength(src) -- first return is length in seconds
  local channels = reaper.GetMediaSourceNumChannels(src)
  reaper.PCM_Source_Destroy(src)
  return { duration = duration or 0, channels = channels or 0 }
end

-- Technical facts about a sound file, for the browser's info row (2026-07-29
-- redesign): sample rate, channel count, bit depth, and the format (upper-cased
-- extension — what the user recognises, without a REAPER-type-name mapping).
-- Same throwaway-source pattern as probe_audio. Called once per browse
-- selection, never per frame. Returns nil when the file can't be opened.
function reaper_api.source_info(path)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local info = {
    rate     = reaper.GetMediaSourceSampleRate(src),
    channels = reaper.GetMediaSourceNumChannels(src),
    format   = (ext_of(path) or ""):upper(),
  }
  -- Bit depth needs SWS, and only PCM formats have one — 0 means "no meaningful
  -- answer" (compressed audio), left nil so the UI omits it rather than printing
  -- "0-bit".
  if reaper.APIExists("CF_GetMediaSourceBitDepth") then
    local bits = reaper.CF_GetMediaSourceBitDepth(src)
    if bits and bits > 0 then info.bits = bits end
  end
  reaper.PCM_Source_Destroy(src)
  return info
end

-- Ask the user to pick sound files. Uses the js multi-select dialog when present,
-- otherwise REAPER's built-in single-file picker (the guaranteed fallback).
-- Returns a list of full paths, or nil if cancelled.
function reaper_api.pick_files()
  if reaper.APIExists("JS_Dialog_BrowseForOpenFiles") then
    local ok, list = reaper.JS_Dialog_BrowseForOpenFiles("Add sounds to library", "", "", "", true)
    if not ok or not list or list == "" then return nil end
    -- js returns either a single full path, or a folder followed by zero-separated
    -- filenames when several are picked. (Lua 5.4 dropped %z — match literal \0.)
    local parts = {}
    for s in (list .. "\0"):gmatch("([^\0]*)\0") do parts[#parts + 1] = s end
    if #parts <= 1 then return parts end
    local dir, files = parts[1], {}
    for i = 2, #parts do files[#files + 1] = reaper_api.join(dir, parts[i]) end
    return files
  end
  local ok, fn = reaper.GetUserFileNameForRead("", "Add a sound to library", "")
  if not ok or not fn or fn == "" then return nil end
  return { fn }
end

return reaper_api
