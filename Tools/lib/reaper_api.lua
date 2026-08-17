-- reaper_api: the ONLY module that calls REAPER/SWS functions (the ui/ layer is
-- the one exception — it may call reaper.ImGui_* because drawing is its job, and
-- nothing else on reaper.*). Keeping every REAPER-specific call in one place is
-- what lets the rest of the code stay pure and unit-testable.

local reaper_api = {}
local product_error = require("product_error")

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

-- Where the title bar's single "Dock window in Docker" item sends the window: the
-- first docker actually attached to REAPER's main window (2026-08-08, replacing an
-- earlier per-side pick-list — one item is what REAPER's own windows offer).
--
-- FLOATING dockers are skipped deliberately: landing in one is refused (see
-- is_floating_docker), so aiming at one would look like the menu did nothing.
-- Falls back to -1 (docker 0) when REAPER can't report positions or nothing is
-- attached — the same guess ReaImGui's own docking examples make.
function reaper_api.dock_target()
  if not reaper.DockGetPosition then return -1 end      -- REAPER < 6.02
  for i = 0, 15 do                                      -- REAPER has 16 dockers
    local pos = reaper.DockGetPosition(i)                -- -1 invalid, 0..3 a side, 4 floating
    if pos >= 0 and pos <= 3 then return ~i end
  end
  return -1
end

-- Which add-ons are present. ImGui is required to draw anything at all; SWS is
-- required for preview playback; js_ReaScriptAPI is optional (nicer multi-file
-- picker). Feature-detected so a missing requirement becomes a friendly startup
-- guide, not a crash.
function reaper_api.is_windows()
  local os_name = reaper.GetOS()
  return os_name == "Win32" or os_name == "Win64"
end

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
    -- Windows' modern folder-only dialog is launched through ExecProcess. The
    -- old js tree dialog remains a fallback if the Windows helper is blocked.
    folder_picker = reaper.APIExists("ExecProcess")
      or reaper.APIExists("JS_Dialog_BrowseForFolder"),
  }
end

-- Default library folder, under REAPER's user-data folder — never the script's
-- install folder (a ReaPack update overwrites that). User-changeable later.
function reaper_api.default_library_dir()
  return reaper_api.join(reaper.GetResourcePath(), "Data", "yb-Reference")
end

local EXT_SECTION = "yb-Reference"
local LEGACY_EXT_SECTION = "yb_Reference"
-- The product rename left some installs with both old and new preference
-- sections. Keep the library location in its own section so an ambiguous
-- preference file can never make an established install look like first run.
local EXT_LOCATION_SECTION = "yb-Reference-location"
local EXT_LIBDIR  = "library_dir"
local EXT_MASTER  = "master_db"
local EXT_LOUD    = "loud_unit"
local EXT_BROWSER_GEOM = "browser_geom"
local EXT_WAVE_H  = "browser_wave_h"
local EXT_MATCH_PRESETS = "match_presets"
local EXT_MATCH_TARGET  = "match_target"
local EXT_SEEN_VERSION  = "seen_version"
local EXT_FEEDBACK_EMAIL = "feedback_email"
local EXT_WALKTHROUGH   = "walkthrough_seen"
local EXT_COL_GEN       = "col_gen"

local function stored_ext(section, key)
  local value = reaper.GetExtState(section, key)
  return value ~= nil and value ~= "" and value or nil
end

local function install_was_used()
  return stored_ext(EXT_SECTION, EXT_SEEN_VERSION)
    or stored_ext(EXT_SECTION, EXT_WALKTHROUGH)
    or stored_ext(LEGACY_EXT_SECTION, EXT_SEEN_VERSION)
    or stored_ext(LEGACY_EXT_SECTION, EXT_WALKTHROUGH)
end

-- The active library folder and whether it was already remembered. The second
-- answer is the startup safety boundary: a remembered folder going missing must
-- STOP, while a never-configured first run may create the default folder.
function reaper_api.library_dir()
  local stored = stored_ext(EXT_LOCATION_SECTION, EXT_LIBDIR)
  if stored then return stored, true end

  stored = stored_ext(EXT_SECTION, EXT_LIBDIR)
    or stored_ext(LEGACY_EXT_SECTION, EXT_LIBDIR)
  if stored then
    -- One successful read repairs old installs and isolates all future reads
    -- from duplicate preference sections left by the product rename.
    reaper_api.set_library_dir(stored)
    return stored, true
  end

  -- Older builds used the default folder without always recording its path. A
  -- seen version or walkthrough proves this is not first run, so a missing
  -- default must enter recovery instead of being silently recreated.
  return reaper_api.default_library_dir(), install_was_used() and true or false
end

-- Remember the user's chosen library folder (persisted, like the other prefs).
function reaper_api.set_library_dir(path)
  reaper.SetExtState(EXT_LOCATION_SECTION, EXT_LIBDIR, path, true)
  -- Keep the ordinary preference section current for older/dev copies. Startup
  -- never relies on it once the dedicated location record exists.
  reaper.SetExtState(EXT_SECTION, EXT_LIBDIR, path, true)
end

-- The newest version whose release notes this user has been SHOWN — written the
-- moment the What's New card opens (audit fix 2026-08-09; it was written on
-- dismissal, which relied on the user closing the card ITSELF — closing the
-- tool with the card open skipped the write and re-showed the notes forever).
--
-- Empty on a first-ever run, which core.changelog.since reads as "show nothing":
-- a new user has no history to catch up on. The entry script stamps it silently
-- in that case so the NEXT update is the first thing they ever see here.
function reaper_api.seen_version()
  local v = reaper.GetExtState(EXT_SECTION, EXT_SEEN_VERSION)
  return v ~= "" and v or nil
end

function reaper_api.set_seen_version(v)
  if type(v) ~= "string" or v == "" then return end
  reaper.SetExtState(EXT_SECTION, EXT_SEEN_VERSION, v, true)
end

-- Whether the first-open walkthrough has ever been SHOWN (2026-08-10,
-- `.brief/_done/walkthrough/`). Written the moment the welcome card appears —
-- the seen-version lesson applied: no dismissal gesture may be load-bearing,
-- so closing the tool mid-walkthrough ends it for good and Settings > Help
-- replays it on request.
function reaper_api.walkthrough_seen()
  return reaper.GetExtState(EXT_SECTION, EXT_WALKTHROUGH) ~= ""
end

function reaper_api.set_walkthrough_seen()
  reaper.SetExtState(EXT_SECTION, EXT_WALKTHROUGH, "1", true)
end

local function quoted_arg(value)
  value = tostring(value or "")
  if value:find('["\r\n]') then return nil end
  return '"' .. value .. '"'
end

local function readable_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local value = file:read("*a")
  file:close()
  return value
end

local folder_picker_pending
local FOLDER_PICKER_TIMEOUT = 600 -- ample browsing time; still recovers from a dead helper
local folder_picker_request = 0

local function folder_picker_now()
  return reaper.time_precise and reaper.time_precise() or os.clock()
end

local function remove_folder_picker_files(path)
  os.remove(path)
  os.remove(path .. ".tmp")
  os.remove(path .. ".vbs.tmp")
end

local function folder_picker_result_path()
  -- os.tmpname() is allowed to return a relative name. That is unsafe across
  -- REAPER and the external Windows helper because the two processes can resolve
  -- it from different working folders. Keep its unique tail, but anchor the
  -- handoff in REAPER's own absolute user-data path.
  local temporary = os.tmpname()
  os.remove(temporary)
  if not reaper.GetResourcePath then return temporary end

  folder_picker_request = folder_picker_request + 1
  local token = temporary:match("[^\\/]+$") or tostring(folder_picker_request)
  token = token:gsub("[^%w_.-]", "_")
  return reaper_api.join(reaper.GetResourcePath(), "Data",
    string.format("yb_reference_folder_picker_%s_%d.result", token, folder_picker_request))
end

function reaper_api.parent_dir(path)
  if type(path) ~= "string" or path == "" then return nil end
  local parent = path:match("^(.*)[\\/][^\\/]+$")
  if parent and parent:match("^%a:$") then return parent .. SEP end
  return parent
end

-- Windows' Common Item Dialog in folder-only mode. The external helper is
-- launched without waiting: waiting here blocks REAPER's one UI thread for the
-- entire time the dialog is open. Callers poll the result once per defer frame.
-- The fixed client GUID lets Windows remember the last folder and geometry.
-- `force_initial` is reserved for actions such as Settings > Library Folder,
-- where opening at the current library's parent is more useful than that memory.
--
-- Returns (folder, error, pending). The old js dialog is a synchronous fallback,
-- while the modern helper returns pending=true until poll_folder_picker finishes.
function reaper_api.browse_for_folder(title, initial, script_root, force_initial)
  if folder_picker_pending then
    return nil, "A folder picker is already open."
  end

  local helper_error
  local vbs = script_root and reaper_api.join(script_root, "assets", "windows", "folder_picker.vbs")
  local ps1 = script_root and reaper_api.join(script_root, "assets", "windows", "folder_picker.ps1")
  if reaper.APIExists("ExecProcess") and readable_file(vbs) and readable_file(ps1) then
    local result_path = folder_picker_result_path()
    remove_folder_picker_files(result_path)
    local args = {
      quoted_arg(vbs), quoted_arg(ps1), quoted_arg(result_path),
      quoted_arg(title), quoted_arg(initial),
    }
    if args[1] and args[2] and args[3] and args[4] and args[5] then
      if force_initial then args[#args + 1] = quoted_arg("FORCE_INITIAL") end
      local launched = reaper.ExecProcess("wscript.exe //B " .. table.concat(args, " "), -1)
      if launched ~= nil then
        folder_picker_pending = {
          result_path = result_path,
          started_at = folder_picker_now(),
        }
        return nil, nil, true
      end
      helper_error = "The folder picker couldn't be opened."
    end
  end

  -- Safe fallback for machines where PowerShell helpers are blocked by policy.
  if reaper.APIExists("JS_Dialog_BrowseForFolder") then
    local rv, folder = reaper.JS_Dialog_BrowseForFolder(title, initial or "")
    if rv == 1 and folder and folder ~= "" then return folder end
    if rv == 0 then return nil end
  end
  return nil, helper_error or "The folder picker is unavailable. Type the path instead."
end

-- Returns nil with no active request, false while the helper is still open, or
-- true plus its folder/error once it has written the result file.
function reaper_api.poll_folder_picker()
  if not folder_picker_pending then return nil end

  local result = readable_file(folder_picker_pending.result_path)
  if not result then
    if folder_picker_now() - folder_picker_pending.started_at < FOLDER_PICKER_TIMEOUT then
      return false
    end
    local path = folder_picker_pending.result_path
    folder_picker_pending = nil
    remove_folder_picker_files(path)
    return true, nil, "The folder picker stopped responding. Try again."
  end

  remove_folder_picker_files(folder_picker_pending.result_path)
  folder_picker_pending = nil
  if result == "CANCEL" then return true end

  local selected = result:match("^OK\r?\n(.+)$")
  if selected and selected ~= "" then return true, selected end

  local helper_error = result:match("^ERROR\r?\n(.+)$")
  if helper_error then
    return true, nil, product_error.with_details("The folder picker couldn't open the selected folder.", helper_error)
  end
  return true, nil, "The folder picker didn't return a usable folder."
end

-- Test/shutdown hygiene for the small result file. It cannot close Windows'
-- dialog; it only stops this script from accepting a result after it has ended.
function reaper_api.cancel_folder_picker()
  if not folder_picker_pending then return end
  remove_folder_picker_files(folder_picker_pending.result_path)
  folder_picker_pending = nil
end

-- Create a folder and any missing parents. Safe to call when it already exists.
function reaper_api.ensure_dir(path)
  reaper.RecursiveCreateDirectory(path, 0)
end

-- Open the startup folder without turning a disappeared known library into a
-- fresh empty one. Only a genuine first run is allowed to create its default.
function reaper_api.prepare_library_dir(path, remembered)
  if reaper_api.path_exists(path) then return true end
  if remembered then return false end
  reaper_api.ensure_dir(path)
  return reaper_api.path_exists(path)
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

-- REAPER's own version string, e.g. "7.66/x64" (core/feedback strips the
-- platform tail for display — it is always Windows 64-bit here).
function reaper_api.app_version()
  return reaper.GetAppVersion()
end

-- Machine-wide clipboard (SWS). The Send-feedback failure path copies the
-- report the MOMENT it fails, whether or not the Help pane is on screen
-- (Codex, 2026-08-09 — the pane's own ImGui copy only ran when it was next
-- drawn, and a tool closed before then took the draft with it). Returns false
-- where the call is missing; the pane's draw-time copy remains the fallback.
function reaper_api.set_clipboard(text)
  if reaper.CF_SetClipboard then
    reaper.CF_SetClipboard(tostring(text or ""))
    return true
  end
  return false
end

-- The Send-feedback panel's remembered reply email — typed once, riding along
-- ever after (decided 2026-08-09). Persistent ExtState is a line-based ini, so
-- the standing rule applies: the value must never contain a newline (an email
-- can't anyway, but the write enforces it rather than trusting the caller).
function reaper_api.get_feedback_email()
  return reaper.GetExtState(EXT_SECTION, EXT_FEEDBACK_EMAIL)
end

function reaper_api.set_feedback_email(email)
  if type(email) ~= "string" then return end
  reaper.SetExtState(EXT_SECTION, EXT_FEEDBACK_EMAIL, (email:gsub("[\r\n]", "")), true)
end

-- The match window's preset list and remembered target — app preferences like
-- the loudness unit, stored as the one-line text core/match.lua encodes and
-- decodes. This layer only ferries the strings; what they mean (and whether
-- stored garbage still means anything) is core's question.
function reaper_api.get_match_presets()
  local v = reaper.GetExtState(EXT_SECTION, EXT_MATCH_PRESETS)
  return v ~= "" and v or nil
end

function reaper_api.set_match_presets(text)
  reaper.SetExtState(EXT_SECTION, EXT_MATCH_PRESETS, text, true)
end

function reaper_api.get_match_target()
  local v = reaper.GetExtState(EXT_SECTION, EXT_MATCH_TARGET)
  return v ~= "" and v or nil
end

function reaper_api.set_match_target(text)
  if text then
    reaper.SetExtState(EXT_SECTION, EXT_MATCH_TARGET, text, true)
  else
    reaper.DeleteExtState(EXT_SECTION, EXT_MATCH_TARGET, true)
  end
end

-- The working-view layout setting retired on 2026-08-06 (the reference-picker
-- redesign): the bar sits on the bottom, full stop — there is no arrangement
-- left to choose between, so there is nothing to remember. Any value an older
-- build left in ExtState is simply never read again.

-- The browser audition strip's dragged height (px of waveform bars). nil when
-- the user has never resized it — or has reset it — so the UI falls back to
-- its default token instead of a frozen copy that would shadow a future
-- default change. Garbage in the stored slot reads as unset, never trusted.
function reaper_api.get_browser_wave_h()
  local n = tonumber(reaper.GetExtState(EXT_SECTION, EXT_WAVE_H))
  if n and n > 0 then return n end
  return nil
end

function reaper_api.set_browser_wave_h(h)
  if h then
    reaper.SetExtState(EXT_SECTION, EXT_WAVE_H, tostring(math.floor(h + 0.5)), true)
  else
    reaper.DeleteExtState(EXT_SECTION, EXT_WAVE_H, true)
  end
end

-- How many times the sound table's columns have been reset to their defaults.
-- It is not a statistic: it is part of the name the table is filed under in
-- ImGui's own settings, and ImGui hands a table back the widths saved under its
-- name (see ui/browser.sounds_table_id).
--
-- PERSISTED since 2026-08-11 (user-reported: "Reset column widths" gave a
-- different result each time it was used). It used to restart at 0 every run, so
-- a reset stepped onto a name this REAPER already had widths saved under — from
-- whatever the user had dragged them to in an earlier session — and restored
-- THOSE instead of the defaults. Seven such sets were sitting in one test
-- machine's settings file. Counting on from where the last session left off is
-- what makes every reset land on a name ImGui has never seen, which is the only
-- state that means "the widths the code asks for".
function reaper_api.get_col_gen()
  local n = tonumber(reaper.GetExtState(EXT_SECTION, EXT_COL_GEN))
  if n and n >= 0 then return math.floor(n) end
  return 0
end

function reaper_api.set_col_gen(n)
  reaper.SetExtState(EXT_SECTION, EXT_COL_GEN, tostring(math.floor(n)), true)
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

-- Open a FOLDER in the OS file browser — the working view's folder square, which
-- opens this project's References folder (where every pinned copy lives).
-- Same shape as reveal_file above: SWS's clean shell call first, Explorer as the
-- fallback, and an honest false when neither is available so the caller can say
-- where the folder is instead of looking like the button did nothing.
function reaper_api.open_folder(dir)
  if not dir or dir == "" then return false end
  if reaper.APIExists("CF_ShellExecute") then
    reaper.CF_ShellExecute(dir)
    return true
  end
  if SEP == "\\" then
    os.execute('explorer "' .. dir .. '"')
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

-- Hand keyboard focus back to REAPER (2026-08-08): called by the entry script
-- whenever ui/focus.lua decides a finished click has no further claim on the
-- keyboard, so the user's REAPER hotkeys keep working while they use the tool.
--
-- Targets the ARRANGE VIEW child window ("trackview"), not the main window:
-- with a MIDI editor docked into the main window, focusing "the main window"
-- hands focus to the docked MIDI editor instead — a failure documented in the
-- wild and re-derived in docs/RESEARCH.md ("Keyboard focus"). Falls back to
-- the main window only when the child can't be found.
--
-- SWS-only on purpose (BR_Win32_*, all verified present in the installed DLL):
-- the tool already requires SWS for preview playback, and js_ReaScriptAPI must
-- stay optional. Without SWS this quietly does nothing — the tool then simply
-- behaves as before (focus stays where the OS put it).
--
-- Same-thread Win32 rule works FOR us here: ReaScript runs on REAPER's UI
-- thread, so SetFocus between REAPER's own windows is always legal, and it can
-- never steal focus from another application.
function reaper_api.focus_arrange()
  if not (reaper.APIExists("BR_Win32_SetFocus")
      and reaper.APIExists("BR_Win32_FindWindowEx")
      and reaper.APIExists("BR_Win32_HwndToString")) then
    return false
  end
  local main = reaper.GetMainHwnd()
  -- BR_Win32 passes window handles as strings; "0" = start of the child list.
  -- Search by the child's NAME ("trackview" — stable across REAPER versions and
  -- platforms), not its class, matching the pattern proven by other scripts.
  local arrange = reaper.BR_Win32_FindWindowEx(reaper.BR_Win32_HwndToString(main),
    "0", "", "trackview", false, true)
  reaper.BR_Win32_SetFocus(arrange or main)
  return true
end

-- Hand a single key press to REAPER's shortcut system (2026-08-08, round 3 of
-- the keyboard-focus work): while one of our windows HOLDS focus — browsing
-- the list, a dropdown standing open — the user's REAPER hotkeys must still
-- work, and this is how. SWS's CF_SendActionShortcut runs whatever action the
-- given section has bound to the key, no OS focus involved. `vk` is a Windows
-- virtual-key code; modifiers are deliberately NOT passed — the documented nil
-- means "read from keyboard", so a physically held Ctrl/Shift/Alt rides along
-- and chords resolve exactly as REAPER would. Section 0 = the Main section.
-- ui/focus.lua decides WHICH keys and WHEN; this only delivers.
function reaper_api.send_key_to_main(vk)
  if not reaper.APIExists("CF_SendActionShortcut") then return false end
  return reaper.CF_SendActionShortcut(reaper.GetMainHwnd(), 0, vk)
end

-- Native REAPER message box. Works even when SWS and ImGui are absent, so it's
-- the right tool for the setup guides that must appear before (or instead of) the
-- ImGui window.
function reaper_api.message(text, title)
  reaper.ShowMessageBox(text, title or "yb-Reference", 0)
end

-- Can this REAPER cleanly restart a running script — terminate it and start a
-- fresh instance from disk, with no "already running" prompt? REAPER 7's
-- set_action_options is the mechanism, live-proven by the update harness's
-- restart probe (yb-reapack-test tests/10_restart_probe.lua, 2026-08-05).
function reaper_api.can_restart()
  return reaper.set_action_options ~= nil and reaper.Main_OnCommand ~= nil
end

-- Restart the tool (the post-update popup's one-click finish). Armed HERE, at
-- restart time, not at startup — so an ordinary re-run of the action while the
-- tool is open keeps REAPER's default behaviour. The re-invoke makes REAPER
-- terminate this instance (its atexit cleanup runs: previews stopped,
-- reference mode restored) and launch a fresh one, which loads the CURRENT
-- files from disk — the updated code. Call from the defer level, the exact
-- shape the probe proved. Returns false when the mechanism (or a real command
-- id) is missing; the UI shouldn't have offered the button then
-- (state.can_restart), so this refusal is belt-and-braces.
function reaper_api.restart_self(cmd_id)
  if not reaper_api.can_restart() then return false end
  if not cmd_id or cmd_id == 0 then return false end
  reaper.set_action_options(1 | 2)
  reaper.Main_OnCommand(cmd_id, 0)
  return true
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
    return false, "Couldn't copy the file because a file that Windows considers the same name " ..
      "already exists at the destination: " .. dest .. "."
  end
  local inp, ierr = io.open(src, "rb")
  if not inp then
    return false, product_error.with_details("Couldn't read the source file.", ierr)
  end
  local out, oerr = io.open(dest, "wb")
  if not out then
    inp:close()
    return false, product_error.with_details("Couldn't create the destination file.", oerr)
  end
  while true do
    -- A read returns nil at the end of the file AND on a read error, so the two
    -- have to be told apart: treating a failed read as "finished" would leave a
    -- truncated copy that every later step reports as a success.
    local chunk, rerr = inp:read(1024 * 1024)
    if not chunk then
      if rerr then
        inp:close(); out:close(); os.remove(dest)
        return false, product_error.with_details("Couldn't finish reading the source file.", rerr)
      end
      break
    end
    local ok, werr = out:write(chunk)
    if not ok then
      inp:close(); out:close(); os.remove(dest)
      return false, product_error.with_details("Couldn't write the destination file.", werr)
    end
  end
  inp:close()
  local closed, cerr = out:close() -- close is where a full disk actually surfaces
  if not closed then
    os.remove(dest)
    return false, product_error.with_details(
      "Couldn't finish writing the destination file. The drive may be full.", cerr)
  end
  return true
end

-- Is there already something at this path? Opening it answers for anything we can
-- read; renaming a name to itself answers for the rest (that can only succeed if
-- something is there), which catches a folder, or a file we may see but not read.
function reaper_api.path_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  -- Windows DIRECTORIES answer through their "nul" device: opening "<dir>\nul"
  -- succeeds exactly when the directory exists, held-open files inside or not.
  -- The rename fallback below is WRONG for a directory here — Windows refuses
  -- to rename a folder (even to its own name) while ANY process holds ANY file
  -- inside it open, and a playing preview, a peaks build or a sync tool doing
  -- exactly that made the startup gate refuse a library that was sitting right
  -- there (live failure 2026-08-08, reproduced with a locked file in a test
  -- folder). A FILE path with "\nul" appended simply fails to open and falls
  -- through, so file semantics are unchanged.
  if SEP == "\\" then
    local probe = io.open(path .. "\\nul", "r")
    if probe then probe:close(); return true end
  end
  return os.rename(path, path) == true
end

function reaper_api.directory_exists(path)
  if SEP == "\\" then
    local probe = io.open(path .. "\\nul", "r")
    if not probe then return false end
    probe:close()
    return true
  end
  return os.rename(path, path) == true
end

-- A new library may only be created in a directory with no files or child
-- folders. Returns nil when the path is not a directory, false when occupied.
function reaper_api.directory_is_empty(path)
  if not reaper_api.directory_exists(path) then return nil end
  if reaper.EnumerateFiles(path, 0) ~= nil then return false end
  if reaper.EnumerateSubdirectories(path, 0) ~= nil then return false end
  return true
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
    return false, "Couldn't move the file because another file already exists at the destination: " ..
      dest .. "."
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
    local ok, list = reaper.JS_Dialog_BrowseForOpenFiles("Add Sounds to Library", "", "", "", true)
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
  local ok, fn = reaper.GetUserFileNameForRead("", "Add a Sound to Library", "")
  if not ok or not fn or fn == "" then return nil end
  return { fn }
end

return reaper_api
