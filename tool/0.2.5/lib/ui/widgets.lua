-- widgets: the shared library of reusable UI controls. Every control that appears
-- more than once — or that carries a standard behaviour (a fader, a toggle, the
-- reset gesture) — is defined HERE, once, so every screen gets exactly the same
-- thing. This is the same discipline theme.lua enforces for colour: never hand-roll
-- a fader or toggle inline in a screen and never invent a one-off interaction; add
-- it here (or extend the one here) and call it. That's what keeps the whole UI
-- behaving consistently instead of drifting per button.
--
-- A ui/ module: it may call reaper.ImGui_* only.

local theme = require("ui.theme")
local icons = require("ui.icons")
local T = theme.tokens
local M = theme.metrics

local widgets = {}

-- The one standard "reset to default" gesture for ANY adjustable control (faders,
-- and later knobs/xy-pads): right-click OR double-click. Defined once so every such
-- control resets identically — right-click has no value jump, double-click matches
-- DAW muscle memory. Call right after submitting the control (it reads "last item").
function widgets.wants_reset(ctx)
  return reaper.ImGui_IsItemHovered(ctx)
    and (reaper.ImGui_IsMouseClicked(ctx, 1) or reaper.ImGui_IsMouseDoubleClicked(ctx, 0))
end

-- DrawList colours ignore the style Alpha (which BeginDisabled lowers), so custom
-- drawing must fade itself or a disabled fader would render at full strength.
local function fade(col, alpha)
  if alpha >= 1 then return col end
  local a = math.floor((col & 0xFF) * alpha + 0.5)
  return (col & ~0xFF) | a
end

-- Fader ids whose current mouse-hold must NOT drag: a reset fired mid-hold (double
-- click, or right-click during a drag), and without this the very next frame's drag
-- would yank the value straight back to the mouse position, undoing the reset.
-- Cleared when that hold ends. Bounded: one entry per fader id, only while held.
local reset_hold = {}

-- A dB fader, custom-drawn: slim track, accent fill, slim pill knob, and the value
-- as a fixed readout to the RIGHT of the track — never under the knob, so it stays
-- readable mid-drag, and the knob (taller than the track) stays visible parked at
-- the extremes. Total width is M.SLIDER_W and never resizes with state.
-- A range that crosses 0 (trim) fills from the 0 dB detent outward; a cut-only
-- range (master) fills from the left like a level.
-- Reports the live value every drag frame with a `commit` flag set only on release,
-- so callers persist once instead of every frame; resets to `opts.default` on the
-- standard reset gesture. opts = { min, max, default, tip }.
-- Returns (value, commit) when something changed this frame, else nil.
function widgets.db_fader(ctx, id, value, opts)
  opts = opts or {}
  local min, max = opts.min or -24, opts.max or 24
  local h = reaper.ImGui_GetFrameHeight(ctx)
  -- `opts.width` lets a narrow host (the side column) say how much room the whole
  -- control has; `opts.stacked` moves the readout BENEATH the track instead of
  -- beside it, which is the only way to have no reserved zone at all — and so no
  -- gap — when the column is barely wider than the number itself.
  local total_w = opts.width or M.SLIDER_W
  local stacked = opts.stacked == true
  local track_w = stacked and total_w or (total_w - M.FADER_VAL_W - M.FADER_VAL_GAP)
  if track_w < 8 then track_w = 8 end
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)

  -- Only the track is interactive; the readout is plain text beside it, so a click
  -- on the number can't jump the value to the far end of the range.
  reaper.ImGui_BeginGroup(ctx)
  reaper.ImGui_InvisibleButton(ctx, "##" .. id, track_w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  if opts.tip and hovered then reaper.ImGui_SetTooltip(ctx, opts.tip) end

  -- Resolve this frame's result. Reset wins over the drag value on the same frame,
  -- and always persists.
  local result, commit
  if widgets.wants_reset(ctx) then
    if active then reset_hold[id] = true end
    result, commit = (opts.default or 0), true
  elseif active and not reset_hold[id] then
    local mx = select(1, reaper.ImGui_GetMousePos(ctx))
    local t = (mx - x0) / track_w
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    -- Snap to 0.1 dB so the value IS what the readout shows.
    local v = math.floor((min + t * (max - min)) * 10 + 0.5) / 10
    if v ~= (value or 0) then result, commit = v, false end
  elseif reaper.ImGui_IsItemDeactivated(ctx) then
    if reset_hold[id] then
      reset_hold[id] = nil -- the reset already committed; this hold stays inert
    else
      -- The caller applied each dragged value back into `value`, so on the release
      -- frame it already holds the final position — persist it once.
      result, commit = (value or 0), true
    end
  end
  local shown = result or value or 0

  -- Geometry: everything vertically centred in the frame-height hit box. In the
  -- stacked form the track sits in the upper part to leave room for the number
  -- underneath, and the whole control still occupies exactly one frame height.
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local cy = stacked and (y0 + h * 0.30) or (y0 + h * 0.5)
  local half_t = M.FADER_TRACK_H * 0.5
  local t_shown = (shown - min) / (max - min)
  if t_shown < 0 then t_shown = 0 elseif t_shown > 1 then t_shown = 1 end
  local kx = x0 + t_shown * track_w

  -- Track (pill: rounding = half its thickness).
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, cy - half_t, x0 + track_w, cy + half_t,
    fade(T.FADER_TRACK, alpha), half_t)
  -- Fill: from the 0 dB point when the range crosses 0, else from the left edge.
  local zero_x = x0
  if min < 0 and max > 0 then zero_x = x0 + (-min / (max - min)) * track_w end
  local fx0, fx1 = math.min(zero_x, kx), math.max(zero_x, kx)
  if fx1 - fx0 >= 1 then
    reaper.ImGui_DrawList_AddRectFilled(dl, fx0, cy - half_t, fx1, cy + half_t,
      fade((hovered or active) and T.ACCENT_HOVER or T.FADER_FILL, alpha), half_t)
  end
  -- 0 dB detent mark (bipolar ranges only), on top of the fill so it never vanishes.
  if min < 0 and max > 0 then
    local half_tick = M.FADER_TICK_H * 0.5
    reaper.ImGui_DrawList_AddRectFilled(dl, zero_x - 1, cy - half_tick, zero_x + 1,
      cy + half_tick, fade(T.FADER_TICK, alpha))
  end
  -- Knob: a slim pill taller than the track, so it reads clearly parked at an end
  -- without the bulk of a circle.
  local half_kw, half_kh = M.FADER_KNOB_W * 0.5, M.FADER_KNOB_H * 0.5
  reaper.ImGui_DrawList_AddRectFilled(dl, kx - half_kw, cy - half_kh, kx + half_kw,
    cy + half_kh, fade(T.FADER_KNOB, alpha), half_kw)

  -- Readout. Exactly 0 shows as a plain "0.0" — never a signed "+0.0"/"-0.0".
  -- The unit is dimmer than the number so the value stays the thing you read.
  --
  -- Drawn rather than laid out, for two reasons. It fixes a real misalignment:
  -- laid-out text is positioned by FramePadding, which sat it ~1.5px below the
  -- track's centre line (reported 2026-07-30, and visible once you look). And it
  -- lets the number ANCHOR TO THE TRACK instead of being right-aligned inside its
  -- reserved zone — the reservation still exists so the digits can't jitter while
  -- dragging, but its unused part now trails off the outer edge as margin rather
  -- than sitting between track and number as a hole.
  local text = shown == 0 and "0.0" or string.format("%+.1f", shown)
  local unit = " dB"
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  local uw = select(1, reaper.ImGui_CalcTextSize(ctx, unit))
  local num_col = fade((hovered or active) and T.TEXT_PRIMARY or T.TEXT_SECONDARY, alpha)
  local tx, ty
  if stacked then
    tx = x0 + (total_w - tw - uw) * 0.5 -- centred under the track
    ty = y0 + h - th - 1
  else
    tx = x0 + track_w + M.FADER_VAL_GAP -- anchored to the track, growing outward
    ty = y0 + (h - th) * 0.5            -- true vertical centre, not frame padding
  end
  reaper.ImGui_DrawList_AddText(dl, tx, ty, num_col, text)
  reaper.ImGui_DrawList_AddText(dl, tx + tw, ty, fade(T.TEXT_TERTIARY, alpha), unit)

  -- The readout is drawn, not laid out, so the control still has to claim the
  -- full width it was promised or a caller placing something beside it would
  -- overlap the number.
  if not stacked and total_w > track_w then
    reaper.ImGui_SameLine(ctx, 0, 0)
    reaper.ImGui_Dummy(ctx, total_w - track_w, h)
  end
  reaper.ImGui_EndGroup(ctx)

  if result ~= nil then return result, commit end
  return nil
end

-- Hoisted so the frame loop never rebuilds it (frame-allocation rule).
local ACCENT_FACE = { color = T.ACCENT }

-- A square toggle, the same square as every icon button — never a size change
-- (UI-stability rule). ON is signalled by the FACE turning accent (accent = active
-- throughout the UI: playing fill, selection edge, active sort), NOT by a
-- background fill: the old ON fill shared its token with the hover fill, so an
-- active toggle and a hovered one were literally the same colour. The background
-- keeps its one meaning — hover/press feedback — in every state.
-- With `font` (the Lucide font) and `icon` (an icons.NAMES key) the face is that
-- glyph; `label` stays as the fallback face when the icon font isn't available.
function widgets.toggle(ctx, id, label, on, tip, font, icon)
  local size = reaper.ImGui_GetFrameHeight(ctx)
  local use_icon = font and icon and icons.NAMES[icon]
  if on and not use_icon then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.ACCENT) end
  local clicked = reaper.ImGui_Button(ctx, (use_icon and "" or label) .. "##" .. id, size, size)
  if on and not use_icon then reaper.ImGui_PopStyleColor(ctx) end
  if use_icon then
    -- Paint the state this click PRODUCES, not the state that was passed in: the
    -- entry script flips the real value next frame, and both callers flip
    -- unconditionally, so the face may safely answer the press instantly instead
    -- of one frame late.
    local shown = on
    if clicked then shown = not shown end
    icons.paint_over_item(ctx, font, icon, shown and ACCENT_FACE or nil)
  end
  if tip and reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, tip) end
  return clicked
end

return widgets
