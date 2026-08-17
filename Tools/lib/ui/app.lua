-- app: owns the ImGui context and the per-frame draw. This is a ui/ module, so
-- calling reaper.ImGui_* is its job — keeping every ImGui call out of the entry
-- script, which owns only the shared state and the defer loop. This is the
-- architecture boundary: reaper_api touches reaper.*, ui/ touches ImGui, nothing
-- crosses over.

local theme    = require("ui.theme")
local window   = require("ui.window")
local browser  = require("ui.browser")
local dropzone = require("ui.dropzone")
local newtrack_strip = require("ui.newtrack_strip")
local settings = require("ui.settings")
local whatsnew = require("ui.whatsnew")
local focus    = require("ui.focus")
local walkthrough_ui = require("ui.walkthrough")

local app = {}

-- ImGui resources that must be created ONCE and reused every frame (never inside
-- the frame loop — per-frame creation crashes ReaImGui). Held here, not on the
-- shared state, so nothing outside ui/ can touch an ImGui object.
local res = {}

-- Feature detection for the browser popup's window behaviour (Phase 5.7 Stage 3).
-- Checked once at load, not per frame — same idiom as browser.lua's HAS_COL_HOVER.
local HAS_NO_DOCK    = reaper.ImGui_WindowFlags_NoDocking ~= nil
local HAS_WIN_FOCUS  = reaper.ImGui_IsWindowFocused ~= nil
local HAS_FOCUS_SCOPE = reaper.ImGui_FocusedFlags_RootAndChildWindows ~= nil
local HAS_ESCAPE     = reaper.ImGui_IsKeyPressed ~= nil and reaper.ImGui_Key_Escape ~= nil
local HAS_POPUP_GUARD = reaper.ImGui_IsPopupOpen ~= nil
  and reaper.ImGui_PopupFlags_AnyPopupId ~= nil and reaper.ImGui_PopupFlags_AnyPopupLevel ~= nil
local HAS_DOCK_MENU = reaper.ImGui_SetNextWindowDockID ~= nil
  and reaper.ImGui_IsWindowDocked ~= nil
  and reaper.ImGui_OpenPopup ~= nil and reaper.ImGui_BeginPopup ~= nil
local HAS_DOCK_ID = reaper.ImGui_GetWindowDockID ~= nil
  and reaper.ImGui_SetNextWindowDockID ~= nil
local HAS_NO_COLLAPSE = reaper.ImGui_WindowFlags_NoCollapse ~= nil

-- Dock change to apply before the next Begin. Two ImGui rules force the one-frame
-- delay: SetNextWindowDockID only works BEFORE Begin, while GetWindowDockID (and
-- the menu click that decides the change) only happen INSIDE the window — so a
-- request made this frame lands at the top of the next one.
local pending_dock

-- Where the window was docked last frame, so a CHANGE can be reported once
-- instead of every frame. Starts as false (not 0) so the very first frame always
-- counts as a change and gets checked — a session that opens already docked has
-- to be judged too, not just docks made while running.
local last_dock_id = false

-- Where each window sat last frame (screen rect), so an in-flight OS files
-- drag can be matched to the window it hovers BEFORE that window's Begin runs.
-- View-only scratch: nothing outside this file reads it, and a stale rect only
-- ever costs one frame of focus-grab accuracy.
local last_rect = {}

-- OS file drops only land once one of our windows has been clicked (user-
-- confirmed 2026-08-01). A full read of the ReaImGui + Dear ImGui source found
-- NO focus gate — every part of the drop pipeline is focus-independent on
-- paper — so the mechanism is unknown (likely inside REAPER itself). Deliberate
-- workaround: the moment a files payload hovers one of our windows, that
-- window is given focus for its next Begin — exactly the state the user's
-- manual click produced, minus the click. Raising the tool mid-drag is the
-- accepted side effect. GetDragDropPayloadFile is the ONE call that truly
-- peeks an OS files payload from anywhere (see dropzone.lua on why
-- GetDragDropPayload can never see it).
local HAS_DRAG_FOCUS = reaper.ImGui_GetDragDropPayloadFile ~= nil
  and reaper.ImGui_SetNextWindowFocus ~= nil
local function files_drag_window(ctx, state)
  if not state.deps.imgui_drop or not HAS_DRAG_FOCUS then return nil end
  if state.drag then return nil end
  if not reaper.ImGui_GetDragDropPayloadFile(ctx, 0) then return nil end
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local function inside(r)
    return r and mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h
  end
  -- The browser wins an overlap: while open it sits above the working view.
  if state.browser_open and inside(last_rect.browser) then return "browser" end
  if inside(last_rect.main) then return "main" end
  return nil
end

-- Ask for a return to a normal floating window. Called by the entry script when
-- it finds the tool sitting in one of REAPER's floating dockers (see
-- reaper_api.is_floating_docker) — the ui/ layer can't make that call itself.
function app.request_undock()
  pending_dock = 0
end

-- Create the ImGui context and turn on docking if the ReaImGui build supports it
-- (feature-detected — an older build simply stays floating instead of erroring).
-- `font_path` is the bundled Lucide icon font; loaded here so the icon system has
-- it. All resources are created ONCE here, never in the frame loop.
function app.create_context(font_path)
  local ctx = reaper.ImGui_CreateContext("yb-Reference")
  -- Feature detection by looking the ImGui function up directly (nil = absent), the
  -- same idiom as window.lua's HAS_COL_HOVER — NOT reaper.APIExists, which is a
  -- non-ImGui call this ui/ module isn't allowed to make.
  if reaper.ImGui_ConfigVar_Flags ~= nil
    and reaper.ImGui_ConfigFlags_DockingEnable ~= nil then
    local flags = reaper.ImGui_ConfigVar_Flags()
    local current = reaper.ImGui_GetConfigVar(ctx, flags)
    reaper.ImGui_SetConfigVar(ctx, flags, current | reaper.ImGui_ConfigFlags_DockingEnable())
    -- REAPER-style docking only (2026-07-30): ImGui's default docking also lets
    -- a dragged window SPLIT an area into sub-panels — REAPER never does that,
    -- and a stray drop on a split target trapped the window inside a floating
    -- panel of its own. NoSplit strips the drag overlay down to the one
    -- "become a tab here" target: a drop on a REAPER docker docks as a docker
    -- tab, a drop anywhere else is just a window move.
    if reaper.ImGui_ConfigVar_DockingNoSplit ~= nil then
      reaper.ImGui_SetConfigVar(ctx, reaper.ImGui_ConfigVar_DockingNoSplit(), 1)
    end
    -- Go transparent while being dragged for a dock (2026-07-30): the drop spot
    -- is a narrow strip the library gives no cue for, and the window being moved
    -- was covering the one marker that does appear.
    if reaper.ImGui_ConfigVar_DockingTransparentPayload ~= nil then
      reaper.ImGui_SetConfigVar(ctx, reaper.ImGui_ConfigVar_DockingTransparentPayload(), 1)
    end
  end
  -- ImGui's own keyboard navigation OFF (2026-08-08). ReaImGui 0.10 turned it
  -- on by default, which quietly claims the arrow keys, Tab and Space for a
  -- widget-highlight system this tool never designed for — and its claim also
  -- reports the window as "using the keyboard", which would fight the focus
  -- handoff (ui/focus.lua) that keeps REAPER's hotkeys working. This tool's
  -- keyboard story is deliberate and small: arrows browse the browser's lists
  -- (ui/browser.lua reads them directly), typed text goes to text fields, and
  -- every other key belongs to REAPER.
  if reaper.ImGui_ConfigVar_Flags ~= nil
    and reaper.ImGui_ConfigFlags_NavEnableKeyboard ~= nil then
    local flags = reaper.ImGui_ConfigVar_Flags()
    local current = reaper.ImGui_GetConfigVar(ctx, flags)
    reaper.ImGui_SetConfigVar(ctx, flags, current & ~reaper.ImGui_ConfigFlags_NavEnableKeyboard())
  end
  -- One list clipper for the sound list, attached so it survives across frames.
  res.clipper = reaper.ImGui_CreateListClipper(ctx)
  reaper.ImGui_Attach(ctx, res.clipper)

  -- The BOLD cut of the UI font — the one thing the app could not draw before
  -- 2026-08-09, and what section headings now lead with
  -- (`.brief/font-and-hierarchy`, the user's own pick).
  --
  -- Only the bold cut is created. ReaImGui's context ALREADY defaults to the
  -- system sans-serif face (`src/context.cpp`: `m_font {new SysFont
  -- {SysFont::SANS_SERIF}}` -> `io.FontDefault`), so the regular text font is
  -- Segoe UI here and the OS's own face elsewhere with nothing asked for. A
  -- CreateFont("sans-serif") for the regular weight was written the same day and
  -- removed within the hour: it requested exactly what was already in place.
  -- **Dear ImGui's own default is ProggyClean; ReaImGui overrides it. Do not
  -- reason about this tool's text from upstream ImGui's defaults** — that
  -- mistake produced a whole wrong diagnosis of why small text was hard to read
  -- (it was small, not blurry: the face was always scalable).
  --
  -- Optional, the house idiom: too-old ReaImGui, no FontFlags_Bold, or a face
  -- the OS can't produce a bold cut for, and this stays nil —
  -- theme.push_heading_font then falls back to the regular small font, so a
  -- heading is merely un-emphasised rather than missing.
  --
  -- Gated on CreateFontFromFile — the same 0.10 marker the icon font below
  -- uses — NOT on CreateFont existing: CreateFont is far older, but pre-0.10
  -- its signature was (family, SIZE, flags). There this call would read the
  -- bold flag as a font SIZE and hand back a poisoned 1–2px regular font that
  -- pushes without error, drawing every heading as a speck (2026-08-09 Fable
  -- review; the fallback promise above only holds if this stays nil there).
  if reaper.ImGui_CreateFontFromFile ~= nil
    and reaper.ImGui_CreateFont ~= nil and reaper.ImGui_FontFlags_Bold ~= nil then
    local ok, bold = pcall(reaper.ImGui_CreateFont, "sans-serif", reaper.ImGui_FontFlags_Bold())
    if ok and bold then
      reaper.ImGui_Attach(ctx, bold)
      res.ui_font_bold = bold
      theme.set_heading_font(bold)
    end
  end

  -- The Lucide icon font. Needs ReaImGui 0.10+ (CreateFontFromFile); an older build
  -- or a missing file leaves res.icon_font nil and the icons fall back to drawn
  -- shapes. pcall so a bad font file can't stop the whole tool from opening.
  if font_path and reaper.ImGui_CreateFontFromFile ~= nil then
    local ok, font = pcall(reaper.ImGui_CreateFontFromFile, font_path, 0)
    if ok and font then
      reaper.ImGui_Attach(ctx, font)
      res.icon_font = font
    end
  end

  return ctx
end

-- Reference mode's red WINDOW OUTLINE is gone (2026-08-06, user's call): the
-- latch button is the only thing that goes red now. Colouring the window chrome
-- for a mode was the part of the old grammar the user disliked, and dropping it
-- also retires the "REF_RED is reserved, nothing else may be red" rule that
-- forced every other red decision through an exception.
--
-- Draw one frame. Returns whether the window is still open (false once the user
-- closes it) so the entry script's defer loop knows when to stop.
--
-- End is called only when Begin reports the window visible. That is ReaImGui's
-- contract — its own demo does `if not rv then return end` and skips End when the
-- window is collapsed — NOT the upstream C++ "always call End" rule.
-- Returns the main-window state, any user action, drag/focus details, and
-- whether the Feedback pane was visible. The entry script uses that last fact
-- to avoid covering an in-pane failure warning with a native message box.
-- `action` is user intent only — the UI never acts on the library itself.
-- `over_target` reports that a drop target inside one of
-- our windows lit up this frame, which the entry script needs before it asserts
-- REAPER's own drag cursor (see ui/dropzone.take_hand_shown).
function app.frame(ctx, state)
  -- Focus bookkeeping first (ui/focus.lua): which mouse presses landed on one
  -- of our windows is read at the top of the frame, before any window draws;
  -- the give-focus-back decision is read at the very end.
  focus.frame_begin(ctx)
  local nc, nv, nf = theme.apply(ctx)

  -- A drag out to the arrange view ends wherever the mouse is let go — usually well
  -- outside this window. Watched here, before Begin, so a collapsed or docked
  -- window can't swallow the release and leave the drag stuck on forever.
  --
  -- Deliberately "the button is no longer down" rather than "the button was just
  -- released this frame": if the release edge is ever missed (focus taken away
  -- mid-drag, mouse capture lost), the edge never comes back, and the drag would
  -- hang on for the rest of the session. This condition keeps being true until it
  -- is dealt with, so it always recovers.
  local action
  if state.drag and not reaper.ImGui_IsMouseDown(ctx, 0) then
    action = { type = "drop_sound" }
  end
  -- While a drag is in flight, ImGui owns the cursor over its own window. Over
  -- the tool a release CANCELS the drag, so the honest cursor here is the
  -- no-entry sign (the hand appears out over the arrange view, where the drop
  -- lands — see reaper_api.show_drag_cursor). Feature-detected; an older
  -- ReaImGui without NotAllowed keeps the plain arrow. Skipped on the release
  -- frame itself (`action` is set), so the cursor doesn't trail past the drop.
  if state.drag and not action and reaper.ImGui_MouseCursor_NotAllowed ~= nil then
    reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_NotAllowed())
  end

  -- A dock/undock asked for by last frame's menu (see the dock menu below).
  if pending_dock then
    reaper.ImGui_SetNextWindowDockID(ctx, pending_dock)
    pending_dock = nil
  end

  -- The files-drag focus grab (see files_drag_window above): decided once per
  -- frame, applied to whichever window the drag is over.
  local drag_focus = files_drag_window(ctx, state)
  if drag_focus == "main" then reaper.ImGui_SetNextWindowFocus(ctx) end

  reaper.ImGui_SetNextWindowSize(ctx, 900, 600, reaper.ImGui_Cond_FirstUseEver())
  -- Floor the floating size (tokens.md "Floating window minimum"): the window
  -- can't be dragged down to nothing, and a squashed size persisted by ImGui's
  -- ini is clamped back to usable on the next open instead of reopening broken.
  -- Applies every frame (no FirstUseEver variant exists); docked windows are
  -- sized by their dock node and ignore it, which is fine — the layout itself
  -- degrades gracefully when docked narrow. Feature-detected like the other
  -- ImGui lookups here: an older build just goes without the floor.
  if reaper.ImGui_SetNextWindowSizeConstraints ~= nil
    and reaper.ImGui_NumericLimits_Float ~= nil then
    local _, flt_max = reaper.ImGui_NumericLimits_Float()
    reaper.ImGui_SetNextWindowSizeConstraints(ctx,
      theme.metrics.MIN_WIN_W, theme.metrics.MIN_WIN_H, flt_max, flt_max)
  end
  -- No collapse arrow in the title bar (2026-07-30): this window has nothing to
  -- fold away to, so the arrow was one more thing to hit by accident. It also
  -- stops a double-click on the title bar collapsing the window.
  local main_flags = HAS_NO_COLLAPSE and reaper.ImGui_WindowFlags_NoCollapse() or 0
  -- Centred title. This REVERSES the 2026-08-07 split that gave the Loudness panel
  -- a centred title and left the two big windows' titles reading as a label on
  -- the left — the user's call on 2026-08-08: every panel in the tool wears its
  -- name the same way, full stop.
  local visible, open = theme.begin_window(ctx, state.win_title, true, main_flags, true)
  local dock_id   -- read inside the window; GetWindowDockID only works there
  if visible then
    -- This frame's rect, for next frame's files-drag focus grab.
    local mwx, mwy = reaper.ImGui_GetWindowPos(ctx)
    last_rect.main = { x = mwx, y = mwy,
      w = reaper.ImGui_GetWindowWidth(ctx), h = reaper.ImGui_GetWindowHeight(ctx) }
    -- ALWAYS draw, then merge — never `action = action or window.draw(...)`, which
    -- short-circuits in Lua and would skip the entire draw for that frame, blanking
    -- the window. The release wins the merge: it's a one-off event, while anything
    -- the frame reports can be reported again next frame. EXCEPT when the frame
    -- reports an in-window drop target caught that same release (`wins_release`)
    -- — then the drop on the row is the user's intent, not the generic "drag
    -- ended" this pre-Begin watcher turned into.
    local frame_action = window.draw(ctx, state, res)
    if frame_action and frame_action.wins_release then
      action = frame_action
    else
      action = action or frame_action
    end

    -- "Dock window in Docker", the way native REAPER windows offer it — and ONLY
    -- from the title bar (decided 2026-07-30): the item must not appear on a
    -- right-click anywhere else in the panel. ImGui has no title-bar context
    -- menu, so the hit test is done by hand. Two facts make it exact rather than
    -- guesswork: a title bar is `GetFrameHeight` tall (both are font size + two
    -- frame paddings), and a DOCKED window has no title bar at all — hence the
    -- IsWindowDocked guard, which also means the only path back out of a docker
    -- is dragging the window out, the gesture NoSplit just made reliable.
    if HAS_DOCK_MENU and not reaper.ImGui_IsWindowDocked(ctx) then
      -- On RELEASE, not press: that's the platform convention ImGui's own context
      -- menus follow, and it stops a right-drag of the title bar from spawning one.
      if reaper.ImGui_IsMouseReleased(ctx, 1) and reaper.ImGui_IsWindowHovered(ctx) then
        local wx, wy = reaper.ImGui_GetWindowPos(ctx)
        local mx, my = reaper.ImGui_GetMousePos(ctx)
        if my >= wy and my < wy + reaper.ImGui_GetFrameHeight(ctx)
          and mx >= wx and mx < wx + reaper.ImGui_GetWindowWidth(ctx) then
          reaper.ImGui_OpenPopup(ctx, "dock_menu")
        end
      end
      if reaper.ImGui_BeginPopup(ctx, "dock_menu") then
        -- ONE item, exactly like REAPER's own windows offer (user's call,
        -- 2026-08-08): the earlier submenu listing every docker by side was more
        -- choice than the gesture is worth. state.dock_target is the docker it
        -- goes to (the entry script picks it from REAPER's own docker list);
        -- from there, dragging the window out is the way back.
        if reaper.ImGui_MenuItem(ctx, "Dock Window In Docker") then
          pending_dock = state.dock_target or -1
        end
        reaper.ImGui_EndPopup(ctx)
      end
    end

    -- (The post-update restart popup used to be announced from here. It is gone:
    -- an update now restarts the tool the moment it lands, and the What's New
    -- card greets the new code on the way back up — see whatsnew.draw below.)

    -- The walkthrough's pin stop rings the WHOLE window — it is one big
    -- drop-to-pin target, and the ring finally shows the gesture.
    walkthrough_ui.note_rect(ctx, state.walkthrough, "pin",
      mwx, mwy, mwx + last_rect.main.w, mwy + last_rect.main.h)
    -- The walkthrough's spotlight over this window (no-op unless it's active).
    -- Inside the Begin scope on purpose: the wash reads this window's rect and
    -- draws into its viewport's foreground list.
    walkthrough_ui.wash(ctx, state.walkthrough, "main")

    if HAS_DOCK_ID then dock_id = reaper.ImGui_GetWindowDockID(ctx) end

    reaper.ImGui_End(ctx)
  end

  -- Report a CHANGE of dock, so the entry script can ask REAPER what kind of
  -- docker it is (only it may call reaper.* — see reaper_api.is_floating_docker)
  -- and bounce us out of a floating one via app.request_undock.
  --
  -- `last_dock_id` is deliberately NOT updated unless the report actually goes
  -- out: if another action wins this frame's single slot, the change is still
  -- pending and gets reported again next frame. Losing it once would leave the
  -- tool parked in a floating docker for the rest of the session.
  if dock_id and dock_id ~= last_dock_id then
    if not action then
      action = { type = "dock_changed", dock_id = dock_id }
      last_dock_id = dock_id
    end
  end

  -- The browser popup (Phase 5.7 Stage 3): its own Begin/End pair, same ctx,
  -- drawn only while state.browser_open. Floating only — never docked, so a
  -- curation popup can't be folded into REAPER's own docker and confused for
  -- part of the permanent layout the working view occupies. Geometry restored
  -- from state.browser_geom (nil the first time this project's user ever opens
  -- it, or on an ancient ReaImGui) with Cond_FirstUseEver, so ImGui's own .ini
  -- memory and ours coexist — whichever ran first just gets overridden by
  -- FirstUseEver's usual "only if this window has no prior state" rule.
  if state.browser_open then
    if state.browser_geom then
      local g = state.browser_geom
      reaper.ImGui_SetNextWindowPos(ctx, g.x, g.y, reaper.ImGui_Cond_FirstUseEver())
      reaper.ImGui_SetNextWindowSize(ctx, g.w, g.h, reaper.ImGui_Cond_FirstUseEver())
    else
      reaper.ImGui_SetNextWindowSize(ctx, 720, 520, reaper.ImGui_Cond_FirstUseEver())
    end
    -- The same floating floor the working view gets (SetNextWindowSizeConstraints
    -- applies only to the very next Begin, so the browser needs its own call —
    -- without it the popup could be squashed below usable and reopen that way).
    -- RULER_H rides on top of the shared floor (2026-08-06, strip ruler): the
    -- browser stacks FIXED-height panes (strip + ruler + info row + list floor)
    -- that just fit the old minimum — the working view instead lets its
    -- waveform yield, so only this window needs the taller floor.
    if reaper.ImGui_SetNextWindowSizeConstraints ~= nil
      and reaper.ImGui_NumericLimits_Float ~= nil then
      local _, flt_max = reaper.ImGui_NumericLimits_Float()
      reaper.ImGui_SetNextWindowSizeConstraints(ctx,
        theme.metrics.BROWSER_MIN_W, theme.metrics.MIN_WIN_H + theme.metrics.RULER_H, flt_max, flt_max)
    end
    -- Zero window padding: the sidebar must bleed to the window's true edges
    -- (2026-07-29 redesign — the old 12px padding showed as a lighter frame
    -- around the sidebar's dark background). The browser's inner panels take
    -- their own padding instead (see browser.draw).
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
    -- Same no-collapse rule as the working view: one window with a fold-away
    -- arrow and one without would read as a bug, not a choice.
    local win_flags = HAS_NO_DOCK and reaper.ImGui_WindowFlags_NoDocking() or 0
    if HAS_NO_COLLAPSE then win_flags = win_flags | reaper.ImGui_WindowFlags_NoCollapse() end
    if drag_focus == "browser" then reaper.ImGui_SetNextWindowFocus(ctx) end
    -- Centred title, like every other panel (2026-08-08 — see the working
    -- view's Begin above).
    local visible2, open2 = theme.begin_window(ctx, "LIBRARY###yb-Reference_Library", true, win_flags, true)
    reaper.ImGui_PopStyleVar(ctx, 1)
    if visible2 then
      -- Read BEFORE this frame's own draw touches any popup (browser.draw opens
      -- Settings/the delete confirm/context menus below) — so "was a popup open"
      -- reflects how the frame STARTED, not something this frame's own drawing
      -- just changed. That is what stops a popup's own Esc-to-close ALSO closing
      -- this window on the very same keypress: ImGui eats that Esc for the popup
      -- first, and this check must agree the popup was already there.
      local popup_open = false
      if HAS_POPUP_GUARD then
        popup_open = reaper.ImGui_IsPopupOpen(ctx, "",
          reaper.ImGui_PopupFlags_AnyPopupId() | reaper.ImGui_PopupFlags_AnyPopupLevel())
      end

      local browser_action = browser.draw(ctx, state, res)
      -- Same precedence rule as the working view above: a release the browser's
      -- own drop target consumed must survive to the end of the frame.
      if browser_action and browser_action.wins_release then
        action = browser_action
      else
        action = action or browser_action
      end

      -- Remembered geometry: only ever reported on the frame it actually
      -- changes (compared as rounded ints against what's stored), so a settled
      -- window doesn't spam an action every single frame.
      local gx, gy = reaper.ImGui_GetWindowPos(ctx)
      local gw, gh = reaper.ImGui_GetWindowSize(ctx)
      gx, gy = math.floor(gx + 0.5), math.floor(gy + 0.5)
      gw, gh = math.floor(gw + 0.5), math.floor(gh + 0.5)
      -- This frame's rect, for next frame's files-drag focus grab.
      last_rect.browser = { x = gx, y = gy, w = gw, h = gh }
      local geom = state.browser_geom
      if not geom or geom.x ~= gx or geom.y ~= gy or geom.w ~= gw or geom.h ~= gh then
        action = action or { type = "browser_geom", x = gx, y = gy, w = gw, h = gh }
      end

      -- The walkthrough's spotlight over the browser (no-op unless active).
      walkthrough_ui.wash(ctx, state.walkthrough, "browser")

      -- Esc closes the browser, but only while it's the focused window and no
      -- popup/modal inside it was open at the top of this frame (see above).
      local focused = false
      if HAS_WIN_FOCUS then
        -- NOT the usual `A and B or C` idiom: B can legitimately be false (not
        -- focused), and that idiom would then wrongly fall through to C.
        if HAS_FOCUS_SCOPE then
          focused = reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())
        else
          focused = reaper.ImGui_IsWindowFocused(ctx)
        end
      end
      -- Closing OVERRIDES any other same-frame action (Codex, 2026-07-29 review):
      -- with `action or`, a geometry save (or any browser action) landing in the
      -- same frame would swallow the close and the window would simply stay
      -- open. The one exception is a release-consuming drop — that's the user's
      -- import intent, and a drop's mouse release can't coincide with a click on
      -- ✕ anyway (one release lands in one place). A final-frame geometry delta
      -- lost to this override is at most one frame of drag, already saved by the
      -- frames before it.
      if focused and not popup_open and HAS_ESCAPE
        and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
        if not (action and action.wins_release) then
          action = { type = "close_browser" }
          -- The window Esc dismisses was the focused one — hand focus back to
          -- REAPER rather than leaving it on a window that's about to vanish.
          focus.request()
        end
      end

      reaper.ImGui_End(ctx)
    end
    if not open2 then
      if not (action and action.wins_release) then
        action = { type = "close_browser" }
      end
      -- ✕ closes it: same handoff as the Esc path above (the click's own
      -- release usually fires it anyway; this covers the widened-✕ edge).
      focus.request()
    end
  end

  -- Settings: a real top-level window since 2026-08-08 (it was a modal inside
  -- the browser panel), so it is drawn OUT here beside the other two rather than
  -- inside the one whose gear opens it — closing the browser must not take an
  -- open Settings with it. Draws nothing unless it is open.
  local settings_action = settings.draw(ctx, state, res)
  action = action or settings_action

  -- What's New: its own top-level window too, opened by the entry script when
  -- the running version is newer than the one whose notes were last read. Drawn
  -- after Settings so it lands on top of it — the one moment both can be up is a
  -- user who opened Settings before the card was dismissed.
  local wn_action = whatsnew.draw(ctx, state)
  action = action or wn_action

  -- The walkthrough's card: its own tiny window, drawn after both hosts so it
  -- anchors on rects recorded THIS frame (ui/walkthrough.lua). Card presses
  -- come back as actions like everything else.
  local walk_action = walkthrough_ui.card(ctx, state.walkthrough)
  action = action or walk_action

  -- The "New Track /" band over REAPER's arrange, drawn LAST and outside both
  -- of our windows: it is its own overlay window sitting over REAPER, not part
  -- of either of ours. Nil on every frame that isn't a drag hovering a track's
  -- top slice, which is the overwhelming majority of them.
  newtrack_strip.draw(ctx, state.drag and state.drag.newtrack or nil)

  theme.unapply(ctx, nc, nv, nf)
  -- Whether this frame should hand keyboard focus back to REAPER (a finished
  -- click with no further claim on the keyboard — see ui/focus.lua). Evaluated
  -- LAST, after every window and popup has drawn, so "is a popup open" and "is
  -- a text field active" describe the frame as it ends. The entry script
  -- performs the actual handoff (reaper_api.focus_arrange).
  local give_focus, forward_keys = focus.frame_end(ctx)
  -- Taken (and cleared) at the very end, so it covers the drop targets in BOTH
  -- windows and can never carry over into the next frame.
  return open, action, dropzone.take_hand_shown(), give_focus, forward_keys,
    settings.feedback_visible()
end

return app
