-- matchwin: the working view's LOUDNESS panel — the target button (◎) beside
-- the trim fader and the window it opens (DESIGN.md "Loudness tools &
-- working-view additions", decided 2026-08-06).
--
-- On screen it is "LOUDNESS", and its custom-target button is "Normalize"
-- (user's rename, 2026-08-11 — it was "MATCH LOUDNESS" / "Match"). The file,
-- the module and every internal name stay `match*`: `core/match.lua` owns the
-- arithmetic and the saved preset keys, and renaming those would throw away
-- the user's stored presets for nothing.
--
-- The popup is the numbers' ONLY home (user's call after three rounds — the
-- corner overlay and hover tooltip were offered and rejected): the armed
-- sound's six measurements, preset rows each showing the trim they would set,
-- a custom row, and Edit presets on the bottom edge. Clicking a preset sets
-- the trim NOW (arithmetic, no analysis — core/match.lua owns the numbers)
-- and becomes the remembered target, named in the button's tooltip.
--
-- It lives in its own file for the same reason refpicker does: one
-- responsibility ("what target, and what trim gets you there"), while
-- transport.lua only decides where the button sits in the bar.
--
-- A ui/ module: reaper.ImGui_* only. Reports intent as actions; the entry
-- script performs them.

local theme = require("ui.theme")
local icons = require("ui.icons")
local widgets = require("ui.widgets")
local tips = require("ui.tips")
local focus = require("ui.focus")
local match = require("core.match")
-- The walkthrough's stop data, PURE core: the finale marks this window as a
-- highlighted region, and reading that here is what avoids a require cycle with
-- ui/walkthrough.lua (which requires this file).
local wt = require("core.walkthrough")
-- The walkthrough's stand-in sound: its numbers fill this window on a tour with
-- an empty library. DISPLAY ONLY — see the `show` vs `sel` split below.
local demo = require("core.demo")
-- Only for pins.drop_target — the tested "insertion gap -> final position"
-- arithmetic the picker's reorder drag uses; the preset list reorders with
-- exactly the same gesture and must not re-derive that off-by-one.
local pins = require("core.pins")
local T = theme.tokens
local M = theme.metrics

local matchwin = {}

-- Transient view state (the refpicker idiom): opening the popup, its anchor,
-- edit mode, the custom row's inputs, and the in-flight preset reorder drag.
-- Never on the shared `state`.
local ui = {
  -- A real WINDOW since 2026-08-06 (user's call), not a popup: a popup dies
  -- on any outside click, and the whole point is keeping the numbers up
  -- while arming different sounds — the readout follows the selection live.
  -- `open` is the standing state; `open_request` marks the frame the button
  -- opened it (that frame positions the window).
  open = false,
  open_request = false,
  -- The button's rect: the window prefers floating above its top edge, and
  -- falls back to below its bottom edge when the screen ends too close above
  -- (user-reported 2026-08-06 — docked top-right, the window opened mostly
  -- off the top of the monitor; an explicitly positioned window is NOT
  -- clamped by ImGui the way an auto-placed popup is).
  anchor_x = nil, anchor_y = nil, anchor_y1 = nil,
  rect = nil, -- last drawn frame's window rect (matchwin.rect, for the walkthrough)
  edit_mode = false,
  custom_unit = 1, -- 0-based Combo index into UNITS
  custom_text = "-16",
  drag_index = nil, -- the preset being dragged by its row body (edit mode)
}

-- The monitor work area's top edge and right edge, if this ReaImGui can say
-- (feature-detected, the house idiom). Falls back to "0 and nothing", which
-- still catches the common case: y < 0 is off every primary screen.
local HAS_VIEWPORT = reaper.ImGui_GetMainViewport ~= nil
  and reaper.ImGui_Viewport_GetWorkPos ~= nil and reaper.ImGui_Viewport_GetWorkSize ~= nil

-- The cursor shown over a draggable preset row — same detection refpicker uses.
local REORDER_CURSOR = (reaper.ImGui_MouseCursor_ResizeNS and reaper.ImGui_MouseCursor_ResizeNS())
  or (reaper.ImGui_MouseCursor_Hand and reaper.ImGui_MouseCursor_Hand())
  or nil

-- Preset row rectangles from the last drawn frame, reused in place (frame
-- rules) — the reorder drag resolves against what is actually on screen.
local prow_rects, prow_n = {}, 0

-- The six units, in the user's reading order: LUFS S -> M -> I, then
-- True Peak · Peak · RMS. The readout lays them out COLUMN-major — the three
-- LUFS down the left, the peaks and RMS down the right (user's call,
-- 2026-08-06: two columns of three, LUFS on the left, so the window can be
-- narrower).
--
-- Every name is spelled out, in the readout and the dropdown alike (user's
-- call, 2026-08-07 — "TP" and "Pk" were shorthand only the writer could read,
-- and "Sample peak" named an implementation detail rather than the thing).
-- The name that follows a preset's VALUE ("-16 LUFS-M") is a different job and
-- comes from core/match.lua, so the window and the status line share one
-- vocabulary there.
local UNITS = {
  { key = "lufs_s_max", tag = "LUFS-S",    combo = "LUFS-S" },
  { key = "lufs_m_max", tag = "LUFS-M",    combo = "LUFS-M" },
  { key = "lufs_i",     tag = "LUFS-I",    combo = "LUFS-I" },
  { key = "true_peak",  tag = "True Peak", combo = "True Peak" },
  { key = "peak",       tag = "Peak",      combo = "Peak" },
  { key = "rms",        tag = "RMS",       combo = "RMS" },
}

-- Built once (frame-allocation rule). This ReaImGui's Combo takes the C API's
-- NUL-separated items and REQUIRES the trailing NUL — it raises
-- "items must be null-terminated" without it (live-verified 2026-08-06; the
-- \31 separator belongs to older ReaImGui versions, not this one).
local COMBO_ITEMS
do
  local parts = {}
  for i, u in ipairs(UNITS) do parts[i] = u.combo end
  COMBO_ITEMS = table.concat(parts, "\0") .. "\0"
end

local function unit_label(key)
  return match.label(key)
end

-- "-16 LUFS-M" — how a target names itself, in the tooltip and on preset rows.
-- %g keeps a whole-number target free of a pointless ".0".
local function fmt_target(unit, value)
  return string.format("%g %s", value, unit_label(unit))
end

-- A trim for display. Mirrors the fader's readout rules: one decimal, an
-- explicit + on boosts, and exactly zero is "0.0", never "+0.0"/"-0.0".
local function fmt_trim(db)
  local r = math.floor(db * 10 + 0.5) / 10
  if r == 0 then return "0.0 dB" end
  return string.format("%+.1f dB", r)
end

local function fmt_meas(v)
  return type(v) == "number" and string.format("%.1f", v) or "\u{2014}"
end

-- One decimal, the precision both the row and the trim fader show. Comparing
-- what is on screen is the point: two trims that read "-3.2 dB" are the same
-- trim as far as the reader is concerned.
local function round1(v) return math.floor(v * 10 + 0.5) / 10 end

-- Snap to a whole pixel (the refpicker rule: a glyph run at a fractional
-- origin renders visibly softer).
local function px(v) return math.floor(v + 0.5) end

-- Whether the window stands open (or is about to, this frame). Read by the
-- walkthrough's finale, whose real-action advance is exactly this turning
-- true — open_request counts, or the tour would lag its own click by a frame.
function matchwin.is_open()
  return ui.open or ui.open_request or false
end

-- Open it from somewhere other than the ◎ — today only the walkthrough's
-- finale, which opens it for the user as the stop is reached. Takes the anchor
-- the ◎ would have supplied (its rect), so the window still stands exactly
-- where clicking the button yourself would have put it; without one it falls
-- back to wherever ImGui last had it.
function matchwin.open_at(x, y_top, y_bottom)
  if ui.open then return end
  ui.rect, ui.settle = nil, 0 -- a fresh open re-settles from scratch
  ui.open_request = true
  ui.edit_mode = false
  ui.anchor_x, ui.anchor_y, ui.anchor_y1 = x, y_top, y_bottom
end

-- Shut it from outside — today only the walkthrough, taking back the window it
-- opened for the finale when the tour ends. Clears the pending request too, so
-- a close on the very frame it was asked for can't leave it opening anyway.
function matchwin.close()
  ui.open, ui.open_request = false, false
  ui.rect, ui.settle = nil, 0
end

-- Last drawn frame's window rect, or nil while it is shut. The walkthrough's
-- card reads it to keep clear of the panel it is describing — it can't ask
-- ImGui itself, being outside this window's scope by then.
function matchwin.rect()
  -- Withheld until the window has SETTLED (see the placement block below).
  -- Handing out the opening frame's rect would place the tour's card against a
  -- window that is about to move, and the card would follow it a frame later.
  if not ui.open or (ui.settle or 0) < 2 then return nil end
  return ui.rect
end

--------------------------------------------------------------- the bar button

-- The ◎ square, LEFT of the trim fader and collapsing with it (transport.lua
-- decides where; the tie to the fader is the design's — the button drives it).
function matchwin.draw_button(ctx, state, res)
  local font = res and res.icon_font
  local target = state.match and state.match.target
  local tip = "Open Loudness. Normalize the selected reference to a target."
    .. (target and ("\nRemembered target: " .. fmt_target(target.unit, target.value)) or "")
  if icons.button(ctx, font, "matchtarget", "target",
      { tip = tip, fallback = icons.draw_target }) then
    -- A toggle now that the window stands open on its own: the button is
    -- also the way to put it away without reaching for its ✕.
    if ui.open then
      ui.open = false
    else
      ui.open_request = true
      ui.edit_mode = false -- a freshly opened window is never already editing
      ui.anchor_x, ui.anchor_y = reaper.ImGui_GetItemRectMin(ctx)
      ui.anchor_y1 = select(2, reaper.ImGui_GetItemRectMax(ctx))
    end
  end
  return nil -- opening is view state; every action comes from the window
end

--------------------------------------------------------------- the readout

-- The armed sound's numbers: labels dim, values bright (the user's explicit
-- readability rule), three cells per line, two lines, fixed geometry.
local function draw_readout(ctx, sel, width)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local line_h = ctrl - 4
  -- Two columns of three (column-major: LUFS down the left), not three of two
  -- — the user's call, 2026-08-06, and what lets the window be narrower.
  reaper.ImGui_Dummy(ctx, width, line_h * 3)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local cell_w = (width - pad_x * 2) / 2

  -- Each cell spreads to its own edges — tag flush left, value flush RIGHT —
  -- with a hairline between the columns (user's call, 2026-08-06: the old
  -- left-packed cells left a ragged run of empty space mid-window). The
  -- divider is what lets the two value columns end at different x without
  -- reading as misalignment.
  local mid = x0 + pad_x + cell_w
  local gutter = 8
  reaper.ImGui_DrawList_AddLine(dl, px(mid), y0 + 2, px(mid), y0 + line_h * 3 - 2, T.STROKE_TERTIARY)

  -- Tags in the PRESET ROWS' exact voice — body size, TEXT_SECONDARY (2026-08-09,
  -- user's ask from the running build: small dim tags were "quite hard to read"
  -- next to rows saying the same unit names comfortably one section down. The
  -- fifth small-text report; same fix as the first three — the element moves to
  -- the body size and colour carries the hierarchy, values staying the brighter
  -- of the two). Widths re-checked: worst cell "True Peak" + "-120.0" at 13px
  -- ≈ 95px in the 110px zone.
  for i, u in ipairs(UNITS) do
    local col, row = math.floor((i - 1) / 3), (i - 1) % 3
    local tx = (col == 0) and (x0 + pad_x) or (mid + gutter)
    local th = select(2, reaper.ImGui_CalcTextSize(ctx, u.tag))
    reaper.ImGui_DrawList_AddText(dl, px(tx),
      px(y0 + row * line_h + (line_h - th) * 0.5), T.TEXT_SECONDARY, u.tag)
  end

  for i, u in ipairs(UNITS) do
    local col, row = math.floor((i - 1) / 3), (i - 1) % 3
    local right_edge = (col == 0) and (mid - gutter) or (x0 + width - pad_x)
    local v = sel and sel[u.key]
    local text = fmt_meas(v)
    local vw, vh = reaper.ImGui_CalcTextSize(ctx, text)
    reaper.ImGui_DrawList_AddText(dl, px(right_edge - vw),
      px(y0 + row * line_h + (line_h - vh) * 0.5),
      type(v) == "number" and T.TEXT_PRIMARY or T.TEXT_QUATERNARY, text)
  end
end

--------------------------------------------------------------- preset rows

-- One preset row: the target on the left, the trim it would set on the right
-- (edit mode: a remove cross instead). The shown trim IS the capped value —
-- clicking sets exactly what the row promised, never more.
-- `show` is the sound the row DESCRIBES, `sel` the one a click would change.
-- They are the same thing except during the walkthrough's demo, where `show` is
-- the stand-in and `sel` is nil: the row then reads as a live row — real target,
-- real trim — while staying unclickable, because there is no sound to trim.
local function draw_preset_row(ctx, state, res, show, sel, p, i, width)
  local action
  local font = res and res.icon_font
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))

  -- One computation feeds the preview, the flag, the tooltip and the click, so
  -- they can never disagree. The second return is the cap that bit when a trim
  -- came back, or the reason when none did.
  local trim, aux = match.trim_for(show, p.unit, p.value)
  local limited = trim and aux or nil
  local why = (not trim) and aux or nil
  local clickable = (not ui.edit_mode) and trim ~= nil and sel ~= nil

  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local x1, y1 = x0 + width, y0 + ctrl
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  -- The hit area stops short of edit mode's cross so it can't swallow its
  -- click (the refpicker row idiom). Rows sit flush: zero vertical spacing
  -- around the row item only.
  local spacing_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local hit_w = ui.edit_mode and (width - M.PICK_TOOL_W - M.PICK_TOOL_LEAD) or width
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), spacing_x, 0)
  local pressed = reaper.ImGui_InvisibleButton(ctx, "##matchpreset_" .. i, math.max(1, hit_w), ctrl)
  reaper.ImGui_PopStyleVar(ctx, 1)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local held = reaper.ImGui_IsItemActive(ctx)

  -- Remembered for the reorder drag (reused in place, never re-allocated).
  prow_n = prow_n + 1
  local r = prow_rects[prow_n]
  if not r then r = {}; prow_rects[prow_n] = r end
  r.y0, r.y1 = y0, y1

  if hovered and (clickable or ui.edit_mode) then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, T.FILL_TERTIARY, 4)
  end

  -- ACCENT means "the trim is AT this row right now" — nothing else. It used to
  -- mean "this was the last target picked", which survives a manual fader move,
  -- so a row stayed lit while the trim had been dragged somewhere else entirely
  -- (user-reported 2026-08-07). The remembered target still names itself in the
  -- ◎ button's tooltip; it just no longer colours anything.
  local at_this = trim ~= nil and sel ~= nil
    and round1(sel.trim_db or 0) == round1(trim)
  local label = fmt_target(p.unit, p.value)
  local lh = select(2, reaper.ImGui_CalcTextSize(ctx, label))
  reaper.ImGui_DrawList_AddText(dl, px(x0 + pad_x), px((y0 + y1) * 0.5 - lh * 0.5),
    at_this and T.ACCENT or T.TEXT_SECONDARY, label)

  if ui.edit_mode then
    -- Edit mode: the row body is the reorder handle (the picker's exact
    -- gesture — the click already means nothing here, so the body is free).
    if held and reaper.ImGui_IsMouseDragging(ctx, 0) then
      ui.drag_index = i
    end
    if hovered and REORDER_CURSOR then reaper.ImGui_SetMouseCursor(ctx, REORDER_CURSOR) end
    reaper.ImGui_SetCursorScreenPos(ctx, x1 - pad_x - M.PICK_TOOL_W, y0)
    if widgets.glyph_button(ctx, font, "matchdel_" .. i, "x", "\u{2715}",
        M.PICK_TOOL_W, ctrl, "Remove this preset", T.DANGER_RED) then
      action = { type = "remove_match_preset", index = i }
    end
    reaper.ImGui_SetCursorScreenPos(ctx, x0, y1)
  else
    -- The trim this preset would set, right-aligned. "—" when this sound has
    -- no number in the preset's unit. When the fader can't reach the target,
    -- "short X dB" gives the honest distance between what was asked and what a
    -- click will set (user's ask, 2026-08-06: a plain "capped" hid how far off
    -- it was).
    -- The trim value right-aligns inside a FIXED zone sized for the widest
    -- possible reading, so the flag beside it sits at one x whatever the
    -- number says (user's call, 2026-08-06 — a flag that wandered with the
    -- digits read as ragged).
    local trim_zone = select(1, reaper.ImGui_CalcTextSize(ctx, "+24.0 dB"))
    local text = trim and fmt_trim(trim) or "\u{2014}"
    local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
    reaper.ImGui_DrawList_AddText(dl, px(x1 - pad_x - tw), px((y0 + y1) * 0.5 - th * 0.5),
      trim and T.TEXT_PRIMARY or T.TEXT_QUATERNARY, text)
    if limited then
      -- RED (user's call, 2026-08-07): this says the click will NOT get you
      -- where you asked, which is the reading a glance must not miss.
      local flag = string.format("short %.1f dB", math.abs((p.value - show[p.unit]) - trim))
      local small = theme.push_small_font(ctx)
      local cw, ch = reaper.ImGui_CalcTextSize(ctx, flag)
      reaper.ImGui_DrawList_AddText(dl, px(x1 - pad_x - trim_zone - 8 - cw), px((y0 + y1) * 0.5 - ch * 0.5),
        T.DANGER_RED, flag)
      if small then reaper.ImGui_PopFont(ctx) end
    end

    if pressed and clickable then
      -- The window STAYS OPEN on a pick (user's call, 2026-08-06 — same as
      -- the reference list: comparing targets means clicking several).
      action = { type = "match_trim", db = trim, limited = limited, unit = p.unit, value = p.value }
    end
  end

  if hovered then
    local tip
    if ui.edit_mode then
      tip = "Drag to reorder"
    elseif not sel then
      tip = "Choose a reference first. Normalize sets the selected reference's trim."
    elseif why == "unmeasured" then
      tip = "No " .. unit_label(p.unit) .. " measurement is available. It may still be analysing, or the audio may have no measurable signal."
    elseif limited == "range" then
      tip = string.format("This target needs more than the trim fader's +%g dB range. Selecting it sets the closest available trim.", match.TRIM_MAX)
    else
      tip = "Set the selected reference's trim and remember this target."
    end
    tips.show(ctx, hovered, tip)
  end

  return action
end

--------------------------------------------------------------- the target row

-- Unit dropdown + typed number + Normalize ("Match" until 2026-08-11, the
-- user's rename). Sits directly under the readout, in the same section as the
-- six measurements it aims at. In edit mode the button becomes Add and the same
-- two inputs describe the preset being added.
-- Same `show` vs `sel` split as the preset rows: the custom target reads its
-- trim off the sound being DESCRIBED, and the Normalize button stays dead
-- unless there is a real armed sound to apply it to.
local function draw_target_row(ctx, show, sel, presets, width)
  local action
  local small = theme.push_heading_font(ctx)
  reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, "SET LOUDNESS")
  if small then reaper.ImGui_PopFont(ctx) end

  -- The Combo paints its arrow square Col_Button and its text area FrameBg —
  -- two different fills in this theme, a seam the user read as a mistake
  -- (2026-08-06). One control, one colour: the arrow zone takes the frame's
  -- own fills, hover variant included, so the whole box reads as one piece
  -- the way the picker's name slot does.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
    reaper.ImGui_GetStyleColor(ctx, reaper.ImGui_Col_FrameBg()))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
    reaper.ImGui_GetStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered()))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),
    reaper.ImGui_GetStyleColor(ctx, reaper.ImGui_Col_FrameBgActive()))
  reaper.ImGui_SetNextItemWidth(ctx, M.MATCH_UNIT_W)
  local changed, idx = reaper.ImGui_Combo(ctx, "##matchunit", ui.custom_unit, COMBO_ITEMS)
  reaper.ImGui_PopStyleColor(ctx, 3)
  if changed then ui.custom_unit = idx end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, M.MATCH_VAL_W)
  local edited, text = reaper.ImGui_InputText(ctx, "##matchvalue", ui.custom_text,
    reaper.ImGui_InputTextFlags_CharsDecimal())
  if edited then ui.custom_text = text end
  reaper.ImGui_SameLine(ctx)

  local unit = UNITS[ui.custom_unit + 1]
  local value = tonumber(ui.custom_text)
  local btn_w = width - M.MATCH_UNIT_W - M.MATCH_VAL_W
    - select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())) * 2
  if ui.edit_mode then
    local full = #presets >= match.PRESET_MAX
    -- The same target twice would be two rows doing one job (user's rule,
    -- 2026-08-06) — the Add button simply refuses, and says why.
    local dup = false
    if unit and value then
      for _, p in ipairs(presets) do
        if p.unit == unit.key and p.value == value then dup = true break end
      end
    end
    local ok_add = unit and value and not full and not dup
    if not ok_add then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Add##matchadd", btn_w, 0) and ok_add then
      action = { type = "add_match_preset", unit = unit.key, value = value }
    end
    if not ok_add then reaper.ImGui_EndDisabled(ctx) end
    local tip = "Save this target as a preset."
    if dup then tip = "This target is already a preset."
    elseif full then tip = "The preset list is full (" .. match.PRESET_MAX .. "). Remove a preset first." end
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), tip)
  else
    local trim, aux
    if unit and value then trim, aux = match.trim_for(show, unit.key, value) end
    local why = (not trim) and aux or nil
    local ok_match = trim ~= nil and sel ~= nil
    if not ok_match then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Normalize##matchcustom", btn_w, 0) and ok_match then
      -- Stays open, like a preset pick.
      action = { type = "match_trim", db = trim, limited = trim and aux or nil,
        unit = unit.key, value = value }
    end
    if not ok_match then reaper.ImGui_EndDisabled(ctx) end
    local tip
    if not value then tip = "Type a target value first."
    elseif not sel then tip = "Choose a reference first."
    elseif why == "unmeasured" then
      tip = "No " .. unit_label(unit.key) .. " measurement is available. It may still be analysing, or the audio may have no measurable signal."
    elseif trim then tip = "Set the selected reference's trim to " .. fmt_trim(trim) .. "." end
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), tip)
  end

  return action
end

--------------------------------------------------------------- the popup

function matchwin.draw_popup(ctx, state, res)
  local action
  local width = M.MATCH_WIN_W

  if ui.open_request then
    ui.open_request = false
    ui.open = true
    ui.settle = 0
  end

  -- Placement is asserted for the first TWO frames, not just the opening one.
  -- An auto-resizing window has no content size on its first frame, and this
  -- one is anchored by its BOTTOM edge — so frame one resolves that anchor
  -- against a size that isn't real yet and the window lands short, then jumps
  -- once ImGui has measured it (user-reported 2026-08-11, the finale's panel
  -- and the tour card beside it both hopping). The second pass uses the real
  -- height and settles it for good. After that the assertion stops and the
  -- window is draggable as before.
  if ui.open and ui.anchor_x and (ui.settle or 0) < 2 then
    -- ABOVE the button by preference, BELOW it when the monitor ends too
    -- close overhead — an explicitly positioned window gets NO clamping
    -- from ImGui, so with the tool docked along REAPER's top edge "above"
    -- meant mostly off-screen (user-reported 2026-08-06). The first pass has
    -- to ESTIMATE the height (title bar, readout, preset rows, control rows,
    -- separators and padding, erring tall — guessing tall merely flips to
    -- "below" a touch early); the second can also weigh what the window
    -- measured.
    -- The TALLER of the two wins, never the measurement alone: a window on its
    -- opening frame reports only its decorations (ImGui auto-fits from a
    -- content size it doesn't have yet), so pass two used to read ~40px, decide
    -- there was room overhead, and pin the panel's BOTTOM to the button — after
    -- which it grew to full height straight off the top of the screen and
    -- stayed there, placement being over (user-reported 2026-08-11, first open
    -- of a session; later opens were fine because ui.rect still held the real
    -- height from the previous open).
    local ctrl = reaper.ImGui_GetFrameHeight(ctx)
    local n = (state.match and state.match.presets and #state.match.presets) or 0
    local est_h = (n + 6) * ctrl + 70
    if ui.rect then est_h = math.max(est_h, ui.rect.y2 - ui.rect.y1) end
    local top, right = 0, nil
    if HAS_VIEWPORT then
      local vp = reaper.ImGui_GetMainViewport(ctx)
      local vx, vy = reaper.ImGui_Viewport_GetWorkPos(vp)
      local vw = select(1, reaper.ImGui_Viewport_GetWorkSize(vp))
      top, right = vy, vx + vw
    end
    -- The right edge gets the same care: the button sits near the bar's
    -- right end, and the window is wider than what's left of a docked strip.
    local wx = ui.anchor_x
    if right and wx + width + 16 > right then wx = right - width - 16 end
    if ui.anchor_y - 2 - est_h >= top then
      reaper.ImGui_SetNextWindowPos(ctx, wx, ui.anchor_y - 2,
        reaper.ImGui_Cond_Always(), 0, 1)
    else
      reaper.ImGui_SetNextWindowPos(ctx, wx, (ui.anchor_y1 or ui.anchor_y) + 2,
        reaper.ImGui_Cond_Always(), 0, 0)
    end
  end

  if not ui.open then
    ui.drag_index = nil
    return nil
  end

  -- A real window (2026-08-06, user's call — a popup closes on any outside
  -- click, and this one must stand while sounds are armed under it; the
  -- readout follows the live selection). Auto-resizing height at a fixed
  -- content width; never a REAPER-docker tab; position not remembered in the
  -- ini — it re-derives from the button every open.
  local flags = reaper.ImGui_WindowFlags_NoCollapse()
    | reaper.ImGui_WindowFlags_AlwaysAutoResize()
    | reaper.ImGui_WindowFlags_NoSavedSettings()
  if reaper.ImGui_WindowFlags_NoDocking then
    flags = flags | reaper.ImGui_WindowFlags_NoDocking()
  end
  -- Whether the walkthrough's finale is pointing at this window. Read from the
  -- shared state through the PURE core module — requiring ui/walkthrough.lua
  -- here would close a cycle, since that file already requires this one.
  local ringed = wt.current(state.walkthrough)
  ringed = type(ringed) == "table" and ringed.panel == "match"
  -- Centred title (user's call, 2026-08-07): this one is a small floating panel
  -- whose name sits over its own contents, not a full app window whose title
  -- reads as a label on the left.
  -- Titled "LOUDNESS" since 2026-08-11 (user's call — "MATCH LOUDNESS" until
  -- then): the panel shows the numbers as much as it sets them, and "match"
  -- named only half of it. The ### id is unchanged on purpose — it is what
  -- ImGui keys the window by, and renaming it would drop its remembered state.
  local visible, still_open = theme.begin_window(ctx, "LOUDNESS###yb_matchwin",
    true, flags, true)
  if not still_open then ui.open = false end
  -- No End on this path: ReaImGui's Begin already called ImGui::End itself when
  -- it returned false (api/window.cpp, verified 2026-08-09) — an extra End here
  -- pops the PARENT window. End belongs to the visible path only, the contract
  -- app.lua documents and the bundled demo follows.
  if not visible then
    ui.drag_index = nil
    return nil
  end

  -- This frame's rect, for the walkthrough card's placement (matchwin.rect) and
  -- for the highlight below, plus the settle counter the placement above reads.
  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww, wh = reaper.ImGui_GetWindowSize(ctx)
  ui.rect = { x1 = wx, y1 = wy, x2 = wx + ww, y2 = wy + wh }
  ui.settle = (ui.settle or 0) + 1

  -- The walkthrough's highlight: an accent line around the OUTSIDE EDGE only,
  -- hand-drawn rather than pushed into `Col_Border`. That slot also paints the
  -- hairline UNDER the title bar, which turned blue with it and read as a stray
  -- line through the panel (user-reported 2026-08-11). Drawn a half pixel inside
  -- the window so the stroke lands ON the border rather than being clipped, and
  -- on the foreground list so the panel's own contents can't cover it. The wash
  -- never reaches this window — a window of its own is a viewport of its own —
  -- so this line is the only mark available here.
  if ringed and reaper.ImGui_GetForegroundDrawList then
    reaper.ImGui_DrawList_AddRect(reaper.ImGui_GetForegroundDrawList(ctx),
      wx + 0.5, wy + 0.5, wx + ww - 0.5, wy + wh - 0.5, T.ACCENT, 8, 0, 1)
  end

  local sel = state.selected
  -- What the window DESCRIBES. Everything that reads numbers uses this; every
  -- action still keys off `sel`, so a demo can be looked at and never touched.
  local show = state.demo and demo.SOUND or sel
  local presets = (state.match and state.match.presets) or {}

  -- Every section of the window is named (user's call, 2026-08-07) — the six
  -- numbers were the one anonymous block, and the target row under them read as
  -- controls with no job. "This reference" over the numbers, because they follow
  -- whatever is armed rather than describing a fixed thing.
  --
  -- Headings are BOLD and TEXT_PRIMARY (2026-08-08/09, both the user's call).
  -- They were small dim regular text, which is the treatment for metadata
  -- sitting beside something louder — and a heading has nothing louder to sit
  -- beside. Weight is what makes it lead now, so it needs no size step and no
  -- colour step; see theme.push_heading_font.
  local small = theme.push_heading_font(ctx)
  reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, "THIS REFERENCE")
  if small then reaper.ImGui_PopFont(ctx) end
  -- The armed sound's numbers — the window is their only home. Without a
  -- selection the cells hold dashes and one dim line says why.
  draw_readout(ctx, show, width)
  if not sel then
    reaper.ImGui_PushTextWrapPos(ctx, width)
    reaper.ImGui_TextColored(ctx, T.TEXT_QUATERNARY, state.demo
      and ("Example numbers, from " .. demo.NAME)
      or "No reference selected. Choose a reference to normalize it to a target.")
    reaper.ImGui_PopTextWrapPos(ctx)
  end
  -- One rule for the whole window: a divider opens each section and nothing
  -- separates a section from its own contents. So a line lands above SET
  -- LOUDNESS and above PRESET TARGETS, and none above Edit presets — that
  -- button belongs to the preset list, not to a fourth thing (user's call,
  -- 2026-08-07; "SET A TARGET" until 2026-08-09).
  reaper.ImGui_Separator(ctx)
  -- Drawn first, merged second: `action = action or draw_…()` short-circuits in
  -- Lua, so a frame that already had an action would skip the row entirely.
  local target_action = draw_target_row(ctx, show, sel, presets, width)
  action = action or target_action

  reaper.ImGui_Separator(ctx)
  local psmall = theme.push_heading_font(ctx)
  reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, "PRESET TARGETS")
  if psmall then reaper.ImGui_PopFont(ctx) end

  prow_n = 0
  for i, p in ipairs(presets) do
    local row_action = draw_preset_row(ctx, state, res, show, sel, p, i, width)
    action = action or row_action
  end
  if #presets == 0 then
    reaper.ImGui_TextColored(ctx, T.TEXT_QUATERNARY,
      "No presets yet. Choose Edit Presets to add one.")
  else
    -- The rows sit flush (their own ItemSpacing is zeroed), which also swallows
    -- the gap between the LAST row and whatever follows it (user-reported
    -- 2026-08-06). A zero-height item hands the theme's normal spacing back
    -- without inventing a second gap value.
    reaper.ImGui_Dummy(ctx, 0, 0)
  end

  -- The preset reorder drag (edit mode), resolved against the rows just
  -- drawn — the picker's exact mechanics: an insertion line at the gap while
  -- held, the move itself on release, the tested gap arithmetic in core.
  if ui.drag_index then
    local gap_i = nil
    if prow_n > 0 then
      local my = select(2, reaper.ImGui_GetMousePos(ctx))
      for ri = 1, prow_n do
        if my < (prow_rects[ri].y0 + prow_rects[ri].y1) * 0.5 then gap_i = ri break end
      end
      gap_i = gap_i or (prow_n + 1)
      local edge = prow_rects[gap_i] and prow_rects[gap_i].y0
        or (prow_rects[prow_n] and prow_rects[prow_n].y1)
      if edge then
        local wx = reaper.ImGui_GetWindowPos(ctx)
        reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
          wx, edge - 1, wx + width, edge - 1, T.ACCENT, 2)
      end
    end
    if not reaper.ImGui_IsMouseDown(ctx, 0) then
      local to = gap_i and pins.drop_target(ui.drag_index, gap_i) or nil
      if to and presets[ui.drag_index] then
        action = action or { type = "reorder_match_preset", from = ui.drag_index, to = to }
      end
      ui.drag_index = nil
    end
  end

  -- ("Match all pins to target" lived above the bottom edge until 2026-08-06,
  -- built — the user found it off in this window and asked for it gone. The
  -- arithmetic, match.bulk, stays in core with its specs in case it returns
  -- with a better home.)

  -- Edit presets, the bottom edge — the same shape the picker's edit mode and
  -- the sidebar's "+ New category" have. No divider above it: it edits the list
  -- it sits under, and a line there made it read as a section of its own.
  if reaper.ImGui_Button(ctx, (ui.edit_mode and "Done" or "Edit Presets") .. "##matchedit", width, 0) then
    ui.edit_mode = not ui.edit_mode
  end
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), ui.edit_mode
    and "Finish editing the preset list"
    or "Add, remove and reorder preset targets")

  -- Esc puts the window away while it has focus — the one popup habit worth
  -- keeping now that outside clicks deliberately don't.
  if reaper.ImGui_IsWindowFocused(ctx)
    and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    ui.open = false
    -- The window Esc dismisses was the focused one — hand focus back to
    -- REAPER rather than leaving it on a window that's about to vanish.
    focus.request()
  end

  reaper.ImGui_End(ctx)
  return action
end

return matchwin
