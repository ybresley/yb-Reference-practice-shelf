-- app: owns the ImGui context and the per-frame draw. This is a ui/ module, so
-- calling reaper.ImGui_* is its job — keeping every ImGui call out of the entry
-- script, which owns only the shared state and the defer loop. This is the
-- architecture boundary: reaper_api touches reaper.*, ui/ touches ImGui, nothing
-- crosses over.

local theme   = require("ui.theme")
local window  = require("ui.window")
local browser = require("ui.browser")
local popups  = require("ui.popups")

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
local HAS_CLOSE_ZONE = reaper.ImGui_IsWindowDocked ~= nil
  and reaper.ImGui_GetFrameHeight ~= nil and reaper.ImGui_GetWindowWidth ~= nil
local HAS_SUBMENU = reaper.ImGui_BeginMenu ~= nil and reaper.ImGui_EndMenu ~= nil

-- The widened close zone (see below). `armed` is the press half of a press-then-
-- release click, so dragging the window by the far right of its title bar can't
-- close it on the way out; `want_close` is consumed on the way out of app.frame.
local close_armed = false
local want_close = false


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
-- View-only scratch, same reasoning as close_armed above.
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
  local ctx = reaper.ImGui_CreateContext("yb_Reference")
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
  -- One list clipper for the sound list, attached so it survives across frames.
  res.clipper = reaper.ImGui_CreateListClipper(ctx)
  reaper.ImGui_Attach(ctx, res.clipper)

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

-- Reference mode's red window outline, applied around a Begin and taken straight
-- back off. ImGui reads the border colour and thickness ONCE, as the window
-- opens; left pushed across the window's contents they also reached every
-- tooltip and right-click menu drawn inside, so while reference mode was latched
-- every little popup wore a 2px red outline of its own (fixed 2026-08-01).
-- Module-level rather than closures inside the frame, per the frame-loop rules.
local function push_ref_border(ctx, on)
  if not on then return end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), theme.tokens.REF_RED)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 2)
end

local function pop_ref_border(ctx, on)
  if not on then return end
  reaper.ImGui_PopStyleVar(ctx, 1)
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- Draw one frame. Returns whether the window is still open (false once the user
-- closes it) so the entry script's defer loop knows when to stop.
--
-- End is called only when Begin reports the window visible. That is ReaImGui's
-- contract — its own demo does `if not rv then return end` and skips End when the
-- window is collapsed — NOT the upstream C++ "always call End" rule.
-- Returns (open, action): `open` drives the defer loop; `action` (or nil) is the
-- user intent the entry script executes — the UI never acts on the library itself.
function app.frame(ctx, state)
  local nc, nv, nf = theme.apply(ctx)

  -- Reference mode outlines the whole window in red — the one unmistakable "your
  -- project is muted" signal, visible even when the window is docked and small.
  -- Only the border changes, so nothing in the layout shifts.
  --
  -- Also held on while an un-latch is still owed (`pending`): the latch is off but
  -- the master may still be muted, and dropping the one unmistakable signal while
  -- that is true would report a clean stop that didn't happen.
  --
  -- Pushed around each Begin and popped the moment it returns (see the two
  -- helpers above app.frame).
  local latched = state.reference.latched or state.reference.pending

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
  push_ref_border(ctx, latched)
  local visible, open = reaper.ImGui_Begin(ctx, state.win_title, true, main_flags)
  pop_ref_border(ctx, latched)
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
        -- A submenu of REAPER's dockers by side (state.dockers, resolved once by
        -- the entry script) rather than one item aimed at a guess: the drag route
        -- means hitting a narrow strip with no cue, and picking from a list needs
        -- no aim. Falls back to a single item where the docker list can't be read.
        local list = state.dockers
        if HAS_SUBMENU and list and #list > 0 then
          if reaper.ImGui_BeginMenu(ctx, "Dock window in Docker") then
            for i = 1, #list do
              if reaper.ImGui_MenuItem(ctx, list[i].label) then
                pending_dock = list[i].dock_id
              end
            end
            reaper.ImGui_EndMenu(ctx)
          end
        elseif reaper.ImGui_MenuItem(ctx, "Dock window in Docker") then
          pending_dock = state.dock_target or -1
        end
        reaper.ImGui_EndPopup(ctx)
      end
    end

    -- ImGui draws the title bar's ✕ at exactly the font's size, which is a small
    -- target (the user's note, 2026-07-30) — and it offers no way to enlarge it.
    -- So ImGui's ✕ is left exactly where it is and this only widens the CLICKABLE
    -- area around it to the full square of the title bar's height. Nothing is
    -- drawn: the button you see is still ImGui's, so being a pixel out here can
    -- never make the window impossible to close. Skipped while docked, where
    -- there is no title bar (REAPER's own docker tab carries the close box).
    if HAS_CLOSE_ZONE and not reaper.ImGui_IsWindowDocked(ctx) then
      local wx, wy = reaper.ImGui_GetWindowPos(ctx)
      local tbh = reaper.ImGui_GetFrameHeight(ctx)
      local right = wx + reaper.ImGui_GetWindowWidth(ctx)
      local mx, my = reaper.ImGui_GetMousePos(ctx)
      local in_zone = mx >= right - tbh and mx < right and my >= wy and my < wy + tbh
      if in_zone and reaper.ImGui_IsWindowHovered(ctx) then
        if reaper.ImGui_IsMouseClicked(ctx, 0) then close_armed = true end
        if close_armed and reaper.ImGui_IsMouseReleased(ctx, 0) then want_close = true end
      end
      -- Any release ends the press, wherever it landed — otherwise a press here
      -- followed by a release elsewhere would stay armed and close on the next
      -- unrelated click in the zone.
      if reaper.ImGui_IsMouseReleased(ctx, 0) then close_armed = false end
    end

    -- The post-update restart popup (popups.update_done): announced from HERE
    -- only while no popup is up anywhere — when the Settings modal is open,
    -- draw_settings stacks it over that modal instead, so it appears the
    -- instant the update lands either way (the user's fix, 2026-08-05:
    -- completion must not wait for Settings to close).
    local can_open = true
    if HAS_POPUP_GUARD then
      can_open = not reaper.ImGui_IsPopupOpen(ctx, "",
        reaper.ImGui_PopupFlags_AnyPopupId() | reaper.ImGui_PopupFlags_AnyPopupLevel())
    end
    local done_action = popups.update_done(ctx, state, "app", can_open)
    if done_action then action = action or done_action end

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
    if reaper.ImGui_SetNextWindowSizeConstraints ~= nil
      and reaper.ImGui_NumericLimits_Float ~= nil then
      local _, flt_max = reaper.ImGui_NumericLimits_Float()
      reaper.ImGui_SetNextWindowSizeConstraints(ctx,
        theme.metrics.MIN_WIN_W, theme.metrics.MIN_WIN_H, flt_max, flt_max)
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
    push_ref_border(ctx, latched)
    local visible2, open2 = reaper.ImGui_Begin(ctx, "Library###yb_Reference_Library", true, win_flags)
    pop_ref_border(ctx, latched)
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
        end
      end

      reaper.ImGui_End(ctx)
    end
    if not open2 then
      if not (action and action.wins_release) then
        action = { type = "close_browser" }
      end
    end
  end

  theme.unapply(ctx, nc, nv, nf)
  -- A click in the widened close zone means the same thing as ImGui's own ✕.
  if want_close then
    want_close = false
    open = false
  end
  return open, action
end

return app
