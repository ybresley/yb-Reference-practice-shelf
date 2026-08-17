-- window: draws the WORKING VIEW — the compact window that's on screen all day.
-- TWO rows since the 2026-08-06 redesign (.brief/working-view-layout): the
-- waveform, and one control bar beneath it. The reference-tab row is GONE —
-- the project's pins live in the bar's reference picker (ui/refpicker.lua)
-- instead, so the window looks identical whether the project has 2 pins or 40
-- and the row's height went to the waveform (34 -> 79px in the user's own
-- 1200x150 docked strip).
--
-- The side-column arrangement went with it (user's call, brief page 23: the bar
-- sits on the bottom, full stop). There is nothing left to choose between, so
-- `pick_arrangement`, both switch thresholds and the dead band are deleted too
-- — that deletion is a large part of what the redesign bought.
--
-- This is a ui/ module, so it may call reaper.ImGui_* (drawing is its job) but
-- nothing else on reaper.* — it never writes files, mutates the library, or
-- starts long work itself.

local theme = require("ui.theme")
local waveform = require("ui.waveform")
local transport = require("ui.transport")
local dropzone = require("ui.dropzone")
local T = theme.tokens
local M = theme.metrics

local window = {}

-- Feature detection for the window-wide drop coverage (checked once at load,
-- the house idiom). Without these calls an internal drag simply can't be
-- dropped here — nothing breaks, the browser's own targets still work.
local HAS_RECT_HOVER = reaper.ImGui_IsMouseHoveringRect ~= nil
local HAS_WIN_HOVER_BLOCKED = reaper.ImGui_IsWindowHovered ~= nil
  and reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem ~= nil

-- A sound dragged from the browser's table onto ANY part of the working view
-- pins it to this project. The reference row used to be that target; with the
-- row gone the whole window is, which is both simpler and a bigger target
-- (Codex's 2026-07-28 point about blank space silently cancelling drops applies
-- here too). A dragged PIN is already here, and damaged pin data refuses every
-- mutation, so neither gets the invite.
local function pin_drop_target(ctx, state, x0, y0, x1, y1)
  local drag = state.drag
  if not drag or not HAS_RECT_HOVER then return nil end
  local ps = state.pins
  if ps and ps.load_error then return nil end
  if type(drag.sound_id) == "string" and drag.sound_id:sub(1, 1) == "p" then return nil end

  -- Gated on this window being the hovered one, so a drag over a browser window
  -- overlapping this rect can't light the working view through it.
  if HAS_WIN_HOVER_BLOCKED and not reaper.ImGui_IsWindowHovered(ctx,
      reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem()) then
    return nil
  end
  if not reaper.ImGui_IsMouseHoveringRect(ctx, x0, y0, x1, y1) then return nil end

  dropzone.draw_drop_rect(ctx, x0, y0, x1, y1, "Pin To This Project")
  dropzone.show_hand_cursor(ctx)
  if reaper.ImGui_IsMouseReleased(ctx, 0) then
    return { type = "pin_sound", id = drag.sound_id, wins_release = true }
  end
  return nil
end

function window.draw(ctx, state, res)
  local action

  -- The WHOLE working view is one OS-file drop target (2026-08-01, user's call
  -- — supersedes the old "browser opens itself" auto-open): files dropped
  -- anywhere on this window import into the library (Uncategorised) and pin to
  -- this project in one motion, with the full-window treatment while the drag
  -- hovers. Submitted only while a files payload is in flight, so it can never
  -- steal a click — see dropzone.file_drop_over_rect.
  local cx0, cy0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  action = dropzone.file_drop_over_rect(ctx, state, cx0, cy0, cx0 + avail_w, cy0 + avail_h,
    { action_type = "import_and_pin", label = "Add to Library and Pin To This Project" })
  local drag_action = pin_drop_target(ctx, state, cx0, cy0, cx0 + avail_w, cy0 + avail_h)
  action = action or drag_action

  -- Vertical priority, unchanged in spirit and much simpler in form: the bar's
  -- height is reserved FIRST, the waveform takes every pixel that's left. Every
  -- number comes from the real content region each frame — never a hardcoded
  -- panel height — so resizing the window is the only thing that can change the
  -- layout. Never state: nothing here reads selection, playback or latch.
  local spacing_y = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local bar_h = transport.measure(ctx, avail_w, state)

  -- The waveform's share carries the ONE spacing step between it and the bar;
  -- shorting it would summon a scrollbar, which is a layout shift and steals
  -- width. RULER_H is carved out here too — waveform.draw adds it straight back
  -- below whatever `wave_h` comes out to, so the block drawn always fits the
  -- room reserved.
  --
  -- It used to carry a hand-added 4px Dummy between two spacing steps as well —
  -- 20px of air under the ruler when ItemSpacing was 8, and still 16 after the
  -- density pass, which read as a hole (user-reported 2026-08-07). Nothing
  -- needed separating there: the ruler ends the waveform block and the bar is
  -- the next element, so the theme's own adjacent-element gap is the whole
  -- answer.
  local wave_h = avail_h - bar_h - spacing_y - M.RULER_H

  -- The ruler YIELDS in a short window (2026-08-07 horizontal-layout brief,
  -- page 7 — the first exception to "the ruler is always reserved"): when
  -- keeping it would drop the picture under WAVE_MIN_H, its RULER_H goes to
  -- the bars instead — the picture is what a short strip exists to show.
  -- This is legal under "reserved height never changes with state": the trade
  -- is driven by WINDOW SIZE alone, exactly like every other collapse step —
  -- nothing here reads selection or playback. The WAVE_MIN_H floor is
  -- provisional until the live round (shown on the decided brief page as
  -- "flag if wrong"; the user didn't flag it).
  local ruler_on = wave_h >= M.WAVE_MIN_H
  if not ruler_on then wave_h = wave_h + M.RULER_H end
  if wave_h < M.WAVE_HIDE_H then wave_h = 0 end

  if wave_h > 0 then
    -- The working view always shows the ARMED reference — never the browser's
    -- own selection (Phase 5.9: the two are independent). Its trim scales the
    -- drawing, so riding the trim fader resizes the wave as it resizes the sound.
    -- `ruler`/`duration` opt in to the time ruler beneath it (the browser's
    -- strip passes its own since 2026-08-06). `slot` names which view this
    -- panel is — its ruler cache, and which remembered pause its playhead
    -- reads (the browser's strip passes "browse").
    -- `span_*` opt in to the start/end handles (loudness tools, 2026-08-06) —
    -- the working view only; the browser strip passes none and stays plain.
    -- `empty_hint` is what the panel says with nothing armed: this window's
    -- whole area is a drop target, and an empty picture is exactly when that
    -- needs saying (2026-08-11, user's ask). Drawn over the baseline, so it
    -- costs no layout and can never shift the bar below it.
    local wave_action = waveform.draw(ctx, state, wave_h,
      { id = state.selected_id, waveform = state.waveform, slot = "main",
        trim_db = state.selected and state.selected.trim_db or 0,
        ruler = ruler_on, duration = state.selected and state.selected.duration or nil,
        span_edit = true,
        span_start = state.selected and state.selected.span_start or nil,
        span_end = state.selected and state.selected.span_end or nil,
        empty_hint = "Drop audio files here to add them to the Library and pin them to this project." })
    action = action or wave_action
  end

  -- Always drawn: the bar carries the reference picker, the Library button and
  -- the Settings gear as well as the listening controls.
  local bar_action = transport.draw(ctx, state, res)
  action = action or bar_action

  return action
end

return window
