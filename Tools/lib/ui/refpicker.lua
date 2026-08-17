-- refpicker: the working view's reference picker — the name slot in the control
-- bar, the joined step arrows, the position count, the list popup and its edit
-- mode. It replaced the reference-tab ROW entirely (redesigned end to end in
-- .brief/working-view-layout, 2026-08-06): the bar now looks identical whether
-- the project has 2 pins or 40, and the height the row used to eat goes to the
-- waveform.
--
-- It lives in its own file rather than inside transport.lua/window.lua because
-- it is one responsibility: "which reference is armed, and how do you change
-- that". transport.lua only decides WHERE its pieces sit in the bar.
--
-- A ui/ module: reaper.ImGui_* only. It reports intent as actions; the entry
-- script performs them.

local theme = require("ui.theme")
local icons = require("ui.icons")
local widgets = require("ui.widgets")
local tips = require("ui.tips")
local popups = require("ui.popups")
local pins = require("core.pins")
local T = theme.tokens
local M = theme.metrics

local refpicker = {}

-- Transient view state — which pin's label is being edited, whether edit mode
-- is on, and the in-flight reorder drag. Never belongs on the shared `state`
-- (the same reasoning ui/window.lua's `edit` table had).
local ui = {
  open_request = false, -- the slot was clicked this frame; open the list next
  anchor_x = nil, anchor_y = nil, anchor_w = nil, -- where the list opens (the slot's bottom-left)
  edit_mode = false,
  label = "", label_id = nil, open_label = false,
  drag_id = nil,        -- the pin being dragged by its handle
  drag_to = nil,        -- where it would land if released now
  -- WHICH PROJECT the two id-keyed operations above belong to. Pin ids restart
  -- at p1 in every project, so a label dialog left open (or a reorder still
  -- held) while the user switches REAPER project tabs would otherwise apply to
  -- the NEW project's p1 — renaming or moving a completely different sound
  -- (Codex, 2026-08-06). Both are checked against the live project before they
  -- act, and abandoned rather than guessed at.
  owner_proj = nil,
}

-- Does an operation started earlier still belong to the project in front of the
-- user? Anything id-keyed must ask this before it acts.
local function same_project(state)
  local proj = state.pins and state.pins.proj
  return ui.owner_proj ~= nil and ui.owner_proj == proj
end

local function claim_project(state)
  ui.owner_proj = state.pins and state.pins.proj
end

-- Another control may discover that choosing a reference is the missing next
-- step (the L button does this when clicked with no target). Keep the opening
-- machinery here so every route uses the same anchored project-specific list.
function refpicker.request_open()
  ui.open_request = true
  ui.edit_mode = false
end

-- Row rectangles from the last drawn frame, reused in place so the frame loop
-- allocates nothing (frame rules). `row_n` says how many of them are live.
local row_rects, row_n = {}, 0

-- The cursor edit mode shows over a draggable row. Resolved once at load (the
-- house feature-detection idiom): an older ReaImGui may define neither, in
-- which case the tooltip carries the affordance alone.
local REORDER_CURSOR = (reaper.ImGui_MouseCursor_ResizeNS and reaper.ImGui_MouseCursor_ResizeNS())
  or (reaper.ImGui_MouseCursor_Hand and reaper.ImGui_MouseCursor_Hand())
  or nil

local CHEVRON_DOWN = "\u{25BE}"
local CHEVRON_LEFT = "\u{2039}"
local CHEVRON_RIGHT = "\u{203A}"

local function fmt_duration(sec)
  local s = math.floor((sec or 0) + 0.5)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- Snap a drawing coordinate to a whole pixel. Centring text in a row lands on
-- half pixels (a 15px line in a 34px row), and ImGui renders a glyph run at a
-- fractional origin softer than the same run at a whole one — which is part of
-- what made this list read as lower quality than the rest of the app.
local function px(v)
  return math.floor(v + 0.5)
end

-- Cutting a name to fit lives in ui/widgets.lua since 2026-08-07 — the browser
-- sidebar needed the same thing, and a second copy of a cached binary search is
-- what that module exists to prevent.
local ellipsize = widgets.ellipsize

-- This project's pin list, or nil when there is nothing usable to show (no pin
-- state yet, or its stored text is damaged and every mutation is paused).
local function pin_list(state)
  local ps = state.pins
  if not ps or ps.load_error then return nil end
  return ps.data.pins
end

--------------------------------------------------------------- measurements

-- The count's RESERVED width: the widest it can ever get at this pin total, so
-- 9/9 growing to 10/12 never shuffles the arrows left of it (UI-stability rule
-- — nothing may move because of state). Zero when there is nothing to count.
function refpicker.count_width(ctx, state)
  local list = pin_list(state)
  if not list or #list == 0 then return 0 end
  local widest = string.format("%d/%d", #list, #list)
  local small = theme.push_small_font(ctx)
  local w = select(1, reaper.ImGui_CalcTextSize(ctx, widest))
  if small then reaper.ImGui_PopFont(ctx) end
  return w
end

-- The arrows are a PAIR — that pairing is why the picker's shape B beat A in
-- the brief: one target, no aiming across the name. They are separated by a
-- hairline gap rather than welded together (2026-08-06, user-reported): at zero
-- they read as one wide button instead of two arrows.
function refpicker.arrows_width(ctx)
  return reaper.ImGui_GetFrameHeight(ctx) * 2 + M.PICK_ARROW_GAP
end

--------------------------------------------------------------- the name slot

-- What the slot says, as (text, is_placeholder). A labeled pin reads
-- "LABEL · name"; an unlabeled one is just its name (its name IS its filename,
-- exactly as the tabs showed it). A library sound selected from the browser is
-- shown by name too — the slot answers "what is armed", not "which pin".
local function slot_text(state)
  local ps = state.pins
  if ps and ps.load_error then return "This project's pinned references couldn't be read", true end
  local sel = state.selected
  if sel then
    if sel.label and sel.label ~= "" then
      return sel.label:upper() .. " \u{00B7} " .. sel.name, false
    end
    return sel.name, false
  end
  if state.reference.latched then return "NO TARGET", false end
  local list = pin_list(state)
  if list and #list > 0 then return "Choose a reference", true end
  if ps and ps.dir then return "Drag a sound or audio file here to pin it", true end
  return "Save your project to pin references here", true
end

-- Has a drag STARTED on the slot during the current mouse hold? A drag that
-- comes back over the slot before the button is let go would otherwise fire the
-- slot's click on release and pop the list open behind the drop.
local slot_dragged = false

-- The flexible element of the control bar: the armed reference's name and the
-- "opens a list" chevron. It does NOT go red while reference mode is latched
-- any more (2026-08-06, user's call): the latch button is the only thing in the
-- UI that reddens now.
--
-- Pulling the slot out is how the armed reference reaches the REAPER timeline
-- (2026-08-07, user's call): the same press-and-pull the list's rows already
-- had, moved onto the one part of the bar that is always on screen, so placing
-- a reference no longer means opening the list first. The two gestures don't
-- fight — ImGui only calls a press a DRAG once it passes its own movement
-- threshold, so an ordinary click still opens the list.
function refpicker.draw_slot(ctx, state, res, w)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local latched = state.reference.latched
  local text, placeholder = slot_text(state)

  local clicked = reaper.ImGui_Button(ctx, "##refslot", w, ctrl)
  local held = reaper.ImGui_IsItemActive(ctx)

  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  -- Remember the live anchor every frame, not only after a slot click: the L
  -- button is drawn just before this slot and may request the same popup.
  ui.anchor_x, ui.anchor_y, ui.anchor_w = x0, y1, x1 - x0
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local col = placeholder and T.TEXT_QUATERNARY or T.TEXT_PRIMARY

  -- The chevron sits inside the slot's right edge, so the name is cut against
  -- it rather than under it.
  local chev_w = ctrl * 0.6
  local shown = ellipsize(ctx, text, (x1 - x0) - pad_x * 2 - chev_w)
  local th = select(2, reaper.ImGui_CalcTextSize(ctx, shown))
  reaper.ImGui_DrawList_AddText(dl, x0 + pad_x, (y0 + y1) * 0.5 - th * 0.5, col, shown)

  local cx = x1 - pad_x - chev_w * 0.5
  if not icons.paint_glyph(ctx, res and res.icon_font, "chevron-down", cx, (y0 + y1) * 0.5, col) then
    local cw, ch = reaper.ImGui_CalcTextSize(ctx, CHEVRON_DOWN)
    reaper.ImGui_DrawList_AddText(dl, cx - cw * 0.5, (y0 + y1) * 0.5 - ch * 0.5, col, CHEVRON_DOWN)
  end

  -- Pull the armed reference out: onto the REAPER timeline, or onto a category
  -- in the browser's sidebar (which files it into the library) — the same
  -- destinations, and the same action, the list's rows report.
  local action
  if state.deps.drag_out and state.selected_id and not state.drag
    and held and reaper.ImGui_IsMouseDragging(ctx, 0) then
    action = { type = "drag_sound", id = state.selected_id }
    slot_dragged = true
  end

  if clicked and not slot_dragged then
    refpicker.request_open() -- a freshly opened list is never already in edit mode
  end
  -- Cleared AFTER the click above, never before: `clicked` IS the release
  -- frame, so clearing on "the button is up" would clear it a moment too early
  -- and the suppressed click would fire anyway.
  if not held then slot_dragged = false end

  if reaper.ImGui_IsItemHovered(ctx) then
    local ps = state.pins
    local slot_tip
    if ps and ps.load_error then
      slot_tip =
        "This project's pinned references couldn't be read, so pinning is paused.\n" ..
        "Open the list to start with no pinned references. The saved project remains\n" ..
        "unchanged until you save it again."
    elseif latched and not state.selected then
      slot_tip =
        "Reference mode is still on and the project's master is muted.\n" ..
        "Choose a reference, or click the Latch button to turn it off."
    else
      -- Only what the slot ITSELF can't say: the full name when it is showing
      -- an ellipsis, and the pin's note. The "click to choose" line is gone
      -- (user's call, 2026-08-06) — a chevron on a button already says it, and
      -- a tooltip that only restates what is on screen is noise following the
      -- cursor. Same rule the list's rows follow.
      local sel = state.selected
      local tip = (shown ~= text) and text or nil
      if sel and sel.note and sel.note ~= "" then
        tip = tip and (tip .. "\n" .. sel.note) or sel.note
      end
      -- The one exception to the rule above, and it proves it: a drag is not
      -- "on screen" at all. Nothing about the slot says it can be pulled out,
      -- so this line is the only place that affordance exists.
      if sel and state.deps.drag_out then
        tip = tip and (tip .. "\n\nDrag to the REAPER timeline to add it.")
          or "Drag to the REAPER timeline to add it."
      end
      slot_tip = tip
    end
    tips.show(ctx, true, slot_tip)
  end

  -- Opening the list is view state (handled in draw_popup below) and choosing IS
  -- the list's job, so the only thing the slot reports is a drag pulled out of it.
  return action
end

--------------------------------------------------------------- arrows + count

-- Previous / next, as one joined pair. They WRAP (the list is a loop, so with
-- two references one arrow is an A/B toggle), and with 0 or 1 pins they stay
-- exactly where they are and go dim — nothing here ever disappears.
function refpicker.draw_arrows(ctx, state, res)
  local action
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local font = res and res.icon_font
  local list = pin_list(state)
  local live = list ~= nil and #list > 1

  if not live then reaper.ImGui_BeginDisabled(ctx) end
  if reaper.ImGui_Button(ctx, (font and icons.NAMES["chevron-left"] and "" or CHEVRON_LEFT) .. "##refprev", ctrl, ctrl) then
    action = { type = "step_reference", delta = -1 }
  end
  icons.paint_over_item(ctx, font, "chevron-left")
  tips.show(ctx, live and reaper.ImGui_IsItemHovered(ctx), "Previous reference")
  reaper.ImGui_SameLine(ctx, 0, M.PICK_ARROW_GAP) -- a pair, not one welded button
  if reaper.ImGui_Button(ctx, (font and icons.NAMES["chevron-right"] and "" or CHEVRON_RIGHT) .. "##refnext", ctrl, ctrl) then
    action = { type = "step_reference", delta = 1 }
  end
  icons.paint_over_item(ctx, font, "chevron-right")
  tips.show(ctx, live and reaper.ImGui_IsItemHovered(ctx), "Next reference")
  if not live then reaper.ImGui_EndDisabled(ctx) end

  return action
end

-- "2/6" — where the armed reference sits in the list. Sits BETWEEN the name
-- slot and the arrows since 2026-08-07 (the horizontal-layout brief reversed
-- the old after-the-arrows seat: "name · 1/3" reads as one fact), in its
-- reserved width so it can grow a digit without moving the arrows. A dash for
-- the position when what's armed isn't one of this project's pins (a library
-- sound picked in the browser).
function refpicker.draw_count(ctx, state, w)
  local list = pin_list(state)
  if not list or #list == 0 or w <= 0 then return end
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local i = pins.index_of(state.pins.data, state.selected_id)
  local text = string.format("%s/%d", i and tostring(i) or "\u{2013}", #list)

  local small = theme.push_small_font(ctx)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  reaper.ImGui_Dummy(ctx, w, ctrl)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  -- TEXT_SECONDARY since 2026-08-06 (user: "quite dark/hard to read") — the
  -- count is a thing the user actually reads, and tokens.md reserves
  -- QUATERNARY for what nobody has to.
  reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx),
    (x0 + x1) * 0.5 - tw * 0.5, (y0 + y1) * 0.5 - th * 0.5, T.TEXT_SECONDARY, text)
  if small then reaper.ImGui_PopFont(ctx) end
end

--------------------------------------------------------------- the list popup

-- An edit-mode control: BARE — no frame and no fill until the cursor is on it
-- (user's call, 2026-08-06, made knowing they had overruled the same look in
-- the browser's toolbar; a row is not a toolbar, and three framed squares per
-- row put nine boxes on screen at once). Drawn at the ROW's full height rather
-- than as a fixed square, which is what makes every one of them line up.
-- The control itself is widgets.glyph_button since the match window adopted
-- the same look (2026-08-06) — repeated behaviour lives in ui.widgets.
local edit_button = function(ctx, font, id, glyph, fallback, w, h, tip, hot_color)
  return widgets.glyph_button(ctx, font, id, glyph, fallback, w, h, tip, hot_color)
end

-- What edit mode's two buttons occupy at the row's right edge.
--
-- This is NOT reserved out of edit mode (user's call, 2026-08-06, reversing the
-- morning's decision): the name gets the whole row and is cut only by the
-- duration, and the buttons simply take that space over when edit mode opens.
-- Reserving it always meant every name was clipped early to protect a mode
-- nobody is in most of the time — dead space in the one place the row has
-- something to say. The cost, accepted deliberately: the name's cut-off point
-- moves when edit mode opens, which is a state-driven layout change of exactly
-- the kind this project's rules otherwise forbid.
local function tools_zone_w()
  return M.PICK_TOOL_W * 2 + M.PICK_TOOL_GAP
end

-- One row, rebuilt 2026-08-06 after the user reported the first version as
-- clunky. Three things changed, each tied to a symptom:
--
--   * every row is the SAME height now (PICK_ROW_H). A labeled pin still gets
--     two lines and an unlabeled one a single centred line — the user's own
--     choice from the design brief — they just no longer have different heights.
--   * the drag handle is GONE. Dragging a row out to the timeline is already
--     suppressed in edit mode, so in edit mode the row body itself is the
--     handle. That deletes a control, deletes the left-hand shift the user
--     complained about, and deletes code.
--   * the row is an InvisibleButton with its fill drawn by hand, not a
--     Selectable. ImGui grows a Selectable's rectangle by half ItemSpacing.y
--     above and below so a list of them has no seams; at the theme's 8px that
--     overhang lands on the neighbours, and a hovered row lights the rows
--     either side of it — the "hovering one row highlights all of them" bug,
--     the same one reported in the browser's table on 2026-08-01. Drawing the
--     fill ourselves removes the overhang question entirely AND lets the fill
--     span the whole row in both modes.
local function draw_row(ctx, state, res, p, w)
  local action
  local font = res and res.icon_font
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local labeled = p.label and p.label ~= ""
  local h = M.PICK_ROW_H
  local tools_w = tools_zone_w()

  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local x1, y1 = x0 + w, y0 + h
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  -- The hit area stops short of the edit controls so it can't swallow their
  -- clicks. Only the invisible area changes with mode — every drawn thing below
  -- spans the full row either way, so nothing visibly moves.
  -- Zero vertical ItemSpacing while the row item is submitted, so consecutive
  -- rows sit FLUSH — a list wants no seams, and the theme's global 8px was the
  -- "extra spacing around the rows" the user reported. Pushed around this one
  -- call and popped straight after, the same idiom the browser's table uses.
  local spacing_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local hit_w = ui.edit_mode and (w - tools_w - M.PICK_TOOL_LEAD) or w
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), spacing_x, 0)
  -- InvisibleButton behaves exactly like a Button: it returns true on the
  -- RELEASE of a press that started on it. That matters — a press that turns
  -- into a drag never returns true, which is what lets the same gesture be
  -- "click to arm" and "pull out to the timeline" without them fighting.
  local pressed = reaper.ImGui_InvisibleButton(ctx, "##pinrow_" .. p.id, math.max(1, hit_w), h)
  reaper.ImGui_PopStyleVar(ctx, 1)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local held = reaper.ImGui_IsItemActive(ctx)

  -- Remembered for the reorder drag below (reused in place, never re-allocated).
  row_n = row_n + 1
  local r = row_rects[row_n]
  if not r then r = {}; row_rects[row_n] = r end
  r.id, r.y0, r.y1 = p.id, y0, y1

  local selected = state.selected_id == p.id
  local fill = selected and T.FILL_SECONDARY or (hovered and T.FILL_TERTIARY or nil)
  if fill then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, fill, 4)
  end

  if ui.edit_mode then
    -- Edit mode: the row body IS the reorder handle. A click alone does nothing
    -- here — arming a reference is the list's normal-mode job, and letting a
    -- click both arm and start a drag is exactly the gesture collision that
    -- made the handle necessary in the first place.
    if held and reaper.ImGui_IsMouseDragging(ctx, 0) then
      ui.drag_id = p.id
      claim_project(state)
    end
    -- The cursor is half the affordance now that the grip is gone; the other
    -- half is the tooltip, emitted at the end of this function with whatever
    -- else the row has to say.
    if hovered and REORDER_CURSOR then reaper.ImGui_SetMouseCursor(ctx, REORDER_CURSOR) end
  else
    if pressed then
      -- The list deliberately STAYS OPEN (user's call, 2026-08-06 — supersedes
      -- the brief's "click a row = choose + close"): comparing references means
      -- picking several in a row, and reopening the list between each was the
      -- friction. Click outside or press Esc to dismiss it.
      --
      -- `quiet` = arming a reference never starts playback of its own (the
      -- user's call the same day). Choosing what the transport will A/B against
      -- is not a request to hear it right now.
      action = { type = "select_sound", id = p.id, quiet = true }
    end
    -- Dragging the row BODY means "pull this out" — onto the REAPER timeline, or
    -- onto a category in the browser's sidebar (which files it into the library).
    -- That is the only route those two actions have.
    if state.deps.drag_out and not state.drag
      and held and reaper.ImGui_IsMouseDragging(ctx, 0) then
      action = action or { type = "drag_sound", id = p.id }
      -- Get out of the way: the drop lands somewhere this list is covering.
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
  end

  -- What ends the row on the right: the duration normally, edit mode's two
  -- buttons instead. The name is cut against whichever is actually there — it
  -- is never cut short to hold space for the other.
  local right_w = tools_w
  if not ui.edit_mode then
    local dur = fmt_duration(p.duration)
    local small = theme.push_small_font(ctx)
    local dw, dh = reaper.ImGui_CalcTextSize(ctx, dur)
    reaper.ImGui_DrawList_AddText(dl, x1 - pad_x - dw, px((y0 + y1) * 0.5 - dh * 0.5),
      T.TEXT_TERTIARY, dur)
    if small then reaper.ImGui_PopFont(ctx) end
    right_w = dw
  end
  local text_w = (x1 - x0) - pad_x * 2 - right_w - M.PICK_TOOL_LEAD

  -- `cut` = something didn't fit and is showing an ellipsis. That's the ONLY
  -- case that earns a name tooltip: a tooltip repeating what is already fully
  -- readable on the row is noise that follows the cursor around.
  local cut = false
  if labeled then
    -- Two lines, each centred in its own half of the row.
    local caps = p.label:upper()
    local top = ellipsize(ctx, caps, text_w)
    cut = top ~= caps
    local _, th = reaper.ImGui_CalcTextSize(ctx, top)
    reaper.ImGui_DrawList_AddText(dl, x0 + pad_x, px(y0 + h * 0.25 - th * 0.5), T.TEXT_PRIMARY, top)
    local small = theme.push_small_font(ctx)
    local sub = ellipsize(ctx, p.name, text_w)
    cut = cut or sub ~= p.name
    local _, sh = reaper.ImGui_CalcTextSize(ctx, sub)
    reaper.ImGui_DrawList_AddText(dl, x0 + pad_x, px(y1 - h * 0.25 - sh * 0.5), T.TEXT_TERTIARY, sub)
    if small then reaper.ImGui_PopFont(ctx) end
  else
    local only = ellipsize(ctx, p.name, text_w)
    cut = only ~= p.name
    local _, th = reaper.ImGui_CalcTextSize(ctx, only)
    reaper.ImGui_DrawList_AddText(dl, x0 + pad_x, px((y0 + y1) * 0.5 - th * 0.5), T.TEXT_PRIMARY, only)
  end

  if ui.edit_mode then
    -- Placed in the zone reserved above, centred on the row — the row is a
    -- fixed height now, so this is one subtraction, not centring arithmetic per
    -- row shape.
    reaper.ImGui_SetCursorScreenPos(ctx, x1 - pad_x - tools_w, px(y0 + (h - ctrl) * 0.5))
    -- The pencil brightens to TEXT_PRIMARY under the cursor — the same "this is
    -- the one you're on" answer the cross gives, in the colour the theme
    -- already uses for an active value. No new token, and it keeps red meaning
    -- destructive rather than merely hovered.
    if edit_button(ctx, font, "ren_" .. p.id, "pencil", "\u{270E}", M.PICK_TOOL_W, ctrl,
        "Add a label to this reference", T.TEXT_PRIMARY) then
      -- Opened once we're clear of this popup (see draw_popup): one naming
      -- dialog in the app, and rows keep their height.
      ui.label_id, ui.label, ui.open_label = p.id, p.label or "", true
      claim_project(state)
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, M.PICK_TOOL_GAP)
    -- The cross goes RED under the cursor: it is the only control in the picker
    -- that takes something away, and it sits one pixel from the pencil.
    if edit_button(ctx, font, "unpin_" .. p.id, "x", "\u{2715}", M.PICK_TOOL_W, ctrl,
        "Unpin this reference. Its audio stays in the project's References folder.",
        T.DANGER_RED) then
      action = action or { type = "unpin", id = p.id }
    end
    -- Put the cursor back below the row: the buttons were placed absolutely and
    -- are shorter than it, so ImGui's own advance would leave the next row
    -- overlapping this one.
    reaper.ImGui_SetCursorScreenPos(ctx, x0, y1)
  end

  -- The row's tooltip, LAST and in one place. A cut-off name is spelled out in
  -- full here — the row is the only place it appears, and a name is exactly the
  -- thing a user leans in to read. In edit mode it also carries the affordance
  -- the drag handle used to be. Emitted after everything else so it can never
  -- fight the edit buttons' own tooltips (hovering one of those means the row
  -- itself isn't hovered, since its hit area stops short of them).
  if hovered then
    local tip
    if cut then
      tip = labeled and (p.label:upper() .. "\n" .. p.name) or p.name
    end
    if ui.edit_mode then
      tip = tip and (tip .. "\n\nDrag to reorder") or "Drag to reorder"
    end
    tips.show(ctx, hovered, tip)
  end

  return action
end

-- Where the pin being dragged would be INSERTED if it were released now: the
-- gap it is hovering, as an index into the list as it stands (1 = before the
-- first row, row_n + 1 = after the last). Read from the rectangles the rows
-- just drew, so it can never disagree with what's on screen.
local function drop_index(ctx)
  if row_n == 0 then return nil end
  local my = select(2, reaper.ImGui_GetMousePos(ctx))
  for i = 1, row_n do
    local r = row_rects[i]
    if my < (r.y0 + r.y1) * 0.5 then return i end
  end
  return row_n + 1
end

-- Turning that gap into the position `reorder` wants is pure list arithmetic
-- with an off-by-one in it, so it lives in core.pins.drop_target where it has
-- tests, not here.

-- The list itself: plain rows, no search box (brief page 12 — a project's pin
-- list is small enough to read). Click a row to arm it and close. The bottom
-- edge carries the one way into edit mode (page 19, the user's pick — the same
-- shape "+ New category" has on the sidebar's bottom edge).
function refpicker.draw_popup(ctx, state, res)
  local action

  if ui.open_request then
    ui.open_request = false
    if ui.anchor_x then
      -- Anchored under the slot. ImGui keeps a popup inside the monitor's work
      -- area by itself, so over a short docked strip it slides up rather than
      -- being cut off — and a popup is its own OS window here, so it is never
      -- trapped inside the strip (verified: ReaImGui gives every window its own
      -- viewport).
      reaper.ImGui_SetNextWindowPos(ctx, ui.anchor_x, ui.anchor_y + 2)
    end
    reaper.ImGui_OpenPopup(ctx, "refpicker_list")
  end

  local list = pin_list(state)
  -- The list matches the slot it drops from, but only between a floor and a
  -- CEILING. The slot is the bar's flexible element, so on a wide window it
  -- grows without limit and the list was following it into a very long, very
  -- empty box (user-reported 2026-08-06). Past PICK_LIST_MAX_W the extra width
  -- buys nothing: a filename that long is rare, and the ellipsis plus the
  -- hover tooltip already cover it.
  local width = math.min(math.max(ui.anchor_w or 0, M.PICK_LIST_W), M.PICK_LIST_MAX_W)

  if reaper.ImGui_BeginPopup(ctx, "refpicker_list") then
    local ps = state.pins
    if ps and ps.load_error then
      reaper.ImGui_PushTextWrapPos(ctx, width)
      reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY,
        "This project's pinned references couldn't be read, so pinning is paused. " ..
        "Starting with no pinned references won't change the saved project until you save it again.")
      reaper.ImGui_PopTextWrapPos(ctx)
      reaper.ImGui_Dummy(ctx, 0, 4)
      if reaper.ImGui_Button(ctx, "Start With No Pinned References", width) then
        action = { type = "reset_pins" }
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
    elseif not list or #list == 0 then
      reaper.ImGui_PushTextWrapPos(ctx, width)
      reaper.ImGui_TextColored(ctx, T.TEXT_QUATERNARY,
        "No pinned references yet. Drag an audio file here or open the Library.")
      reaper.ImGui_PopTextWrapPos(ctx)
      reaper.ImGui_Dummy(ctx, 0, 4)
      if reaper.ImGui_Button(ctx, "Open Library##empty_refpicker", width) then
        action = { type = "open_browser" }
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
    else
      -- Every row is the same height and they sit flush, so this is a
      -- multiplication rather than a running total. The old version added a
      -- row gap after the LAST row too (Codex, 2026-08-06), which left a dead
      -- strip at the bottom of the list and made it start scrolling a row early.
      local list_h = math.min(#list, M.PICK_LIST_ROWS) * M.PICK_ROW_H

      row_n = 0
      -- The child's background is pushed TRANSPARENT so the rows sit on the
      -- popup's own colour (user-reported 2026-08-06, and their words for the
      -- fix: "the row can just be the same colour as the popup background").
      -- The theme paints every child `BG_WINDOW` and every popup `BG_POPUP`,
      -- which are different greys — so the list was drawing itself as a darker
      -- rectangle inside the menu, a seam nobody chose.
      --
      -- Both pushes are popped the INSTANT the child has taken them: ImGui
      -- reads WindowPadding and ChildBg once, at Begin, and left pushed across
      -- the contents they would also land on every tooltip submitted inside.
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
      local open = reaper.ImGui_BeginChild(ctx, "refpicker_rows", width, list_h)
      reaper.ImGui_PopStyleVar(ctx, 1)
      reaper.ImGui_PopStyleColor(ctx, 1)
      if open then
        -- Measured INSIDE the child: once the list is long enough to scroll, a
        -- scrollbar eats part of the width, and rows sized to the outer width
        -- would summon a horizontal scrollbar as well.
        local inner_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
        for _, p in ipairs(list) do
          local row_action = draw_row(ctx, state, res, p, inner_w)
          action = action or row_action
        end

        -- The reorder drag, resolved against the rows just drawn: a line where
        -- it would land while the button is held, the move itself on release.
        if ui.drag_id then
          ui.drag_to = drop_index(ctx)
          -- The line sits at the gap itself: the top of the row it would land
          -- above, or the bottom of the last row when it would land at the end.
          local edge = ui.drag_to and (row_rects[ui.drag_to] and row_rects[ui.drag_to].y0
            or (row_rects[row_n] and row_rects[row_n].y1))
          if edge then
            local wx = reaper.ImGui_GetWindowPos(ctx)
            reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
              wx, edge - 1, wx + inner_w, edge - 1, T.ACCENT, 2)
          end
          if not reaper.ImGui_IsMouseDown(ctx, 0) then
            -- Resolved against the list as it stands RIGHT NOW, not against the
            -- index the drag started from: a row can vanish mid-drag (unpinned
            -- from elsewhere, or the project switched under us).
            -- Abandoned outright if the user switched project tabs mid-drag:
            -- this id means a different sound over there.
            local to = same_project(state)
              and pins.drop_target(pins.index_of(state.pins.data, ui.drag_id), ui.drag_to)
              or nil
            if to then
              action = action or { type = "reorder_pin", id = ui.drag_id, to = to }
            end
            ui.drag_id, ui.drag_to = nil, nil
          end
        end
        reaper.ImGui_EndChild(ctx)
      end

      -- Edit mode's one entrance, on the list's bottom edge. Full width so the
      -- button never changes size when its label does.
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_Button(ctx, (ui.edit_mode and "Done" or "Edit Pinned References") .. "##refpick_edit", width) then
        ui.edit_mode = not ui.edit_mode
        ui.drag_id, ui.drag_to = nil, nil
      end
      tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), ui.edit_mode
        and "Finish reordering and unpinning"
        or "Reorder, rename and unpin references")
    end
    reaper.ImGui_EndPopup(ctx)
  else
    -- The list closed (a pick, a click outside, Esc): drop any half-finished
    -- reorder rather than letting it resolve against rows nobody can see.
    ui.drag_id, ui.drag_to = nil, nil
  end

  -- The label dialog, opened from a row's pencil once we're clear of the list
  -- popup (OpenPopup can't run inside the popup that's closing). It's the SAME
  -- dialog the browser uses for every other name in the app.
  if ui.open_label then
    reaper.ImGui_OpenPopup(ctx, "refpick_label")
    ui.open_label = false
  end
  local labeled = popups.edit_popup(ctx, ui, "refpick_label", "Label", "label", { allow_empty = true })
  if labeled ~= nil and same_project(state) then
    -- Dropped silently when the project changed while the dialog sat open: the
    -- remembered id names a different pin in the new project.
    action = action or { type = "set_pin_label", id = ui.label_id, label = labeled }
  end

  return action
end

return refpicker
