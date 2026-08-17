-- transport: the play/loop/auto-audition controls plus the per-sound trim and
-- master preview volume faders. A ui/ module — draws and reports intent only.
-- Reusable controls (faders, toggles, the reset gesture) come from ui.widgets so
-- they behave identically everywhere; this file only arranges them.

local theme = require("ui.theme")
local tips = require("ui.tips")
local widgets = require("ui.widgets")
local match = require("core.match")
local icons = require("ui.icons")
local refpicker = require("ui.refpicker")
local matchwin = require("ui.matchwin")
local settings = require("ui.settings")
local walkthrough_ui = require("ui.walkthrough")
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

------------------------------------------------------- the transport controls

-- PLAY/PAUSE AND STOP LIVE HERE ONCE AND BOTH WINDOWS DRAW THEM (2026-08-12,
-- when the Library gained a transport of its own): the working view's control
-- cluster and the Library's info row call the same two functions, so the two
-- transports cannot drift into looking or behaving differently — which is the
-- whole reason the user asked for a full transport in the Library rather than a
-- lone stop button.
--
-- Each draws ONE control-height square AT THE CURSOR. Placement stays with the
-- caller on purpose: the working view positions its cluster absolutely (its bar
-- folds to two lines) while the browser lays its row out with SameLine, and a
-- shared function that owned placement would have to speak both languages.
--
-- `opts` = { slot, id, sound }:
--   slot   which playback this pair speaks for — "main" (the working view and
--          reference mode) or "browse" (the Library). It is stamped on the
--          returned action as `target`, exactly the way the browser tags its
--          seek, and the entry script reads it to decide whose remembered pause
--          the click belongs to
--   id     the sound id this window is pointed at (selected_id / browse_id)
--   sound  that sound's record, or nil when this window has nothing to act on

-- Is this slot's own sound sounding, and is it paused? One answer, because it
-- decides three things at once (the face, the tooltip, and whether the square is
-- dim) and the two buttons must agree about it exactly.
--
-- The slot test matters as much as the id: there is ONE live preview and two
-- windows that can speak for it, so without it a Library audition of the very
-- sound the working view has armed would light up both transports and let either
-- one pause it. Reading `state.preview.paused` directly (rather than through
-- holders, which pulls in the adapters a ui/ module may not touch) is the same
-- draw-from-state deal every other panel here has.
local function playback_state(state, slot, id)
  local playing = state.preview.playing and state.preview.slot == slot
    and state.preview.sound_id ~= nil and state.preview.sound_id == id
  local parked = state.preview.paused[slot]
  local paused = (not playing) and parked ~= nil and id ~= nil and parked.sound_id == id
  return playing, paused
end

-- Play / pause. Accent-filled while actually sounding — hover and pressed are
-- pushed to accent shades like the latch pushes its red, since overriding only
-- the resting colour lets ImGui's grey hover fill swallow the blue on mouseover.
-- Over that fill the glyph switches to TEXT_ON_ACCENT so it stays legible.
--
-- "Stopped" and "paused" share the same PLAY face: clicking either resumes from
-- wherever this slot was left, or starts fresh. Dimmed — never hidden, never
-- resized — when the window has no sound to act on at all.
function transport.draw_play(ctx, state, font, opts)
  local slot = opts.slot
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local playing, paused = playback_state(state, slot, opts.id)
  local face = playing and "pause" or "play"
  local use_icon = font and icons.NAMES[face]

  local dim = opts.sound == nil
  if dim then reaper.ImGui_BeginDisabled(ctx) end
  if playing then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), T.ACCENT)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.ACCENT_HOVER)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.ACCENT)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_ON_ACCENT) -- text fallback face
  end
  local clicked = reaper.ImGui_Button(ctx,
    (use_icon and "" or (playing and PAUSE or PLAY)) .. "##playpause_" .. slot, ctrl, ctrl)
  if playing then reaper.ImGui_PopStyleColor(ctx, 4) end
  -- The painted glyph fades itself against the live style alpha (icons.lua), so
  -- a disabled square dims face and all with no hand-faded colour here.
  if use_icon then
    icons.paint_over_item(ctx, font, face, playing and ON_ACCENT_FACE or nil)
  end
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if dim then reaper.ImGui_EndDisabled(ctx) end
  tips.show(ctx, hovered,
    playing and "Pause" or (paused and "Resume" or "Play selected sound"))

  if clicked then return { type = "toggle_play", target = slot } end
  return nil
end

-- What the STOP square acts on: anything this slot has going, whatever sound it
-- happens to be. Deliberately NOT id-matched the way play/pause is, because the
-- two buttons answer different questions. "Play" means "play the sound this
-- window is pointed at", so it follows the selection. "Stop" means "stop what
-- this window has going" — and a window whose selection has moved on while its
-- own audio still runs (clicking a row with auto-audition off) must still be
-- able to stop it. Id-matched, the square went dim exactly then, and the only
-- way to silence the sound was to start another one.
local function slot_busy(state, slot)
  return (state.preview.playing and state.preview.slot == slot)
    or state.preview.paused[slot] ~= nil
end

-- Stop: back to the start, no remembered position. Dimmed while this slot has
-- nothing sounding and nothing paused — there is genuinely nothing to stop.
-- (It used to be drawn bright and inert instead, because a dimmed button would
-- have left a bright glyph sitting on a faded square; the painters read the
-- style alpha themselves since 2026-08-12, so BeginDisabled is now enough.)
function transport.draw_stop(ctx, state, font, opts)
  local slot = opts.slot
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local use_icon = font and icons.NAMES["square"]

  local dim = not slot_busy(state, slot)
  if dim then reaper.ImGui_BeginDisabled(ctx) end
  local clicked = reaper.ImGui_Button(ctx,
    (use_icon and "" or STOP) .. "##stop_" .. slot, ctrl, ctrl)
  if use_icon then icons.paint_over_item(ctx, font, "square") end
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if dim then reaper.ImGui_EndDisabled(ctx) end
  tips.show(ctx, hovered, "Stop and return to the start")

  if clicked then return { type = "stop_play", target = slot } end
  return nil
end

--------------------------------------------------------------- bar geometry

-- The bar's shape at a given width, worked out WITHOUT drawing anything.
-- `transport.measure` and `transport.draw` both go through here, so the height
-- reserved for the bar can never disagree with the height it actually takes —
-- which matters because the working view reserves the bar FIRST and hands
-- everything left to the waveform.
--
-- Full width, left to right:
--
--   [L][>][#][loop][M]  [ LABEL . name  v ] 2/6 [<][>]  48 kHz . 24-bit . WAV . stereo  [@][==trim==][library][gear]
--
-- ([@] = the match window's target button, which collapses WITH the trim
-- fader it drives — one unit in every arrangement below. The gear holds the
-- bar's corner — the user's pick, 2026-08-10 `.brief/settings-move`, when it
-- moved here from the browser toolbar and the References-folder square it
-- replaces became a Settings row.)
--
-- THE RULE, from the 2026-08-08 brief (.brief/bar-space-and-folding, replacing
-- the 08-07 ladder): **space is never left empty — the name box absorbs it.**
-- The box takes every pixel between the arrows and the right-hand group, up to
-- PICK_MAX_W; pieces fold away one by one only when the box has given
-- everything back. The user accepted the visible consequence: at each fold
-- moment the box GROWS by the folded piece's width (~35/27/68px) — small
-- steps, each at an instant a control visibly leaves anyway. (This knowingly
-- retires the 08-06 "slot never widens while narrowing" cap: THAT rule, kept
-- mechanically, was what pinned the box at 80px under a mid-bar hole — the
-- thing the user photographed and rejected.)
--
-- Narrowing, in order. **NOTHING ever disappears** (user's call, 2026-08-08
-- third round: the folder button used to hide on one line and reappear on
-- two — "no icon should disappear; when there's no more room for removing
-- stuff, that's when we create the 2nd row"). The only moves are shrinks and
-- folds:
--   1. the info text steps aside (it only ever borrows genuinely spare room —
--      see draw — so its leaving moves nothing)
--   2. the name box shrinks, PICK_MAX_W down to PICK_MIN_W
--   3. the trim fader folds to [@] + a draggable dB number, the box taking
--      the freed width — the ONE mid-ladder step left. Once a number, NEVER
--      a fader again at any narrower size (no shape flip-flops)
--   4. out of room: the bar folds to the user's balanced TWO lines — line one
--      is the name box stretched to whatever space it has, ending in the
--      count + arrows; line two is [L][cluster] left and [@][number][library]
--      [gear] pinned right. Two lines is the MAXIMUM — no third, ever.
--   5. that full two-line form IS the minimum (second round: "don't remove
--      the library or folder icons" — the gear inherits the folder square's
--      never-hides standing). The floating window's floor (MIN_WIN_W)
--      sits just above it; only a REAPER dock can go narrower, and there the
--      bar keeps every control and CLIPS at the window's edge. Nothing poorer
--      exists.
--
-- `trim`: "fader" (the @ + full fader) or "number" (the @ + the draggable dB
-- number). The trim never leaves the bar; the count, Library and gear never
-- hide — so the Library/gear pair isn't flagged per arrangement at all.
local ARRANGEMENTS = {
  { count = true, trim = "fader"  },
  { count = true, trim = "number" },
  { two_line = true, count = true, trim = "number" },
}

-- Squares in the transport cluster: play, stop, loop, mono (the ear left for the
-- browser, 2026-08-07; mono arrived the same day). A constant so `cluster_w`
-- and the draw loop can never disagree about how many squares exist.
local N_CLUSTER = 4

-- One candidate arrangement, measured. Returns nil when it doesn't fit, so the
-- caller can try the next (poorer) one. `m` carries the per-frame measurements
-- (count/arrows/number widths) so the parameter list stays readable.
--
-- Every control's x AND y come out of here (`ctrl_y` is the line every button
-- sits on — 0 on one line, the second line after the fold), so `draw` never
-- repeats the arithmetic.
local function try_fit(a, width, ctrl, gap, gap_y, m, cluster_w, floor_it)
  local count_on = a.count and m.count_w > 0
  -- The count sits BETWEEN the slot and the arrows ("name · 1/3" reads as one
  -- fact), with PICK_COUNT_PAD of air either side rather than the usual
  -- ItemSpacing — a small dim number wedged against controls at ItemSpacing
  -- read as cramped (user-reported 2026-08-06).
  local before_arrows = count_on and (M.PICK_COUNT_PAD + m.count_w + M.PICK_COUNT_PAD) or gap
  -- The trim control brings the target button (◎) with it: the button drives
  -- it, so they fold as one unit — in both its shapes.
  local trim_w = (a.trim == "fader" and M.SLIDER_W) or (a.trim == "number" and m.num_w) or nil

  local g = {
    ctrl = ctrl, gap = gap, gap_y = gap_y,
    two_line = a.two_line or false,
    count_w = count_on and m.count_w or 0,
    trim_shown = a.trim, trim_w = trim_w,
  }

  if a.two_line then
    -- The balanced fold (the user's own layout, 2026-08-08): line one is the
    -- name box stretched across the window — no cap; the fold only exists
    -- below ~PICK_MAX_W + fixtures anyway, and an empty tail here was exactly
    -- the hole the brief killed — ending in the count and arrows. Line two:
    -- R + the cluster on the left, the right-hand group (◎ · trim · Library ·
    -- gear) PINNED RIGHT — the same grammar as one line, and what makes
    -- line two's right edge sit exactly under line one's arrows at every
    -- width (user-reported 2026-08-08: packed-left, the Library button's edge
    -- drifted out of line with the arrow above it).
    local slot_w = width - before_arrows - m.arrows_w
    -- Library + gear sit PICK_ARROW_GAP apart, not ItemSpacing: they end
    -- line two exactly under the arrow pair ending line one, and the arrows'
    -- tighter pair gap is what the eye lines the columns up by — at the
    -- normal gap the inner square poked 2px further left than the ‹ above it
    -- (user-reported 2026-08-08, when the pair was folder + Library).
    local group_w = ctrl + M.PICK_ARROW_GAP + ctrl -- Library + gear, always
    if trim_w then group_w = group_w + gap + ctrl + gap + trim_w end
    local packed_x = ctrl + gap + cluster_w + gap -- tightest the group may sit
    if (slot_w < M.PICK_MIN_W or packed_x + group_w > width) and not floor_it then return nil end

    g.slot_x, g.slot_w = 0, math.max(0, slot_w)
    if count_on then
      g.count_x = g.slot_w + M.PICK_COUNT_PAD
      g.arrows_x = g.count_x + m.count_w + M.PICK_COUNT_PAD
    else
      g.arrows_x = g.slot_w + gap
    end
    g.ctrl_y = ctrl + gap_y
    g.latch_x = 0
    -- Below the full form's width (only a dock can force it) line two does
    -- NOT overflow: its seven ItemSpacing gaps tighten evenly, down to a 2px
    -- floor, so the Library button stays EXACTLY flush under line one's arrow
    -- through the squeeze (user-reported 2026-08-08: overflowing into the
    -- window padding put line two's edge past line one's). Only past the
    -- squeeze's own floor (~28px more) does the line finally clip.
    local G = gap
    local deficit = (packed_x + group_w) - width
    if deficit > 0 then G = gap - math.min(gap - 2, deficit / 7) end
    g.cluster_gap = G
    g.cluster_x = ctrl + G
    local x = math.max(width - group_w, g.cluster_x + cluster_w - 3 * (gap - G) + G)
    if trim_w then
      g.target_x = x
      g.trim_x = g.target_x + ctrl + G
      x = g.trim_x + trim_w + G
    end
    g.library_x = x
    g.gear_x = g.library_x + ctrl + M.PICK_ARROW_GAP
    g.height = ctrl * 2 + gap_y
    return g
  end

  -- One line: the right-hand group pinned right, the box absorbing every pixel
  -- between the arrows and it — up to PICK_MAX_W. Above the cap the leftover
  -- is genuinely spare, and the info text borrows it (see draw): with every
  -- control on show, edge room reads as margin; it was the STARVED box beside
  -- a mid-bar hole that read as broken.
  local right_w = ctrl + gap + ctrl -- Library + the gear, always
  if trim_w then right_w = right_w + gap + ctrl + gap + trim_w end
  local slot_raw = width - (ctrl + gap + cluster_w + gap)
    - before_arrows - m.arrows_w - gap - right_w
  if slot_raw < M.PICK_MIN_W and not floor_it then return nil end

  g.slot_w = math.max(0, math.min(slot_raw, M.PICK_MAX_W))
  g.ctrl_y = 0
  g.latch_x = 0
  g.cluster_gap = gap -- only line two ever tightens it
  g.cluster_x = ctrl + gap
  g.slot_x = g.cluster_x + cluster_w + gap
  if count_on then
    g.count_x = g.slot_x + g.slot_w + M.PICK_COUNT_PAD
    g.arrows_x = g.count_x + m.count_w + M.PICK_COUNT_PAD
  else
    g.arrows_x = g.slot_x + g.slot_w + gap
  end
  g.gear_x = width - ctrl -- the corner (user's pick, 2026-08-10)
  g.library_x = g.gear_x - gap - ctrl
  if trim_w then
    g.trim_x = g.library_x - gap - trim_w
    g.target_x = g.trim_x - gap - ctrl -- the ◎ button, immediately left
  end
  -- The info text's borrowed zone: after the arrows, up to the right group.
  -- Positive ONLY once the box is at its full cap (uncapped, the box takes
  -- this exactly to zero) — which is what makes the text's coming and going
  -- move nothing, and why a longer line on a different sound can't resize the
  -- box: the box never waits on the text.
  g.tech_x = g.arrows_x + m.arrows_w + M.PICK_COUNT_PAD
  g.tech_max = (g.target_x or g.library_x) - gap - g.tech_x
  g.height = ctrl
  return g
end

local function geometry(ctx, width, count_w)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local gap, gap_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
  local cluster_w = ctrl * N_CLUSTER + gap * (N_CLUSTER - 1)

  local m = { count_w = count_w or 0 }
  -- Asked of the picker, never re-derived here: this used to be its own
  -- `ctrl * 2`, which silently went stale the day the arrow pair gained a
  -- gap between them, so the fit test measured a bar 4px narrower than the
  -- one that draws (Codex, 2026-08-06).
  m.arrows_w = refpicker.arrows_width(ctx)
  -- The collapsed trim's number, sized for its widest reading ("+24.0 dB").
  m.num_w = select(1, reaper.ImGui_CalcTextSize(ctx, "+24.0 dB"))
    + select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding())) * 2

  for _, a in ipairs(ARRANGEMENTS) do
    local g = try_fit(a, width, ctrl, gap, gap_y, m, cluster_w, false)
    if g then return g end
  end
  -- Narrower than the full two-line form (only a dock can force this — the
  -- floating window's minimum sits above it). Floors lifted: the name box goes
  -- to its floor and line two keeps EVERY control, clipping at the window's
  -- edge (user's call, 2026-08-08 second round — the full form is the
  -- minimum; never shed the Library or gear squares, never a third line).
  return try_fit(ARRANGEMENTS[#ARRANGEMENTS], width, ctrl, gap, gap_y,
    m, cluster_w, true)
end

-- How tall the bar needs to be at `width`. Called before anything else is laid
-- out in the working view. `state` is needed because the count reserves its
-- width from the project's pin total.
function transport.measure(ctx, width, state)
  return geometry(ctx, width, refpicker.count_width(ctx, state)).height
end

-- The collapse arithmetic, exposed for the offline width sweep (run against a
-- fake `reaper` outside REAPER whenever the ARRANGEMENTS change — it proved
-- the 2026-08-06 slot-never-widens rule and re-proved this ladder). Nothing
-- inside REAPER calls this.
transport._geometry = geometry

-- The reference-mode latch: a square like every other transport control since
-- 2026-07-30, faced with "L" for latch (2026-08-08, user's call — it wore "R"
-- for reference until then). Filled REF_RED while ON. Hover and
-- pressed are pushed to the same red so the fill never blinks back to grey.
-- Fixed size always: latching signals itself by colour alone, never by changing
-- shape.
--
-- Since 2026-08-06 this button is the ONLY thing in the UI that reddens for
-- reference mode — the red window outline and the picker slot's red both went
-- (user's call). Since 2026-08-13 it is deliberately project-specific: red means
-- THIS project owns the one active latch. Other tabs stay grey and usable; a
-- closed owner waits in the recovery queue without leaving a stuck-looking button.
-- Genuine recovery failures are surfaced as errors instead of overloading this
-- current-project control.
--
-- The word "LATCH" is gone from the face. That's a real cost on the tool's least
-- self-explanatory control, so the tooltip carries the full explanation and the
-- red fill still shouts when it's on.
function transport.draw_latch(ctx, state)
  local action
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local ref = state.reference
  local latched = ref.latched
  if latched then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), T.REF_RED)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.REF_RED)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.REF_RED)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_ON_REF)
  end
  if reaper.ImGui_Button(ctx, "L##reference", ctrl, ctrl) then
    if not latched and not state.selected then
      -- Muting an empty project would buy silence for nothing. Opening this
      -- project's chooser makes the missing step visible instead of making L
      -- appear dead; once a reference is armed, L remains fully usable.
      refpicker.request_open()
    else
      action = { type = "toggle_reference" }
    end
  end
  if latched then reaper.ImGui_PopStyleColor(ctx, 4) end
  local tip = latched
    and ("Reference mode is on for " .. (ref.owner_name or "this project") ..
      ". Its master is muted. Press Play in REAPER to hear the selected reference. " ..
      "Click the Latch button to turn it off.")
    or (state.selected
      and "Turn on Reference mode. This mutes the project so Play in REAPER hears the selected reference instead. You can bind the Latch button to a REAPER shortcut."
      or "Choose a reference first. Click the Latch button to open the reference list.")
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), tip, "reference_latch")
  return action
end

function transport.draw(ctx, state, res)
  local action
  local font = res and res.icon_font

  -- Bar geometry, worked out once up front by the shared `geometry` helper above
  -- so the height reserved for the bar matches the height it takes. Everything
  -- is fixed-size except the picker's name slot; only that slot and the gaps
  -- flex, which is what makes the collapse order work.
  local row_x0, row_y0 = reaper.ImGui_GetCursorPos(ctx)
  local row_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local g = geometry(ctx, row_w, refpicker.count_width(ctx, state))
  local ctrl, gap = g.ctrl, g.gap
  local trim_shown = g.trim_shown -- "fader" | "number" | false

  -- Absolute placement for the cluster: every button lives on `ctrl_y`'s line
  -- (line one normally, line two after the fold), so SameLine can't express it.
  -- `cluster_gap`, not the theme gap: a squeezed line two tightens it.
  local function place_cluster(i) -- i is 0-based
    reaper.ImGui_SetCursorPos(ctx,
      row_x0 + g.cluster_x + i * (ctrl + g.cluster_gap),
      row_y0 + g.ctrl_y)
  end

  -- LATCH: the A/B-against-your-project reference-mode toggle (labeled "LATCH"
  -- on the button, 2026-07-28 — a label change only; the action type and every
  -- internal name stay "reference"). Filled REF_RED only while ON — the only
  -- thing in the UI that reddens for reference mode. Hover and pressed
  -- states are pushed to the same red so the fill never blinks back to grey.
  -- Fixed width, always present: latching signals itself by colour alone, never
  -- by changing the row's shape. After the fold it leads line two.
  reaper.ImGui_SetCursorPos(ctx, row_x0 + g.latch_x, row_y0 + g.ctrl_y)
  -- Walkthrough targets are noted from GEOMETRY, not from "the last item":
  -- these buttons show tooltips, and a tooltip's own text becomes the last
  -- item the frame it appears — the ring would jump onto it (the same
  -- last-item trap tips.show documents).
  local walk_x, walk_y = reaper.ImGui_GetCursorScreenPos(ctx)
  action = transport.draw_latch(ctx, state) or action
  walkthrough_ui.note_rect(ctx, state.walkthrough, "latch",
    walk_x, walk_y, walk_x + ctrl, walk_y + ctrl)

  -- The transport cluster. The play/pause and stop squares are the SHARED pair
  -- (see the top of this file) — the Library's info row draws the same two —
  -- pointed at the "main" slot, so they speak only for the working view even
  -- while the one live preview is a browse audition (Phase 5.9: independent
  -- browsing).
  --
  -- Drawn, THEN merged (`local a = draw(...)`, never `action = action or
  -- draw(...)`): Lua's `or` short-circuits, so merging the wrong way round
  -- would skip the button's whole submission for any frame an earlier control
  -- already reported something, and the square would vanish for that frame.
  local main_slot = { slot = "main", id = state.selected_id, sound = state.selected }
  place_cluster(0)
  local play_action = transport.draw_play(ctx, state, font, main_slot)
  action = action or play_action

  place_cluster(1)
  local stop_action = transport.draw_stop(ctx, state, font, main_slot)
  action = action or stop_action

  place_cluster(2)
  if widgets.toggle(ctx, "loop", LOOP, state.loop, "Loop", font, "repeat") then action = { type = "toggle_loop" } end
  -- (The auto-audition ear left the bar 2026-08-07 — it only ever governed the
  -- browser's click-to-hear, so it lives beside the browser's audition strip.)

  -- MONO: fold both channels together and hear the result in both speakers, the
  -- console mono button. Faced "M" rather than a glyph — Lucide has no icon that
  -- reads as "mono", and an arbitrary one would need learning; the latch's "L"
  -- already set the precedent that a letter is a legitimate face here.
  --
  -- A plain toggle like loop, NOT the latch's red fill: red means "your project
  -- is muted, and it will stay that way until you deal with it". Mono changes
  -- nothing but what you hear right now, so it wears the same accent face every
  -- other monitoring toggle does.
  place_cluster(3)
  if widgets.toggle(ctx, "mono", "M", state.mono,
      "Fold left and right together in both speakers to check mono compatibility.",
      font) then
    action = { type = "toggle_mono" }
  end
  -- The reference picker: the name slot (the bar's one flexible element), the
  -- position count in its reserved width, then the joined step arrows — count
  -- BETWEEN slot and arrows since 2026-08-07 ("name · 1/3" is one fact). This
  -- is what replaced the reference-tab row AND the old armed-reference readout
  -- — one place that says what's armed and changes it (see ui/refpicker.lua).
  --
  -- Always draw, then merge (`action = action or …`, never the other way round):
  -- Lua's `or` short-circuits, so merging the wrong way would skip a draw
  -- entirely for the frame an earlier control reported something.
  reaper.ImGui_SetCursorPos(ctx, row_x0 + g.slot_x, row_y0)
  local slot_action = refpicker.draw_slot(ctx, state, res, g.slot_w)
  action = action or slot_action
  if g.count_w > 0 then
    reaper.ImGui_SetCursorPos(ctx, row_x0 + g.count_x, row_y0)
    refpicker.draw_count(ctx, state, g.count_w)
  end
  reaper.ImGui_SetCursorPos(ctx, row_x0 + g.arrows_x, row_y0)
  local arrow_action = refpicker.draw_arrows(ctx, state, res)
  action = action or arrow_action

  -- The armed sound's tech facts ("48 kHz · 24-bit · WAV · stereo"), following
  -- the picker unit — small dim metadata in the browser info row's exact voice
  -- (the text is state.selected_tech, formatted by the entry script once per
  -- selection through the same core.techfacts the browser uses).
  --
  -- A BORROWER, never a tenant (2026-08-08 brief, retiring the ~200px held
  -- seat that starved the name box): it draws only into `tech_max`, the room
  -- that is genuinely spare once the box has everything it may take — so its
  -- coming and going moves nothing, and a longer line on the next sound can't
  -- resize the box. All-or-nothing on purpose: a partially-fitting line would
  -- ellipsise and re-cut with every pixel of resize, a flicker in the corner
  -- of the eye for text nobody is reading at that moment.
  if g.tech_x and state.selected_tech then
    local small = theme.push_small_font(ctx)
    local tw, th = reaper.ImGui_CalcTextSize(ctx, state.selected_tech)
    if tw <= g.tech_max then
      -- Placed-then-painted, the draw_count idiom.
      reaper.ImGui_SetCursorPos(ctx, row_x0 + g.tech_x, row_y0)
      reaper.ImGui_Dummy(ctx, tw, ctrl)
      local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
      local _, y1 = reaper.ImGui_GetItemRectMax(ctx)
      reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx),
        x0, (y0 + y1) * 0.5 - th * 0.5, T.TEXT_TERTIARY, state.selected_tech)
    end
    if small then reaper.ImGui_PopFont(ctx) end
  end

  -- Per-sound trim, pinned to the row's right edge (disabled, but still drawn,
  -- when nothing is selected so the row never changes shape). Trim can boost as
  -- well as cut, unlike the master.
  --
  -- Responsive collapse (tokens.md "working view — responsive collapse order"):
  -- the trim gives way AFTER the count and the tech facts —
  -- and it collapses rather than hides (2026-08-07 brief pages 6/12): the
  -- track goes and the dB number itself becomes the control, so the value
  -- stays adjustable and the ◎ beside it keeps the match window reachable at
  -- every one-line width. Driven only by window size (via `geometry` above),
  -- never by selection or latch state — the SAME disabled-but-present control
  -- still draws whenever there's room, whether or not a sound is selected.
  if trim_shown then
    -- The target button (◎) rides with the trim control it drives: same
    -- collapse step, immediately to its left, in both shapes. Clicking it
    -- opens the match window (submitted at the end of this function).
    reaper.ImGui_SetCursorPos(ctx, row_x0 + g.target_x, row_y0 + g.ctrl_y)
    -- The ◎ is the walkthrough's finale target — noted from geometry, see the
    -- latch's note. (It used to be noted twice, for a second match stop that
    -- described the open panel while still ringing this button; that stop is
    -- gone — 2026-08-10, `.brief/walkthrough-footer/`.)
    local match_x, match_y = reaper.ImGui_GetCursorScreenPos(ctx)
    walkthrough_ui.note_rect(ctx, state.walkthrough, "match_open",
      match_x, match_y, match_x + ctrl, match_y + ctrl)
    matchwin.draw_button(ctx, state, res)

    reaper.ImGui_SetCursorPos(ctx, row_x0 + g.trim_x, row_y0 + g.ctrl_y)
    local sel = state.selected
    -- Both shapes ride the same set_trim action, the same taper and the same
    -- reset gesture — collapsing changes the control's shape, never its feel
    -- or its wiring (widgets.db_drag matches the fader's dB-per-pixel).
    local trim_opts = { min = match.TRIM_SILENCE, max = match.TRIM_MAX, default = 0,
      taper = true, width = g.trim_w }
    local draw_trim = trim_shown == "fader" and widgets.db_fader or widgets.db_drag
    if sel then
      trim_opts.tip = (trim_shown == "fader"
          and "Adjust the selected reference's remembered trim"
          or "Adjust the selected reference's remembered trim \u{00B7} drag up or down")
        .. RESET_HINT
      -- A real fader's shape since 2026-08-07: silence at the bottom, +24 at
      -- the top, steps growing as it goes down. No cut a match asks for can be
      -- out of its reach any more (core/match.lua owns both numbers).
      local db, commit = draw_trim(ctx, "trim", sel.trim_db, trim_opts)
      if db ~= nil then action = { type = "set_trim", db = db, commit = commit } end
    else
      trim_opts.tip = "Select a reference to adjust its trim."
      reaper.ImGui_BeginDisabled(ctx)
      draw_trim(ctx, "trim", 0, trim_opts)
      reaper.ImGui_EndDisabled(ctx)
    end
  end

  -- The Library button. It moved here from the retired reference row
  -- (2026-08-06) and never collapses: it is the only way to the browser. The
  -- References-folder square that used to sit in this slot became a Settings
  -- row (2026-08-10, `.brief/settings-move`).
  reaper.ImGui_SetCursorPos(ctx, row_x0 + g.library_x, row_y0 + g.ctrl_y)
  -- Walkthrough stop 1's target — and the frozen state's ring, since this is
  -- the button that reopens the Library. Geometry-noted (see the latch).
  local lib_x, lib_y = reaper.ImGui_GetCursorScreenPos(ctx)
  walkthrough_ui.note_rect(ctx, state.walkthrough, "library",
    lib_x, lib_y, lib_x + ctrl, lib_y + ctrl)
  if icons.button(ctx, font, "openlibrary", "library",
      { tip = "Open the Library.", fallback = icons.draw_folder }) then
    action = action or { type = "toggle_browser" }
  end

  -- Settings, the bar's corner (the user's pick over gear-beside-Library —
  -- same brief). Moved here from the browser toolbar so Settings is one click
  -- from the window that's on screen all day. The update notice comes with it:
  -- an ACCENT dot over the gear's corner, nothing else anywhere, persisting
  -- until the update actually installs (state.update.available goes nil then)
  -- — and it's now visible without the browser open, which the old placement
  -- never managed.
  reaper.ImGui_SetCursorPos(ctx, row_x0 + g.gear_x, row_y0 + g.ctrl_y)
  local update_due = state.update and state.update.available ~= nil
  if icons.button(ctx, font, "settings", "settings",
      { tip = update_due and "Settings. An update is available" or "Settings",
        fallback = icons.draw_gear }) then
    settings.open(state)
    -- Also reported as an action: the entry script refreshes the update
    -- feature's registry read, so the UPDATES section opens describing NOW
    -- (a pin set or cleared in ReaPack five minutes ago), not the last daily
    -- check. Losing this to an earlier same-frame action is harmless — the
    -- window still opens, just on day-old facts.
    action = action or { type = "settings_opened" }
  end
  if update_due then
    local max_x = reaper.ImGui_GetItemRectMax(ctx)
    local _, min_y = reaper.ImGui_GetItemRectMin(ctx)
    local r = M.UPDATE_DOT_R
    reaper.ImGui_DrawList_AddCircleFilled(reaper.ImGui_GetWindowDrawList(ctx),
      max_x - r - 2, min_y + r + 2, r, T.ACCENT)
  end

  -- Every item above was placed absolutely, so leave the cursor where a normal
  -- row would have left it — directly below the bar's full (possibly wrapped)
  -- height, so a caller that adds something after it needn't know about the
  -- wrapping.
  reaper.ImGui_SetCursorPos(ctx, row_x0, row_y0 + g.height)

  -- The popups LAST: submitted in this window's own scope (never inside a
  -- child), and after everything the bar draws, so they can never steal a
  -- click meant for a control beneath them.
  local popup_action = refpicker.draw_popup(ctx, state, res)
  action = action or popup_action
  local match_action = matchwin.draw_popup(ctx, state, res)
  action = action or match_action

  return action
end

return transport
