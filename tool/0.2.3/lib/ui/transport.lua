-- transport: the play/loop/auto-audition controls plus the per-sound trim and
-- master preview volume faders. A ui/ module — draws and reports intent only.
-- Reusable controls (faders, toggles, the reset gesture) come from ui.widgets so
-- they behave identically everywhere; this file only arranges them.

local theme = require("ui.theme")
local widgets = require("ui.widgets")
local icons = require("ui.icons")
local T = theme.tokens
local M = theme.metrics

local transport = {}

-- Text fallbacks for when the Lucide icon font isn't available (see ui/icons.lua);
-- normally the transport draws Lucide glyphs, same set as every other icon.
local PLAY = "\u{25B6}" -- ▶
local PAUSE = "\u{23F8}" -- ⏸
local STOP = "\u{25A0}" -- ■
local LOOP = "\u{21BB}" -- ↻

-- Hoisted so the frame loop never rebuilds it (frame-allocation rule).
local ON_ACCENT_FACE = { color = T.TEXT_ON_ACCENT }

local RESET_HINT = " \u{00B7} right-click or double-click to reset"

-- The master preview-volume fader, right-aligned to the current line (it owns its
-- placement so a host row can just drop it in). The "Preview" label introduces it
-- (2026-07-29 review — the user couldn't tell what the fader was for): small, but
-- a label the user is meant to read, so TEXT_SECONDARY like every other label
-- (2026-08-01 — it was TEXT_QUATERNARY, which tokens.md reserves for things
-- nobody has to read; mixed case for the same reason, small caps read as noise
-- here rather than as a heading).
--
-- The caption is RESERVED then painted, not laid out. Laid-out text is positioned
-- by FramePadding, which sits a 13px caption about a pixel above the 15px readout
-- beside it — enough to read as "the number is sitting low". Reserving a
-- full-control-height slot and centring the caption in it by hand lines the
-- caption, the track and the number up on one axis exactly.
function transport.draw_master(ctx, state)
  local label = "Preview"
  -- Read BEFORE the small font goes on: GetFrameHeight follows the CURRENT font,
  -- so asking with 13px pushed answers 25 instead of the row's real 27 — and the
  -- caption would then be centred in a slot two pixels short of the fader's.
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)
  local small = theme.push_small_font(ctx)
  local lw, lh = reaper.ImGui_CalcTextSize(ctx, label)
  local spacing = 6
  local block_w = lw + spacing + M.SLIDER_W
  local cx = reaper.ImGui_GetCursorPosX(ctx)
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local target = cx + avail - block_w
  if target > cx then reaper.ImGui_SetCursorPosX(ctx, target) end -- push to the right edge

  reaper.ImGui_Dummy(ctx, lw, frame_h)
  local lx0, ly0 = reaper.ImGui_GetItemRectMin(ctx)
  local _, ly1 = reaper.ImGui_GetItemRectMax(ctx)
  reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx),
    lx0, (ly0 + ly1) * 0.5 - lh * 0.5, T.TEXT_SECONDARY, label)
  if small then reaper.ImGui_PopFont(ctx) end
  reaper.ImGui_SameLine(ctx, 0, spacing)
  -- Master caps at 0 dB (unity) and only attenuates from there.
  local mdb, mcommit = widgets.db_fader(ctx, "master", state.master_db,
    { min = -60, max = 0, default = 0, tip = "Master preview volume" .. RESET_HINT })
  if mdb ~= nil then return { type = "set_master", db = mdb, commit = mcommit } end
  return nil
end

local function is_pin_id(id)
  return type(id) == "string" and id:sub(1, 1) == "p"
end

--------------------------------------------------------------- row geometry

-- The row's shape at a given width, worked out WITHOUT drawing anything.
-- `transport.measure` and `transport.draw` both go through here, so the height
-- reserved for this row can never disagree with the height it actually takes —
-- which matters because the working view now reserves the transport FIRST and
-- hands what's left to the reference row and the waveform (vertical priority,
-- decided 2026-07-30).
--
-- Collapse order (tokens.md "responsive collapse order"), narrowest last:
--   1. the readout's gap shrinks     2. the trim fader hides
--   3. the cluster drops to its own line   4. the cluster wraps within that line
-- Steps 3 and 4 are the 2026-07-30 additions: before them the row simply ran
-- past the right edge, because "every control is already icon-sized" left
-- nothing else to give.
local function geometry(ctx, width)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local gap, gap_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
  local cluster_w = ctrl * 4 + gap * 3
  -- LATCH is a square like every other transport control since 2026-07-30 (it
  -- wore the word "LATCH" at REF_W before), so the cluster's left bound is just
  -- one control plus a gap.
  local left_bound = ctrl + gap

  local two_line, per_line = false, 4
  if left_bound + cluster_w > width then
    -- Step 3: LATCH keeps line one, the cluster starts a fresh line at the row
    -- origin. Step 4: if even a full line can't hold four squares, they wrap
    -- among themselves rather than clipping. One square wide still works.
    two_line = true
    per_line = math.max(1, math.min(4, math.floor((width + gap) / (ctrl + gap))))
  end

  local lines = math.ceil(4 / per_line)
  local cluster_x = two_line and 0 or nil
  if not two_line then
    -- Centre the cluster, but never let it collide with LATCH or the trim
    -- fader; fall back to left-aligned rather than overlapping anything.
    local ideal_x = (width - cluster_w) / 2
    local room_if_centered = width - (ideal_x + cluster_w) - gap
    local right_bound = width
      - ((room_if_centered >= M.SLIDER_W + M.TRIM_MIN_TAIL) and (M.SLIDER_W + gap) or 0)
    cluster_x = (ideal_x < left_bound or ideal_x + cluster_w > right_bound) and left_bound or ideal_x
  end

  local cluster_top = two_line and (ctrl + gap_y) or 0
  local last_count = 4 - per_line * (lines - 1)
  local last_line_w = last_count * ctrl + (last_count - 1) * gap
  local last_line_top = cluster_top + (lines - 1) * (ctrl + gap_y)

  local room_after = width - (cluster_x + last_line_w) - gap
  local trim_shown = room_after >= M.SLIDER_W + M.TRIM_MIN_TAIL

  return {
    ctrl = ctrl, gap = gap, gap_y = gap_y,
    cluster_x = cluster_x, cluster_top = cluster_top, per_line = per_line,
    last_line_w = last_line_w, last_line_top = last_line_top,
    trim_shown = trim_shown, trim_x = width - M.SLIDER_W,
    height = two_line and (ctrl + lines * (ctrl + gap_y)) or ctrl,
  }
end

-- How tall this row needs to be at `width`. Called before anything else is laid
-- out in the working view.
function transport.measure(ctx, width)
  return geometry(ctx, width).height
end

-- The reference-mode latch: a square like every other transport control since
-- 2026-07-30, faced with "R" for reference. Filled REF_RED only while ON — the
-- one red in the whole UI, reserved for exactly this. Hover and pressed are
-- pushed to the same red so the fill never blinks back to grey. Fixed size
-- always: latching signals itself by colour alone, never by changing shape.
--
-- The word "LATCH" is gone from the face. That's a real cost on the tool's least
-- self-explanatory control, so the tooltip carries the full explanation and the
-- red fill still shouts when it's on.
function transport.draw_latch(ctx, state)
  local action
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local latched = state.reference.latched
  if latched then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), T.REF_RED)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.REF_RED)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.REF_RED)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_ON_REF)
  end
  if reaper.ImGui_Button(ctx, "R##reference", ctrl, ctrl) then
    action = { type = "toggle_reference" }
  end
  if latched then reaper.ImGui_PopStyleColor(ctx, 4) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, latched
      and "Reference latched \u{00B7} your project is muted. Press play in REAPER to hear the selected sound. Click to unlatch."
      or "Latch reference: mute your project so pressing play in REAPER plays the selected sound instead (A/B). Bindable to a hotkey.")
  end
  return action
end

-- The armed-reference readout: a fixed slot at the tail of the transport row that
-- answers "what will play right now?" while reference mode is latched — state
-- (ARMED / PLAYING / NO TARGET) · the pin's label, if it has one · the reference's
-- name. Selection IS the armed reference now (Contexts and "what armed it" are
-- gone — DESIGN, decided 2026-07-28): a label is just a name that lives on the
-- pin itself, so there's nothing left to look up or fall back to "Manual" from.
-- Unlatched it stays empty; it's the row's tail, so nothing ever shifts. A narrow
-- docked strip clips the text; hovering shows the full story.
--
-- While a drag is in flight this same slot doubles as the live drag-hint (Phase
-- 5.7 Stage 2): dragging a reference tab out to the timeline can happen with the
-- browser closed, so its old status-line home isn't guaranteed to be on screen —
-- but the transport row always is. Both are the row's tail, so doubling the one
-- fixed slot is the only way to show either without anything in this row
-- changing size or position (decided in this stage, see HANDOFF/report).
local function draw_readout(ctx, state)
  if state.drag then
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, state.drag.hint or "")
    return
  end

  local ref = state.reference
  if not ref.latched then
    -- Submit an empty placeholder so the row's item count/height never changes.
    reaper.ImGui_Dummy(ctx, 0, 0)
    return
  end

  local sel = state.selected
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_BeginGroup(ctx)
  local tip
  if not sel then
    -- The armed reference vanished (unpinned, deleted, project switch) while
    -- latched. Deliberately still latched — auto-unlatching would surprise-blast
    -- project audio — and the readout is where that silence must look chosen.
    reaper.ImGui_TextColored(ctx, T.REF_RED, "NO TARGET")
    tip = "Reference mode is still on and your project is still muted, but nothing is armed.\n" ..
      "Select a sound or a pin to arm it — or click LATCH to turn reference mode off."
  else
    local playing = ref.active
    reaper.ImGui_TextColored(ctx, playing and T.ACCENT or T.TEXT_PRIMARY, playing and "PLAYING" or "ARMED")
    if sel.label then
      reaper.ImGui_SameLine(ctx, 0, 6)
      reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "\u{00B7} " .. sel.label:upper() .. " \u{2192}")
    end
    reaper.ImGui_SameLine(ctx, 0, 6)
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, sel.name)
    tip = string.format("%s%s \u{2192} %s\n%s",
      playing and "PLAYING" or "ARMED", sel.label and (" \u{00B7} " .. sel.label) or "", sel.name,
      playing and "This is sounding now; stopping REAPER's transport silences it."
        or "This is what will play when you press play in REAPER.")
    -- Hovering adds the pin's note, when the armed reference is a pin that has
    -- one (DESIGN, 2026-07-28) — a reference is often chosen FOR a reason
    -- ("great low-end thump"), and this is the one place that's a hover away.
    if is_pin_id(sel.id) and sel.note and sel.note ~= "" then
      tip = tip .. "\n" .. sel.note
    end
  end
  reaper.ImGui_EndGroup(ctx)
  if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, tip) end
end

function transport.draw(ctx, state, res)
  local action
  local font = res and res.icon_font

  -- Row geometry, worked out once up front by the shared `geometry` helper above
  -- so the height reserved for this row matches the height it takes. LATCH
  -- pinned left, the cluster centred (or dropped to a second line when the row
  -- is too narrow to hold both), the trim fader pinned right. Everything is
  -- fixed-size; only the gaps flex, which is what makes the collapse order work.
  local row_x0, row_y0 = reaper.ImGui_GetCursorPos(ctx)
  local row_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local g = geometry(ctx, row_w)
  local ctrl, gap = g.ctrl, g.gap
  local trim_shown = g.trim_shown
  local trim_x = row_x0 + g.trim_x

  -- Absolute placement for the cluster: with wrapping in play, SameLine can no
  -- longer express where each square goes, so each one is positioned directly.
  local function place_cluster(i) -- i is 0-based
    local line = math.floor(i / g.per_line)
    local col = i % g.per_line
    reaper.ImGui_SetCursorPos(ctx,
      row_x0 + g.cluster_x + col * (ctrl + gap),
      row_y0 + g.cluster_top + line * (ctrl + g.gap_y))
  end

  -- LATCH: the A/B-against-your-project reference-mode toggle (labeled "LATCH"
  -- on the button, 2026-07-28 — a label change only; the action type and every
  -- internal name stay "reference"). Filled REF_RED only while ON (the one red
  -- in the whole UI, reserved for exactly this — tokens.md). Hover and pressed
  -- states are pushed to the same red so the fill never blinks back to grey.
  -- Fixed width, always present: latching signals itself by colour alone, never
  -- by changing the row's shape.
  action = transport.draw_latch(ctx, state) or action

  -- The transport cluster. Gated throughout on the ARMED reference actually
  -- being what's sounding/paused — the one live preview may currently be a
  -- browse audition instead (Phase 5.9: independent browsing), and these
  -- controls speak only for the working view.
  place_cluster(0)

  local sound_current = state.preview.sound_id == state.selected_id
  local playing = state.preview.playing and sound_current
  -- `paused_sound_id`, not `sound_id`: the pause memory is tracked separately
  -- so it survives an unrelated browse audition sounding through the same
  -- shared preview in between (see the state init comment in the entry script).
  local paused = (not playing) and state.preview.paused_at ~= nil
    and state.preview.paused_sound_id == state.selected_id

  -- Play / pause (accent-filled while actually sounding). A one-off transport
  -- control, so it stays here rather than in ui.widgets — but the same square
  -- as every icon button. Lucide glyph face with a text fallback; over the
  -- accent fill the glyph switches to TEXT_ON_ACCENT so it stays legible. Hover
  -- and pressed are pushed to accent shades like LATCH pushes its red —
  -- override only the resting colour and ImGui's grey hover fill swallows the
  -- blue on mouseover. Covers both "stopped" and "paused" with the same PLAY
  -- face — clicking either resumes from wherever it was, or starts fresh.
  local face = playing and "pause" or "play"
  local use_icon = font and icons.NAMES[face]
  if playing then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), T.ACCENT)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.ACCENT_HOVER)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.ACCENT)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_ON_ACCENT) -- text fallback face
  end
  if reaper.ImGui_Button(ctx, (use_icon and "" or (playing and PAUSE or PLAY)) .. "##playpause", ctrl, ctrl) then
    action = { type = "toggle_play" }
  end
  if playing then reaper.ImGui_PopStyleColor(ctx, 4) end
  if use_icon then
    icons.paint_over_item(ctx, font, face, playing and ON_ACCENT_FACE or nil)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, playing and "Pause" or (paused and "Resume" or "Play selected sound"))
  end

  -- Stop: a separate button beside play/pause, back to the start (no
  -- remembered position). Always the same size and always drawn the same
  -- way — it simply does nothing when there's nothing of the working view's
  -- own playing or paused, rather than a dimmed "disabled" look (which would
  -- need its own hand-faded icon colour to avoid a bright glyph sitting on a
  -- dimmed button — not worth the complexity for a button that's a no-op
  -- either way).
  place_cluster(1)
  local stop_use_icon = font and icons.NAMES["square"]
  if reaper.ImGui_Button(ctx, (stop_use_icon and "" or STOP) .. "##stop", ctrl, ctrl) then
    action = { type = "stop_play" }
  end
  if stop_use_icon then icons.paint_over_item(ctx, font, "square") end
  if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, "Stop and return to the start") end

  place_cluster(2)
  if widgets.toggle(ctx, "loop", LOOP, state.loop, "Loop", font, "repeat") then action = { type = "toggle_loop" } end

  place_cluster(3)
  if widgets.toggle(ctx, "auto", "A", state.auto_audition,
      "Auto-audition: play a sound the moment you select it", font, "ear") then
    action = { type = "toggle_auto" }
  end

  -- The armed-reference readout fills the flexible gap between the cluster and
  -- the trim fader (or the window edge, once trim itself has hidden) — clipped
  -- to that exact width in a zero-padding child, so a long armed-reference name
  -- truncates against the GAP instead of drawing over the trim fader (tokens.md
  -- "working view — transport row layout").
  -- Anchored to the cluster's LAST line, so a wrapped cluster doesn't leave the
  -- readout stranded up beside LATCH.
  local readout_x0 = row_x0 + g.cluster_x + g.last_line_w + gap
  local readout_x1 = trim_shown and (trim_x - gap) or (row_x0 + row_w)
  local readout_w = readout_x1 - readout_x0
  if readout_w > 0 then
    reaper.ImGui_SetCursorPos(ctx, readout_x0, row_y0 + g.last_line_top)
    local no_scroll = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
    -- Padding popped the instant the child has taken it, so the readout's own
    -- tooltip keeps the theme's padding (see ui/window.lua for the full note).
    -- EndChild only inside the `if` (ReaImGui contract, see ui/browser.lua): a
    -- fully clipped child returns false WITHOUT opening.
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
    local open = reaper.ImGui_BeginChild(ctx, "transport_readout", readout_w, ctrl, 0, no_scroll)
    reaper.ImGui_PopStyleVar(ctx, 1)
    if open then
      draw_readout(ctx, state)
      reaper.ImGui_EndChild(ctx)
    end
  end

  -- Per-sound trim, pinned to the row's right edge (disabled, but still drawn,
  -- when nothing is selected so the row never changes shape). Trim can boost as
  -- well as cut, unlike the master.
  --
  -- Responsive collapse (tokens.md "working view — responsive collapse order"):
  -- the trim fader is the first FIXED control to give way in a narrow/docked
  -- window — the readout's gap already shrinks before this point, so hiding the
  -- fader next is the cheapest way to keep every remaining control at its
  -- normal size instead of crushing everything together. Driven only by window
  -- size (GetContentRegionAvail via room_after_cluster above), never by
  -- selection or latch state — the SAME disabled-but-present fader still draws
  -- whenever there's room, whether or not a sound is selected.
  if trim_shown then
    reaper.ImGui_SetCursorPos(ctx, trim_x, row_y0 + g.last_line_top)
    local sel = state.selected
    if sel then
      local db, commit = widgets.db_fader(ctx, "trim", sel.trim_db,
        { min = -24, max = 24, default = 0, tip = "Trim for this sound (remembered)" .. RESET_HINT })
      if db ~= nil then action = { type = "set_trim", db = db, commit = commit } end
    else
      reaper.ImGui_BeginDisabled(ctx)
      widgets.db_fader(ctx, "trim", 0, { min = -24, max = 24, tip = "Trim for this sound (select a sound first)" })
      reaper.ImGui_EndDisabled(ctx)
    end
  end

  -- Every item above was placed absolutely, so leave the cursor where a normal
  -- row would have left it — directly below the row's full (possibly wrapped)
  -- height. Nothing follows the transport in the stacked arrangement today, but
  -- a caller that adds something must not have to know about the wrapping.
  reaper.ImGui_SetCursorPos(ctx, row_x0, row_y0 + g.height)

  return action
end

--------------------------------------------------------------- column variant

-- The side column packs everything into PAIRS (decided 2026-07-30): two squares
-- per row, so every row is exactly the same width and none of them carries the
-- dead space the first attempt had. The column ends up as narrow as it can be,
-- which is the point — every pixel it doesn't take goes to the waveform.
--
--   [ R ][library]   <- the library button is the host's, drawn by ui/window.lua
--   [ ▶ ][ stop  ]
--   [loop][ ear  ]
--   [== trim fader ==]   track full width, value beneath
--
-- Deliberately NOT built on transport.draw: that function's whole job is the
-- one-row collapse order, and bending it into a column was what produced the
-- three-and-one row. This lays the pairs out directly.

-- The column is exactly two squares plus one gap wide. Derived, never typed, so
-- it tracks the control height and can't drift.
function transport.column_width(ctx)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local gap = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  return ctrl * 2 + gap
end

-- Four rows: latch/library, play/stop, loop/auto, fader.
function transport.column_height(ctx)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local gap_y = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  return ctrl * 4 + gap_y * 3
end

-- The three transport rows BELOW the latch/library pair (the host draws that one,
-- because the library button belongs to the window, not the transport).
function transport.draw_column_body(ctx, state, res)
  local action
  local font = res and res.icon_font
  local col_w = transport.column_width(ctx)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)

  local sound_current = state.preview.sound_id == state.selected_id
  local playing = state.preview.playing and sound_current

  -- Play / pause, then stop.
  local face = playing and "pause" or "play"
  local use_icon = font and icons.NAMES[face]
  if playing then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), T.ACCENT)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.ACCENT_HOVER)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.ACCENT)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_ON_ACCENT)
  end
  if reaper.ImGui_Button(ctx, (use_icon and "" or (playing and PAUSE or PLAY)) .. "##playpause", ctrl, ctrl) then
    action = { type = "toggle_play" }
  end
  if playing then reaper.ImGui_PopStyleColor(ctx, 4) end
  if use_icon then icons.paint_over_item(ctx, font, face, playing and ON_ACCENT_FACE or nil) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, playing and "Pause" or "Play selected sound")
  end

  reaper.ImGui_SameLine(ctx)
  local stop_use_icon = font and icons.NAMES["square"]
  if reaper.ImGui_Button(ctx, (stop_use_icon and "" or STOP) .. "##stop", ctrl, ctrl) then
    action = action or { type = "stop_play" }
  end
  if stop_use_icon then icons.paint_over_item(ctx, font, "square") end
  if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, "Stop and return to the start") end

  -- Loop, then auto-audition.
  if widgets.toggle(ctx, "loop", LOOP, state.loop, "Loop", font, "repeat") then
    action = action or { type = "toggle_loop" }
  end
  reaper.ImGui_SameLine(ctx)
  if widgets.toggle(ctx, "auto", "A", state.auto_audition,
      "Auto-audition: play a sound the moment you select it", font, "ear") then
    action = action or { type = "toggle_auto" }
  end

  -- Trim, stacked: track across the column's full width, value beneath. No
  -- reserved zone beside the track means no gap can open up in a column this
  -- narrow (reported 2026-07-30).
  local sel = state.selected
  local fader_opts = { min = -24, max = 24, width = col_w, stacked = true }
  if sel then
    fader_opts.default = 0
    fader_opts.tip = "Trim for this sound (remembered)" .. RESET_HINT
    local db, commit = widgets.db_fader(ctx, "trim", sel.trim_db, fader_opts)
    if db ~= nil then action = action or { type = "set_trim", db = db, commit = commit } end
  else
    fader_opts.tip = "Trim for this sound (select a sound first)"
    reaper.ImGui_BeginDisabled(ctx)
    widgets.db_fader(ctx, "trim", 0, fader_opts)
    reaper.ImGui_EndDisabled(ctx)
  end

  return action
end

return transport
