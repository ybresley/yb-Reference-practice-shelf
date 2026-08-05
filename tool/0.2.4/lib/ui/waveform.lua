-- waveform: draws a sound's envelope and playhead, and reports a click as a seek
-- intent. A ui/ module — it may call reaper.ImGui_* only. It never reads `state`
-- selection directly: the caller's `opts` names which sound + which pre-built
-- per-channel envelope to draw (the entry script builds envelopes when a
-- selection changes), so the working view and the browser's audition strip can
-- each show their OWN, independent selection through the same widget (Phase 5.9).
-- Scales the envelope to the available width; never reads audio itself.
--
-- One lane per channel (mono = 1, stereo = 2, ...), stacked to fill the panel. The
-- playhead spans all lanes.

local theme = require("ui.theme")
local T = theme.tokens
local M = theme.metrics

local waveform = {}

-- Draw one channel's envelope into a horizontal lane [lane_y, lane_y+lane_h].
-- `show_head` covers both a sound actually playing and one paused mid-way —
-- either way there's a real position to colour up to (see waveform.draw).
-- `gain` is the trim expressed as a multiplier, so louder draws taller.
local function draw_lane(dl, x, lane_y, lane_h, avail_w, ch, show_head, play_px, cols, gain)
  local midy = lane_y + lane_h * 0.5
  reaper.ImGui_DrawList_AddLine(dl, x, midy, x + avail_w, midy, T.STROKE_TERTIARY) -- lane centre
  local maxs, mins = ch.maxs, ch.mins
  local n = #maxs
  -- A fixed inset off the lane edge, capped so a squashed panel (many channels in a
  -- docked strip) can never pad the lane down to nothing or past it into inverted bars.
  local lane_half = lane_h * 0.5
  local half = lane_half - math.min(M.WAVE_LANE_PAD, lane_half * 0.2)
  local scale = half * gain
  for px = 0, cols - 1 do
    -- Fold the envelope bins covered by this pixel column into one min/max.
    local b0 = math.floor(px * n / cols) + 1
    local b1 = math.floor((px + 1) * n / cols)
    if b1 < b0 then b1 = b0 end
    local hi, lo = 0, 0
    for b = b0, b1 do
      if maxs[b] > hi then hi = maxs[b] end
      if mins[b] < lo then lo = mins[b] end
    end
    -- Clamp to the lane. A boosted trim can ask for many times the height available,
    -- and unclamped those bars draw over the next channel's lane and outside the
    -- panel entirely. Going flat at the ceiling is also the truth: `half` is exactly
    -- where an untrimmed full-scale file already reaches, so a flat top means "past
    -- full scale" — which a float file whose samples exceed 0 dBFS can manage on its
    -- own, at no trim at all.
    local up, dn = hi * scale, lo * scale
    if up > half then up = half end
    if dn < -half then dn = -half end
    -- Columns left of the playhead read as "played" (accent); the rest is dim.
    local col = (show_head and px <= play_px) and T.WAVE_PLAYED or T.WAVE_BARS
    local cx = x + px
    reaper.ImGui_DrawList_AddLine(dl, cx, midy - up, cx, midy - dn, col)
  end
end

-- Draw the panel. `height` is the pixel height the caller has measured out for
-- it this frame (Phase 5.7 Stage 2 — the working view hands it everything left
-- over between the reference row and the transport row, so the waveform grows
-- and shrinks with the WINDOW, never with any state change). Falls back to the
-- floor metric if a caller doesn't pass one.
--
-- `opts` tells this draw WHICH sound + envelope to show — the working view
-- passes the armed reference (`state.selected_id`/`state.waveform`), the
-- browser's audition strip passes its own browse selection instead (Phase
-- 5.9 — independent browsing). Reading `state.selected*` in here directly
-- would make the two views draw the same thing, which is exactly what they
-- must not do. Returns a seek action { type="seek", fraction } on a click
-- inside it, else nil — the CALLER tags which sound it seeks (see
-- ui/browser.lua's target="browse").
--
-- `opts.trim_db` scales the drawing the way a DAW scales an item whose take volume
-- you change: louder trim, taller wave (2026-07-30). It comes from the caller for
-- the same reason the sound does — the browser passes none, because a browse
-- audition applies no trim either, and a picture that disagreed with the audio
-- would be worse than no picture.
function waveform.draw(ctx, state, height, opts)
  opts = opts or {}
  local target_id = opts.id
  local gain = 10 ^ ((opts.trim_db or 0) / 20) -- dB -> multiplier; 0 dB = 1.0
  local action
  local avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  if avail_w < 1 then avail_w = 1 end
  local h = height or M.WAVE_MIN_H
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + avail_w, y + h, T.WAVE_BG, 4)

  -- Where the playhead sits (0..1 of the file), only while the sound being shown
  -- is the one this preview slot actually owns (auto-audition off, or the OTHER
  -- slot auditioning, can leave a different sound playing than this one — its
  -- playhead must not slide over this one). A paused sound owns the slot just as
  -- much as a playing one — the playhead should stay put at the paused position
  -- rather than vanish — so both count as "showing a head", just from different
  -- position fields. Paused ownership is tracked via `paused_sound_id`, kept
  -- separate from `sound_id` (which follows whatever the ONE shared preview is
  -- CURRENTLY sounding), so an unrelated browse audition in between doesn't
  -- erase this slot's own paused playhead.
  local sounding = state.preview.playing and state.preview.sound_id == target_id
  local paused = (not state.preview.playing) and state.preview.paused_at ~= nil
    and state.preview.paused_sound_id == target_id
  -- Paused reads its OWN length snapshot, not the shared `length` field — that
  -- field follows whatever's currently sounding, which may by now be a
  -- completely different (browsed) sound with a different duration.
  local pos, len
  if sounding then
    pos, len = state.preview.position, state.preview.length
  elseif paused then
    pos, len = state.preview.paused_at, state.preview.paused_length
  end
  local show_head = pos ~= nil and len ~= nil and len > 0
  local play_frac = -1
  if show_head then
    play_frac = pos / len
    if play_frac < 0 then play_frac = 0 elseif play_frac > 1 then play_frac = 1 end
  end

  local wf = opts.waveform
  local chans = (wf and wf.sound_id == target_id) and wf.channels or nil
  local have_wave = chans and #chans > 0 and chans[1].maxs and #chans[1].maxs > 0

  if have_wave then
    local nch = #chans
    local lane_h = h / nch
    local cols = math.floor(avail_w)
    local play_px = play_frac * cols
    for ci = 1, nch do
      local lane_y = y + (ci - 1) * lane_h
      draw_lane(dl, x, lane_y, lane_h, avail_w, chans[ci], show_head, play_px, cols, gain)
      if ci < nch then -- hairline between lanes
        local by = y + ci * lane_h
        reaper.ImGui_DrawList_AddLine(dl, x, by, x + avail_w, by, T.STROKE_TERTIARY)
      end
    end
  else
    -- Nothing to show yet: a single centre baseline, plus a "reading…" hint while a
    -- build is running for this sound (drawn, not laid out, so it never shifts).
    local midy = y + h * 0.5
    reaper.ImGui_DrawList_AddLine(dl, x, midy, x + avail_w, midy, T.STROKE_TERTIARY)
    if state.wave_loading and state.wave_loading == target_id then
      local label = "reading waveform\u{2026}"
      local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
      reaper.ImGui_DrawList_AddText(dl, x + (avail_w - tw) * 0.5, midy - th * 0.5, T.TEXT_QUATERNARY, label)
    end
  end

  -- Playhead line spanning all lanes, on top of the bars.
  if show_head then
    local px = x + play_frac * avail_w
    reaper.ImGui_DrawList_AddLine(dl, px, y, px, y + h, T.WAVE_PLAYHEAD, 1)
  end

  -- Invisible button reserves the layout space AND captures clicks for seeking.
  reaper.ImGui_InvisibleButton(ctx, "##waveform", avail_w, h)
  if reaper.ImGui_IsItemClicked(ctx) then
    local mx = select(1, reaper.ImGui_GetMousePos(ctx))
    local frac = (mx - x) / avail_w
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    action = { type = "seek", fraction = frac }
  end

  return action
end

return waveform
