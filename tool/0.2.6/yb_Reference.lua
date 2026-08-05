-- @description yb_Reference — audio reference library with instant preview
-- @version 0.2.6
-- @author Yoni Bresley
-- @about
--   A floating/dockable window for keeping a curated library of reference sounds
--   inside REAPER, with instant preview through Monitor FX and an A/B reference
--   mode against your project. Requires SWS and ReaImGui.
-- @provides
--   [nomain] lib/**/*.lua
--   [nomain] assets/fonts/lucide.ttf
--   [nomain] assets/fonts/LICENSE-Lucide.txt
--   [nomain] assets/cursors/drag_copy.cur
--   yb_Reference_ToggleReferenceMode.lua
-- @changelog
--   0.2.6 - Popup-timing stage (popup stacks over the open Settings panel).
--   0.2.0 - In-app updates: a daily check lights a dot on the browser's gear when
--     a newer version is on the shelf; Settings gains an UPDATES section with a
--     one-button update (ReaPack does the install; close and reopen to finish).
--   0.1.0 - First skeleton: window shell, library folder + data file, add-on guide.
--
-- NOTE: this @version header is what ReaPack's registry reports as the installed
-- version, which is exactly what the update badge compares the catalog against —
-- keep it honest on every release, and keep the release shelf's catalog naming
-- the same number.

-- This entry script owns the single shared `state` table and the one defer loop.
-- Everything else lives in lib/: core/ is pure Lua (unit-tested), reaper_api is
-- the only REAPER-calling layer, ui/ only draws. No globals.

--------------------------------------------------------------- module path

-- Resolve the script's own folder from the debug info, then make lib/ requireable
-- (so `require("core.schema")`, `require("ui.window")`, etc. resolve). Never
-- hard-code the separator.
local SEP = package.config:sub(1, 1)
local script_path = debug.getinfo(1, "S").source:sub(2) -- strip the leading "@"
local root = script_path:match("^(.*)[\\/]") or "."

-- The action id this tool is running as (get_action_context return #4) — what
-- the post-update "Restart now" button re-invokes. For a dev slot launched
-- through its wrapper action this is the WRAPPER's id, which is exactly right:
-- restarting re-runs whatever the user actually launched. 0 when there is no
-- real action (run from a console), which disables the restart offer.
local CMD_ID = ({reaper.get_action_context()})[4]
package.path = table.concat({
  root .. SEP .. "lib" .. SEP .. "?.lua",
  root .. SEP .. "lib" .. SEP .. "?" .. SEP .. "init.lua",
  package.path,
}, ";")

-- Which copy of the tool this is, shown in the title bar so a window is never
-- mistaken for another version: a dev slot (a git worktree parked under
-- .claude/worktrees/ — see the dev-worktrees skill) shows its slot name, the
-- main dev checkout shows [MAIN]. An end-user install (via ReaPack) has no git
-- bookkeeping and keeps the plain title — the labels are dev-only. The "###"
-- keeps the ImGui window identity stable regardless of the visible title.
local slot = root:match("[\\/]%.claude[\\/]worktrees[\\/]([^\\/]+)$")
local copy_label
if slot then
  copy_label = slot:upper():gsub("%-", " ")
else
  local git_head = io.open(root .. SEP .. ".git" .. SEP .. "HEAD", "r")
  if git_head then
    git_head:close()
    copy_label = "MAIN"
  end
end
local WIN_TITLE = copy_label
  and ("yb_Reference  [" .. copy_label .. "]###yb_Reference")
  or "yb_Reference 0.2.6###yb_Reference"

--------------------------------------------------------------- crash recovery

-- FIRST, before anything that can bail out below: a recovery note means a previous run
-- died while reference mode was latched, leaving a master muted. Restoring it must not
-- depend on ReaImGui being installed or the library file being readable — both of those
-- give up and `return`, which would strand a muted project. Also drop any leftover
-- hotkey press from while the tool was closed, so it can't silently latch on launch.
local reaper_api = require("reaper_api")
local reference  = require("reference")
reference.clear_toggle_request()
local recovery_msg, recovery_urgent = reference.recover()

-- An unresolved recovery is the user's project still sitting muted, so it can't wait
-- for the status line — the startup paths below may never reach it.
if recovery_urgent then
  reaper_api.message(recovery_msg, "yb_Reference — reference mode needs attention")
end

--------------------------------------------------------------- dependencies

local deps = reaper_api.check_deps()

-- ImGui is required to draw anything, so if it's missing we can't show an in-app
-- guide — fall back to a plain REAPER message box with install steps.
if not deps.imgui then
  reaper_api.message(
    "yb_Reference needs the ReaImGui extension, which isn't installed.\n\n" ..
    "Install it (free) via ReaPack:\n" ..
    "  1. Extensions > ReaPack > Browse packages\n" ..
    "  2. Search \"ReaImGui\" and install it\n" ..
    "  3. Restart REAPER, then run this again\n\n" ..
    "No ReaPack yet? Get it at https://reapack.com",
    "yb_Reference — setup needed")
  return
end

--------------------------------------------------------------- library data

local schema = require("core.schema")
local store  = require("core.library_store")

local library_dir  = reaper_api.library_dir()
local library_path = reaper_api.join(library_dir, "library.json")

-- The folder must really be there before anything else happens. A user-chosen
-- library can live on a drive or network share that isn't connected right now —
-- treating that as a first run would build an empty library that, once the drive
-- comes back, saves over the real one. Stopping loses nothing.
reaper_api.ensure_dir(library_dir)
if not reaper_api.path_exists(library_dir) then
  reaper_api.message(
    "Your library folder couldn't be found or created:\n\n" .. library_dir .. "\n\n" ..
    "If it's on a drive or network location that isn't connected right now, reconnect it and run the " ..
    "tool again. Nothing has been changed.",
    "yb_Reference — library not loaded")
  return
end

-- Undo a save interrupted by a previous crash. If the rescue itself can't be done we
-- must STOP: carrying on would find no library, create an empty one, and saving that
-- would delete the backup holding the real one.
local rec_ok, rec_err = pcall(store.recover, library_path)
if not rec_ok then
  reaper_api.message(
    "Your library couldn't be repaired after an interrupted save:\n\n" .. tostring(rec_err) .. "\n\n" ..
    "Nothing has been changed. Close REAPER, rename the \".bak\" file back to \"library.json\" " ..
    "by hand, then start the tool again.\n\nFolder:\n" .. library_dir,
    "yb_Reference — library not loaded")
  return
end

local library
if store.exists(library_path) then
  -- Load an existing library. If the file is unreadable we must NOT overwrite it
  -- (that would destroy the user's data) — surface a clear message and stop.
  local ok, result = pcall(store.load, library_path)
  if not ok then
    reaper_api.message(
      "Your library file couldn't be read:\n\n" .. tostring(result) .. "\n\n" ..
      "The tool has left the file untouched. Restore it from a backup, or move it " ..
      "aside to start a fresh library.\n\nFile:\n" .. library_path,
      "yb_Reference — library not loaded")
    return
  end
  library = result
elseif store.present(library_path) then
  -- The file is THERE but won't open — a lock, not a first run. Stopping is the
  -- only safe answer: carrying on with a fresh empty library would save it over
  -- the real one the moment the lock clears.
  reaper_api.message(
    "Your library file exists but couldn't be opened — something else (backup or " ..
    "sync software, most likely) is probably holding on to it.\n\nNothing has been " ..
    "changed. Close whatever is using the file, then run the tool again.\n\nFile:\n" .. library_path,
    "yb_Reference — library not loaded")
  return
else
  -- First run in this folder: create an empty library and save it immediately.
  -- If that very first save FAILS, stop — the folder can be a user-chosen
  -- location (Settings) that isn't really usable right now (a disconnected
  -- drive, a file sitting where the folder should be). Opening anyway with an
  -- empty in-memory library would save it over the real one the moment the
  -- location comes back. Stopping loses nothing.
  library = schema.new_library()
  local ok, err = pcall(store.save, library_path, library)
  if not ok then
    reaper_api.message(
      "A library couldn't be created in this folder:\n\n" .. tostring(err) ..
      "\n\nNothing has been changed. Check the folder is reachable and can be written to, " ..
      "then run the tool again:\n" .. library_dir,
      "yb_Reference — library not loaded")
    return
  end
end

--------------------------------------------------------------- UI + defer loop

-- The entry script owns the shared state and the one defer loop. All ImGui lives
-- in ui/app: context creation and the per-frame draw. library_service performs
-- the library-changing work the UI asks for (importing, orphan sweep).
local service    = require("library_service")
local categories = require("core.categories")
local search     = require("core.search")
local analysis   = require("core.analysis") -- what still needs measuring
local preview    = require("preview")  -- SWS audio-preview adapter (playback)
local peaks      = require("peaks")    -- waveform envelope reader
local loudness   = require("loudness") -- background loudness measurement
local dragout    = require("dragout")  -- dropping a sound onto the arrange view
local importer     = require("core.importer") -- dedup lookup for import-and-pin
local pins_core    = require("core.pins")     -- per-project pin records (pure)
local pins_service = require("pins_service")  -- pin/unpin/adopt + project switch handling
local updater      = require("updater")       -- in-app update check + one-button update
local app = require("ui.app")
-- The bundled Lucide icon font travels with the script (shipped via @provides), so
-- it's resolved from the script root, not the user's library folder.
local icon_font_path = table.concat({ root, "assets", "fonts", "lucide.ttf" }, SEP)
local ctx = app.create_context(icon_font_path)

-- The drag-out cursor travels with the script the same way. Handed over once
-- here because reaper_api has no business knowing where the script lives.
reaper_api.set_drag_cursor_file(table.concat({ root, "assets", "cursors", "drag_copy.cur" }, SEP))

-- The Loudness column can show any of the three measurements we store; which one is
-- remembered between runs. Anything unrecognised falls back to the default rather
-- than showing an empty column.
local stored_unit = reaper_api.get_loud_unit()
if not analysis.is_field(stored_unit) then stored_unit = search.DEFAULT_LOUD_FIELD end

-- REAPER's dockers, asked once: they're a property of the user's layout, not ours.
local dockers = reaper_api.dockers()

-- The update feature, told which file ReaPack would know this copy as. Also
-- replays the crash-window recovery if a previous run died mid-update (see
-- lib/updater.lua) — which is why it runs unconditionally, before the feature
-- decides whether THIS copy is even ReaPack-owned.
updater.init(script_path)

local state = {
  deps           = deps,
  library        = library,
  library_dir    = library_dir,
  library_path   = library_path,
  win_title      = WIN_TITLE,                    -- names the dev slot in the title bar when this copy is one
  -- The title bar's "Dock window in Docker" submenu, and the single docker it
  -- falls back to on a REAPER too old to report docker positions.
  dockers        = dockers,
  dock_target    = (dockers[1] and dockers[1].dock_id) or -1,
  selected_id    = nil,
  selected       = nil,                          -- the selected sound record (convenience for the UI)
  status         = nil,
  view           = { scope = "all" },            -- which category the list is showing
  query          = "",                           -- search box text
  sort           = { col = "name", asc = true }, -- matches the Name column's default sort
  loud_unit      = stored_unit,                  -- which measurement the Loudness column shows
  -- Which working-view arrangement to use: "auto" lets the window pick from the
  -- room it measures, "stacked"/"column" pin it. A remembered preference like
  -- the master volume; the arrangement auto actually settles on each frame is
  -- view-only scratch and lives in ui/window.lua, not here.
  layout         = reaper_api.get_layout_mode(),
  visible_sounds = {},                           -- library sounds for the view (filtered + sorted, cached)
  -- Playback (Phase 3). auto_audition on by default = clicking a sound plays it.
  auto_audition  = true,
  loop           = false,
  master_db      = math.max(-60, math.min(0, reaper_api.get_master_db())), -- preview level, clamped to -60..0 dB

  -- The browser's own selection (Phase 5.9 — independent browsing): a LIBRARY
  -- sound the browser table's row is on, entirely separate from `selected` (the
  -- working view's armed reference). Set only by browse_sound, below; the
  -- browser's rows must never touch `selected_id` (DESIGN "no REF latch and no
  -- trim here — browsing can never surprise-mute anything").
  browse_id      = nil,
  browse         = nil,
  browse_waveform = { sound_id = nil, channels = {} }, -- the browser's own audition-strip envelope
  browse_info    = nil, -- tech facts (rate/bits/format/channels) of the browsed sound, for the info row
  counts         = nil, -- per-category sound counts for the sidebar (filled by refresh_view)
  -- "Show in library": which sound the browser's table should scroll to, and a
  -- counter the table watches so it acts on each request exactly once (and so
  -- asking twice for the SAME sound still scrolls). Set by show_in_library.
  reveal_id      = nil,
  reveal_seq     = 0,

  -- `paused_at` (seconds) + `paused_sound_id` + `paused_length` are set only
  -- while the working view's OWN sound is paused (see
  -- pause_playback/resume_playback) — nil the rest of the time. Tracked
  -- SEPARATELY from `sound_id`/`length` on purpose: those two mean "whatever
  -- the one shared preview is sounding right now" (both get reassigned the
  -- instant a browse audition plays something else), but the pause memory must
  -- survive that — pausing sound A, then auditioning B and C in the browser,
  -- then coming back to A must still offer to resume it, and its waveform's
  -- paused playhead must keep scaling by A's real length, not whatever B or C
  -- left behind. Cleared on every real stop and whenever a DIFFERENT sound is
  -- selected, so a stale position can never resurrect on the wrong sound.
  -- `slot` records WHICH view started the playback ("main" = working view or
  -- reference mode, "browse" = the library browser) and `trim_db` the per-sound trim
  -- in force for it. They differ because a browse audition deliberately applies no
  -- trim at all, so neither the level nor the waveform can be re-derived from the
  -- sound record alone — the same sound sounds different depending on who started it.
  preview        = { playing = false, sound_id = nil, position = 0, length = 0,
    slot = nil, trim_db = 0,
    paused_at = nil, paused_sound_id = nil, paused_length = nil },
  -- Reference mode (Phase 4). `active` = the current preview was started BY the
  -- REAPER transport, so only transport changes may stop it (a casual audition the
  -- user started themselves is left alone). `sound_id` is what it's playing, so
  -- picking a different sound mid-play switches the reference live. `failed_id` is a
  -- sound that wouldn't play, so we don't retry it every frame.
  -- `pending` mirrors reference.pending() each frame: an un-latch that couldn't
  -- finish (project closed, write refused) — the master may still be muted, so the
  -- red border must stay on even though the latch itself is off.
  reference      = { latched = false, active = false, sound_id = nil, failed_id = nil, pending = false },
  waveform       = { sound_id = nil, channels = {} }, -- per-channel envelope of the selected sound
  -- A sound being dragged out to the arrange view: { sound_id, hint }. nil the rest
  -- of the time. One drag at a time, held here rather than per row.
  drag           = nil,
  -- The library browser popup (Phase 5.7 — two-view redesign): closed by
  -- default, toggled by the working view's Library button / the popup's own
  -- close button / Esc / an OS file drag passing over the working view.
  browser_open   = false,
  -- Remembered position + size (Phase 5.7 Stage 3), loaded once here; nil the
  -- first time this user ever opens it (or on an ancient ReaImGui without the
  -- geometry-reading calls) — app.lua then falls back to its default size.
  browser_geom   = reaper_api.get_browser_geom(),
  -- This project's pins (Phase 5.5): filled by pins_service.refresh before the
  -- first frame and re-filled whenever the project in front of the user changes.
  pins           = nil,
  wave_loading   = nil,                          -- sound id whose waveform is still building (UI hint)
  -- Loudness (Phase 5): ids waiting to be measured, worked through one pass per
  -- frame in the background. The list reads each record's own `analysis` field.
  analysis_queue = {},
  -- The update feature's view (lib/updater.lua mutates this one table for the
  -- whole session): enabled/installed/available/pinned/phase. The UI reads it —
  -- the gear's accent dot and Settings' UPDATES section — and reports
  -- "start_update" back; nothing else touches it.
  update         = updater.state,
  -- Whether the post-update popup may offer its one-click "Restart now"
  -- (REAPER 7's relaunch mechanism + a real action id to re-invoke). Without
  -- it the popup falls back to "close and reopen" wording.
  can_restart    = reaper_api.can_restart() and CMD_ID ~= nil and CMD_ID ~= 0,
}

-- The pinned set the visible list was last sorted against (see refresh_view).
-- Sorting by the pin column depends on data that lives outside the library, so
-- the list has to be re-sorted when the pins change and not just when the
-- library does.
local sorted_pins_version = nil

-- Recompute the filtered + sorted list. Called on view/search/sort change and
-- after any library change, NOT per frame (the UI reads the cached result).
local function refresh_view()
  state.visible_sounds = search.filter(state.library, state.view, state.query)
  search.sort(state.visible_sounds, state.sort.col, state.sort.asc, state.loud_unit,
    state.pins and state.pins.by_origin)
  sorted_pins_version = state.pins and state.pins.markers_version
  -- The sidebar's per-category counts (2026-07-29 redesign). Cheap (one pass over
  -- the sounds) and refresh_view already runs on every library mutation, so the
  -- numbers can never go stale without the list itself being stale too.
  state.counts = categories.counts(state.library)
end
refresh_view()

-- Save the whole library atomically after a mutation (never exit-time). A failed
-- save (disk full, a sync/backup tool holding the file) must NOT take the tool down
-- mid-frame: the change is still in memory and the very next mutation retries the
-- whole save, since every save writes the complete library. Said loudly once in a
-- dialog, then kept on the status line — a box per keystroke would be hostile.
local save_warned = false
local function commit()
  local ok, err = pcall(store.save, state.library_path, state.library)
  if ok then
    -- A retry that succeeded ends the episode: say so (a status line still claiming
    -- the library isn't saved would be a lie), and re-arm the one-time dialog so a
    -- NEW failure later isn't silently demoted to a status line nobody notices.
    if save_warned then
      save_warned = false
      state.status = "Library saved — everything is up to date on disk again."
    end
  else
    state.status = "Your last change couldn't be saved to the library file — it stays in the list and saving will be retried on the next change."
    if not save_warned then
      save_warned = true
      reaper_api.message(
        "Your last change couldn't be saved to the library file:\n\n" .. tostring(err) ..
        "\n\nThe tool keeps running, and the next change will try to save everything again. " ..
        "If this keeps happening, check your disk space, and whether backup or sync software " ..
        "is holding on to:\n" .. state.library_path,
        "yb_Reference — library couldn't be saved")
    end
  end
  return ok
end

--------------------------------------------------------------- playback

-- Pins carry their own id prefix ("p1" vs the library's "s1"), so one lookup can
-- serve both kinds of record — everything downstream (playback, waveform, seek,
-- drag-out) works on whichever the selection happens to be.
local function is_pin_id(id)
  return type(id) == "string" and id:sub(1, 1) == "p"
end

local function find_sound(id)
  if is_pin_id(id) then
    return state.pins and pins_core.find(state.pins.data, id) or nil
  end
  for _, s in ipairs(state.library.sounds) do
    if s.id == id then return s end
  end
  return nil
end

local function sound_path(s)
  if is_pin_id(s.id) then
    -- A pin's audio lives in the References folder beside the project file. dir
    -- is only nil when pin records arrived in a never-saved project (a project
    -- template, say) — the unresolvable path then fails exactly like a missing
    -- file: loudly, in the status line, when the user tries to play it.
    return state.pins.dir and reaper_api.join(state.pins.dir, s.filename) or ""
  end
  return reaper_api.join(state.library_dir, s.filename)
end

-- Start previewing a sound at its recorded level plus its remembered trim and the
-- master preview volume. `position` (seconds) lets click-to-seek start partway in.
-- `slot` names the view asking ("main" = working view / reference, "browse" = the
-- library browser) and decides whether the sound's own trim applies: the browser is
-- a neutral comparison surface, so only the preview level colours what you hear
-- there (decided 2026-07-30). `loop` overrides the loop toggle for this one
-- playback (reference mode always loops); leave it nil to follow the user's setting.
local function play_sound(s, position, slot, loop)
  if not state.deps.sws then return false end
  if loop == nil then loop = state.loop end
  local trim_db = (slot == "browse") and 0 or (s.trim_db or 0)
  local ok = preview.play(sound_path(s), {
    db       = trim_db + state.master_db,
    loop     = loop,
    position = position,
  })
  state.preview.playing  = ok
  state.preview.sound_id = ok and s.id or nil
  state.preview.slot     = ok and slot or nil
  state.preview.trim_db  = ok and trim_db or 0
  -- The REAL length of what is playing, not the record's stored duration — the two
  -- disagree when a file was replaced on disk, and the playhead must scale to the
  -- audio actually sounding.
  state.preview.length   = ok and preview.length() or 0
  state.preview.position = ok and (position or 0) or 0
  -- Say so. The usual cause is a file deleted or moved outside the tool, and the
  -- row gives nothing away — same name, and the loudness from when it last WAS
  -- readable. Without this, clicking it just silently does nothing.
  if not ok then
    state.status = string.format(
      "\"%s\" wouldn't play — its file is missing from the library folder, or can't be read.", s.name)
  end
  return ok -- callers must know: reference mode may not claim a playback that failed
end

-- Forget a remembered pause. Its own function because the memory outlives the
-- shared preview fields (see the state init comment), so the places that must
-- drop it aren't the same places that stop audio.
local function clear_pause()
  state.preview.paused_at, state.preview.paused_sound_id, state.preview.paused_length = nil, nil, nil
end

local function stop_playback()
  preview.stop()
  state.preview.playing  = false
  state.preview.sound_id = nil
  state.preview.slot     = nil
  state.preview.trim_db  = 0
  state.preview.position = 0
  clear_pause()
end

-- Pause: preview.lua has no pause primitive (an SWS preview is play-or-nothing),
-- so pausing is really "remember exactly where we were, then stop like normal" —
-- everything else (sound_id/length/position/playing) resets exactly like a
-- full stop; only paused_at/paused_sound_id/paused_length survive, tagged to
-- the sound that was actually playing (always the armed reference —
-- pause_playback is only ever called from the gated toggle_play handler
-- below). `paused_length` is its own snapshot, not a read of the shared
-- `length` later on, because an intervening browse audition would otherwise
-- leave this sound's paused playhead scaling by a DIFFERENT sound's length.
local function pause_playback()
  state.preview.paused_at = preview.position() or state.preview.position
  state.preview.paused_sound_id = state.selected_id
  state.preview.paused_length = state.preview.length
  preview.stop()
  state.preview.playing  = false
  state.preview.sound_id = nil
  state.preview.slot     = nil
  state.preview.trim_db  = 0
  state.preview.position = 0
end

-- Resume: play_sound already accepts a start position, so resuming is just a
-- fresh play from the remembered spot — trim/master volume/loop are re-applied
-- exactly like any other play, which is correct (they may have changed while
-- paused).
local function resume_playback()
  if not state.selected then return end
  if play_sound(state.selected, state.preview.paused_at or 0, "main") then clear_pause() end
end

-- The last sound id each waveform slot ASKED peaks for (not what it holds).
-- peaks owns exactly ONE build job, so the two slots have to queue: the defer
-- loop hands out requests one at a time and this remembers what's already been
-- asked, so a file that can't be opened is tried once rather than every frame.
-- Exactly two entries, ever.
local wave_asked = { main = nil, browse = nil }

-- Select a sound: remember it, kick off its waveform build in the background, and
-- — when auto-audition is on — start playing it from the top immediately. Playback
-- never waits on the waveform; the envelope fills in over the next frames.
--
-- While reference mode is latched the REAPER transport is the trigger, so auto-audition
-- stands down: sync_reference below picks up the new selection instead (switching the
-- reference live if the transport is already rolling). Without this, selecting a sound
-- mid-play would start it twice in one frame.
-- `quiet` selects without auto-auditioning — used when restoring a project's
-- remembered reference, because opening a project must never start sound on its own.
local function select_sound(id, quiet)
  -- A paused position belongs to whichever sound it was paused ON; picking a
  -- DIFFERENT one must drop that memory outright, or it could resurface later
  -- if the user comes back to a sound they never actually paused.
  if state.preview.paused_sound_id ~= id then clear_pause() end
  state.selected_id = id
  state.selected = find_sound(id)
  if not state.selected then return end
  -- The envelope itself is fetched by the defer loop (see wave_asked there):
  -- there is only ONE peaks job, so whichever slot asked last would otherwise
  -- starve the other. Clearing the "asked" mark makes a deliberate re-pick
  -- retry a sound whose file was missing when it was first tried.
  wave_asked.main = nil
  -- A deliberate re-pick clears the "this one wouldn't play" mark, so the user can
  -- retry a sound whose file was missing once they've put it back.
  state.reference.failed_id = nil
  -- Only a PIN selection is remembered with the project. A library id stored in a
  -- shared project would name a different sound on a teammate's machine — silently
  -- selecting the wrong audio there is worse than remembering nothing. Moving on
  -- to a library sound CLEARS the memory: restoring an older pin later would
  -- claim it was the last reference when it wasn't.
  pins_service.remember_selected(state, is_pin_id(id) and id or nil)
  if not quiet and state.auto_audition and not state.reference.latched then play_sound(state.selected, 0, "main") end
end

-- Reference mode re-asserts its own preview every frame (sync_reference below),
-- so a browse audition sounding at the same time would fight it — refused here
-- rather than silently losing the fight to sync_reference one frame later.
local REF_PLAYING_MSG = "Reference mode is playing \u{2014} stop the transport to audition here."

-- Browse a LIBRARY sound in the browser popup: entirely separate from
-- select_sound above (DESIGN "browsing can never surprise-mute anything, and
-- one readout — the working view's — tells what's armed"). Never touches
-- `selected`/`selected_id`, the armed reference, the latch, or pins_service's
-- remembered selection — only the browser's own slots.
-- `quiet` browses without auditioning — used by "Show in library" below, where
-- the user asked WHERE a sound is, not to hear it.
local function browse_sound(id, quiet)
  state.browse_id = id
  state.browse = find_sound(id)
  state.browse_info = nil
  if not state.browse then return end
  -- Picking a sound clears an old status message: the info row (the status
  -- line's new home, 2026-07-29) should now describe THIS sound, not carry
  -- yesterday's news. Anything below that sets a fresh status still wins.
  state.status = nil
  -- The info row's technical facts (sample rate / bit depth / format / channels),
  -- read once per pick — never per frame.
  state.browse_info = reaper_api.source_info(sound_path(state.browse))
  wave_asked.browse = nil -- same as select_sound: the loop fetches, a re-pick retries
  if quiet then return end
  if state.reference.active then
    state.status = REF_PLAYING_MSG
    return
  end
  if state.auto_audition then play_sound(state.browse, 0, "browse") end
end

-- "Show in library" (a pin's right-click menu, 2026-08-01): open the browser on
-- the sound this pin was made from, with the row selected and scrolled into
-- sight. Silent on purpose — this answers "where is this filed?", and the
-- working view may be mid-comparison.
--
-- There is nothing to disambiguate about WHERE a sound is: it has exactly one
-- category and at most one sub-category inside it. What varies is which VIEW
-- shows it — All sounds, its category and its sub-category all do — so the most
-- specific one wins, and the sidebar then reads as the true answer.
--
-- The pin is matched by VERIFIED origin only (pins_service.origin_of), the same
-- match that lights the library table's pin marker: a pin with no provable
-- library twin (a timeline capture, a teammate's pin, a deleted record) doesn't
-- offer the menu item at all, and this is the backstop if one slips through.
local function show_in_library(pin_id)
  local ps = state.pins
  local sound_id = ps and ps.origin_of and ps.origin_of[pin_id]
  local s = sound_id and find_sound(sound_id)
  if not s then
    state.status = "This pin isn't in your library \u{2014} right-click it and choose \"Save to my library\" to add it."
    return
  end

  if s.subcategory and categories.get(state.library, s.subcategory) then
    state.view = { scope = "subcategory", id = s.subcategory }
  elseif s.category and categories.get(state.library, s.category) then
    state.view = { scope = "category", id = s.category }
  else
    state.view = { scope = "uncategorised" }
  end
  -- A search still in the box would filter the very row we're revealing straight
  -- back out. Cleared ONLY when it actually would: a query the sound already
  -- matches is the user's, and wiping that would be the surprise.
  if state.query ~= "" and not search.matches(s, state.query) then
    state.query = ""
  end
  refresh_view()

  state.browser_open = true
  browse_sound(sound_id, true) -- quiet: reveal it, never play it
  -- The scroll itself belongs to the table (only it knows where the row landed).
  -- A counter rather than a flag, so revealing the SAME sound twice still
  -- scrolls — the browser acts on each new number exactly once.
  state.reveal_id = sound_id
  state.reveal_seq = (state.reveal_seq or 0) + 1
end

-- Click-to-seek, shared by the working view's waveform and the browser's
-- audition strip (each calls this on ITS OWN sound — see the `seek` action
-- handler below). Scaled by the REAL length of the audio, same reasoning as
-- play_sound's own comment: the record's stored duration goes stale once a
-- file is replaced on disk.
local function seek_sound(s, fraction, slot)
  if state.preview.playing and state.preview.sound_id == s.id then
    local pos = fraction * (state.preview.length or 0)
    preview.seek(pos)
    state.preview.position = pos
  elseif play_sound(s, 0, slot) then
    local pos = fraction * (state.preview.length or 0)
    if pos > 0 then preview.seek(pos) end
    state.preview.position = pos
  end
end

-- The project in front of the user changed (tab switch, open, Save As): `r` is
-- pins_service.refresh's report. Anything bound to a pin is dropped OUTRIGHT —
-- never carried by id, because pin ids restart at "p1" in every project, so the
-- "same" id here is a different record in a different References folder. The
-- remembered selection then rebinds against the freshly loaded data, quietly.
-- Returns the message to surface, if any (the right channel differs at startup
-- vs mid-session).
local function apply_pins_refresh(r)
  if not r then return nil end
  if is_pin_id(state.preview.sound_id) then stop_playback() end
  -- A PAUSED sound clears `sound_id`, so the stop above can't see it — and pin
  -- ids restart at "p1" in every project, so a pause remembered against the old
  -- project's p1 would offer to resume the NEW project's p1 at a position that
  -- means nothing there. Dropped outright, like every other pin binding here.
  if is_pin_id(state.preview.paused_sound_id) then clear_pause() end
  if is_pin_id(peaks.pending()) then peaks.cancel() end
  -- A cancelled build must not leave its id marked as already-asked, or the slot
  -- that still wants it would never get another try.
  wave_asked.main, wave_asked.browse = nil, nil
  local ref = state.reference
  if is_pin_id(ref.sound_id) or is_pin_id(ref.failed_id) then
    ref.active, ref.sound_id, ref.failed_id = false, nil, nil
  end
  if is_pin_id(state.selected_id) then
    state.selected_id, state.selected = nil, nil
    state.waveform = { sound_id = nil, channels = {} }
  end
  -- The remembered selection is NOT restored when a DIFFERENT project arrives
  -- while reference mode is latched: the latch belongs to the project it was
  -- switched on in, and quietly arming the incoming project's pin against that
  -- latch would hand its transport a reference nobody chose. Latched, such a
  -- switch lands at NO TARGET instead — an explicit click can still retarget,
  -- but silence never picks a sound. Save As (`same_project`) is exempt: the
  -- latch and the restored pin belong to the same project, so dropping the
  -- selection there would yank a rolling reference to NO TARGET mid-save.
  if r.selected and not state.selected_id and (r.same_project or not state.reference.latched)
    and find_sound(r.selected) then
    select_sound(r.selected, true)
  end
  return state.pins.load_error or r.warning
end

--------------------------------------------------------------- drag to timeline

-- The drag has been let go. Whatever is under the mouse at this instant decides
-- what happens: the arrange view gets the sound, anything else cancels quietly.
local function drop_sound()
  local drag = state.drag
  state.drag = nil
  if not drag then return end

  local s = find_sound(drag.sound_id)
  if not s then return end

  local target = dragout.target()
  if not target.over_arrange then
    -- Not a failure — letting go somewhere else is how you change your mind.
    state.status = string.format("\"%s\" wasn't added — you let go over %s, not the arrange view.",
      s.name, target.where)
    return
  end

  local ok, result = dragout.insert(sound_path(s), target.track, target.position, s.name)
  if ok then
    state.status = dragout.landed_at(target.track, result)
  else
    state.status = string.format("\"%s\" couldn't be added to the timeline — %s.", s.name, tostring(result))
  end
end

--------------------------------------------------------------- deleting

-- Delete a sound. Anything holding the file OPEN must let go before it moves — a
-- preview playing it, a waveform build or a loudness pass reading it — and if the
-- delete then can't be done, that background work is started again, so a refusal
-- really does leave everything as it was.
local function delete_sound(id)
  local s = find_sound(id)
  local name = s and s.name or "That sound"

  if state.preview.sound_id == id then stop_playback() end
  local ref = state.reference
  if ref.sound_id == id or ref.failed_id == id then
    ref.active, ref.sound_id, ref.failed_id = false, nil, nil
  end
  local was_measuring = loudness.current() == id
  if was_measuring then loudness.cancel() end
  local was_drawing = peaks.pending() == id
  if was_drawing then peaks.cancel() end

  -- `audio_gone` marks the one failure that isn't a clean refusal: the file reached
  -- the trash but the library wouldn't save. The sound is still listed, so its work
  -- must NOT be restarted — there's no file left to read, and a measurement failing
  -- on it would try to save the library all over again.
  local ok, why, audio_gone = service.delete_sound(state, id)
  if not ok then
    if not audio_gone then
      -- A clean refusal: hand the sound back its unfinished work.
      if was_measuring then table.insert(state.analysis_queue, 1, id) end
      if was_drawing and s then peaks.request(id, sound_path(s)) end
    end
    state.status = why
    reaper_api.message(why, "yb_Reference — delete")
    return
  end

  -- Gone for good: drop it from the measuring queue too (it holds nothing open, so
  -- it only needed clearing once the delete actually happened).
  for i = #state.analysis_queue, 1, -1 do
    if state.analysis_queue[i] == id then table.remove(state.analysis_queue, i) end
  end

  -- Nothing is selected afterwards: the row is gone, and silently jumping the
  -- selection somewhere else would start auditioning a sound nobody asked for.
  if state.selected_id == id then
    state.selected_id, state.selected = nil, nil
    state.waveform = { sound_id = nil, channels = {} }
  end
  -- Same for the browser's own selection (a library sound, so it's always this
  -- one that can be deleted here — never a pin).
  if state.browse_id == id then
    state.browse_id, state.browse, state.browse_info = nil, nil, nil
    state.browse_waveform = { sound_id = nil, channels = {} }
  end
  refresh_view()
  state.status = string.format("\"%s\" moved to the trash folder in your library.", name)
end

--------------------------------------------------------------- pins

-- Unpin: like delete, anything holding the pin's file open must let go first (a
-- preview playing it, a waveform build reading it) — its References copy is about
-- to be removed. Only the project's own copy is at stake; the library original,
-- if there is one, is never touched. Loudness never runs on pins, so unlike
-- delete there is no measurement to stop or hand back.
local function unpin_sound(id)
  local p = find_sound(id)
  if not p then return end

  if state.preview.sound_id == id then stop_playback() end
  local ref = state.reference
  if ref.sound_id == id or ref.failed_id == id then
    ref.active, ref.sound_id, ref.failed_id = false, nil, nil
  end
  local was_drawing = peaks.pending() == id
  if was_drawing then peaks.cancel() end

  local ok, msg = pins_service.unpin(state, id)
  state.status = msg
  if not ok then
    -- A clean refusal: the pin is still there, so hand back its unfinished waveform.
    if was_drawing then peaks.request(id, sound_path(p)) end
    return
  end
  if state.selected_id == id then
    state.selected_id, state.selected = nil, nil
    state.waveform = { sound_id = nil, channels = {} }
  end
end

-- Adopt a pin into the library. The service answers "already there" without
-- copying anything; a genuinely new sound joins the list, the view, and the
-- loudness queue exactly like an import does.
local function save_pin_to_library(id)
  local ok, msg, _, added = pins_service.save_pin_to_library(state, id)
  -- Multi-line messages are real problems (a copy or save failure) — those get a
  -- dialog, like import failures do. One-liners stay on the status line.
  state.status = msg:match("^[^\n]*")
  if msg:find("\n", 1, true) then
    reaper_api.message(msg, "yb_Reference — save to library")
  end
  if ok and added then
    refresh_view()
    if loudness.available() then
      state.analysis_queue = analysis.queue(state.library, loudness.current())
    end
  end
end

--------------------------------------------------------------- loudness analysis

-- Work through the queue of unmeasured sounds in the background: one measurement
-- pass per frame, three passes per sound. Importing never waits on this — a sound is
-- playable the moment it lands, and its loudness fills in over the next few frames.
--
-- Paused while anything is playing. A pass on a long file blocks the frame for up to
-- a second, and a stalled playhead in the middle of an A/B is far more annoying than
-- a number arriving a few seconds later.
local function step_analysis()
  if state.preview.playing then return end

  local id, results = loudness.advance()
  if id then
    local s = find_sound(id)
    if s then
      if results then analysis.apply(s, results) else analysis.mark_failed(s) end
      commit() -- library data is saved the moment it changes, never at exit
      -- A number arriving changes where its row belongs, but only when the list is
      -- ordered by loudness — under any other sort the order is unaffected, so we
      -- don't rebuild the view for nothing (measurements land in a steady stream
      -- right after an import).
      if state.sort.col == "loud" then refresh_view() end
    end
  end

  -- Nothing in flight: line up the next sound. Records that vanished (deleted while
  -- queued) are skipped; a file REAPER can't open is marked failed straight away so
  -- it can't sit in the queue forever. One failure per frame keeps a folder full of
  -- broken files from being chewed through in a single frame.
  if not loudness.current() then
    while #state.analysis_queue > 0 do
      local next_id = table.remove(state.analysis_queue, 1)
      local s = find_sound(next_id)
      if s and analysis.needs(s) then
        if not loudness.request(next_id, sound_path(s)) then
          analysis.mark_failed(s)
          commit()
        end
        break
      end
    end
  end
end

-- Reference mode, once per frame. The project is muted while latched, so the REAPER
-- transport drives the reference instead: rolling the transport plays the selected
-- sound, stopping it goes silent again. The reference always loops (independent of the
-- loop toggle) so a short reference keeps going for as long as you play — that is the
-- A/B this whole feature exists for.
--
-- Stopping is guarded on `active`: only a preview THIS started may be stopped here, so
-- an audition the user kicked off by hand isn't cut off the moment the transport idles.
-- `active` is only claimed when playback actually STARTED — a failed one must never be
-- recorded as playing, or every later frame would think the reference is running and
-- leave a muted project sitting in silence.
local function sync_reference()
  local ref = state.reference
  if not ref.latched then return end

  if reference.transport_playing() and state.selected then
    local id = state.selected.id
    -- failed_id stops a broken file being re-opened on every single frame (that would
    -- hammer the disk inside the frame loop); the user picking a sound clears it.
    if ref.failed_id ~= id and (not ref.active or ref.sound_id ~= id) then
      if play_sound(state.selected, 0, "main", true) then
        ref.active, ref.sound_id, ref.failed_id = true, id, nil
      else
        ref.active, ref.sound_id, ref.failed_id = false, nil, id
        state.status = "That sound couldn't be played as your reference — its file may be missing or unreadable."
      end
    end
  elseif ref.active or ref.failed_id then
    -- Transport stopped: drop the reference AND the "wouldn't play" mark, so pressing
    -- play again is a fresh attempt. Without clearing it, one transient failure would
    -- suppress every later play until the user re-picked the sound.
    if ref.active then stop_playback() end
    ref.active, ref.sound_id, ref.failed_id = false, nil, nil
  end
end

-- Turn reference mode on/off. Playback is stopped on BOTH edges: latching should begin
-- from real silence, and un-latching must not leave a preview playing over a project
-- that is audible again.
local function toggle_reference()
  local ref = state.reference
  stop_playback()
  ref.active, ref.sound_id, ref.failed_id = false, nil, nil

  if ref.latched then
    ref.latched = false
    -- An un-latch that couldn't finish (project closed, write refused) leaves an
    -- outstanding obligation; say so plainly rather than reporting a clean stop.
    if reference.latch_off() then
      state.status = "Reference mode off — your project plays normally again."
    else
      state.status = reference.pending()
      reaper_api.message(reference.pending(), "yb_Reference — reference mode needs attention")
    end
  else
    -- Refuse an empty latch: muting the project with nothing armed buys silence
    -- for nothing, and "press play, hear nothing" reads as broken. (Losing the
    -- armed reference LATER, while latched, is different — then we stay latched
    -- at NO TARGET, because auto-unlatching would surprise-blast project audio.)
    if not state.selected then
      state.status = "Select a reference first — pick a sound or a pin, then press LATCH."
      return
    end
    -- Refusing to latch is the only safe answer when the records can't be laid down
    -- first, or when an earlier obligation is still outstanding: a muted project with
    -- nothing on disk describing it is the one state we could never recover from.
    local ok, reason = reference.latch_on()
    if ok then
      ref.latched = true
      state.status = "Reference mode on — your project is muted. Press play in REAPER to hear the selected sound."
    else
      state.status = reason
      reaper_api.message(reason, "yb_Reference — reference mode")
    end
  end
end

-- Queue everything unmeasured: freshly imported sounds, and anything a previous run
-- was interrupted part-way through. Sounds marked "failed" are included deliberately
-- — the usual cause is a file that was missing at the time, so putting it back and
-- reopening the tool simply measures it.
if loudness.available() then
  state.analysis_queue = analysis.queue(state.library)
else
  state.status = "This REAPER version can't measure loudness, so the Loudness column stays empty. Everything else works normally."
end

-- Check the folder against the records both ways round, and say what's wrong rather
-- than letting the user find out by clicking a sound that does nothing.
local orphans, missing = service.check_files(state)

local function add_status(msg)
  state.status = state.status and (state.status .. "  \u{00B7}  " .. msg) or msg
end

-- This project's pins, loaded before the first frame (the sidebar reads them),
-- and its remembered reference restored — without auto-playing anything.
local pins_warning = apply_pins_refresh(pins_service.refresh(state))
if pins_warning then add_status(pins_warning) end

if #orphans > 0 then
  add_status(string.format(
    "%d audio file(s) in the library folder aren't in your library yet (left by an interrupted add).",
    #orphans))
end

-- A record whose file is gone still looks perfectly normal in the list — same name,
-- same loudness from when it was last measured — so name the offenders. A handful
-- get named outright; beyond that the list would swamp the status line.
if #missing > 0 then
  local names = {}
  for i = 1, math.min(#missing, 3) do names[i] = missing[i].name end
  local list = table.concat(names, ", ")
  if #missing > #names then list = list .. string.format(" and %d more", #missing - #names) end
  add_status(string.format("%d sound%s missing %s file from the library folder: %s.",
    #missing, #missing == 1 and "" or "s", #missing == 1 and "its" or "their", list))
end

-- A restored master mute matters more than an orphan count, so it leads the line.
if recovery_msg then
  state.status = state.status and (recovery_msg .. "  \u{00B7}  " .. state.status) or recovery_msg
end

-- Turn an import summary into one plain-language status line.
local function summarize(sum)
  local parts = {}
  if sum.added > 0 then
    parts[#parts + 1] = string.format("%d %s added", sum.added, sum.added == 1 and "sound" or "sounds")
  end
  if #sum.duplicates > 0 then parts[#parts + 1] = #sum.duplicates .. " already in library" end
  if #sum.skipped > 0 then parts[#parts + 1] = #sum.skipped .. " skipped" end
  if #sum.errors > 0 then parts[#parts + 1] = #sum.errors .. " failed" end
  if #parts == 0 then return "Nothing to add." end
  return table.concat(parts, "  \u{00B7}  ")
end

local function do_import(paths, category, subcategory)
  if not paths or #paths == 0 then return end
  -- pcall: the one raise left in here is the library save at the very end. By then
  -- every copied sound is already in the in-memory list, so the tool must keep
  -- running — the next successful save writes the complete library anyway.
  local ok, sum = pcall(service.import_files, state, paths, category, subcategory)
  refresh_view()
  -- Rebuild rather than append: this picks up the new sounds AND anything still
  -- unmeasured from before, and skips the one being measured right now so it can't
  -- be queued twice.
  if loudness.available() then
    state.analysis_queue = analysis.queue(state.library, loudness.current())
  end
  if not ok then
    state.status = "The added sounds are in the list, but the library file couldn't be updated — saving will be retried on the next change."
    reaper_api.message(
      "The sounds were added, but the library file couldn't be updated:\n\n" .. tostring(sum) ..
      "\n\nThey stay in the list, and the next change will try to save everything again.",
      "yb_Reference — add sounds")
    return
  end
  state.status = summarize(sum)
  -- Skips/errors are real problems the user should see spelled out — surface them
  -- in a dialog (duplicates are benign and stay in the status line only).
  local detail = {}
  for _, d in ipairs(sum.skipped) do detail[#detail + 1] = d end
  for _, e in ipairs(sum.errors) do detail[#detail + 1] = e end
  if #detail > 0 then
    reaper_api.message(state.status .. "\n\n" .. table.concat(detail, "\n"), "yb_Reference — add sounds")
  end
end

-- Run a library-changing category op; on success save + refresh, on failure show
-- the plain-language reason. pcall so a fail-loud core error becomes a message,
-- not a script crash.
local function try(fn, on_ok, fail_title, fail_hint)
  local ok, err = pcall(fn)
  if ok then
    commit()
    if on_ok then on_ok() end
  else
    reaper_api.message((fail_hint and (fail_hint .. "\n\n") or "") .. tostring(err), fail_title)
  end
end

-- True if the current view is showing the category being removed (so we can fall
-- back to "All" instead of pointing at something that no longer exists).
local function viewing_category(id)
  return (state.view.scope == "category" or state.view.scope == "subcategory") and state.view.id == id
end

--------------------------------------------------------------- library location

-- Switch to a different library folder (from Settings). This OPENS whatever
-- library lives there — an existing library.json is loaded, an empty folder
-- starts a fresh one — it never moves or copies sounds. The current library
-- stays where it is on disk, so switching back is just picking it again.
local function switch_library(new_dir)
  -- Trailing separators would make the same folder look like a different one
  -- (and double up inside joined paths). A bare drive keeps its slash.
  new_dir = new_dir:gsub("[\\/]+$", "")
  if new_dir:match("^%a:$") then new_dir = new_dir .. SEP end
  if new_dir == "" then return end
  if new_dir == state.library_dir then
    state.status = "That's already your library folder."
    return
  end

  -- The copy in memory is the ONLY complete record of the current library — a
  -- failed save anywhere (a keystroke's commit, an import, a pin adoption) can
  -- leave disk behind it. So a switch always writes the whole current library
  -- first, and a save that won't land blocks the switch: walking away would lose
  -- whatever disk is missing. (Every save writes the full library, so this can
  -- never make things worse.)
  if not commit() then
    reaper_api.message(
      "Your current library couldn't be saved, so the tool won't switch away from it — switching now would " ..
      "lose unsaved changes. Fix what's blocking the save (disk space, or backup/sync software holding the " ..
      "file), then try again.",
      "yb_Reference — library folder not changed")
    return
  end

  -- The same guarded sequence startup runs, but non-fatal: any failure keeps the
  -- current library open and untouched.
  local new_path = reaper_api.join(new_dir, "library.json")
  reaper_api.ensure_dir(new_dir)
  if not reaper_api.path_exists(new_dir) then
    reaper_api.message(
      "That folder couldn't be found or created:\n\n" .. new_dir .. "\n\nNothing has been changed — " ..
      "you're still on your current library. If it's on a drive or network location, check it's connected.",
      "yb_Reference — library folder not changed")
    return
  end

  local rec_ok, rec_err = pcall(store.recover, new_path)
  if not rec_ok then
    reaper_api.message(
      "The library in that folder couldn't be repaired after an interrupted save:\n\n" .. tostring(rec_err) ..
      "\n\nNothing has been changed — you're still on your current library. Rename the \".bak\" file in that " ..
      "folder back to \"library.json\" by hand, then try again.",
      "yb_Reference — library folder not changed")
    return
  end

  local lib
  if store.exists(new_path) then
    local ok, result = pcall(store.load, new_path)
    if not ok then
      reaper_api.message(
        "The library file in that folder couldn't be read:\n\n" .. tostring(result) ..
        "\n\nNothing has been changed — you're still on your current library.\n\nFile:\n" .. new_path,
        "yb_Reference — library folder not changed")
      return
    end
    lib = result
  elseif store.present(new_path) then
    reaper_api.message(
      "The library file in that folder exists but couldn't be opened — something else (backup or sync " ..
      "software, most likely) is probably holding on to it.\n\nNothing has been changed — you're still on " ..
      "your current library.\n\nFile:\n" .. new_path,
      "yb_Reference — library folder not changed")
    return
  else
    lib = schema.new_library()
    local ok, err = pcall(store.save, new_path, lib)
    if not ok then
      reaper_api.message(
        "A new library couldn't be created in that folder:\n\n" .. tostring(err) ..
        "\n\nNothing has been changed — you're still on your current library. Check that the folder can be " ..
        "written to.",
        "yb_Reference — library folder not changed")
      return
    end
  end

  -- Let go of everything reading the old library's files. Pins are untouched —
  -- their audio lives beside the project, not in the library.
  if state.preview.sound_id and not is_pin_id(state.preview.sound_id) then stop_playback() end
  -- Same blind spot as the project switch: a paused LIBRARY sound is invisible to
  -- the stop above, and its id names a different sound in the new library.
  local paused_id = state.preview.paused_sound_id
  if paused_id and not is_pin_id(paused_id) then clear_pause() end
  if peaks.pending() and not is_pin_id(peaks.pending()) then peaks.cancel() end
  wave_asked.main, wave_asked.browse = nil, nil -- see apply_pins_refresh
  loudness.cancel() -- measurements only ever run on library sounds
  local ref = state.reference
  if (ref.sound_id and not is_pin_id(ref.sound_id)) or (ref.failed_id and not is_pin_id(ref.failed_id)) then
    ref.active, ref.sound_id, ref.failed_id = false, nil, nil
  end
  if state.selected_id and not is_pin_id(state.selected_id) then
    state.selected_id, state.selected = nil, nil
    state.waveform = { sound_id = nil, channels = {} }
  end
  -- The browser's selection is ALWAYS a library id (never a pin), so it's
  -- unconditionally stale here: "s1" in the new library names a different
  -- sound than "s1" in the old one.
  if state.browse_id then
    state.browse_id, state.browse, state.browse_info = nil, nil, nil
    state.browse_waveform = { sound_id = nil, channels = {} }
  end

  state.library, state.library_dir, state.library_path = lib, new_dir, new_path
  reaper_api.set_library_dir(new_dir)
  -- The view could be filtering by a category id from the OLD library — in the
  -- new one that id is a different category or nothing at all. Back to All.
  state.view = { scope = "all" }
  refresh_view()
  state.analysis_queue = loudness.available() and analysis.queue(state.library) or {}
  -- The pin markers point into the library, so they're re-derived against the new one.
  if state.pins then pins_service.rebuild_markers(state) end

  local n = #state.library.sounds
  state.status = string.format("Library folder changed — %d sound%s loaded from  %s",
    n, n == 1 and "" or "s", new_dir)
  local _, now_missing = service.check_files(state)
  if #now_missing > 0 then
    state.status = state.status .. string.format("  \u{00B7}  %d sound%s missing %s audio file",
      #now_missing, #now_missing == 1 and "" or "s", #now_missing == 1 and "its" or "their")
  end
end

local function handle_action(a)
  if a.type == "pick" then
    do_import(reaper_api.pick_files(), a.category, a.subcategory)
  elseif a.type == "import" then
    do_import(a.paths, a.category, a.subcategory)
  elseif a.type == "select_view" then
    state.view = a.view
    refresh_view()
  elseif a.type == "set_query" then
    state.query = a.query
    refresh_view()
  elseif a.type == "set_sort" then
    -- Idempotent: only rebuild the view when the sort truly changes, so a per-frame
    -- "need sort" flag can't keep re-sorting (and re-shuffling) the list.
    if a.col and (state.sort.col ~= a.col or state.sort.asc ~= a.asc) then
      state.sort = { col = a.col, asc = a.asc }
      refresh_view()
    end
  elseif a.type == "drag_sound" then
    -- The name is captured HERE, at the start of the drag, not looked up each
    -- frame: it feeds the tag that follows the mouse, and a record that goes
    -- away mid-drag should not make the tag flicker between a name and none.
    if state.deps.drag_out then
      local s = find_sound(a.id)
      state.drag = { sound_id = a.id, name = s and s.name or nil }
    end
  elseif a.type == "drop_sound" then
    drop_sound()
  elseif a.type == "toggle_browser" then
    state.browser_open = not state.browser_open
  elseif a.type == "open_browser" then
    state.browser_open = true
  elseif a.type == "close_browser" then
    state.browser_open = false
  elseif a.type == "dock_changed" then
    -- The window landed somewhere new. Two destinations are refused outright,
    -- both of which look the same to the user — the tool as a tab inside some
    -- extra window (decided 2026-07-30, from the user's screenshots):
    --
    --   * a POSITIVE dock id = an ImGui-made panel node. Only one window here is
    --     dockable, so there is no legitimate way to be inside one; any that
    --     turns up is left over from before panel-splitting was switched off.
    --   * one of REAPER's FLOATING dockers, which is what REAPER puts a window
    --     in when its tab is dragged out of a docker.
    --
    -- Real dockers — bottom, left, top, right — are kept, which is the whole
    -- point of docking. Bouncing means the extra window may flash up for a frame
    -- before it goes; that beats being stuck in it.
    if a.dock_id > 0 or reaper_api.is_floating_docker(a.dock_id) then
      app.request_undock()
    end
  elseif a.type == "browser_geom" then
    -- Only ever sent when it actually changed (see app.lua) — write straight
    -- through, no coalescing needed here.
    state.browser_geom = { x = a.x, y = a.y, w = a.w, h = a.h }
    reaper_api.set_browser_geom(a.x, a.y, a.w, a.h)
  elseif a.type == "reveal_library" then
    -- Point at the library file so the folder opens with something highlighted; if
    -- the tool can't open a file browser here, say so instead of doing nothing.
    if not reaper_api.reveal_file(state.library_path) then
      state.status = "Couldn't open the library folder automatically. It's here:  " .. state.library_dir
    end
  elseif a.type == "delete_sound" then
    delete_sound(a.id)
  elseif a.type == "set_loud_unit" then
    -- Switching the displayed measurement re-sorts too, so the order on screen
    -- always matches the numbers on screen when the list is sorted by loudness.
    if analysis.is_field(a.field) and a.field ~= state.loud_unit then
      state.loud_unit = a.field
      reaper_api.set_loud_unit(a.field)
      refresh_view()
    end
  elseif a.type == "set_layout_mode" then
    -- Purely how the working view arranges itself; nothing to refresh, and it
    -- takes effect on the very next frame.
    if a.mode ~= state.layout then
      state.layout = a.mode
      reaper_api.set_layout_mode(a.mode)
    end
  elseif a.type == "select_sound" then
    select_sound(a.id)
  elseif a.type == "browse_sound" then
    browse_sound(a.id)
  elseif a.type == "show_in_library" then
    show_in_library(a.id)
  elseif a.type == "toggle_play" then
    -- Play <-> pause. Gated on the ARMED reference actually being what's
    -- sounding/paused — the one live preview may currently be a browse
    -- audition instead, and this button (like its own "playing" readout)
    -- speaks only for the working view.
    if state.preview.playing and state.preview.sound_id == state.selected_id then
      pause_playback()
    elseif state.preview.paused_at and state.preview.paused_sound_id == state.selected_id then
      resume_playback()
    elseif state.selected then
      play_sound(state.selected, 0, "main")
    end
  elseif a.type == "stop_play" then
    -- The separate Stop button: back to the start, no remembered position.
    -- Same gating as toggle_play; simply does nothing when there's nothing of
    -- the working view's own to stop (already stopped, or the live preview is
    -- a browse audition).
    if (state.preview.playing and state.preview.sound_id == state.selected_id)
        or (state.preview.paused_at and state.preview.paused_sound_id == state.selected_id) then
      stop_playback()
    end
  elseif a.type == "toggle_loop" then
    state.loop = not state.loop
    -- Affect the current preview live — but never a transport-driven reference. That
    -- one is forced to loop for as long as the transport rolls; switching looping off
    -- underneath it would end the reference and leave a muted project in silence.
    if not state.reference.active then preview.set_loop(state.loop) end
  elseif a.type == "toggle_auto" then
    state.auto_audition = not state.auto_audition
  elseif a.type == "toggle_reference" then
    -- Gated on SWS: without preview playback, latching would only mute the project
    -- with no way to hear a reference — silence for nothing.
    if state.deps.sws then toggle_reference() end
  elseif a.type == "seek" then
    -- Click-to-seek. The browser's audition strip tags its own seek with
    -- target="browse" (ui/browser.lua) so it lands on the BROWSED sound, never
    -- the armed reference; the working view's waveform is untagged and acts on
    -- `selected` as before. Same reference-mode refusal as browse_sound: a
    -- click meant to audition must not fight sync_reference's own preview.
    if a.target == "browse" then
      if state.reference.active then
        state.status = REF_PLAYING_MSG
      elseif state.browse then
        seek_sound(state.browse, a.fraction, "browse")
      end
    elseif state.selected then
      seek_sound(state.selected, a.fraction, "main")
    end
  elseif a.type == "set_trim" then
    -- Per-sound trim. A library sound's trim is library data; a pin's trim is its
    -- project-specific snapshot, stored with the project — deliberately separate
    -- lives (see DESIGN). Audio updates live either way; persist only on release
    -- (a.commit) so dragging the slider doesn't hammer the disk every frame.
    if state.selected then
      state.selected.trim_db = a.db
      -- Only a "main" playback wears a trim. Matching the id alone isn't enough: the
      -- one live preview may be a BROWSE audition of this very sound, which is
      -- deliberately untrimmed, and riding this fader must not colour it.
      if state.preview.playing and state.preview.slot == "main"
        and state.preview.sound_id == state.selected.id then
        state.preview.trim_db = a.db
        preview.set_volume_db(a.db + state.master_db)
      end
      if a.commit then
        if is_pin_id(state.selected.id) then
          -- A pin trim that couldn't be stored would silently snap back on the
          -- next project switch — say so instead.
          if not pins_service.persist(state) then
            state.status = "The trim couldn't be stored in your project — it will reset when the project changes or reopens."
          end
        else
          commit()
        end
      end
    end
  elseif a.type == "pin_sound" then
    -- Pin failures are all non-destructive (already pinned, project not saved yet,
    -- a copy that didn't take) — the status line is the honest place for them.
    -- Arrives from the right-click menu or as a drop on THIS PROJECT; the drop
    -- consumed the drag (clearing a drag that isn't there is a no-op).
    state.drag = nil
    local s = find_sound(a.id)
    if s then
      local _, msg = pins_service.pin_sound(state, s)
      state.status = msg
    end
  elseif a.type == "unpin" then
    unpin_sound(a.id)
  elseif a.type == "save_pin_to_library" then
    save_pin_to_library(a.id)
  elseif a.type == "reset_pins" then
    -- The explicit escape from damaged pin data — only ever offered by the UI
    -- when a load error is standing.
    local _, msg = pins_service.reset_pins(state)
    state.status = msg
  elseif a.type == "set_pin_label" then
    local _, msg = pins_service.set_pin_label(state, a.id, a.label)
    state.status = msg
  elseif a.type == "refile_sound" then
    -- A sound dragged from the table dropped on a category (or Uncategorised):
    -- re-file it there. Pins aren't library records, so they have no category
    -- to change — refused with the way forward instead of silently ignored.
    state.drag = nil -- this drop consumed the drag
    local s = find_sound(a.id)
    if s and is_pin_id(a.id) then
      state.status = "Pins aren't in your library, so they can't be filed into a category — right-click the pin and \"Save to my library\" first."
    elseif s then
      if s.category ~= a.category or s.subcategory ~= a.subcategory then
        s.category, s.subcategory = a.category, a.subcategory
        commit()
        refresh_view()
        local dest = a.subcategory or a.category
        local c = dest and categories.get(state.library, dest)
        state.status = string.format("\"%s\" filed under %s.", s.name, c and c.name or "Uncategorised")
      end
    end
  elseif a.type == "import_and_pin" then
    -- Audio files from Explorer dropped straight onto a reference target:
    -- imported into the library (Uncategorised) and pinned to this project in
    -- one motion instead of two.
    --
    -- Refused OUTRIGHT when pinning can't happen (unsaved project, damaged pin
    -- data) — checked BEFORE anything is imported. Importing first would
    -- strand a half-done drop: the sounds land in the library but stay
    -- unpinned, and retrying the same drop after fixing things would dedup to
    -- "already in library" and never pin them. All-or-nothing keeps the retry
    -- honest: fix the cause, drop again, everything happens.
    local refusal = pins_service.can_pin(state)
    if refusal then
      state.status = refusal .. " Nothing was imported."
    else
      -- Dropped files the library ALREADY holds never come back from the import
      -- (dedup skips them), so resolve them up front and pin the existing
      -- records too: dropping on the reference row means "I want this pinned",
      -- whether or not the library knows the file. This is also what keeps a
      -- RETRY honest — if a pin failed last time, the same drop now dedups to
      -- "already in library" and still pins it (Codex, 2026-07-28 review).
      local existing = {}
      for _, src in ipairs(a.paths) do
        local dup = importer.find_duplicate(state.library,
          importer.basename(src), reaper_api.file_size(src))
        if dup then existing[#existing + 1] = dup end
      end
      local before = #state.library.sounds
      do_import(a.paths, nil, nil)
      for _, s in ipairs(existing) do
        -- Third return = the pin it already has; only a REAL refusal is news.
        local ok, msg, pid = pins_service.pin_sound(state, s)
        if not ok and not pid then state.status = msg end
      end
      for i = before + 1, #state.library.sounds do
        local ok, msg = pins_service.pin_sound(state, state.library.sounds[i])
        if not ok then state.status = msg end
      end
    end
  elseif a.type == "restart_tool" then
    -- The post-update popup's Restart now (probe-proven mechanism — harness
    -- script 10): REAPER terminates this instance (atexit cleanup runs) and
    -- starts a fresh one from the updated files on disk; its startup replay
    -- then finishes the update's remaining bookkeeping (the journal). Code
    -- after this call may simply never run — nothing below depends on it.
    reaper_api.restart_self(CMD_ID)
  elseif a.type == "settings_opened" then
    -- The gear was clicked: freshen the UPDATES section's registry facts
    -- (installed version, pin state) so the modal describes now, not the
    -- last daily check.
    updater.refresh_registry()
  elseif a.type == "start_update" then
    -- Settings' Update-now button. The updater owns everything from here:
    -- the single-repo sync (ReaPack's Progress window appears), the verify,
    -- the fallback — Settings' UPDATES section reads the outcome from
    -- state.update. Refusals (pinned, not ReaPack-owned) surface there too.
    updater.start_update()
  elseif a.type == "change_library_dir" then
    -- From Settings. `a.dir` is the typed-path fallback (no js_ReaScriptAPI);
    -- with the extension present the OS folder picker asks instead.
    local dir = a.dir or reaper_api.browse_for_folder("Choose a library folder", state.library_dir)
    if dir and dir ~= "" then switch_library(dir) end
  elseif a.type == "set_master" then
    -- Master preview volume is an app pref. Live audio now; save to ExtState only
    -- on release (a.commit) — never write ExtState every drag frame.
    state.master_db = a.db
    -- The trim on top is the one recorded when this playback STARTED, not whatever
    -- the sound record says now: a browse audition of a trimmed sound is running at
    -- no trim, so looking the record up again (as this did before 2026-07-30) would
    -- re-apply a trim that isn't in force.
    if state.preview.playing then
      preview.set_volume_db(state.preview.trim_db + state.master_db)
    end
    if a.commit then reaper_api.set_master_db(a.db) end
  elseif a.type == "add_category" then
    try(function() categories.add(state.library, a.name) end, refresh_view, "yb_Reference — add category")
  elseif a.type == "add_subcategory" then
    try(function() categories.add(state.library, a.name, a.parent) end, refresh_view, "yb_Reference — add sub-category")
  elseif a.type == "import_new_category" then
    -- Files dropped on "+ New category" (2026-08-01): create the category,
    -- then run the normal import into it. Named after the folder the files
    -- came from — the closest thing a drop carries to an intended name; a
    -- rename is one right-click away. `try` saves the new category even if
    -- the import then fails; do_import saves and refreshes on its own.
    local name = (a.paths[1] or ""):match("([^/\\]+)[/\\][^/\\]*$") or "New category"
    local cat
    try(function() cat = categories.add(state.library, name) end, refresh_view,
      "yb_Reference — add category")
    if cat then do_import(a.paths, cat.id) end
  elseif a.type == "rename_category" then
    try(function() categories.rename(state.library, a.id, a.name) end, nil, "yb_Reference — rename")
  elseif a.type == "remove_category" then
    try(function() categories.remove(state.library, a.id) end, function()
      if viewing_category(a.id) then state.view = { scope = "all" } end
      refresh_view()
    end, "yb_Reference — delete category",
      "This category can't be deleted while it still has sub-categories or sounds in it. Move or remove those first.")
  end
end

-- Best-effort cleanup when REAPER unloads the script: stop playback and un-latch
-- reference mode so the master isn't left muted. Best-effort is the operative word —
-- this never runs on a crash, which is why reference mode also keeps a recovery note
-- on disk (lib/reference.lua). That note, not this, is the real safety net.
-- reference.cleanup() goes FIRST: it is the only one whose failure to run harms the
-- user (a master left muted). If a later destructor throws, the mute is already back.
reaper.atexit(function()
  reference.cleanup(); preview.stop(); peaks.cancel(); loudness.cancel()
  dragout.hide_tag() -- a drag in flight when the script is closed leaves no label behind
end)

local function loop()
  -- "This Project" follows the project in front of the user: switching tabs,
  -- opening a project, or Save As re-reads that project's pins (two cheap REAPER
  -- calls and a compare on the frames where nothing changed).
  local pin_refresh = pins_service.refresh(state)
  if pin_refresh then
    local warning = apply_pins_refresh(pin_refresh)
    if warning then state.status = warning end
  end

  -- The hotkey companion action leaves a note rather than acting itself, so exactly
  -- one script owns the latch. Pick it up here and treat it as the same intent the
  -- REF button reports.
  if reference.take_toggle_request() then handle_action({ type = "toggle_reference" }) end
  sync_reference()

  -- A list ordered BY the pin column has to follow the pins, which live outside
  -- the library — pinning, unpinning and switching project all change the order
  -- without touching a single sound record. Same shape as the loudness case
  -- above: only when that column is the one sorting the list.
  if state.sort.col == "pin" and state.pins
    and state.pins.markers_version ~= sorted_pins_version then
    refresh_view()
  end

  -- Advance playback bookkeeping before drawing so the waveform shows this frame's
  -- position. poll() reports a non-looping preview that just ended on its own.
  if state.deps.sws and state.preview.playing then
    if preview.poll() then
      state.preview.playing = false
      state.preview.sound_id = nil
      state.preview.slot = nil
      state.preview.trim_db = 0
      state.preview.position = 0
      -- NOT paused_at/paused_sound_id: this is whatever the ONE shared preview
      -- was just sounding (could be a browse audition), which is independent of
      -- any separately-remembered working-view pause (see the preview state
      -- init comment) — that memory must survive an unrelated preview ending.
      -- If that was the transport-driven reference dying on us, forget it — and mark
      -- the sound failed. A reference always loops, so a healthy one never ends on
      -- its own: this death is abnormal (decoder or device trouble), and without the
      -- mark sync_reference would reopen the file every frame for as long as the
      -- transport rolls. Marked, it is retried on the next transport stop/start or
      -- re-selection instead of sixty times a second.
      if state.reference.active then
        state.reference.failed_id = state.reference.sound_id
      end
      state.reference.active = false
      state.reference.sound_id = nil
    else
      local pos = preview.position()
      if pos then state.preview.position = pos end
    end
  end

  -- Build a waveform a slice per frame (never blocks). A finished envelope goes
  -- to EVERY slot that wants that sound, so the working view and the browser
  -- looking at the same sound cost one build, not two.
  state.wave_loading = peaks.pending()
  local wid, chans = peaks.advance()
  if wid then
    if wid == state.selected_id then state.waveform = { sound_id = wid, channels = chans } end
    if wid == state.browse_id then state.browse_waveform = { sound_id = wid, channels = chans } end
  end

  -- Hand out the next build. peaks owns exactly ONE job (it holds a live PCM
  -- source across frames), so requesting is done HERE rather than at the moment
  -- a selection changes: with two independent selections, whichever asked last
  -- would cancel the other's job and that slot would then wait forever for an
  -- envelope nobody was building. Queuing here, one at a time, means both slots
  -- always converge. `wave_asked` stops a file that won't open from being
  -- retried every frame (a deliberate re-pick clears it).
  if not peaks.pending() then
    local want, path, slot
    if state.selected and state.waveform.sound_id ~= state.selected_id then
      want, path, slot = state.selected_id, sound_path(state.selected), "main"
    elseif state.browse and state.browse_waveform.sound_id ~= state.browse_id then
      want, path, slot = state.browse_id, sound_path(state.browse), "browse"
    end
    if want and wave_asked[slot] ~= want then
      wave_asked[slot] = want
      peaks.request(want, path)
    end
  end

  -- Measure loudness in the background, one pass per frame.
  step_analysis()

  -- The update feature's heartbeat: three compares on an idle frame; a file
  -- poll only while its daily catalog fetch is in flight, a registry poll only
  -- while an update is being verified. Never blocks (the download runs in a
  -- separate process; ReaPack's own sync shows its own Progress window).
  updater.tick()

  -- A drag in flight: read where the mouse is so the status line can say where
  -- the sound would land. Only while dragging — asking REAPER every frame
  -- otherwise would be work for nothing. (The drag CURSOR is asserted after the
  -- frame below, once the release has had its chance to end the drag — asserting
  -- it here would show a drag cursor one frame past the drop.)
  if state.drag then
    local target = dragout.target()
    state.drag.hint = dragout.hint(target)
    -- Remembered for the cursor below: the hand where a release lands the
    -- sound, the no-entry circle where it would cancel.
    state.drag.over_arrange = target.over_arrange
  end

  -- An un-latch that couldn't finish keeps the red border up (see app.frame) —
  -- read fresh each frame so recovery clearing the obligation clears the border.
  state.reference.pending = reference.pending() ~= nil

  local open, action = app.frame(ctx, state)
  if action then handle_action(action) end
  -- Keep the drag cursor and the name tag asserted while a drag is live (REAPER
  -- re-asserts its own cursor constantly, so this must repeat per frame). After
  -- the action handling above, so a drop has already cleared the drag — no
  -- trailing cursor and no tag left hanging over the timeline. hide_tag is a
  -- no-op when nothing is up, so it is safe to call on every idle frame.
  if state.drag then
    reaper_api.show_drag_cursor(state.drag.over_arrange)
    dragout.show_tag(state.drag.name, state.drag.hint)
  else
    dragout.hide_tag()
  end
  if open then
    reaper.defer(loop)
  else
    reference.cleanup() -- window closed: never leave the project muted behind us
    preview.stop()      -- then stop any sound still playing
    peaks.cancel()      -- and free any half-finished waveform build
    loudness.cancel()   -- and any half-finished loudness measurement
  end
end

reaper.defer(loop)
