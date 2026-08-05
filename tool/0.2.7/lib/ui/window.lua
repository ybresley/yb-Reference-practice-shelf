-- window: draws the WORKING VIEW — the compact window that's on screen all day
-- (Phase 5.7 Stage 2, two-view redesign, 2026-07-28). Three rows, top to bottom:
-- reference row (the project's pins as tabs) -> waveform (fills every spare
-- pixel) -> transport (LATCH left, play/pause + stop + loop + auto centred,
-- trim + readout right — see ui/transport.lua, 2026-07-28 row redesign). The
-- sidebar, toolbar, status/search/count row and the sound table all moved OUT
-- to ui/browser.lua —
-- see DESIGN.md "UI layout — two views" and HANDOFF's Phase 5.7 build spec.
--
-- This is a ui/ module, so it may call reaper.ImGui_* (drawing is its job) but
-- nothing else on reaper.* — it never writes files, mutates the library, or
-- starts long work itself.

local theme = require("ui.theme")
local waveform = require("ui.waveform")
local transport = require("ui.transport")
local icons = require("ui.icons")
local dropzone = require("ui.dropzone")
local popups = require("ui.popups")
local T = theme.tokens
local M = theme.metrics

local window = {}

-- Feature detection for the reference row's rect-based drop coverage (checked
-- once at load, the house idiom). Without these calls the row falls back to
-- per-item hover only — narrower target, nothing broken.
local HAS_RECT_HOVER = reaper.ImGui_IsMouseHoveringRect ~= nil
local HAS_WIN_HOVER_BLOCKED = reaper.ImGui_IsWindowHovered ~= nil
  and reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem ~= nil

-- Transient popup scratch (which pin's label is being edited, and whether a
-- popup was requested from inside a closing right-click menu — see
-- `edit.open_label` below). View-only state that never belongs on the shared
-- library — kept here, not on `state`.
local edit = { label = "", label_id = nil, open_label = false }

--------------------------------------------------------------- reference row

-- One reference tab: CAPS label for a labeled pin ("FIRE"), normal-case filename
-- for a plain one — the two species must read apart at a glance (DESIGN
-- "Reference triggering — labeled pins"). An ordinary Button, sized to its own
-- text like every other button (FramePadding already gives it the chip look),
-- so tabs of different lengths just sit at their natural width — nothing here
-- changes SIZE with state, only colour:
--   selected  -> the same fill every Selectable/Header uses (REF_TAB_SELECTED)
--   armed     -> reference-red (REF_TAB_ARMED), red's third home after the
--                window border and the REF button itself
local function ref_tab(ctx, state, p, slot)
  local action
  local label = p.label and p.label:upper() or p.name
  local selected = state.selected_id == p.id
  local armed = state.reference.latched and selected

  local pushed = 0
  if armed then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), T.REF_TAB_ARMED)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.REF_TAB_ARMED)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.REF_TAB_ARMED)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_ON_REF)
    pushed = 4
  elseif selected then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), T.REF_TAB_SELECTED)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.REF_TAB_SELECTED)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.FILL_PRIMARY)
    pushed = 3
  end
  local clicked = reaper.ImGui_Button(ctx, label .. "##reftab_" .. slot)
  if pushed > 0 then reaper.ImGui_PopStyleColor(ctx, pushed) end
  if clicked then action = { type = "select_sound", id = p.id } end

  -- No double-click gesture here (removed 2026-08-01, user's call): a tab is
  -- clicked constantly to arm it, and the second click of a quick re-arm kept
  -- opening the label popup. Labelling is the right-click menu's job only.

  -- Same drag-out gesture every draggable row shares: hold and pull onto the
  -- timeline.
  if state.deps.drag_out and not state.drag
    and reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, 0) then
    action = action or { type = "drag_sound", id = p.id }
  end

  if reaper.ImGui_BeginPopupContextItem(ctx, "reftab_menu_" .. slot) then
    if reaper.ImGui_MenuItem(ctx, "Label\u{2026}") then
      -- Can't OpenPopup directly from in here — it runs inside the closing
      -- context menu (same reason the sidebar's category menu defers "Add
      -- sub-category…"/"Rename…"). Stashed and opened once we're back at the
      -- row loop's own scope, below.
      edit.label_id, edit.label, edit.open_label = p.id, p.label or "", true
    end
    -- Only offered when this pin has a PROVEN library twin (pins_service builds
    -- that map from the same verified match that lights the library table's pin
    -- marker) — a capture, a teammate's pin or a deleted record simply doesn't
    -- get the item, rather than an item that reports a failure when clicked.
    if state.pins and state.pins.origin_of and state.pins.origin_of[p.id] then
      if reaper.ImGui_MenuItem(ctx, "Show in library") then
        action = { type = "show_in_library", id = p.id }
      end
    end
    if reaper.ImGui_MenuItem(ctx, "Save to my library") then
      action = { type = "save_pin_to_library", id = p.id }
    end
    if reaper.ImGui_MenuItem(ctx, "Unpin") then
      action = { type = "unpin", id = p.id }
    end
    reaper.ImGui_EndPopup(ctx)
  end

  -- Tooltip LAST (house rule: SetTooltip replaces ImGui's "last item", so it
  -- must run after everything above that reads the item).
  if reaper.ImGui_IsItemHovered(ctx) and p.note and p.note ~= "" then
    reaper.ImGui_SetTooltip(ctx, p.note)
  end

  return action
end

-- One tab's width, from its own label. Shared by the measure pass and the draw
-- pass so they can never disagree about where a line breaks.
local function tab_width(ctx, p, pad_x)
  local label = p.label and p.label:upper() or p.name
  return select(1, reaper.ImGui_CalcTextSize(ctx, label)) + pad_x * 2
end

-- The row's natural height WITHOUT drawing it. The working view needs this
-- before laying anything out, because vertical space is now handed out in a
-- strict order (transport first, this row second, waveform last — decided
-- 2026-07-30) and the first two have to be known up front.
function window.measure_reference_row(ctx, state, avail_w, omit_library)
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)
  local spacing, spacing_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local ps = state.pins
  local pins = (ps and not ps.load_error and ps.data) and ps.data.pins or nil
  if not pins or #pins == 0 then return frame_h end -- the hint row / damaged row: one line

  -- The Library button's reserved corner, unless the column is already carrying it.
  local limit_w = omit_library and avail_w or (avail_w - frame_h - spacing)
  local lines, x = 1, 0
  for i, p in ipairs(pins) do
    local w = tab_width(ctx, p, pad_x)
    if i == 1 then
      x = w
    elseif x + spacing + w <= limit_w then
      x = x + spacing + w
    else
      lines = lines + 1
      x = w
    end
  end
  return lines * frame_h + (lines - 1) * spacing_y
end

-- The project's pins as compact tabs, wrapping to more rows when the window is
-- narrow (window-SIZE driven, never state-driven — the one kind of layout
-- change the UI-stability rule allows). The Library button is pinned to the
-- row's top-right corner and drawn FIRST, so it holds one place whatever the
-- pins do and can never be pushed off screen (decided 2026-07-30, after it
-- turned out to be the first casualty of an overflowing row).
local function draw_reference_row(ctx, state, res, omit_library)
  local action
  local ps = state.pins

  -- Reserve the corner before anything else claims the width. Skipped in the
  -- side-column arrangement, where the Library button lives in the column beside
  -- the latch instead and this row is pins only.
  local btn_x0, btn_y0 = reaper.ImGui_GetCursorPos(ctx)
  local row_avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local btn_size = reaper.ImGui_GetFrameHeight(ctx)
  local spacing_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local wrap_limit = omit_library and row_avail_w or (row_avail_w - btn_size - spacing_x)

  if not omit_library then
    reaper.ImGui_SetCursorPos(ctx, btn_x0 + row_avail_w - btn_size, btn_y0)
    if icons.button(ctx, res and res.icon_font, "openlibrary", "library",
        { tip = "Open the library browser", fallback = icons.draw_folder }) then
      action = { type = "toggle_browser" }
    end
    reaper.ImGui_SetCursorPos(ctx, btn_x0, btn_y0)
  end

  -- The whole row is a drop target for a sound dragged from elsewhere (the
  -- browser's table, or another tab): let go anywhere on it and it's pinned. A
  -- dragged PIN is already here, and damaged pin data refuses every mutation,
  -- so neither gets the invite. Cross-window drags (browser row -> this row)
  -- rely on ImGui's hover bookkeeping not being scoped per window — the one
  -- mechanism in this stage that needs a manual REAPER check (see HANDOFF).
  local drag = state.drag
  local zone_on = drag ~= nil and not (ps and ps.load_error)
    and not (type(drag.sound_id) == "string" and drag.sound_id:sub(1, 1) == "p")
  local zone_hov, zone_rel = false, false
  local function pin_target(hov, rel)
    if not zone_on then return end
    zone_hov = zone_hov or hov
    zone_rel = zone_rel or rel
  end

  local zx0, zy0 = reaper.ImGui_GetCursorScreenPos(ctx)

  if ps and ps.load_error then
    -- Damaged stored data: pinning is paused (the service refuses every
    -- mutation) so nothing can overwrite what's still recoverable from the
    -- saved project. The only way forward is this explicit, deliberate discard
    -- — kept reachable exactly where the old sidebar section put it.
    reaper.ImGui_Selectable(ctx, "Pins couldn't be read##pins_damaged", false)
    local damaged_hovered = reaper.ImGui_IsItemHovered(ctx)
    if reaper.ImGui_BeginPopupContextItem(ctx, "pins_damaged_menu") then
      if reaper.ImGui_MenuItem(ctx, "Discard damaged pin data") then
        action = { type = "reset_pins" }
      end
      reaper.ImGui_EndPopup(ctx)
    end
    if damaged_hovered then
      reaper.ImGui_SetTooltip(ctx,
        "This project's stored pin data is damaged, so pinning is paused here.\n" ..
        "Right-click to discard it and start empty — until you save the project,\n" ..
        "the damaged text is still in the last saved project file.")
    end
  elseif not ps or #ps.data.pins == 0 then
    -- One dim hint row, whether the project is unsaved (pins have nowhere to
    -- live yet) or simply has no pins. A full-width inert row, not bare text,
    -- so a drag or an OS drop is caught anywhere across it.
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_QUATERNARY)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), 0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(), 0)
    -- Shortened 2026-07-30: the old wording needed ~434px and was already being
    -- sliced mid-sentence at the smallest allowed window width.
    reaper.ImGui_Selectable(ctx, ((ps and ps.dir) and "Drag a sound or audio file here to pin it"
      or "Save your project to pin references here") .. "##pins_empty", false)
    reaper.ImGui_PopStyleColor(ctx, 3)
    pin_target(dropzone.sound_drop_state(ctx, state))
  else
    -- Flow layout, tracked by hand: ImGui resets the cursor to the start of the
    -- NEXT line after each item, so asking it "how much room is left?" always
    -- answers "the whole width" and every wrap test passes. That is why nothing
    -- ever wrapped here before 2026-07-30. Accumulating the line width
    -- ourselves is the only honest measure, and it matches measure_reference_row
    -- above exactly.
    local x = 0
    for i, p in ipairs(ps.data.pins) do
      local w = tab_width(ctx, p, pad_x)
      if i == 1 then
        x = w
      elseif x + spacing_x + w <= wrap_limit then
        reaper.ImGui_SameLine(ctx)
        x = x + spacing_x + w
      else
        x = w -- falls to the next line: the cursor is already there
      end
      local tab_action = ref_tab(ctx, state, p, p.id)
      pin_target(dropzone.sound_drop_state(ctx, state))
      action = action or tab_action
    end
  end

  -- The row's full extent, Library button included, now that every item is
  -- laid out. Both drag kinds must treat the WHOLE block as the target — blank
  -- space right of the tabs included (Codex, 2026-07-28: per-item hover alone
  -- left that space silently cancelling drops).
  local wx = reaper.ImGui_GetWindowPos(ctx)
  local ww = select(1, reaper.ImGui_GetWindowSize(ctx))
  local zy1 = select(2, reaper.ImGui_GetCursorScreenPos(ctx))

  -- Internal drags: rect-based hover over the block, on top of the per-item
  -- checks (which stay — they're what an ancient build without these calls
  -- falls back to). Gated on this window being the hovered one, so a drag over
  -- a browser window overlapping this rect can't light the row through it.
  if zone_on and HAS_RECT_HOVER then
    local over_window = true
    if HAS_WIN_HOVER_BLOCKED then
      over_window = reaper.ImGui_IsWindowHovered(ctx,
        reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem())
    end
    if over_window and reaper.ImGui_IsMouseHoveringRect(ctx, zx0, zy0, wx + ww, zy1) then
      zone_hov = true
      zone_rel = zone_rel or reaper.ImGui_IsMouseReleased(ctx, 0)
    end
  end
  if zone_hov or zone_rel then
    -- Clamped to the window's own bounds by draw_drop_rect, so passing the
    -- window's right edge as x1 is safe even though a wrapped block's own item
    -- rects don't span the full width.
    if zone_hov then
      dropzone.draw_drop_rect(ctx, zx0, zy0, wx + ww, zy1)
      dropzone.show_hand_cursor(ctx)
    end
    if zone_rel then
      action = { type = "pin_sound", id = drag.sound_id, wins_release = true }
    end
  end

  -- OS file drops need no target here: the WHOLE working view is one
  -- import_and_pin target (see window.draw), and this row sits inside it.

  -- Open a menu-requested popup now that we're clear of the closing menu.
  if edit.open_label then
    reaper.ImGui_OpenPopup(ctx, "reftab_label")
    edit.open_label = false
  end

  -- The label/rename popup (double-click or the tab's right-click menu). Empty
  -- clears the label — allow_empty lets that submission through.
  local labeled = popups.edit_popup(ctx, edit, "reftab_label", "Label", "label", { allow_empty = true })
  if labeled ~= nil then
    action = { type = "set_pin_label", id = edit.label_id, label = labeled }
  end

  return action
end

--------------------------------------------------------------- arrangements

-- Which arrangement `auto` last settled on. Remembered only so the dead band
-- below has something to compare against — view-only scratch, never persisted,
-- and deliberately not on the shared `state` (same reasoning as `edit` above).
local layout_now = "stacked"

-- The reference row, inside a scrolling child only when its natural height
-- exceeds what it has been given. This cap is what guarantees the transport row
-- can never be scrolled out of reach (decided 2026-07-30): with too many pins to
-- fit, the PINS scroll rather than the whole window.
local function draw_reference_row_capped(ctx, state, res, ref_h, ref_natural, omit_library)
  if ref_natural <= ref_h + 0.5 then
    return draw_reference_row(ctx, state, res, omit_library)
  end
  local action
  -- Popped the INSTANT the child has taken it (ImGui reads WindowPadding once,
  -- at Begin). Left pushed across the child's contents it also lands on every
  -- tooltip and right-click menu submitted inside — which is what made the
  -- working view's menus look cramped and borderless next to the browser's
  -- (reported 2026-08-01). Same one-line rule everywhere a child pushes padding.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  -- EndChild only inside the `if` (ReaImGui contract, as in ui/browser.lua): a
  -- fully clipped child returns false WITHOUT opening.
  local open = reaper.ImGui_BeginChild(ctx, "refrow_scroll", 0, ref_h)
  reaper.ImGui_PopStyleVar(ctx, 1)
  if open then
    action = draw_reference_row(ctx, state, res, omit_library)
    reaper.ImGui_EndChild(ctx)
  end
  return action
end

-- Pick the arrangement from the room actually measured — never from the window's
-- shape. A 900×450 panel and a 400×200 panel share an aspect ratio and need
-- opposite treatment, so the test is "would stacking still leave the waveform a
-- usable band", not "is this wide or tall".
local function pick_arrangement(ctx, state, avail_w, avail_h, ref_h, transport_h)
  local mode = state.layout or "auto"
  if mode == "stacked" then return "stacked" end

  local spacing, spacing_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
  local fits = avail_h >= transport.column_height(ctx)
    and avail_w >= transport.column_width(ctx) + spacing + M.WAVE_MIN_W
  if mode == "column" then return fits and "column" or "stacked" end
  if not fits then return "stacked" end

  -- Two thresholds, not one: switching arrangement changes how much room there
  -- is, which would re-trigger a single-threshold test and oscillate while the
  -- user drags the dock edge. The gap between LO and HI is the dead band.
  local stacked_wave = avail_h - ref_h - transport_h - (2 + 4 + spacing_y * 4)
  if layout_now == "stacked" and stacked_wave < M.LAYOUT_SWITCH_LO then return "column" end
  if layout_now == "column" and stacked_wave > M.LAYOUT_SWITCH_HI then return "stacked" end
  return layout_now
end

-- Stacked: reference row -> waveform -> transport, the arrangement the working
-- view has always had. Vertical space is handed out in a strict order now, so a
-- short window can never push the controls off the bottom:
--   1. the transport row's height is reserved first
--   2. the reference row takes what's left, capped (and scrolling) beyond that
--   3. the waveform takes the remainder — including none at all
local function draw_stacked(ctx, state, res, avail_h, ref_natural, transport_h)
  local action
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)
  local spacing_y = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))

  -- Always present below the reference row: the 4px gap, the transport, and the
  -- two item-spacing steps around them.
  local base = 4 + transport_h + spacing_y * 2
  local room = avail_h - base
  local ref_h = math.min(ref_natural, math.max(frame_h, room))
  -- The waveform's own share also carries the 2px gap above it and two more
  -- spacing steps; shorting them would summon a scrollbar, which is a layout
  -- shift and steals width.
  local wave_h = room - ref_h - (2 + spacing_y * 2)
  if wave_h < M.WAVE_HIDE_H then wave_h = 0 end

  local ref_action = draw_reference_row_capped(ctx, state, res, ref_h, ref_natural)
  action = action or ref_action

  if wave_h > 0 then
    reaper.ImGui_Dummy(ctx, 0, 2)
    -- The working view always shows the ARMED reference — never the browser's
    -- own selection (Phase 5.9: the two are independent). Its trim scales the
    -- drawing, so riding the trim fader resizes the wave as it resizes the sound.
    local wave_action = waveform.draw(ctx, state, wave_h,
      { id = state.selected_id, waveform = state.waveform,
        trim_db = state.selected and state.selected.trim_db or 0 })
    action = action or wave_action
  end

  reaper.ImGui_Dummy(ctx, 0, 4)
  if state.deps.sws then
    local transport_action = transport.draw(ctx, state, res)
    action = action or transport_action
  end
  return action
end

-- Column: the controls gather into a fixed-width column on the left and the
-- waveform takes the whole remaining area at full height (decided 2026-07-30).
-- For a wide, short dock this roughly doubles the waveform's height and reclaims
-- the empty gaps the stacked transport row leaves across its width.
--
-- Both halves are zero-padding children, so every inner draw's own
-- GetContentRegionAvail already reports its half — no width has to be threaded
-- through, and the reference row's drop rectangle picks up the child's bounds
-- instead of the window's, which is exactly what it should cover here.
local function draw_column(ctx, state, res, avail_h)
  local action
  local spacing, spacing_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)
  local no_scroll = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()

  -- Pushed and popped around each BeginChild only (see draw_reference_row_capped):
  -- held across the contents it would also strip the padding off every tooltip and
  -- right-click menu in this arrangement.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local col_open = reaper.ImGui_BeginChild(ctx, "wv_column", transport.column_width(ctx), avail_h, 0, no_scroll)
  reaper.ImGui_PopStyleVar(ctx, 1)
  if col_open then
    -- Top row is the pair the two modules share: the latch is the transport's,
    -- the Library button is this window's, and together they fill the column's
    -- width exactly (decided 2026-07-30 — it costs no height at all, which is
    -- why it beat giving the Library button its own row).
    if state.deps.sws then
      local latch_action = transport.draw_latch(ctx, state)
      action = action or latch_action
      reaper.ImGui_SameLine(ctx)
    end
    if icons.button(ctx, res and res.icon_font, "openlibrary_col", "library",
        { tip = "Open the library browser", fallback = icons.draw_folder }) then
      action = action or { type = "toggle_browser" }
    end
    if state.deps.sws then
      local body_action = transport.draw_column_body(ctx, state, res)
      action = action or body_action
    end
    reaper.ImGui_EndChild(ctx)
  end

  reaper.ImGui_SameLine(ctx, 0, spacing)

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local main_open = reaper.ImGui_BeginChild(ctx, "wv_main", 0, avail_h, 0, no_scroll)
  reaper.ImGui_PopStyleVar(ctx, 1)
  if main_open then
    local main_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local ref_natural = window.measure_reference_row(ctx, state, main_w, true)
    -- Same priority rule, one row shorter: the pins are capped so the waveform
    -- always keeps at least a usable band.
    local ref_h = math.min(ref_natural,
      math.max(frame_h, avail_h - M.WAVE_HIDE_H - spacing_y))
    local ref_action = draw_reference_row_capped(ctx, state, res, ref_h, ref_natural, true)
    action = action or ref_action

    local wave_h = avail_h - ref_h - spacing_y
    if wave_h >= M.WAVE_HIDE_H then
      local wave_action = waveform.draw(ctx, state, wave_h,
        { id = state.selected_id, waveform = state.waveform,
          trim_db = state.selected and state.selected.trim_db or 0 })
      action = action or wave_action
    end
    reaper.ImGui_EndChild(ctx)
  end

  return action
end

--------------------------------------------------------------- main draw

function window.draw(ctx, state, res)
  local action

  -- The WHOLE working view is one OS-file drop target (2026-08-01, user's call
  -- — supersedes the old "browser opens itself" auto-open): files dropped
  -- anywhere on this window import into the library (Uncategorised) and pin to
  -- this project in one motion, with the full-window treatment while the drag
  -- hovers. Submitted only while a files payload is in flight, so it can never
  -- steal a click — see dropzone.file_drop_over_rect.
  do
    local cx0, cy0 = reaper.ImGui_GetCursorScreenPos(ctx)
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    action = dropzone.file_drop_over_rect(ctx, state, cx0, cy0, cx0 + avail_w, cy0 + avail_h,
      { action_type = "import_and_pin", label = "Add + pin to this project" })
  end

  if not state.deps.sws then
    -- TEXT_PRIMARY, not red: REF_RED is reserved for reference mode (tokens.md).
    -- Wrapped at the content edge (2026-07-30) — as one long line the second
    -- sentence ran straight off the right edge at any normal window width.
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, "Preview needs the SWS extension")
    reaper.ImGui_PushTextWrapPos(ctx, 0)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY,
      "You can still add and organise sounds (in the library browser); previewing turns on once SWS is installed (free, from sws-extension.org).")
    reaper.ImGui_PopTextWrapPos(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Dummy(ctx, 0, 4)
  end

  -- Measure before laying anything out: the transport's height is reserved
  -- first, the reference row's natural height decides both the cap and which
  -- arrangement wins. Everything comes from the real content region each frame
  -- — never a hardcoded panel height — so resizing the window is the only thing
  -- that can change the layout. Never state: nothing here reads selection,
  -- playback or latch.
  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local transport_h = state.deps.sws and transport.measure(ctx, avail_w) or 0
  local ref_natural = window.measure_reference_row(ctx, state, avail_w)
  local arrangement = pick_arrangement(ctx, state, avail_w, avail_h, ref_natural, transport_h)
  layout_now = arrangement

  -- Always draw, then merge — never `action = action or draw(...)`, which
  -- short-circuits in Lua and would skip the draw entirely for the frame the
  -- moment an earlier step reports an action (the same rule app.lua follows).
  local body_action
  if arrangement == "column" then
    body_action = draw_column(ctx, state, res, avail_h)
  else
    body_action = draw_stacked(ctx, state, res, avail_h, ref_natural, transport_h)
  end
  action = action or body_action

  return action
end

return window
