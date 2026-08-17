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
local tips = require("ui.tips")
local T = theme.tokens
local M = theme.metrics

local widgets = {}

-- Cut text down to `max_w`, ending in an ellipsis. Lives here because two
-- screens now need it — the reference picker's rows and the browser sidebar's
-- category rows (2026-08-07) — and a second copy of a binary search plus its
-- own cache is exactly what this module exists to prevent.
--
-- Cached because the same name is re-measured every frame it is on screen, and
-- the binary search would otherwise be a dozen CalcTextSize calls a frame for a
-- string that almost never changes. Bounded: the whole cache is dropped once it
-- grows past a project's worth of names.
local ell_cache, ell_n = {}, 0
-- `cut` says WHERE the ellipsis goes:
--   nil / "end"  "Some long name…"        — the default; a name is read front-first
--   "middle"     "C:\Users\…\yb-Reference" — a PATH: keeps the drive AND the leaf,
--                the two ends you actually identify a folder by (Windows' own
--                convention, and what Explorer's address bar does)
--   "front"      "…\REAPER\yb-Reference"   — keeps the tail only
--
-- Paths use "middle" (2026-08-08, user's call after seeing "front" running: a
-- leading ellipsis loses the drive, so two libraries on different drives look
-- identical). Never use either on a NAME, where the front is what you read.
function widgets.ellipsize(ctx, text, max_w, cut)
  if text == "" or max_w <= 0 then return "" end
  -- The FONT SIZE is part of the key: the same name at the same width cuts at a
  -- different character in a 13px row than an 11px one, and callers push the
  -- small font around some of these. (It also keeps the cache honest if the UI
  -- scale is ever changed while running.) `cut` is part of it too — the same
  -- string at the same width has a different answer per mode.
  local key = text .. "\0" .. math.floor(max_w) .. "\0" .. reaper.ImGui_GetFontSize(ctx)
    .. "\0" .. (cut or "end")
  local hit = ell_cache[key]
  if hit then return hit end

  local out = text
  if select(1, reaper.ImGui_CalcTextSize(ctx, text)) > max_w then
    -- Character positions, so a multi-byte name is never cut mid-character.
    -- A name that isn't valid UTF-8 falls back to byte positions: a clipped
    -- name beats an error.
    local len = utf8.len(text)
    local function prefix(n)
      if n <= 0 then return "" end
      if not len then return text:sub(1, n) end
      local at = utf8.offset(text, n + 1)
      return text:sub(1, (at or (#text + 1)) - 1)
    end
    local function suffix(n)
      if n <= 0 then return "" end
      if not len then return text:sub(-n) end
      local at = utf8.offset(text, -n)
      return at and text:sub(at) or text
    end
    -- Every mode binary-searches the same thing: the most characters that still
    -- fit once the ellipsis is in. Widening `n` only ever widens the result, in
    -- all three modes, which is what makes the search valid.
    local function build(n)
      if cut == "front" then return "\u{2026}" .. suffix(n) end
      if cut == "middle" then
        local head = math.ceil(n / 2) -- the odd character goes to the front
        return prefix(head) .. "\u{2026}" .. suffix(n - head)
      end
      return prefix(n) .. "\u{2026}"
    end
    local lo, hi = 0, len or #text
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if select(1, reaper.ImGui_CalcTextSize(ctx, build(mid))) <= max_w then
        lo = mid
      else
        hi = mid - 1
      end
    end
    out = build(lo)
  end

  -- Sized for everything ON SCREEN at once, with room to scroll: the sound table
  -- asks for one entry per visible row (2026-08-12), so a bound of a few dozen
  -- would empty itself every frame and the search would stop being cached at all.
  if ell_n > 512 then ell_cache, ell_n = {}, 0 end
  ell_cache[key] = out
  ell_n = ell_n + 1
  return out
end

-- The one standard "reset to default" gesture for ANY adjustable control (faders,
-- and later knobs/xy-pads): right-click OR double-click. Defined once so every such
-- control resets identically — right-click has no value jump, double-click matches
-- DAW muscle memory. Call right after submitting the control (it reads "last item").
function widgets.wants_reset(ctx)
  return reaper.ImGui_IsItemHovered(ctx)
    and (reaper.ImGui_IsMouseClicked(ctx, 1) or reaper.ImGui_IsMouseDoubleClicked(ctx, 0))
end

-- A BARE glyph button: no frame and no fill until the cursor is on it. Born as
-- the reference picker's edit-mode control (2026-08-06, user's call — three
-- framed squares per row put nine boxes on screen at once) and shared here the
-- day the match window needed the same thing. `hot_color` (optional) recolours
-- the GLYPH while hovered — the unpin/remove crosses use it to go DANGER_RED,
-- so a control that takes something away says so before it is clicked. The
-- no-icon-font fallback keeps the theme's text colour, since its label is
-- drawn by the Button itself.
function widgets.glyph_button(ctx, font, id, glyph, fallback, w, h, tip, hot_color)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0)
  local has_icon = font and icons.NAMES[glyph]
  local clicked = reaper.ImGui_Button(ctx, (has_icon and "" or fallback) .. "##" .. id, w, h)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PopStyleVar(ctx, 1)
  local hot = reaper.ImGui_IsItemHovered(ctx)
  if has_icon then
    icons.paint_over_item(ctx, font, glyph, (hot and hot_color) and { color = hot_color } or nil)
  end
  -- Tooltip LAST (house rule: SetTooltip replaces ImGui's "last item", so
  -- anything reading the button must run before it).
  tips.show(ctx, tip and reaper.ImGui_IsItemHovered(ctx), tip)
  return clicked
end

-- DrawList colours ignore the style Alpha (which BeginDisabled lowers), so custom
-- drawing must fade itself or a disabled fader would render at full strength.
-- Shared with icons.lua (theme.fade) so every hand-painted glyph agrees.
local fade = theme.fade

-- ---- the tapered (real-fader) shape, opts.taper ------------------------------
--
-- A linear dB fader has to choose between reach and precision: 70 pixels of
-- track either cover a useful range coarsely or a fine range that a match can
-- fall outside. A taper refuses the choice, the way every mixing fader does —
-- the bottom of the travel IS silence, and the steps grow the further down you
-- push, so the fine control stays where the work happens (user's call,
-- 2026-08-07: "as you approach -inf, the increment becomes bigger and bigger").
--
-- Below unity the AMPLITUDE follows a cube law, which is what makes the
-- decibels stretch out at the bottom: half the cut travel is about -18 dB, a
-- quarter of it about -36. Above unity it is plain linear dB — a boost range is
-- short enough not to need shaping.
-- 0 dB sits at the MIDDLE of the track (2026-08-07, second look: at 0.75 the
-- knob rested a few pixels from the right end and the +24 above it was squeezed
-- into 17px, which read as no room at all). Half the track is the same 35px the
-- old linear ±24 fader gave the boost, so boosting feels exactly as it always
-- did; everything the taper buys goes to the cut side, which now reaches
-- silence in the other half. Moving unity right only trades that back: at 0.75
-- the boost ran at 1.37 dB/px against the old fader's 0.69.
local UNITY_T = 0.5           -- where 0 dB sits along the track
local CUT_PER_DECADE = 60     -- 20 dB x the cube law

local function taper_db(t, max_db, silence)
  if t <= 0 then return silence end
  if t >= UNITY_T then return max_db * (t - UNITY_T) / (1 - UNITY_T) end
  local db = CUT_PER_DECADE * math.log(t / UNITY_T, 10)
  return db < silence and silence or db
end

local function taper_t(db, max_db, silence)
  if db <= silence then return 0 end
  if db >= 0 then return UNITY_T + (db / max_db) * (1 - UNITY_T) end
  return UNITY_T * 10 ^ (db / CUT_PER_DECADE)
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
-- standard reset gesture. opts = { min, max, default, tip, taper }.
-- `taper` gives the control a real fader's shape (see above), where `min` is
-- the silence the bottom of the track means rather than a number to land on.
-- Returns (value, commit) when something changed this frame, else nil.
function widgets.db_fader(ctx, id, value, opts)
  opts = opts or {}
  local min, max = opts.min or -24, opts.max or 24
  local taper = opts.taper == true
  -- One conversion each way, used by the drag, the knob and the 0 dB detent, so
  -- the value under the cursor and the value drawn can never disagree.
  local to_db = function(t) return taper and taper_db(t, max, min) or (min + t * (max - min)) end
  local to_t = function(db) return taper and taper_t(db, max, min) or ((db - min) / (max - min)) end
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
  tips.show(ctx, opts.tip and hovered, opts.tip)

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
    local v = math.floor(to_db(t) * 10 + 0.5) / 10
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
  local t_shown = to_t(shown)
  if t_shown < 0 then t_shown = 0 elseif t_shown > 1 then t_shown = 1 end
  local kx = x0 + t_shown * track_w

  -- Track (pill: rounding = half its thickness).
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, cy - half_t, x0 + track_w, cy + half_t,
    fade(T.FADER_TRACK, alpha), half_t)
  -- Fill: from the 0 dB point when the range crosses 0, else from the left edge.
  -- Tapered, 0 dB is three-quarters up rather than mid-track, so the detent and
  -- the fill's origin both come from the same conversion the knob uses.
  local zero_x = x0
  if min < 0 and max > 0 then zero_x = x0 + to_t(0) * track_w end
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
  -- At the bottom of a tapered track the value is silence, and "-120.0" would
  -- name a number nobody set — the fader was dragged to the end, not to −120.
  local text = shown == 0 and "0.0"
    or (taper and shown <= min and "-inf")
    or string.format("%+.1f", shown)
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

-- The collapsed trim's cursor: a vertical-drag affordance, resolved once at
-- load (the house feature-detection idiom) — nil on an older ReaImGui, where
-- the tooltip carries the affordance alone.
local DRAG_NS_CURSOR = (reaper.ImGui_MouseCursor_ResizeNS and reaper.ImGui_MouseCursor_ResizeNS())
  or nil

-- Where each in-flight vertical drag started: id -> { t, my }. One entry per
-- control, only while its mouse button is held (cleared on release), so this
-- can't grow (frame-allocation rule).
local drag_anchor = {}

-- A dB value as a bare draggable NUMBER — the trim fader's collapsed form
-- (horizontal-layout brief page 12, 2026-08-07): when the bar runs out of
-- width the track goes and the number becomes the control. Drag up = louder,
-- down = quieter; the shared wants_reset gesture resets, exactly like the
-- fader it stands in for.
--
-- The drag runs through the SAME taper as the trim fader's track, over the
-- same virtual track length, so a pixel of vertical drag here moves the value
-- exactly as far as a pixel of horizontal drag on the full fader — collapsing
-- must change the control's shape, never its feel. Anchored at the value the
-- drag STARTED on (a vertical drag has no track under it to read positions
-- from), so there is no jump on grab.
--
-- opts = { min, max, default, tip, width, taper } — the fader's vocabulary.
-- Returns (value, commit) when something changed this frame, else nil.
function widgets.db_drag(ctx, id, value, opts)
  opts = opts or {}
  local min, max = opts.min or -24, opts.max or 24
  local taper = opts.taper == true
  local to_db = function(t) return taper and taper_db(t, max, min) or (min + t * (max - min)) end
  local to_t = function(db) return taper and taper_t(db, max, min) or ((db - min) / (max - min)) end
  local h = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local w = opts.width or (select(1, reaper.ImGui_CalcTextSize(ctx, "+24.0 dB")) + pad_x * 2)
  -- The full fader's track length, so the dB-per-pixel feel matches it.
  local track = M.SLIDER_W - M.FADER_VAL_W - M.FADER_VAL_GAP
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)

  reaper.ImGui_InvisibleButton(ctx, "##" .. id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  if (hovered or active) and DRAG_NS_CURSOR then reaper.ImGui_SetMouseCursor(ctx, DRAG_NS_CURSOR) end
  tips.show(ctx, opts.tip and hovered, opts.tip)

  -- Same resolution order as db_fader: a reset wins over the drag on its frame,
  -- and a reset fired mid-hold parks the rest of that hold (reset_hold) so the
  -- next frame's drag can't yank the value straight back.
  local result, commit
  if widgets.wants_reset(ctx) then
    if active then reset_hold[id] = true end
    drag_anchor[id] = nil
    result, commit = (opts.default or 0), true
  elseif reaper.ImGui_IsItemActivated(ctx) then
    drag_anchor[id] = { t = to_t(value or 0), my = select(2, reaper.ImGui_GetMousePos(ctx)) }
  elseif active and not reset_hold[id] and drag_anchor[id] then
    local a = drag_anchor[id]
    local t = a.t + (a.my - select(2, reaper.ImGui_GetMousePos(ctx))) / track
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    -- Snap to 0.1 dB so the value IS what the readout shows.
    local v = math.floor(to_db(t) * 10 + 0.5) / 10
    if v ~= (value or 0) then result, commit = v, false end
  elseif reaper.ImGui_IsItemDeactivated(ctx) then
    drag_anchor[id] = nil
    if reset_hold[id] then
      reset_hold[id] = nil -- the reset already committed; this hold stays inert
    else
      result, commit = (value or 0), true
    end
  end
  local shown = result or value or 0

  -- Drawn like the fader's readout, right-aligned inside the reserved width so
  -- the digits' right edge (and the " dB" beside it) never wanders as the
  -- number changes sign or grows a digit.
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local text = shown == 0 and "0.0"
    or (taper and shown <= min and "-inf")
    or string.format("%+.1f", shown)
  local unit = " dB"
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  local uw = select(1, reaper.ImGui_CalcTextSize(ctx, unit))
  local tx = x0 + w - pad_x - uw - tw
  local ty = y0 + (h - th) * 0.5
  reaper.ImGui_DrawList_AddText(dl, tx, ty,
    fade((hovered or active) and T.TEXT_PRIMARY or T.TEXT_SECONDARY, alpha), text)
  reaper.ImGui_DrawList_AddText(dl, tx + tw, ty, fade(T.TEXT_TERTIARY, alpha), unit)

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
  tips.show(ctx, tip and reaper.ImGui_IsItemHovered(ctx), tip)
  return clicked
end

-- The slim scrollbar (brief `table-scrollbar`, 2026-08-09): a thumb-only pill
-- in a strip the CALLER has reserved — the empty strip is the track. It
-- replaces ImGui's own bar wherever it's used (the browser's sound table and
-- its sidebar): that bar carves its width out of the content — which is what
-- made the table's columns jump whenever it appeared — and runs the full
-- window height, frozen headers included.
--
-- Geometry in, intent out: the caller says where the strip is (x, y, w, h) and
-- what the scrolled window reports (scroll_y, scroll_max — LAST frame's
-- numbers are fine; one frame of thumb lag is imperceptible), and gets back
-- the scroll position the user asked for, or nil. Applying it stays with the
-- caller — only the caller knows which window scrolls and when it is current.
--
-- The layout cursor is saved and restored around the hit item, so the widget
-- can be dropped anywhere in a window's draw order without displacing what
-- comes after it.
local grab_off = {}
function widgets.scrollbar(ctx, id, x, y, w, h, scroll_y, scroll_max)
  if not (scroll_max > 0 and h > 0) then grab_off[id] = nil; return nil end

  -- Thumb length mirrors how much of the list is on screen (the native ratio),
  -- floored so a huge library still leaves something to grab.
  local thumb_h = h * (h / (h + scroll_max))
  if thumb_h < M.SCROLL_THUMB_MIN_H then thumb_h = M.SCROLL_THUMB_MIN_H end
  if thumb_h > h then thumb_h = h end
  local travel = h - thumb_h
  local t = scroll_y / scroll_max
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local thumb_y = y + travel * t

  -- The whole strip is the hit area. A drag keeps the point that was grabbed
  -- under the cursor; a press elsewhere in the strip centres the thumb there
  -- and drags on from that grip without releasing.
  local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, "##" .. id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, cx, cy)

  local result
  if active and travel > 0 then
    local my = select(2, reaper.ImGui_GetMousePos(ctx))
    if reaper.ImGui_IsItemActivated(ctx) then
      local on_thumb = my >= thumb_y and my <= thumb_y + thumb_h
      grab_off[id] = on_thumb and (my - thumb_y) or thumb_h * 0.5
    end
    local nt = (my - (grab_off[id] or thumb_h * 0.5) - y) / travel
    if nt < 0 then nt = 0 elseif nt > 1 then nt = 1 end
    if math.abs(nt * scroll_max - scroll_y) >= 0.5 then result = nt * scroll_max end
    thumb_y = y + travel * nt -- draw at the drag's own answer, not a frame behind
  else
    grab_off[id] = nil
  end

  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local tx = x + (w - M.SCROLL_THUMB_W) * 0.5
  reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx),
    tx, thumb_y, tx + M.SCROLL_THUMB_W, thumb_y + thumb_h,
    fade((hovered or active) and T.SCROLL_THUMB_HOT or T.SCROLL_THUMB, alpha),
    M.SCROLL_THUMB_W * 0.5)
  return result
end

return widgets
