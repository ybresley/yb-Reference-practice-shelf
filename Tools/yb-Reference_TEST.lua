-- @description yb-Reference TEST · packaging rehearsal
-- @version 0.2.19
-- @author Yoni Bresley
-- @about
--   TEST package for clean-install and update rehearsals.
--   This is not a beta or release build.
--
--   A floating/dockable window for keeping a curated library of reference sounds
--   inside REAPER, with instant preview through Monitor FX and Reference mode
--   for comparing sounds with your project.
--
--   **Windows only.** Requires the free [SWS](https://www.sws-extension.org/)
--   and [ReaImGui](https://github.com/cfillion/reaimgui) extensions.
--
--   Support: [yoni.ybtools@gmail.com](mailto:yoni.ybtools@gmail.com)
-- @provides
--   [nomain] lib/**/*.lua
--   [nomain] assets/fonts/lucide.ttf
--   [nomain] assets/fonts/LICENSE-Lucide.txt
--   [nomain] assets/cursors/drag_copy.cur
--   [nomain] assets/windows/folder_picker.ps1
--   [nomain] assets/windows/folder_picker.vbs
--   [nomain] CHANGELOG.md
--   [main] yb-Reference_TEST_ToggleReferenceMode.lua
--
-- RELEASE NOTES ARE GENERATED — never hand-write them here. CHANGELOG.md is the
-- single source of truth (2026-08-08); `lua scripts/gen_header.lua` writes the
-- changelog tag and its block directly under the packing list above, and the tool reads
-- that same file for the What's New card and Settings > Updates.
--
-- No tag there at all means CHANGELOG.md holds no releases yet — the beta ships
-- with no history (2026-08-09), and the first release after it adds one. (The
-- tag's own name is deliberately not spelled out in this comment: ReaPack would
-- read a second one as a duplicate.)
--
-- NOTE: this @version header is what ReaPack's registry reports as the installed
-- version, which is exactly what the update badge compares the catalog against —
-- keep it honest on every release, and keep the release shelf's catalog naming
-- the same number.

-- This entry script owns the single shared `state` table and the one defer loop.
-- Everything else lives in lib/: core/ is pure Lua (unit-tested), reaper_api is
-- the only REAPER-calling layer, ui/ only draws. No globals.

-- A second launch closes this running copy instead of starting another one.
-- Cleanup still runs, so reference mode is restored and previews are stopped.
-- Library recovery overrides this only when it deliberately reloads the tool.
if reaper.set_action_options then reaper.set_action_options(1) end

--------------------------------------------------------------- module path

-- Resolve the script's own folder from the debug info, then make lib/ requireable
-- (so `require("core.schema")`, `require("ui.window")`, etc. resolve). Never
-- hard-code the separator.
local SEP = package.config:sub(1, 1)
local script_path = debug.getinfo(1, "S").source:sub(2) -- strip the leading "@"
local root = script_path:match("^(.*)[\\/]") or "."

-- The action id this tool is running as (get_action_context return #4) — what
-- the post-update report watcher re-invokes. For a dev slot launched
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
  and ("yb-Reference  [" .. copy_label .. "]###yb-Reference")
  or "yb-Reference"

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
-- Recovery retries every frame while it can still help, but a persistent failure
-- gets one native warning per distinct message rather than reopening the same box.
local reference_alerted

-- An unresolved recovery is the user's project still sitting muted, so it can't wait
-- for the status line — the startup paths below may never reach it.
if recovery_urgent then
  reaper_api.message(recovery_msg, "yb-Reference · Reference Mode Needs Attention")
  reference_alerted = recovery_msg
end

--------------------------------------------------------------- dependencies

-- The tool relies on Windows-only shell, focus and update paths. Stop before
-- loading anything further rather than letting another system enter a session
-- where some features appear to work and others fail later. Crash recovery stays
-- above this gate so an unsupported system can still repair a project left muted.
if not reaper_api.is_windows() then
  reaper_api.message(
    "yb-Reference supports Windows only.\n\n" ..
    "The tool has stopped because this operating system is not supported.\n\n" ..
    "Support: yoni.ybtools@gmail.com",
    "yb-Reference \u{00B7} Windows required")
  return
end

local deps = reaper_api.check_deps()

-- ImGui is required to draw anything, so if it's missing we can't show an in-app
-- guide — fall back to a plain REAPER message box with install steps.
if not deps.imgui then
  reaper_api.message(
    "yb-Reference needs the ReaImGui extension, which isn't installed.\n\n" ..
    "Install it (free) via ReaPack:\n" ..
    "  1. Extensions > ReaPack > Browse packages\n" ..
    "  2. Search \"ReaImGui\" and install it\n" ..
    "  3. Restart REAPER, then run this again\n\n" ..
    "If ReaPack isn't installed, get it at https://reapack.com.\n\n" ..
    "Support: yoni.ybtools@gmail.com",
    "yb-Reference \u{00B7} Setup Needed")
  return
end

-- SWS supplies the preview engine and the Windows integration behind the tool's
-- core listening workflow. Library-only reduced mode is not a supported product
-- mode, so explain the missing requirement and stop before the UI opens.
if not deps.sws then
  reaper_api.message(
    "yb-Reference needs the SWS extension, which isn't installed.\n\n" ..
    "Install SWS (free) from:\n" ..
    "https://www.sws-extension.org/\n\n" ..
    "Restart REAPER, then run this again.\n\n" ..
    "Support: yoni.ybtools@gmail.com",
    "yb-Reference \u{00B7} Setup Needed")
  return
end

-- Loaded before the library so its one public support address is also available
-- to the serious startup failures below. Loading the adapter has no side effects;
-- feedback.init() still runs only after the library and UI are ready.
local feedback = require("feedback")
local product_error = require("product_error")

--------------------------------------------------------------- library data

local schema = require("core.schema")
local store  = require("core.library_store")
local location = require("core.library_location")

-- Bundled UI assets are resolved from the script install, never the library.
-- Recovery needs the same context setup as the full tool, so this is known
-- before the library startup gate.
local icon_font_path = table.concat({ root, "assets", "fonts", "lucide.ttf" }, SEP)

local library_dir, library_remembered = reaper_api.library_dir()
local library_path = reaper_api.join(library_dir, "library.json")

-- Keep the tool alive when no safe library can be loaded. Without real library
-- data the normal browser cannot tell the truth, so this small window only
-- reconnects an existing library or deliberately creates a new one.
local function run_library_recovery(missing_dir)
  local app = require("ui.app")
  local recovery_ui = require("ui.library_recovery")
  local ctx = app.create_context(icon_font_path)
  local recovery_state = {
    copy_label = copy_label,
    path = missing_dir,
    folder_picker = deps.folder_picker,
    mode = "missing",
  }
  local pending_folder_action
  local restart_fallback_at

  local function fail(message)
    recovery_state.status = tostring(message):gsub("^.-:%d+:%s*", "")
    recovery_state.error = true
  end

  local function finish(dir)
    reaper_api.set_library_dir(dir)
    recovery_state.status = "Library ready · reopening…"
    recovery_state.error = false
    if reaper_api.restart_self(CMD_ID) then
      -- A successful restart terminates this instance. If REAPER accepts the
      -- command but does not relaunch it, this loop survives and reveals the
      -- manual fallback instead of silently stopping on a dead panel.
      restart_fallback_at = reaper.time_precise() + 1
    else
      recovery_state.status = "Library ready. Close this window and reopen yb-Reference."
    end
  end

  local function use_existing(dir)
    if type(dir) ~= "string" or dir:match("^%s*$") then
      fail("Choose or type a library folder first.")
      return
    end
    local path = reaper_api.join(dir, "library.json")
    local ok, result = pcall(location.open_existing, path)
    if not ok then fail(result); return end
    finish(dir)
  end

  local function create_new(dir)
    if type(dir) ~= "string" or dir:match("^%s*$") then
      fail("Choose an empty folder for the new library.")
      return
    end
    if not reaper_api.path_exists(dir) then reaper_api.ensure_dir(dir) end
    local empty = reaper_api.directory_is_empty(dir)
    if empty == nil then
      fail("That folder could not be created or reached.")
      return
    end
    local path = reaper_api.join(dir, "library.json")
    local ok, result = pcall(location.create_new, path, empty)
    if not ok then fail(result); return end
    finish(dir)
  end

  local function back_to_missing()
    recovery_state.mode = "missing"
    recovery_state.path = missing_dir
    recovery_state.status = nil
    recovery_state.error = false
  end

  local function choose_with_dialog(title, initial, on_chosen)
    -- A cancelled Windows helper can finish without its final result being
    -- observed. A deliberate second click is a new request, so release any
    -- stale request before opening it instead of leaving the button inert.
    if pending_folder_action then
      reaper_api.cancel_folder_picker()
      pending_folder_action = nil
    end
    local dir, pick_err, pending = reaper_api.browse_for_folder(title, initial, root)
    if dir then
      on_chosen(dir)
    elseif pending then
      pending_folder_action = on_chosen
    elseif pick_err then
      fail(pick_err)
    end
  end

  local function create_elsewhere()
    if recovery_state.folder_picker then
      choose_with_dialog(
        "Choose an Empty Folder",
        reaper_api.parent_dir(reaper_api.default_library_dir()), function(dir)
          recovery_state.path = dir
          create_new(dir)
        end)
    else
      recovery_state.mode = "create_elsewhere"
      recovery_state.path = ""
      recovery_state.status = nil
      recovery_state.error = false
    end
  end

  local function create_in_default()
    local dir = reaper_api.default_library_dir()
    if not reaper_api.path_exists(dir) then reaper_api.ensure_dir(dir) end
    local empty = reaper_api.directory_is_empty(dir)
    if empty == nil then
      recovery_state.status = "The default location is unavailable. Choose another folder."
      recovery_state.error = false
      create_elsewhere()
      return
    end

    local path = reaper_api.join(dir, "library.json")
    local ok, kind = pcall(location.classify, path, empty)
    if ok and kind == "empty" then
      create_new(dir)
    elseif ok and kind == "library" then
      recovery_state.mode = "existing_default"
      recovery_state.path = dir
      recovery_state.status = nil
      recovery_state.error = false
    else
      recovery_state.status = "The default location is in use. Choose an empty folder."
      recovery_state.error = false
      create_elsewhere()
    end
  end

  local function loop()
    -- Crash recovery remains live even though the normal tool has not opened.
    -- A missing audio library must never stop a queued muted-project repair.
    local _, message, urgent = reference.refresh()
    if urgent and message ~= reference_alerted then
      reaper_api.message(message, "yb-Reference · Reference Mode Needs Attention")
      reference_alerted = message
    elseif not urgent then
      reference_alerted = nil
    end
    reference.clear_toggle_request()

    if pending_folder_action then
      local done, dir, pick_err = reaper_api.poll_folder_picker()
      if done then
        local on_chosen = pending_folder_action
        pending_folder_action = nil
        if dir then on_chosen(dir) elseif pick_err then fail(pick_err) end
      end
    end

    if restart_fallback_at and reaper.time_precise() >= restart_fallback_at then
      restart_fallback_at = nil
      recovery_state.status = "Library ready · close and reopen yb-Reference."
    end

    local open, action = recovery_ui.frame(ctx, recovery_state)
    if action then
      recovery_state.status, recovery_state.error = nil, false
      if action.type == "choose" then
        local dir = action.dir
        if not dir then
          choose_with_dialog(
            "Choose Library Folder", reaper_api.parent_dir(missing_dir), function(chosen)
              recovery_state.path = chosen
              use_existing(chosen)
            end)
        end
        if dir then
          recovery_state.path = dir
          use_existing(dir)
        end
      elseif action.type == "new" then
        create_in_default()
      elseif action.type == "back" then
        back_to_missing()
      elseif action.type == "use_default" then
        use_existing(recovery_state.path)
      elseif action.type == "create_elsewhere" then
        create_elsewhere()
      elseif action.type == "create_at" then
        create_new(action.dir)
      end
    end
    if open then reaper.defer(loop) end
  end

  -- This startup branch returns before the normal tool registers its shutdown
  -- cleanup below, so recovery owns the resources it can hold across frames.
  reaper.atexit(function()
    reference.cleanup()
    reaper_api.cancel_folder_picker()
  end)
  reaper.defer(loop)
end

-- The folder must really be there before anything else happens. A user-chosen
-- library can live on a drive or network share that isn't connected right now —
-- treating that as a first run would build an empty library that, once the drive
-- comes back, saves over the real one. Recovery stays open without inventing a
-- replacement; only the explicit New library action may create one.
if not reaper_api.prepare_library_dir(library_dir, library_remembered) then
  run_library_recovery(library_dir)
  return
end

-- Undo a save interrupted by a previous crash. If the rescue itself can't be done we
-- must STOP: carrying on would find no library, create an empty one, and saving that
-- would delete the backup holding the real one.
local rec_ok, rec_err = pcall(store.recover, library_path)
if not rec_ok then
  reaper_api.message(
    product_error.with_details(
      "The Library couldn't be repaired after an interrupted save. Nothing has been changed.", rec_err) .. "\n\n" ..
    "Close REAPER before repairing the Library. You can rename the " ..
    "\".bak\" file back to \"library.json\", or email " .. feedback.ADDRESS ..
    " for help.\n\nFolder:\n" .. library_dir,
    "yb-Reference · Library Not Loaded")
  return
end

local library
if store.exists(library_path) then
  -- Load an existing library. If the file is unreadable we must NOT overwrite it
  -- (that would destroy the user's data) — surface a clear message and stop.
  local ok, result = pcall(store.load, library_path)
  if not ok then
    reaper_api.message(
      product_error.with_details(
        "The Library couldn't be opened because its data is damaged or incompatible. The file was not changed.", result) .. "\n\n" ..
      "The tool has left the file untouched. Restore it from a backup, or move it " ..
      "aside to start a fresh library, or email " .. feedback.ADDRESS ..
      " for help.\n\nFile:\n" .. library_path,
      "yb-Reference · Library Not Loaded")
    return
  end
  library = result
elseif store.present(library_path) then
  -- The file is THERE but won't open — a lock, not a first run. Stopping is the
  -- only safe answer: carrying on with a fresh empty library would save it over
  -- the real one the moment the lock clears.
  reaper_api.message(
    "The Library file exists but couldn't be opened. Another program may be using it.\n\n" ..
    "Nothing has been changed. Close any program using the file, then run the tool again.\n\n" ..
    "File:\n" .. library_path,
    "yb-Reference · Library Not Loaded")
  return
else
  -- A library is only born in a folder proved empty. Existing unrelated files
  -- are never mixed into a new library; the recovery window lets the user pick
  -- another location instead.
  if not reaper_api.directory_is_empty(library_dir) then
    run_library_recovery(library_dir)
    return
  end
  -- First run in this folder: create an empty library and save it immediately.
  -- If that very first save FAILS, stop — the folder can be a user-chosen
  -- location (Settings) that isn't really usable right now (a disconnected
  -- drive, a file sitting where the folder should be). Opening anyway with an
  -- empty in-memory library would save it over the real one the moment the
  -- location comes back. Stopping loses nothing.
  -- Born with the starter categories (2026-08-10) — a first import has
  -- somewhere to go, and the sidebar never greets a new user empty.
  library = schema.starter_library()
  local ok, err = pcall(store.save, library_path, library)
  if not ok then
    reaper_api.message(
      product_error.with_details(
        "A Library couldn't be created in this folder. Nothing has been changed.", err) ..
      "\n\nCheck the folder is reachable and can be written to, " ..
      "then run the tool again:\n" .. library_dir,
      "yb-Reference · Library Not Loaded")
    return
  end
end

-- Older installs could use the default folder without storing it as a setting.
-- Remember it after one successful load so a later disappearance is treated as
-- a missing known library, not another first run. A failed load never stamps it.
if not library_remembered then reaper_api.set_library_dir(library_dir) end

--------------------------------------------------------------- UI + defer loop

-- The entry script owns the shared state and the one defer loop. All ImGui lives
-- in ui/app: context creation and the per-frame draw. library_service performs
-- the library-changing work the UI asks for (importing, orphan sweep).
local service    = require("library_service")
local categories = require("core.categories")
local search     = require("core.search")
local analysis   = require("core.analysis") -- what still needs measuring
local match      = require("core.match")    -- match-to-target trim arithmetic
local span       = require("core.span")     -- start/end points: clamping + effective range
local techfacts  = require("core.techfacts") -- the armed sound's tech line for the bar
local preview    = require("preview")  -- SWS audio-preview adapter (playback)
local peaks      = require("peaks")    -- waveform envelope reader
local loudness   = require("loudness") -- background loudness measurement
local holders    = require("holders")  -- what is holding a sound, and letting go of all of it at once
local dragout    = require("dragout")  -- dropping a sound onto the arrange view
local importer     = require("core.importer") -- dedup lookup for import-and-pin
local pins_core    = require("core.pins")     -- per-project pin records (pure)
local pins_service = require("pins_service")  -- pin/unpin/adopt + project switch handling
local updater      = require("updater")       -- in-app update check + one-button update
local changelog    = require("core.changelog") -- CHANGELOG.md -> the What's New card + Settings history
local fb_core      = require("core.feedback")  -- report payload building (pure)
local walkthrough  = require("core.walkthrough") -- first-open walkthrough state machine (pure)
local demo         = require("core.demo")        -- the walkthrough's stand-in sound (pure, drawing data only)
local walkthrough_ui = require("ui.walkthrough")  -- asked ONE question here: can its card draw on this ReaImGui
local app = require("ui.app")
local ctx = app.create_context(icon_font_path)

-- The drag-out cursor travels with the script the same way. Handed over once
-- here because reaper_api has no business knowing where the script lives.
reaper_api.set_drag_cursor_file(table.concat({ root, "assets", "cursors", "drag_copy.cur" }, SEP))

-- The Loudness column can show any of the three measurements we store; which one is
-- remembered between runs. Anything unrecognised falls back to the default rather
-- than showing an empty column.
local stored_unit = reaper_api.get_loud_unit()
if not analysis.is_field(stored_unit) then stored_unit = search.DEFAULT_LOUD_FIELD end

-- Where the title bar's "Dock window in Docker" sends the window, asked once:
-- REAPER's dockers are a property of the user's layout, not ours.
local dock_target = reaper_api.dock_target()

-- Read a text file whole, or nil if it isn't there. Used once, at startup, for
-- CHANGELOG.md — which ships beside the script (@provides) and never changes
-- while the tool runs, so this is never called from the frame loop. A missing
-- file is not an error: a dev copy or a half-finished install simply has no
-- release notes to show, and the tool must still open.
local function read_text_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

-- The update feature, told which file ReaPack would know this copy as. Also
-- replays the crash-window recovery if a previous run died mid-update (see
-- lib/updater.lua) — which is why it runs unconditionally, before the feature
-- decides whether THIS copy is even ReaPack-owned.
updater.init(script_path)

-- Send feedback (2026-08-09, `.brief/_done/send-feedback/`). The adapter owns
-- delivery and the phase; the display fields the Help pane reads are filled
-- here — after updater.init, because the attach line and the payload both
-- lean on what the updater learned about this copy (version, install kind).
feedback.init()
local fb_last_phase = nil -- the frame loop's failed-edge detector
local fb_failure_notice -- waits until the frame tells us whether Feedback was visible
local FB_REAPER_VER = fb_core.reaper_version(reaper_api.app_version())
feedback.state.address = feedback.ADDRESS
feedback.state.email = reaper_api.get_feedback_email()

-- (The "Sends with …" attach line lived here until 2026-08-09 — the Help pane
-- stopped showing it on the user's call, `.brief/feedback-pane` round 2, so
-- nothing displays it and nothing builds it. The payload still carries the
-- same facts; they are read fresh at the moment of a send below.)

local state = {
  deps           = deps,
  library        = library,
  library_dir    = library_dir,
  library_path   = library_path,
  win_title      = WIN_TITLE,                    -- names the dev slot in the title bar when this copy is one
  dock_target    = dock_target,                  -- where the title bar's "Dock window in Docker" sends it
  selected_id    = nil,
  selected       = nil,                          -- the selected sound record (convenience for the UI)
  selected_tech  = nil, -- the armed sound's tech line for the bar (core.techfacts, set per selection)
  status         = nil,
  view           = { scope = "all" },            -- which category the list is showing
  query          = "",                           -- search box text
  sort           = { col = "name", asc = true }, -- matches the Name column's default sort
  loud_unit      = stored_unit,                  -- which measurement the Loudness column shows
  -- How many times the columns have been reset — carried over from the last run
  -- (2026-08-11), because it is part of the name ImGui files the table's widths
  -- under: restarting it at 0 made a reset land on a name that already had saved
  -- widths. See reaper_api.get_col_gen and ui/browser.sounds_table_id.
  col_gen        = reaper_api.get_col_gen(),
  -- The match window's preset list and remembered target (loudness tools,
  -- 2026-08-06). App preferences like loud_unit: stored garbage falls back
  -- quietly (core/match.lua decodes), never crashes the tool.
  match          = { presets = match.decode_presets(reaper_api.get_match_presets()),
                     target  = match.decode_target(reaper_api.get_match_target()) },
  -- The browser audition strip's dragged height; nil = the default token
  -- (ui/browser.lua clamps it to the window each frame, so a value saved on a
  -- big screen can't crush the sound list on a small one).
  browser_wave_h = reaper_api.get_browser_wave_h(),
  visible_sounds = {},                           -- library sounds for the view (filtered + sorted, cached)
  -- Playback (Phase 3). auto_audition on by default = clicking a sound plays it.
  auto_audition  = true,
  loop           = false,
  -- Mono monitoring (2026-08-07): fold left and right together and hear the
  -- result in both speakers, for checking a sound survives a mono system.
  -- Session state like `loop` and `auto_audition`, deliberately NOT persisted —
  -- it is a thing you switch on to check something and off again, and a tool
  -- that silently reopened in mono would be a bug report waiting to happen.
  mono           = false,
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

  -- `paused` holds one remembered pause PER SLOT — `{ at, sound_id, length }`
  -- under "main" (the working view / reference mode) and under "browse" (the
  -- Library), each nil while that view has nothing parked. lib/holders.lua owns
  -- the shape and every read and write of it; nothing here touches the table
  -- directly except the UI, which only reads it to draw.
  --
  -- Tracked SEPARATELY from `sound_id`/`length` on purpose: those two mean
  -- "whatever the one shared preview is sounding right now" (both get
  -- reassigned the instant a browse audition plays something else), but a pause
  -- memory must survive that — pausing sound A, then auditioning B and C in the
  -- browser, then coming back to A must still offer to resume it, and its
  -- waveform's paused playhead must keep scaling by A's real length, not
  -- whatever B or C left behind.
  --
  -- And PER SLOT rather than one memory for the tool, since both windows carry a
  -- transport (2026-08-12): a Library audition paused at 0:10 must not overwrite
  -- the reference the working view has paused at 0:30. Each slot's memory is
  -- cleared on that slot's own real stop and whenever that view moves to a
  -- DIFFERENT sound, so a stale position can never resurrect on the wrong sound.
  --
  -- `slot` records WHICH view started the playback ("main" = working view or
  -- reference mode, "browse" = the library browser) and `trim_db` the per-sound trim
  -- in force for it. They differ because a browse audition deliberately applies no
  -- trim at all, so neither the level nor the waveform can be re-derived from the
  -- sound record alone — the same sound sounds different depending on who started it.
  preview        = { playing = false, sound_id = nil, position = 0, length = 0,
    slot = nil, trim_db = 0, paused = { main = nil, browse = nil } },
  -- Reference mode (Phase 4). `active` = the current preview was started BY the
  -- REAPER transport, so only transport changes may stop it (a casual audition the
  -- user started themselves is left alone). `sound_id` is what it's playing, so
  -- picking a different sound mid-play switches the reference live. `failed_id` is a
  -- sound that wouldn't play, so we don't retry it every frame.
  -- `latched` is CURRENT-project-specific: another tab may own the one live
  -- latch while this tab's L button remains off and usable. Closed owners move
  -- into the adapter's recovery queue; only a real safety failure sets pending.
  reference      = { latched = false, active = false, sound_id = nil, failed_id = nil,
    live = false, pending = false, owner_name = nil, queued_count = 0 },
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
  -- The Send-feedback panel's view (lib/feedback.lua mutates phase; the
  -- display fields were filled at startup above). Settings' HELP section reads
  -- it and reports "send_feedback" back.
  feedback       = feedback.state,
  -- The parsed CHANGELOG.md (2026-08-08). Read ONCE here — a file read, and the
  -- text never changes while the tool runs. Both surfaces that show release
  -- notes read this same list: the What's New card and Settings > Updates.
  changelog      = changelog.parse(read_text_file(
                     table.concat({ root, "CHANGELOG.md" }, SEP))),
  -- { list, version } while release notes are waiting to be read, else nil. The
  -- What's New card draws whatever is here; clearing it is what dismisses it.
  whatsnew       = nil,
  -- The first-open walkthrough (core/walkthrough.lua owns the rules; ui/
  -- walkthrough.lua draws it). Inactive here — the block below decides whether
  -- this launch is the first-ever one.
  walkthrough    = walkthrough.new(),
}

-- What's New, decided once at startup (2026-08-08, `.brief/_done/changelog/`).
--
-- Since an update restarts the tool after ReaPack's report closes, "the first
-- frame of a version whose notes haven't been read" is exactly the safe moment
-- after an update — no popup has to be timed against ReaPack's install, and
-- everything the card describes is code that is already running.
--
-- A first-ever run stamps the mark SILENTLY and shows nothing: greeting a new
-- user with the notes for versions they never had would read as a fault. That is
-- also why core.changelog.since returns nothing for an empty mark, so this stays
-- the one place that writes the mark without showing anything.
-- `version` is what the card is TITLED by — the version actually running, which
-- is what happened to the user. `mark` is what gets written when they close it,
-- and is the newest of the running version and everything just shown, so the
-- card can never re-open on notes that have been read. The two are separate
-- because they answer different questions and only agree most of the time.
local running_version = state.update.installed
if running_version then
  local seen = reaper_api.seen_version()
  if not seen then
    reaper_api.set_seen_version(running_version)
  else
    local missed = changelog.since(state.changelog, seen)
    if #missed > 0 then
      state.whatsnew = { list = missed, version = running_version }
      -- The mark is written NOW, at show time — not when the card is dismissed
      -- (audit fix, 2026-08-09). Write-on-dismissal depended on the user closing
      -- the CARD itself, and both of its gestures could go unperformed: Esc goes
      -- to REAPER until the card is clicked (the tool's own focus handoff), and
      -- closing the whole tool with the card open skipped the write entirely —
      -- which showed the same notes again on every launch. Cost, accepted: a
      -- crash while the card is open loses the re-push; Settings > Updates still
      -- holds every note. mark_for() takes the newest of running/shown, so a
      -- hand-edited file listing a version above the running one can't loop.
      reaper_api.set_seen_version(changelog.mark_for(missed, running_version))
    end
  end
end

-- The first-open walkthrough (decided 2026-08-10, `.brief/_done/walkthrough/`).
-- The seen-mark is written the moment the welcome card is SHOWN — the What's
-- New card's own lesson, applied from day one: no dismissal gesture may be
-- load-bearing. Closing the tool mid-walkthrough therefore ends it for good
-- (one-shot, the user's pick); Settings → Help replays it whole on request.
-- Gated on the card being drawable at all: the mark is one-shot, so starting a
-- tour whose card this ReaImGui can never render would spend the user's only
-- first run on an empty screen (Codex, 2026-08-10). Nothing is written in that
-- case, so a later ReaImGui update still gets its first open.
if not reaper_api.walkthrough_seen() and walkthrough_ui.can_draw() then
  walkthrough.begin_welcome(state.walkthrough)
  reaper_api.set_walkthrough_seen()
end

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
-- Returns whether the save actually landed, so a caller that wants to report
-- its own success can check first — overwriting the status line below with a
-- cheerful message would delete the only notice a REPEAT failure gets (the
-- dialog fires once per episode, the status line every time).
local function commit()
  local ok, err = pcall(store.save, state.library_path, state.library)
  if ok then
    -- A retry that succeeded ends the episode: say so (a status line still claiming
    -- the library isn't saved would be a lie), and re-arm the one-time dialog so a
    -- NEW failure later isn't silently demoted to a status line nobody notices.
    if save_warned then
      save_warned = false
      state.status = "Library saved."
    end
  else
    state.status = "Couldn't save the latest change. It remains in the Library, and yb-Reference will try again when you make another change."
    if not save_warned then
      save_warned = true
      reaper_api.message(
        product_error.with_details(
          "The Library couldn't be saved. Your latest change remains in the Library.", err) ..
        "\n\nyb-Reference will try to save everything again when you make another change. " ..
        "If this keeps happening, check your disk space, and whether backup or sync software " ..
        "is holding on to:\n" .. state.library_path,
        "yb-Reference · Library Couldn't Be Saved")
    end
  end
  return ok
end

--------------------------------------------------------------- playback

-- Pins carry their own id prefix ("p1" vs the library's "s1"), so one lookup can
-- serve both kinds of record — everything downstream (playback, waveform, seek,
-- drag-out) works on whichever the selection happens to be. The test itself lives
-- in holders, which lets go of background work by exactly this distinction.
local is_pin_id = holders.is_pin

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
  if loop == nil then loop = state.loop end
  -- Play runs start -> end (loudness tools, 2026-08-06): a fresh start in the
  -- working view begins at the sound's start point. An explicit position — a
  -- parked playhead, a resume, a browse click-from-there — is the user's own
  -- and is honoured as given; the end point is enforced in the frame loop.
  if slot == "main" and (position == nil or position == 0)
    and type(s.span_start) == "number" and s.span_start > 0 then
    position = s.span_start
  end
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
    local folder = is_pin_id(s.id)
      and "the project's References folder" or "the Library folder"
    state.status = string.format(
      "\"%s\" couldn't be played. Its audio file is missing or can't be read from %s.", s.name, folder)
  end
  return ok -- callers must know: reference mode may not claim a playback that failed
end

-- Pause: preview.lua has no pause primitive (an SWS preview is play-or-nothing),
-- so pausing is really "remember exactly where we were, then stop like normal" —
-- everything else (sound_id/length/position/playing) resets exactly like a full
-- stop; only the slot's own remembered pause survives, tagged to the sound that
-- was actually playing. The memory is written BEFORE the audio is stopped,
-- because stopping is what makes the live position unreadable.
--
-- `slot` says whose pause this is: the working view's transport pauses "main",
-- the Library's pauses "browse", and neither can reach the other's memory (see
-- the state init comment and holders.lua).
local function pause_playback(slot, id)
  holders.set_pause(state, slot, id,
    preview.position() or state.preview.position, state.preview.length)
  holders.stop_audio(state)
end

-- Resume: play_sound already accepts a start position, so resuming is just a
-- fresh play from the remembered spot — trim/master volume/loop are re-applied
-- exactly like any other play, which is correct (they may have changed while
-- paused).
local function resume_playback(slot, s)
  if not s then return end
  local p = holders.pause_of(state, slot)
  if play_sound(s, p and p.at or 0, slot) then holders.clear_pause(state, slot) end
end

-- Hand a finished envelope to every slot that wants that sound, so the working
-- view and the browser looking at the same file cost one build, not two.
local function deliver_wave(wid, chans)
  if not wid then return end
  if wid == state.selected_id then state.waveform = { sound_id = wid, channels = chans } end
  if wid == state.browse_id then state.browse_waveform = { sound_id = wid, channels = chans } end
end

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
  -- if the user comes back to a sound they never actually paused. The working
  -- view's own slot only — the Library's park is none of this view's business.
  if not holders.paused_on(state, "main", id) then holders.clear_pause(state, "main") end
  state.selected_id = id
  state.selected = find_sound(id)
  state.selected_tech = nil
  if not state.selected then return end
  -- The bar's tech-facts line (horizontal-layout brief, 2026-08-07), formatted
  -- ONCE per selection — the bar draws this string every frame and must never
  -- probe the file or format it itself (ui reads state; frame-allocation rule).
  state.selected_tech = techfacts.format(reaper_api.source_info(sound_path(state.selected)))
  -- The envelope itself is fetched by the defer loop (see the "asked" marks
  -- there): there is only ONE peaks job, so whichever slot asked last would
  -- starve the other. Clearing the "asked" mark makes a deliberate re-pick
  -- retry a sound whose file was missing when it was first tried.
  holders.forget_wave("main")
  -- ...except where the answer is already sitting on disk, which is the case for
  -- every file the tool has drawn once (REAPER writes a .reapeaks sidecar). Ask
  -- for it RIGHT HERE instead of waiting for the loop to notice: the round trip
  -- through the loop cost two frames with nothing to draw, and that gap was the
  -- blank flash the user saw every time they changed reference (2026-08-07).
  -- A file with no sidecar yet still returns nothing here and builds a slice per
  -- frame as before, with the "reading waveform…" hint — that wait is real work,
  -- not plumbing.
  --
  -- Only while peaks is IDLE. Taking over a live job would cancel it, and a
  -- cancelled browse build is never re-queued (its browse mark is already set),
  -- leaving that slot waiting on an envelope nobody is making.
  if not peaks.pending() then
    peaks.request(id, sound_path(state.selected))
    holders.mark_wave("main", id) -- asked, whether or not it answered on the spot
    deliver_wave(peaks.advance())
  end
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
local REF_PLAYING_MSG = "Reference mode is playing. Stop the transport to audition here."

-- Browse a LIBRARY sound in the browser popup: entirely separate from
-- select_sound above (DESIGN "browsing can never surprise-mute anything, and
-- one readout — the working view's — tells what's armed"). Never touches
-- `selected`/`selected_id`, the armed reference, the latch, or pins_service's
-- remembered selection — only the browser's own slots.
-- `quiet` browses without auditioning — used by "Show in library" below, where
-- the user asked WHERE a sound is, not to hear it.
local function browse_sound(id, quiet)
  -- Same rule select_sound follows, on this window's own slot: a park belongs to
  -- the sound it was made on, so moving the Library to a different row drops it.
  if not holders.paused_on(state, "browse", id) then holders.clear_pause(state, "browse") end
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
  holders.forget_wave("browse") -- same as select_sound: the loop fetches, a re-pick retries
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
    state.status = "This pin isn't in the Library. Drag it onto a Library category to add it."
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
  local parked = holders.paused_on(state, slot, s.id)
  if state.preview.playing and state.preview.sound_id == s.id then
    local pos = fraction * (state.preview.length or 0)
    preview.seek(pos)
    state.preview.position = pos
  elseif parked then
    -- A real pause keeps its own length snapshot (live audio's number) — the
    -- click just moves the remembered position within it.
    parked.at = fraction * (parked.length or 0)
  elseif slot == "main" then
    -- The working view NEVER starts audio from a click (user, 2026-08-06:
    -- "move the playhead there and wait for me to trigger the sound"). The
    -- click PARKS the position, written as a synthetic pause — the paused
    -- playhead already draws it and toggle_play's resume gate already starts
    -- from it, so parking needs no machinery of its own. Scaled by the
    -- record's stored duration: the live length only exists while audio runs,
    -- and this is the same number the ruler under the wave draws by.
    holders.set_pause(state, "main", s.id, fraction * (s.duration or 0), s.duration or 0)
  elseif play_sound(s, 0, slot) then
    -- The browser strip keeps click-auditions-from-there: browsing IS
    -- listening (the sample-browser convention), unlike the working view.
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
  -- Everything holding a pin lets go at once. The pause memory matters as much as
  -- the audio here: pin ids restart at "p1" in every project, so a pause
  -- remembered against the old project's p1 would offer to resume the NEW
  -- project's p1 at a position that means nothing there.
  holders.release(state, holders.is_pin)
  holders.forget_selection(state, holders.is_pin)
  -- The latch view is project-specific now. An incoming project's remembered
  -- pin is safe to restore because only a CURRENT owner can drive reference
  -- playback; another tab's live latch never reads this project's selection.
  if r.selected and not state.selected_id and find_sound(r.selected) then
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
  -- The ghost goes FIRST, on every path out of here: the real insert below
  -- makes its own item, and a ghost still standing would leave two.
  dragout.hide_ghost()
  if not drag then return end

  -- A PIN dragged out of a project the user has since left names a different
  -- sound now; drop it rather than inserting the wrong audio.
  if is_pin_id(drag.sound_id) and drag.proj ~= (state.pins and state.pins.proj) then
    state.status = "That drag ended in a different project, so nothing was added."
    return
  end

  local s = find_sound(drag.sound_id)
  if not s then return end

  local target = dragout.target()
  if not target.over_arrange then
    -- Not a failure — letting go somewhere else is how you change your mind.
    state.status = string.format("\"%s\" wasn't added. It was dropped over %s, not the timeline.",
      s.name, target.where)
    return
  end

  -- The framed span travels: the dropped item carries the sound's start->end
  -- stretch, not the whole file (loudness tools, 2026-08-06).
  --
  -- Re-asked HERE rather than trusted from the last drawn frame: the pointer
  -- moves between the frame that painted the strip and the release, and the
  -- drop must do what the mouse is over NOW.
  local new_track = dragout.newtrack_zone(target) ~= nil
  local ok, result = dragout.insert(sound_path(s), target.track, target.position, s.name,
    s.span_start, s.span_end, new_track)
  if ok then
    state.status = new_track
      and string.format("Added \"%s\" to a new track.", s.name)
      or dragout.landed_at(target.track, result)
  else
    state.status = string.format("\"%s\" couldn't be added to the timeline: %s.", s.name, tostring(result))
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
  local mine = holders.is_id(id)

  local held = holders.release(state, mine)

  -- `audio_gone` marks the one failure that isn't a clean refusal: the file reached
  -- the trash but the library wouldn't save. The sound is still listed, so its work
  -- must NOT be restarted — there's no file left to read, and a measurement failing
  -- on it would try to save the library all over again.
  local ok, why, audio_gone = service.delete_sound(state, id)
  if not ok then
    -- A clean refusal: hand the sound back its unfinished work.
    if not audio_gone then
      holders.restore(state, held, function() return s and sound_path(s) end)
    end
    state.status = why
    reaper_api.message(why, "yb-Reference · Delete Sound")
    return
  end

  -- Gone for good: drop it from the measuring queue too (it holds nothing open, so
  -- it only needed clearing once the delete actually happened).
  for i = #state.analysis_queue, 1, -1 do
    if state.analysis_queue[i] == id then table.remove(state.analysis_queue, i) end
  end

  -- The row is gone, so neither view may still be pointing at it.
  holders.forget_selection(state, mine)
  holders.forget_browse(state, mine)
  refresh_view()
  state.status = string.format("\"%s\" moved to the trash folder in your Library.", name)
end

--------------------------------------------------------------- pins

-- Unpin: like delete, anything holding the pin must let go first — its References
-- copy is about to be removed. Only the project's own copy is at stake; the
-- library original, if there is one, is never touched. (Loudness never runs on
-- pins, so there is no measurement to stop here — holders knows that, so this
-- doesn't have to.)
local function unpin_sound(id)
  local p = find_sound(id)
  if not p then return end

  local mine = holders.is_id(id)
  local held = holders.release(state, mine)

  local ok, msg = pins_service.unpin(state, id)
  state.status = msg
  if not ok then
    -- A clean refusal: the pin is still there, so hand back its unfinished work.
    holders.restore(state, held, function() return sound_path(p) end)
    return
  end
  holders.forget_selection(state, mine)
end

-- Adopt a pin into the library. The service answers "already there" without
-- copying anything; a genuinely new sound joins the list, the view, and the
-- loudness queue exactly like an import does.
-- Adopt a pin into the library. `dest` (optional) is where it should be filed —
-- set when the pin was DRAGGED onto a category in the browser's sidebar, which
-- since 2026-08-06 is the only route this action has (the picker's list has no
-- right-click menu by design). Filing an already-adopted sound is allowed and
-- deliberate: dropping a pin on a second category moves the library copy there
-- rather than making another one.
local function save_pin_to_library(id, dest)
  local ok, msg, sound_id, added = pins_service.save_pin_to_library(state, id)
  -- Multi-line messages are real problems (a copy or save failure) — those get a
  -- dialog, like import failures do. One-liners stay on the status line.
  state.status = msg:match("^[^\n]*")
  if msg:find("\n", 1, true) then
    reaper_api.message(msg, "yb-Reference · Save to Library")
  end
  if ok and sound_id and dest then
    local adopted = find_sound(sound_id)
    if adopted and (adopted.category ~= dest.category or adopted.subcategory ~= dest.subcategory) then
      adopted.category, adopted.subcategory = dest.category, dest.subcategory
      -- Only claim it landed if the library file actually took it. commit()
      -- writes its own failure message, and a repeat failure gets ONLY that
      -- status line (the dialog fires once per episode) — overwriting it with
      -- "saved under Whooshes" would be the tool lying about where the sound is.
      if commit() then
        local where = dest.subcategory or dest.category
        local c = where and categories.get(state.library, where)
        state.status = string.format("\"%s\" saved to your Library under %s.",
          adopted.name, c and c.name or "Uncategorised")
      end
    end
  end
  if ok and (added or dest) then
    refresh_view()
    if added and loudness.available() then
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

  if reference.transport_preview_wanted() and state.selected then
    local id = state.selected.id
    -- failed_id stops a broken file being re-opened on every single frame (that would
    -- hammer the disk inside the frame loop); the user picking a sound clears it.
    if ref.failed_id ~= id and (not ref.active or ref.sound_id ~= id) then
      -- From the PARKED playhead, not always from the top (Codex, 2026-08-06):
      -- a click on the working view's waveform parks a position rather than
      -- starting audio, and DESIGN already promised "play/REF triggers from the
      -- parked spot" — but this call passed a hard 0, so latching and rolling
      -- the transport always restarted from the beginning. The park is stored
      -- as a synthetic pause, so it is read the same way resume_playback reads
      -- it, and it is NOT consumed: stopping and rolling again re-triggers from
      -- the same spot, which is the point of parking one.
      local parked = holders.paused_on(state, "main", id)
      local from = parked and parked.at or 0
      if play_sound(state.selected, from, "main", true) then
        ref.active, ref.sound_id, ref.failed_id = true, id, nil
      else
        ref.active, ref.sound_id, ref.failed_id = false, nil, id
        state.status = "That reference couldn't be played. Its audio file may be missing or unreadable."
      end
    end
  elseif ref.active or ref.failed_id then
    -- Transport stopped: drop the reference AND the "wouldn't play" mark, so pressing
    -- play again is a fresh attempt. Without clearing it, one transient failure would
    -- suppress every later play until the user re-picked the sound.
    if ref.active then holders.stop_playback(state, "main") end
    ref.active, ref.sound_id, ref.failed_id = false, nil, nil
  end
end

-- Turn reference mode on/off. Playback is stopped on BOTH edges: latching should begin
-- from real silence, and un-latching must not leave a preview playing over a project
-- that is audible again.
local function toggle_reference()
  local ref = state.reference
  -- The working view's slot: latching is that view's act. A Library audition
  -- still stops (the audio is shared), but where the Library was paused is not
  -- this button's to forget.
  holders.stop_playback(state, "main")
  ref.active, ref.sound_id, ref.failed_id = false, nil, nil

  if ref.latched then
    ref.latched = false
    if reference.latch_off() then
      ref.live, ref.pending, ref.owner_name = false, false, nil
      state.status = "Reference mode is off. Your project plays normally again."
    else
      local view, recovered, urgent = reference.refresh()
      ref.latched, ref.live, ref.pending = view.latched, view.live, view.pending
      ref.owner_name, ref.queued_count = view.owner_name, view.queued_count
      local message = recovered or reference.pending()
      if message then
        state.status = message
        if (urgent or view.pending) and message ~= reference_alerted then
          reaper_api.message(message, "yb-Reference · Reference Mode Needs Attention")
          reference_alerted = message
        end
      end
    end
  else
    -- Refuse an empty latch: muting the project with nothing armed buys silence
    -- for nothing, and "press play, hear nothing" reads as broken. (Losing the
    -- armed reference LATER, while latched, is different — then we stay latched
    -- at NO TARGET, because auto-unlatching would surprise-blast project audio.)
    if not state.selected then
      state.status = "Select a reference first. Choose a sound or pin, then turn on the Latch button."
      return
    end
    -- Refusing to latch is the only safe answer when its records can't be laid down
    -- first or a genuine recovery failure is outstanding. Closed projects with
    -- verified records are ordinary queue entries and do not block this project.
    local ok, reason = reference.latch_on()
    if ok then
      local view = reference.refresh()
      ref.latched, ref.live, ref.pending = view.latched, view.live, view.pending
      ref.owner_name, ref.queued_count = view.owner_name, view.queued_count
      state.status = "Reference mode is on for " .. (view.owner_name or "this project") ..
        ". Its master is muted. Press Play in REAPER to hear the selected reference."
    else
      state.status = reason
      reaper_api.message(reason, "yb-Reference · Reference Mode")
      if reference.pending() then reference_alerted = reason end
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
  state.status = "Loudness measurements aren't available in this version of REAPER. Everything else works normally."
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

if #orphans == 1 then
  add_status("1 audio file in the Library folder is not yet in the Library. It may be left over from an interrupted add.")
elseif #orphans > 1 then
  add_status(string.format(
    "%d audio files in the Library folder are not yet in the Library. They may be left over from an interrupted add.",
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
  if #missing == 1 then
    add_status(string.format("1 sound has a missing audio file in the Library folder: %s.", list))
  else
    add_status(string.format("%d sounds have missing audio files in the Library folder: %s.",
      #missing, list))
  end
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
  if #sum.duplicates > 0 then
    parts[#parts + 1] = string.format("%d %s already in the Library",
      #sum.duplicates, #sum.duplicates == 1 and "sound" or "sounds")
  end
  if #sum.skipped > 0 then parts[#parts + 1] = #sum.skipped .. " skipped" end
  if #sum.errors > 0 then parts[#parts + 1] = #sum.errors .. " couldn't be added" end
  if #parts == 0 then return "Nothing to add." end
  return table.concat(parts, "  \u{00B7}  ")
end

local function do_import(paths, category, subcategory)
  if not paths or #paths == 0 then return end
  local sounds_before = #state.library.sounds
  -- pcall: the one raise left in here is the library save at the very end. By then
  -- every copied sound is already in the in-memory list, so the tool must keep
  -- running — the next successful save writes the complete library anyway.
  local ok, sum = pcall(service.import_files, state, paths, category, subcategory)
  refresh_view()
  -- Walkthrough stop 2 advances the moment files really land ("real actions
  -- advance where natural"). Counted, not assumed, so a pick that dedups to
  -- nothing doesn't claim an add that didn't happen — and it fires even on a
  -- failed SAVE, because the sounds are in the list either way.
  if #state.library.sounds > sounds_before then
    walkthrough.event(state.walkthrough, "files_added")
  end
  -- Rebuild rather than append: this picks up the new sounds AND anything still
  -- unmeasured from before, and skips the one being measured right now so it can't
  -- be queued twice.
  if loudness.available() then
    state.analysis_queue = analysis.queue(state.library, loudness.current())
  end
  if not ok then
    state.status = "The sounds were added, but the Library couldn't be saved. They remain in the Library, and yb-Reference will try again when you make another change."
    reaper_api.message(
      product_error.with_details(
        "The sounds were added, but the Library couldn't be saved. They remain in the Library.", sum) ..
      "\n\nyb-Reference will try to save everything again when you make another change.",
      "yb-Reference · Add Sounds")
    return
  end
  state.status = summarize(sum)
  -- Skips/errors are real problems the user should see spelled out — surface them
  -- in a dialog (duplicates are benign and stay in the status line only).
  local detail = {}
  for _, d in ipairs(sum.skipped) do detail[#detail + 1] = d end
  for _, e in ipairs(sum.errors) do detail[#detail + 1] = e end
  if #detail > 0 then
    reaper_api.message(state.status .. "\n\n" .. table.concat(detail, "\n"), "yb-Reference · Add Sounds")
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
    local message = fail_hint or "The change couldn't be completed."
    reaper_api.message(product_error.with_details(message, err), fail_title)
  end
end

-- True if the current view is showing the category being removed (so we can fall
-- back to "All" instead of pointing at something that no longer exists).
local function viewing_category(id)
  return (state.view.scope == "category" or state.view.scope == "subcategory") and state.view.id == id
end

--------------------------------------------------------------- library location

-- Switch to a different library folder from Settings. A real library opens; an
-- empty folder starts a new one; anything else is refused. Nothing moves or
-- copies sounds, and the current library stays on disk.
local function switch_library(new_dir)
  -- Trailing separators would make the same folder look like a different one
  -- (and double up inside joined paths). A bare drive keeps its slash.
  new_dir = new_dir:gsub("[\\/]+$", "")
  if new_dir:match("^%a:$") then new_dir = new_dir .. SEP end
  if new_dir == "" then return end
  if new_dir == state.library_dir then
    state.status = "You're already using that Library folder."
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
      "Your current Library couldn't be saved, so yb-Reference didn't switch folders. Switching now would " ..
      "lose unsaved changes. Fix what's blocking the save, such as low disk space or backup or sync software holding the " ..
      "file, then try again.",
      "yb-Reference · Library Folder Not Changed")
    return
  end

  local new_path = reaper_api.join(new_dir, "library.json")
  reaper_api.ensure_dir(new_dir)
  if not reaper_api.path_exists(new_dir) then
    reaper_api.message(
      "That folder couldn't be found or created:\n\n" .. new_dir .. "\n\nNothing has been changed. " ..
      "you're still using your current Library. If it's on a drive or network location, check that it's connected.",
      "yb-Reference · Library Folder Not Changed")
    return
  end

  local folder_empty = reaper_api.directory_is_empty(new_dir)
  if folder_empty == nil then
    reaper_api.message(
      "That folder couldn't be read:\n\n" .. new_dir ..
      "\n\nNothing has been changed. You're still using your current Library.",
      "yb-Reference · Library Folder Not Changed")
    return
  end

  local ok, kind, lib = pcall(location.classify, new_path, folder_empty)
  if not ok then
    reaper_api.message(
      product_error.with_details("The Library in that folder couldn't be opened. Nothing has been changed. " ..
        "You're still using your current Library.", kind),
      "yb-Reference · Library Folder Not Changed")
    return
  end
  if kind == "occupied" then
    reaper_api.message(
      "That folder isn't empty and doesn't contain a readable Library.\n\n" ..
      "Nothing has been changed. You're still using your current Library.",
      "yb-Reference · Library Folder Not Changed")
    return
  end

  if kind == "empty" then
    local create_ok, result = pcall(location.create_new, new_path, true)
    if not create_ok then
      reaper_api.message(
        product_error.with_details("A new Library couldn't be created in that folder. Nothing has been " ..
          "changed. You're still using your current Library.", result),
        "yb-Reference · Library Folder Not Changed")
      return
    end
    lib = result
  end

  -- Let go of everything reading the old library's files — every library id names
  -- a different sound in the new folder. Pins are untouched: their audio lives
  -- beside the project, not in the library.
  holders.release(state, holders.is_library)
  holders.forget_selection(state, holders.is_library)
  -- The browser's selection is ALWAYS a library id (never a pin), so it's
  -- unconditionally stale here: "s1" in the new library names a different
  -- sound than "s1" in the old one.
  holders.forget_browse(state, holders.is_library)

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
  state.status = string.format("Now using the Library in %s. %d sound%s loaded.",
    new_dir, n, n == 1 and "" or "s")
  local _, now_missing = service.check_files(state)
  if #now_missing == 1 then
    state.status = state.status .. " One sound has a missing audio file."
  elseif #now_missing > 1 then
    state.status = state.status .. string.format(" %d sounds have missing audio files.", #now_missing)
  end
end

local library_picker_pending = false

local function choose_library_folder()
  -- Treat an explicit second click as a retry after a cancelled helper. The OS
  -- dialog owns the REAPER window while genuinely open, so the user cannot
  -- create two active pickers through this path.
  if library_picker_pending then
    reaper_api.cancel_folder_picker()
    library_picker_pending = false
  end
  local dir, pick_err, pending = reaper_api.browse_for_folder(
    "Choose Library Folder", reaper_api.parent_dir(state.library_dir), root, true)
  if dir and dir ~= "" then
    switch_library(dir)
  elseif pending then
    library_picker_pending = true
  elseif pick_err then
    reaper_api.message(pick_err, "yb-Reference · Library Folder Not Changed")
  end
end

local function poll_library_folder()
  if not library_picker_pending then return end
  local done, dir, pick_err = reaper_api.poll_folder_picker()
  if not done then return end

  library_picker_pending = false
  if dir and dir ~= "" then
    switch_library(dir)
  elseif pick_err then
    reaper_api.message(pick_err, "yb-Reference · Library Folder Not Changed")
  end
end

-- Every route that closes the Library converges here (the toggle button, the
-- ✕, Esc, and the walkthrough's own auto-advance) so the teardown is written
-- once. Closing the window stops only what the Library itself started —
-- holders.stop_browse_audition already refuses to touch a main-slot
-- reference, so this never needs to ask which is which.
local function close_browser()
  state.browser_open = false
  holders.stop_browse_audition(state)
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
      -- `proj` for the same reason refpicker records one: PIN ids restart at p1
      -- in every project, so a drag still in flight when the user switches
      -- project tabs would resolve to a different sound on release (Codex,
      -- 2026-08-06). Library ids are global, so this only gates pins.
      state.drag = { sound_id = a.id, name = s and s.name or nil,
        proj = state.pins and state.pins.proj }
    end
  elseif a.type == "drop_sound" then
    drop_sound()
  elseif a.type == "toggle_browser" then
    if state.browser_open then close_browser() else state.browser_open = true end
  elseif a.type == "open_browser" then
    state.browser_open = true
  elseif a.type == "close_browser" then
    close_browser()
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
      state.status = "Couldn't open the Library folder automatically. It's here:  " .. state.library_dir
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
  elseif a.type == "reset_columns" then
    -- ImGui offers no way to set a column's width, so the list is rebuilt under a
    -- new internal name and starts again at the widths the UI asks for. WIDTHS
    -- ONLY since 2026-08-11: the sort is ours now (the header draws its own
    -- arrow — see ui/browser.header_cell), so it no longer lives in the per-table
    -- state ImGui throws away here, and the list stays in the order it was in.
    --
    -- The new number is REMEMBERED (same day): ImGui keeps saved widths per name
    -- forever, so a count that restarted at 0 next run walked back over names it
    -- had already saved widths under — which is why the same menu item gave a
    -- different answer each time it was used.
    state.col_gen = state.col_gen + 1
    reaper_api.set_col_gen(state.col_gen)
  elseif a.type == "step_reference" then
    -- The picker's arrows. Stepping WRAPS (the list is a loop), and it behaves
    -- exactly as clicking a tab used to: it retargets a latched reference live
    -- while the transport rolls, silently while it's stopped.
    local ps = state.pins
    if ps and not ps.load_error then
      local id = pins_core.step(ps.data, state.selected_id, a.delta)
      -- Quiet, like the list's own rows: stepping ARMS the next reference, it
      -- doesn't audition it (user's call, 2026-08-06). Stepping while latched
      -- still retargets live exactly as clicking a tab used to.
      if id then select_sound(id, true) end
    end
  elseif a.type == "reorder_pin" then
    -- The stored order IS the order the arrows step through, so this is real
    -- project data: the service persists it and rolls back if it can't.
    local _, msg = pins_service.reorder_pin(state, a.id, a.to)
    if msg then state.status = msg end
  elseif a.type == "open_refs_folder" then
    -- Settings' Project References row (the bar's folder square until
    -- 2026-08-10). The folder is created if this project has never had
    -- anything pinned — opening a path that doesn't exist yet would just
    -- look like the button did nothing.
    local dir = state.pins and state.pins.dir
    if not dir then
      state.status = "This project hasn't been saved yet, so it has no References folder."
    else
      reaper_api.ensure_dir(dir)
      if not reaper_api.open_folder(dir) then
        state.status = "Couldn't open the folder automatically. It's here:  " .. dir
      end
    end
  elseif a.type == "set_browser_wave_h" then
    -- The audition strip's dragged height, reported once on release (or with
    -- no height at all: the seam's reset gesture, meaning "back to whatever
    -- the default is"). Presentation-only, like the layout mode above.
    local h = a.h and math.floor(a.h + 0.5) or nil
    if h ~= state.browser_wave_h then
      state.browser_wave_h = h
      reaper_api.set_browser_wave_h(h)
    end
  elseif a.type == "select_sound" then
    -- a.quiet = arm it without auditioning. The reference picker sets it on
    -- every route (rows and arrows): choosing what the transport will A/B
    -- against is not a request to hear it right now.
    select_sound(a.id, a.quiet)
  elseif a.type == "browse_sound" then
    browse_sound(a.id)
  elseif a.type == "show_in_library" then
    show_in_library(a.id)
  elseif a.type == "toggle_play" then
    -- Play <-> pause, for whichever window's transport reported it: `target`
    -- names the slot, exactly the way the browser tags its seek (untagged = the
    -- working view). Gated on THAT slot's own sound actually being what's
    -- sounding or paused — there is one live preview and two windows that can
    -- speak, so a Library audition must never answer the working view's button
    -- (or the other way round) even when both are pointed at the same sound.
    local slot = (a.target == "browse") and "browse" or "main"
    local s  = (slot == "browse") and state.browse or state.selected
    local id = (slot == "browse") and state.browse_id or state.selected_id
    if state.preview.playing and state.preview.slot == slot
      and state.preview.sound_id ~= nil and state.preview.sound_id == id then
      pause_playback(slot, id)
    elseif slot == "browse" and state.reference.active then
      -- Same refusal browse_sound and the strip's seek make: sync_reference
      -- re-asserts its own preview every frame, so an audition started here
      -- would just lose the fight one frame later.
      state.status = REF_PLAYING_MSG
    elseif s and holders.paused_on(state, slot, id) then
      resume_playback(slot, s)
    elseif s then
      play_sound(s, 0, slot)
    end
  elseif a.type == "stop_play" then
    -- The separate Stop button: back to the start, no remembered position. It
    -- acts on the SLOT — whatever this window has going — rather than on the
    -- sound the window is pointed at, so a selection that moved on while the
    -- audio kept running can still be stopped (see the note by draw_stop).
    --
    -- The audio is only stopped when it is THIS window's: with a park of our own
    -- but the other window sounding, all we may do is forget the park. Stopping
    -- there would silence the other view's reference from a button that speaks
    -- for this one.
    local slot = (a.target == "browse") and "browse" or "main"
    if state.preview.playing and state.preview.slot == slot then
      holders.stop_playback(state, slot)
    else
      holders.clear_pause(state, slot)
    end
  elseif a.type == "toggle_loop" then
    state.loop = not state.loop
    -- Affect the current preview live — but never a transport-driven reference. That
    -- one is forced to loop for as long as the transport rolls; switching looping off
    -- underneath it would end the reference and leave a muted project in silence.
    if not state.reference.active then preview.set_loop(state.loop) end
  elseif a.type == "toggle_auto" then
    state.auto_audition = not state.auto_audition
  elseif a.type == "toggle_mono" then
    state.mono = not state.mono
    -- Applies to whatever is sounding right now, reference mode included: it is
    -- the same preview path, and a mono check you have to restart the sound to
    -- hear would be useless for the thing it exists for — flicking between mono
    -- and stereo while listening.
    --
    -- Nothing restarts: every routing is already playing and set_mono only
    -- changes which are above silence (see the preview.lua header). Rebuilding
    -- here is what caused the click the user reported on 2026-08-07 — do not
    -- reintroduce it.
    preview.set_mono(state.mono)
  elseif a.type == "toggle_reference" then
    toggle_reference()
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
      if a.commit then
        if is_pin_id(state.selected.id) then
          -- A pin's trim is project data, and a refused store puts the record
          -- back to the value the project actually holds (pins_service owns
          -- that). Hence the live volume below reads the RECORD, not a.db: the
          -- fader and what you hear have to end up agreeing either way.
          local ok, msg = pins_service.commit_trim(state, state.selected)
          if not ok then state.status = msg end
        else
          commit()
        end
      end
      -- Only a "main" playback wears a trim. Matching the id alone isn't enough: the
      -- one live preview may be a BROWSE audition of this very sound, which is
      -- deliberately untrimmed, and riding this fader must not colour it.
      if state.preview.playing and state.preview.slot == "main"
        and state.preview.sound_id == state.selected.id then
        state.preview.trim_db = state.selected.trim_db
        preview.set_volume_db(state.selected.trim_db + state.master_db)
      end
    end
  elseif a.type == "match_trim" then
    -- The match window's headline act: set the armed sound's trim by arithmetic
    -- (the UI computed it through core/match.lua) and remember the target it
    -- aimed at. Setting the trim IS a committed set_trim — one
    -- code path, so a matched trim persists and colours live audio exactly
    -- like a dragged one, and the fader's reset undoes it the same way.
    handle_action({ type = "set_trim", db = a.db, commit = true })
    state.match.target = { unit = a.unit, value = a.value }
    reaper_api.set_match_target(match.encode_target(state.match.target))
    -- When the fader's range clamped it, the full match was NOT set — say so
    -- (fail loud, never silent).
    if a.limited == "range" then
      state.status = string.format(
        "Normalized to +%g dB, the trim fader's maximum. Reaching the target needs more boost.",
        match.TRIM_MAX)
    end
  -- ("match_all_pins" was handled here for a few hours on 2026-08-06 — built,
  -- Codex-hardened with a rollback, then removed the same day at the user's
  -- ask (the button felt off in the match window). core/match.bulk and its
  -- specs remain for a possible return; the handler went with the button so
  -- no unreachable action lingers.)
  elseif a.type == "set_span" then
    -- A start/end handle moved: live while it drags, persisted once on
    -- release or reset — the trim fader's exact save rhythm, and the same
    -- pin-vs-library split. Clamping lives in core/span.lua; the duration the
    -- handles move against is the record's own (what the picture draws by).
    local sel = state.selected
    if sel and type(sel.duration) == "number" and sel.duration > 0 then
      local which = (a.which == "start") and "start" or "finish"
      if a.reset then
        span.set(sel, which, nil, sel.duration)
      elseif a.seconds then
        span.set(sel, which, a.seconds, sel.duration)
      end
      if a.commit or a.reset then
        if is_pin_id(sel.id) then
          -- Project data like the trim, with the same deal on a refused store:
          -- the handles go back to what the project holds (pins_service.commit_span).
          local ok, msg = pins_service.commit_span(state, sel)
          if not ok then state.status = msg end
        else
          commit()
        end
      end

      -- Keep LIVE playback inside the edited frame: the loop's end-point rule
      -- only reacts to a CROSSING, so an end handle dragged behind the rolling
      -- playhead (or a start handle dragged ahead of it) would otherwise leave
      -- audio sounding outside the span the handles claim to control. Pulled
      -- to the start point the moment the edit strands it — while dragging the
      -- start handle rightwards past the playhead this re-triggers each frame,
      -- which usefully reads as scrubbing the start point.
      --
      -- Runs AFTER the commit (Codex, 2026-08-12): a refused store puts the
      -- handles back to what the project holds, and enforcing against the
      -- pre-rollback span would leave audio sounding outside the restored one.
      -- The trim does the same thing for the same reason.
      if state.preview.playing and state.preview.slot == "main"
        and state.preview.sound_id == sel.id then
        local s0, s1 = span.range(sel, state.preview.length)
        local pos = state.preview.position
        if s1 > 0 and (pos >= s1 or pos < s0) then
          preview.seek(s0)
          state.preview.position = s0
        end
      end
    end
  elseif a.type == "add_match_preset" then
    if #state.match.presets < match.PRESET_MAX then
      -- No duplicate targets (user's rule, 2026-08-06). The Add button
      -- already refuses; this guard keeps the list honest regardless of who
      -- asks.
      local dup = false
      for _, p in ipairs(state.match.presets) do
        if p.unit == a.unit and p.value == a.value then dup = true break end
      end
      if not dup then
        table.insert(state.match.presets, { unit = a.unit, value = a.value })
        reaper_api.set_match_presets(match.encode_presets(state.match.presets))
      end
    end
  elseif a.type == "remove_match_preset" then
    if state.match.presets[a.index] then
      table.remove(state.match.presets, a.index)
      reaper_api.set_match_presets(match.encode_presets(state.match.presets))
    end
  elseif a.type == "reorder_match_preset" then
    -- The match window's edit-mode drag (the picker's gesture): the UI has
    -- already turned the insertion gap into a final position through the
    -- tested core arithmetic.
    local list = state.match.presets
    if list[a.from] and type(a.to) == "number" and a.to >= 1 and a.to <= #list then
      table.insert(list, a.to, table.remove(list, a.from))
      reaper_api.set_match_presets(match.encode_presets(list))
    end
  elseif a.type == "pin_sound" then
    -- Pin failures are all non-destructive (already pinned, project not saved yet,
    -- a copy that didn't take) — the status line is the honest place for them.
    -- Arrives from the right-click menu or as a drop on THIS PROJECT; the drop
    -- consumed the drag (clearing a drag that isn't there is a no-op).
    state.drag = nil
    local s = find_sound(a.id)
    if s then
      local ok, msg, pid = pins_service.pin_sound(state, s)
      state.status = msg
      -- Dropping a sound on the working view IS asking for it (user's call,
      -- 2026-08-07) — so it arms itself, exactly as clicking it in the picker
      -- would, auto-audition included. An ALREADY pinned sound arms too: the
      -- gesture said the same thing, and `pid` names the pin it hit.
      if pid then
        select_sound(pid)
        walkthrough.event(state.walkthrough, "sound_pinned")
      end
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
      -- A PIN dropped on a category: copy it into the library and file it there
      -- in one motion (2026-08-06 — this replaced "Save to my library" as a menu
      -- item, because the picker's list deliberately has no right-click menu).
      -- Dedup runs first inside the service, so dropping the same pin twice
      -- files the existing library sound rather than making a second copy.
      save_pin_to_library(a.id, { category = a.category, subcategory = a.subcategory })
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
      -- The FIRST pin this drop produces arms itself (user's call, 2026-08-07:
      -- dropping on the working view means "I want to hear this"). First, not
      -- last, so a multi-file drop arms the one at the top of what arrived
      -- rather than whichever happened to import last.
      local first_pin
      for _, s in ipairs(existing) do
        -- Third return = the pin it already has; only a REAL refusal is news.
        local ok, msg, pid = pins_service.pin_sound(state, s)
        if not ok and not pid then state.status = msg end
        first_pin = first_pin or pid
      end
      for i = before + 1, #state.library.sounds do
        local ok, msg, pid = pins_service.pin_sound(state, state.library.sounds[i])
        if not ok then state.status = msg end
        first_pin = first_pin or pid
      end
      if first_pin then
        select_sound(first_pin)
        walkthrough.event(state.walkthrough, "sound_pinned")
      end
    end
  elseif a.type == "walkthrough" then
    -- Card presses, plus Settings' Show row. "next" covers Start and Done too:
    -- the state machine walks welcome -> stops -> done through one door.
    if a.ev == "skip" then
      walkthrough.skip(state.walkthrough)
    elseif a.ev == "next" then
      walkthrough.next(state.walkthrough)
    elseif a.ev == "show" then
      walkthrough.begin_stops(state.walkthrough)
    else
      -- Anything else is a REAL-ACTION report the card noticed itself (today:
      -- the match window standing open) — it goes to the state machine as the
      -- event it is. Missing this door hung the tour on the match stop: the
      -- card reported "match_opened" every frame, nothing listened, and since
      -- the card returns BEFORE drawing when it reports, the tour looked like
      -- it had vanished while the ring stayed on the button (user, live
      -- 2026-08-10).
      walkthrough.event(state.walkthrough, a.ev)
    end
  elseif a.type == "whatsnew_closed" then
    -- The card was dismissed. Only view cleanup — the seen-mark was already
    -- written when the card was SHOWN (see the startup block), so no dismissal
    -- gesture is load-bearing any more.
    state.whatsnew = nil
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
  elseif a.type == "send_feedback" then
    -- The Help pane's Send. The email is remembered the moment it rides a
    -- report (typed once, never twice — 2026-08-09); the payload is built
    -- pure, and lib/feedback owns delivery and the loud failure from here.
    reaper_api.set_feedback_email(a.email or "")
    state.feedback.email = a.email or ""
    -- Kept for the failure path: the moment a send fails, this text goes to
    -- the machine clipboard even if Settings is long closed (Codex finding).
    state.feedback.last_message = a.message
    local payload = fb_core.payload({
      message = a.message, email = a.email,
      tool = state.update.installed,
      reaper = FB_REAPER_VER,
      install = fb_core.install_kind(state.update.enabled, state.update.disabled_reason),
    })
    if payload then
      -- Re-arm the detector for every deliberate retry. A courier can refuse
      -- immediately, changing failed -> sending -> failed inside this call;
      -- the frame loop would otherwise see failed on both sides and miss it.
      fb_last_phase = nil
      feedback.start(payload)
    end
  elseif a.type == "change_library_dir" then
    if a.dir then switch_library(a.dir) else choose_library_folder() end
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
    try(function() categories.add(state.library, a.name) end, refresh_view, "yb-Reference · Add Category")
  elseif a.type == "add_subcategory" then
    try(function() categories.add(state.library, a.name, a.parent) end, refresh_view, "yb-Reference · Add Subcategory")
  elseif a.type == "import_new_category" then
    -- Files dropped on "+ New category" (2026-08-01): create the category,
    -- then run the normal import into it. Named after the folder the files
    -- came from — the closest thing a drop carries to an intended name; a
    -- rename is one right-click away. `try` saves the new category even if
    -- the import then fails; do_import saves and refreshes on its own.
    local name = (a.paths[1] or ""):match("([^/\\]+)[/\\][^/\\]*$") or "New category"
    local cat
    try(function() cat = categories.add(state.library, name) end, refresh_view,
      "yb-Reference · Add Category")
    if cat then do_import(a.paths, cat.id) end
  elseif a.type == "rename_category" then
    try(function() categories.rename(state.library, a.id, a.name) end, nil, "yb-Reference · Rename Category")
  elseif a.type == "remove_category" then
    try(function() categories.remove(state.library, a.id) end, function()
      if viewing_category(a.id) then state.view = { scope = "all" } end
      refresh_view()
    end, "yb-Reference · Delete Category",
      "This category can't be deleted while it still has sub-categories or sounds in it. Move or remove those first.")
  end
end

-- Best-effort cleanup when REAPER unloads the script: stop playback and un-latch
-- reference mode so the master isn't left muted. Best-effort is the operative word —
-- this never runs on a crash, which is why reference mode also keeps a recovery note
-- on disk (lib/reference.lua). That note, not this, is the real safety net.
-- reference.cleanup() goes FIRST: it is the only one whose failure to run harms the
-- user (a master left muted). If a later destructor throws, the mute is already back.
-- That inverted order is why shutdown is written out by hand instead of going
-- through holders.release — and why a new holder owning a REAPER resource has to be
-- added here (and to the window-closed branch at the end of the loop) as well.
reaper.atexit(function()
  reference.cleanup(); preview.stop(); peaks.cancel(); loudness.cancel()
  reaper_api.cancel_folder_picker()
  dragout.hide_tag() -- a drag in flight when the script is closed leaves no label behind
  -- ...and no throwaway item behind either. This runs on every way the script
  -- ends, a Lua error included — which is the realistic way one could be
  -- stranded (see dragout.hide_ghost on why a REAPER crash needs nothing more).
  dragout.hide_ghost()
end)

-- The browser's open/closed EDGE feeds the walkthrough (stop 1 advances on the
-- real open; a browser stop freezes while it's closed). Watched here, on the
-- state itself, because more than one action can change it (toggle, Esc, the
-- ✕, "Show in library") — one comparison catches every door.
local walk_browser_was = false
-- ...and the walkthrough's own POSITION edge closes the browser when the tour
-- moves on to a main-window stop (user's call, round 2): the latch stop points
-- at the working view's bar, and a Library window left open would cover the
-- very thing being ringed. nil while inactive so a replay can't inherit a
-- stale position.
local walk_pos_was = nil
-- A successful self-restart should terminate this instance immediately. If
-- REAPER accepts the command but leaves the old loop alive, turn the status
-- into a manual fallback instead of claiming that reopening is still underway.
local update_restart_fallback_at = nil

local function loop()
  -- The modern Windows folder dialog runs in a helper process. Polling its tiny
  -- result file keeps REAPER's defer loop alive while the dialog is open.
  poll_library_folder()

  -- Reference mode is shown from the project in front: another tab may own the
  -- one live latch, while this tab's L button stays off and usable. A queued
  -- project restoring here never disturbs a different live owner.
  local ref = state.reference
  local was_current_latched = ref.latched
  local ref_view, ref_recovery, ref_urgent, ref_event = reference.refresh()
  ref.latched, ref.live, ref.pending = ref_view.latched, ref_view.live, ref_view.pending
  ref.owner_name, ref.queued_count = ref_view.owner_name, ref_view.queued_count

  -- Leaving the live owner's tab stops its reference preview. The project stays
  -- muted and latched; returning to it can resume from its own remembered pin.
  -- A closed owner also ends the live slot and becomes a queued recovery.
  if (was_current_latched and not ref.latched) or ref_event.live_ended then
    holders.stop_playback(state, "main")
    ref.active, ref.sound_id, ref.failed_id = false, nil, nil
  end

  -- "This Project" follows the project in front of the user: switching tabs,
  -- opening a project, or Save As re-reads that project's pins (two cheap REAPER
  -- calls and a compare on the frames where nothing changed).
  local pin_refresh = pins_service.refresh(state)
  local pins_warning
  if pin_refresh then
    pins_warning = apply_pins_refresh(pin_refresh)
  end

  if ref_recovery then
    state.status = ref_recovery
    if ref_urgent and ref_recovery ~= reference_alerted then
      reaper_api.message(ref_recovery, "yb-Reference · Reference Mode Needs Attention")
      reference_alerted = ref_recovery
    end
  elseif pins_warning then
    state.status = pins_warning
  end
  if not ref_urgent then reference_alerted = nil end

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
  if state.preview.playing then
    if preview.poll() then
      state.preview.playing = false
      state.preview.sound_id = nil
      state.preview.slot = nil
      state.preview.trim_db = 0
      state.preview.position = 0
      -- NOT `preview.paused`: this is whatever the ONE shared preview was just
      -- sounding (either slot's), which is independent of the per-slot pause
      -- memories (see the preview state init comment) — a sound running out is
      -- not a reason for either window to lose the place it parked.
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
      if pos then
        local prev = state.preview.position
        state.preview.position = pos
        -- The end point, enforced here because the engine has no "stop at"
        -- (loudness tools, 2026-08-06): the working view's playback runs
        -- start -> end. Crossing-only — a playhead the user parked PAST the
        -- end point plays out to the file's edge rather than being cut the
        -- instant it starts (their seek was explicit).
        if state.preview.slot == "main" then
          local s = find_sound(state.preview.sound_id)
          if s and (s.span_start or s.span_end) then
            local s0, s1 = span.range(s, state.preview.length)
            if s1 > 0 and prev < s1 and pos >= s1 then
              -- References always loop; otherwise follow the loop toggle.
              if state.reference.active or state.loop then
                preview.seek(s0)
                state.preview.position = s0
              else
                -- Inside the `slot == "main"` branch: only the working view's
                -- own playback runs start -> end, so only its park is ended.
                holders.stop_playback(state, "main")
              end
            elseif s0 > 0 and pos < prev and pos < s0 then
              -- The engine's own loop wrapped to the file's start (an end
              -- point at the file's edge never trips the crossing above):
              -- pull the new pass up to the start point.
              preview.seek(s0)
              state.preview.position = s0
            end
          end
        end
      end
    end
  end

  -- Build a waveform a slice per frame (never blocks); deliver_wave hands the
  -- finished envelope to every slot that wants that sound.
  state.wave_loading = peaks.pending()
  deliver_wave(peaks.advance())

  -- Hand out the next build. peaks owns exactly ONE job (it holds a live PCM
  -- source across frames), so requesting is done HERE rather than at the moment
  -- a selection changes: with two independent selections, whichever asked last
  -- would cancel the other's job and that slot would then wait forever for an
  -- envelope nobody was building. Queuing here, one at a time, means both slots
  -- always converge. The "asked" mark (holders) stops a file that won't open from
  -- being retried every frame; a deliberate re-pick, or a release, clears it.
  if not peaks.pending() then
    local want, path, slot
    if state.selected and state.waveform.sound_id ~= state.selected_id then
      want, path, slot = state.selected_id, sound_path(state.selected), "main"
    elseif state.browse and state.browse_waveform.sound_id ~= state.browse_id then
      want, path, slot = state.browse_id, sound_path(state.browse), "browse"
    end
    if want and holders.wave_asked(slot) ~= want then
      holders.mark_wave(slot, want)
      peaks.request(want, path)
    end
  end

  -- Measure loudness in the background, one pass per frame.
  step_analysis()

  -- The update feature's heartbeat. During an update it makes no ReaPack calls:
  -- SWS watches the native transaction report, then asks this defer-level owner
  -- to relaunch only after that report has closed and its cleanup grace elapsed.
  local update_intent = updater.tick()
  if update_intent == "restart" then
    if reaper_api.restart_self(CMD_ID) then
      update_restart_fallback_at = reaper.time_precise() + 1
    else
      updater.restart_unavailable()
    end
  elseif update_restart_fallback_at
    and reaper.time_precise() >= update_restart_fallback_at then
    update_restart_fallback_at = nil
    updater.restart_unavailable()
  end

  -- The feedback sender's heartbeat: one compare on an idle frame; a reply-file
  -- poll only while a report is in flight, time-bounded under 10 s. The curl
  -- itself runs in a separate process — nothing here blocks.
  feedback.tick()

  -- The never-silently-lost promise holds OUTSIDE the Feedback pane too: a send
  -- takes up to ~9 s, so the user may close Settings or switch sections before
  -- the answer arrives. Remember the failure until this frame has drawn; only
  -- then do we know whether the pane itself showed its red warning.
  if state.feedback.phase == "failed" and fb_last_phase ~= "failed" then
    -- Copy immediately when SWS offers a machine-wide clipboard call. The pane
    -- has its own ImGui fallback when it is visible; the native notice below
    -- says which outcome actually happened instead of promising a copy that
    -- this installation could not make.
    fb_failure_notice = {
      copied = reaper_api.set_clipboard(state.feedback.last_message or "")
    }
    state.status = "Your feedback couldn't be sent. Your draft is still in Settings \u{2192} Feedback, where you can email it instead."
  end
  fb_last_phase = state.feedback.phase

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
    -- The ghost on the timeline (2026-08-08): REAPER's own picture of the sound,
    -- riding the spot where a release would put it. Only over the arrange —
    -- everywhere else a release cancels, so a picture there would be a promise
    -- the drop wouldn't keep. Driven from here rather than from drop_sound
    -- because it has to follow the mouse, exactly like the cursor and the tag.
    -- Held to the SAME refusal the drop makes (see drop_sound): a pin id means
    -- a different sound in a different project, so a drag still in flight when
    -- the user switches project tabs must not show — it would be a picture of
    -- audio the release is about to refuse to add.
    local stale_pin = is_pin_id(state.drag.sound_id)
      and state.drag.proj ~= (state.pins and state.pins.proj)
    local gs = (target.over_arrange and not stale_pin)
      and find_sound(state.drag.sound_id) or nil
    -- The top slice of a track means "make a NEW track here" (2026-08-08,
    -- REAPER's own behaviour, gated on REAPER's own preference). The strip
    -- REPLACES the ghost while it shows: a ghost sitting on the track below
    -- would be pointing at the wrong place entirely. ui/ draws it from here.
    state.drag.newtrack = gs and dragout.newtrack_zone(target) or nil
    if state.drag.newtrack then gs = nil end
    if gs then
      dragout.show_ghost(target.track, target.position, sound_path(gs), gs.name,
        gs.span_start, gs.span_end)
    else
      dragout.hide_ghost()
    end
  end

  -- The walkthrough's browser edge (see walk_browser_was above). Before the
  -- frame draws, so the stop that advances on "the Library opened" rings its
  -- new target the same frame the window appears.
  if state.browser_open ~= walk_browser_was then
    walk_browser_was = state.browser_open
    walkthrough.event(state.walkthrough,
      state.browser_open and "browser_opened" or "browser_closed")
  end

  -- The walkthrough's stand-in numbers, decided ONCE here and read as a plain
  -- flag by the match window (core/demo.lua owns the conditions: the finale,
  -- and a user with nothing of their own).
  -- Derived per frame rather than remembered, so the moment a real sound lands
  -- the demo is gone with it.
  state.demo = demo.active(state.walkthrough,
    #state.library.sounds > 0,
    (state.pins and state.pins.data and #state.pins.data.pins or 0) > 0,
    state.selected ~= nil)

  local open, action, over_target, give_focus, forward_keys, feedback_visible = app.frame(ctx, state)
  if action then handle_action(action) end

  -- The pane's own fixed red line is enough while the user can see it. In every
  -- other case, use REAPER's native message box: feedback failure is an outcome
  -- of a deliberate Send action, not background chatter, and must not depend on
  -- the Library's clipped status line being open.
  if fb_failure_notice then
    if not feedback_visible then
      local copy_line = fb_failure_notice.copied
        and "Your message is still in Settings \u{2192} Feedback and has also been copied to your clipboard."
        or "Your message is still in Settings \u{2192} Feedback."
      reaper_api.message(
        "Your feedback couldn't be sent.\n\n" .. copy_line ..
        "\n\nYou can email it instead to:\n" .. tostring(state.feedback.address or ""),
        "yb-Reference · Feedback Couldn't Be Sent")
    end
    fb_failure_notice = nil
  end

  -- The walkthrough left the browser stops for a main-window one: close the
  -- Library for them (see walk_pos_was above). After handle_action, so a Next
  -- press or a real pin has already moved the position this same frame. Only
  -- on a REAL transition (walk_pos_was non-nil) — starting the tour never
  -- slams a window the user had open.
  if state.walkthrough.active then
    if walk_pos_was ~= state.walkthrough.pos then
      local cur = walkthrough.current(state.walkthrough)
      if walk_pos_was and type(cur) == "table" and cur.window == "main"
        and state.browser_open then
        close_browser()
      end
      walk_pos_was = state.walkthrough.pos
    end
  else
    walk_pos_was = nil
  end

  -- Hand keyboard focus back to REAPER when the frame says the tool has no
  -- further claim on it (a finished click outside the browsing panes — see
  -- ui/focus.lua for the rules). This is what keeps the user's REAPER hotkeys
  -- working while they click around the tool (2026-08-08, user's ask). After
  -- handle_action, so a drop/import has fully landed before focus moves.
  if give_focus then reaper_api.focus_arrange() end
  -- And while the tool legitimately HOLDS focus (browsing the list, a dropdown
  -- standing open), key presses the tool doesn't use are handed to REAPER's
  -- shortcut system instead — Space still plays the project mid-browse
  -- (2026-08-08 round 3; which keys and when is ui/focus.lua's decision).
  if forward_keys then
    for i = 1, #forward_keys do reaper_api.send_key_to_main(forward_keys[i]) end
  end
  -- Keep the drag cursor and the name tag asserted while a drag is live (REAPER
  -- re-asserts its own cursor constantly, so this must repeat per frame). After
  -- the action handling above, so a drop has already cleared the drag — no
  -- trailing cursor and no tag left hanging over the timeline. hide_tag is a
  -- no-op when nothing is up, so it is safe to call on every idle frame.
  --
  -- The arrange view is not the only place a drop lands: our own windows take
  -- one too (pinning to the project, filing into a category). `over_target` is
  -- the frame just drawn reporting that one of those lit up — without it this
  -- painted the no-entry circle over a target that accepts the drop, and the tag
  -- read "anywhere else cancels" while sitting on exactly such a place
  -- (user-reported 2026-08-07). Over one of ours the tag drops its destination
  -- line entirely: the zone's own dashed outline and pill already name where the
  -- sound is going, in the place the user is looking.
  if state.drag then
    reaper_api.show_drag_cursor(state.drag.over_arrange or over_target)
    dragout.show_tag(state.drag.name, not over_target and state.drag.hint or nil)
  else
    dragout.hide_tag()
    dragout.hide_ghost() -- no drag: never a ghost. Cheap no-op when there is none.
    -- The arrange can be moved or resized between drags, so what the last one
    -- learned about it is thrown away rather than trusted.
    dragout.forget_arrange()
  end
  if open then
    reaper.defer(loop)
  else
    -- Same order and the same reasoning as the atexit handler above (which is
    -- also why this isn't a holders.release): the un-mute leads, everything else
    -- follows.
    reference.cleanup() -- window closed: never leave the project muted behind us
    preview.stop()      -- then stop any sound still playing
    peaks.cancel()      -- and free any half-finished waveform build
    loudness.cancel()   -- and any half-finished loudness measurement
    reaper_api.cancel_folder_picker()
  end
end

reaper.defer(loop)
