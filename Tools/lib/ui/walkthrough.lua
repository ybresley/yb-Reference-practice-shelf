-- walkthrough: the first-open tour's overlay (decided 2026-08-10,
-- `.brief/_done/walkthrough/` — every answer the user's own). Spotlight look:
-- each tool window gets a dark wash with the current stop's target left bright
-- inside an accent ring, and one titled card sits beside the target carrying
-- progress dots, Skip and one button. The wash is PAINT, not glass —
-- nothing is blocked, real actions advance the stops (core/walkthrough.lua owns
-- that state machine; this file only draws it and reports button presses).
--
-- A ui/ module: reaper.ImGui_* only. It never touches the library, never writes
-- the seen-mark — card presses leave as { type = "walkthrough", ev = ... }. Two
-- exceptions: a stop whose button DOES the deed it teaches emits that deed's own
-- action (`open_browser`), and the finale OPENS the match window itself on
-- arrival, the way the ◎ does — opening is view state, not an action
-- (matchwin.lua).
--
-- The card is its own little WINDOW rather than shapes on the host's draw list,
-- for one reason: its buttons must swallow their clicks. Hand-drawn buttons over
-- the waveform would click through to the seek handler underneath — a real
-- window on top receives the mouse the way any overlapping window does.

local wt    = require("core.walkthrough")
local theme = require("ui.theme")
local matchwin = require("ui.matchwin") -- the finale opens it, rings it, keeps clear of it
local T = theme.tokens
local M = theme.metrics

local walkthrough = {}

-- Feature detection, once at load (the house idiom). The card degrades in
-- steps: without TopMost it can slip behind a clicked window (rare, accepted on
-- old builds); without the core flag set it isn't drawn at all — a naked
-- titled window flashing up would look broken, worse than no card.
local CARD_FLAGS, CARD_OK = 0, true
for _, name in ipairs({ "NoTitleBar", "NoResize", "NoScrollbar", "NoCollapse",
                        "NoMove", "NoSavedSettings", "NoFocusOnAppearing", "NoNav",
                        "AlwaysAutoResize" }) do
  local fn = reaper["ImGui_WindowFlags_" .. name]
  if fn then CARD_FLAGS = CARD_FLAGS | fn() else CARD_OK = false end
end
if reaper.ImGui_WindowFlags_NoDocking then
  CARD_FLAGS = CARD_FLAGS | reaper.ImGui_WindowFlags_NoDocking()
end
-- TopMost is what keeps the card over the window it annotates even after that
-- window is clicked — which stop 1 explicitly asks the user to do.
if reaper.ImGui_WindowFlags_TopMost then
  CARD_FLAGS = CARD_FLAGS | reaper.ImGui_WindowFlags_TopMost()
end
local HAS_FG_LIST = reaper.ImGui_GetForegroundDrawList ~= nil

-- Whether a card can be drawn at all on this ReaImGui. The entry script asks
-- BEFORE starting the tour and writing the seen-mark: that mark is one-shot, so
-- starting a tour whose card can never appear would silently spend the user's
-- only first run on nothing (Codex, 2026-08-10). Every flag in the list above
-- is ancient, so this is a guard against a build nobody has rather than a
-- known case — but the failure it prevents is invisible and permanent.
function walkthrough.can_draw()
  return CARD_OK
end

-- Per-frame target geometry, keyed by stop id. Stamped with the frame count so
-- yesterday's rect can never place today's ring: a window that stopped drawing
-- (the browser mid-close) simply stops noting, and its entry goes stale.
local rects = {}
-- Host-window rects, recorded by wash() so card() can anchor and clamp without
-- being inside either window's Begin scope.
local hosts = {}
-- The stop position whose `auto` deed has already been carried out, so it fires
-- once on arrival and never again (see card()).
local auto_done = nil
-- Last frame's active flag. The tour ENDING is an edge, not a state: closing the
-- match window whenever the tour is inactive would make that window impossible
-- to open at all.
local was_active = false

-- The stop the ring and card belong to right now. While frozen the target is
-- the LIBRARY BUTTON — the card parks on the main window asking for a reopen,
-- and ringing the button that does it is the whole hint.
local function effective_target(ws)
  local cur = wt.current(ws)
  if not cur or cur == "welcome" then return nil, cur end
  if wt.is_frozen(ws) then return "library", cur end
  return cur.id, cur
end

-- Whether the current stop wants a rect under this id: as its ringed TARGET,
-- or as its CONTEXT — a second region kept bright without a ring (the sidebar
-- stop keeps the sound list visible so a category click visibly filters).
local function wants(ws, id)
  local target, cur = effective_target(ws)
  if target == id then return true end
  return type(cur) == "table" and not wt.is_frozen(ws) and cur.context == id
end

-- Record the LAST SUBMITTED ITEM as (part of) target `id`. Called by the
-- windows right after they submit the real control. Two notes for one id in
-- one frame UNION into one rect.
function walkthrough.note(ctx, ws, id)
  if not ws or not ws.active then return end
  if not wants(ws, id) then return end
  local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
  local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
  walkthrough.note_rect(ctx, ws, id, x1, y1, x2, y2)
end

-- Same, for a region that isn't one item (a child window, the drop area).
function walkthrough.note_rect(ctx, ws, id, x1, y1, x2, y2)
  if not ws or not ws.active then return end
  if not wants(ws, id) then return end
  local frame = reaper.ImGui_GetFrameCount(ctx)
  local r = rects[id]
  if r and r.frame == frame then
    r.x1, r.y1 = math.min(r.x1, x1), math.min(r.y1, y1)
    r.x2, r.y2 = math.max(r.x2, x2), math.max(r.y2, y2)
  else
    rects[id] = { frame = frame, x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
  end
end

-- Inflate a noted rect by the ring pad and clamp it INSIDE the window: a
-- target flush against an edge (the sidebar's left is the window's own left)
-- would otherwise push the ring outside the viewport, where the foreground
-- list clips it and the border simply vanishes (round 2 fix).
local function inflate_clamped(r, wx, wy, ww, wh)
  local p = M.WALK_RING_PAD
  return {
    x1 = math.max(r.x1 - p, wx + 1), y1 = math.max(r.y1 - p, wy + 1),
    x2 = math.min(r.x2 + p, wx + ww - 1), y2 = math.min(r.y2 + p, wy + wh - 1),
  }
end

-- The spotlight, drawn from INSIDE a window's Begin scope. Foreground draw
-- list, not the window's own: the browser is built of child windows, which
-- render over anything their parent painted — the wash has to land on top of
-- everything, hole and ring included. Also records the window's rect for the
-- card's anchoring below.
--
-- A stop may keep up to TWO regions bright: its ringed target, and an unringed
-- `context` region (the sidebar stop's sound list). The wash is therefore cut
-- band by band around however many holes this window carries, instead of the
-- fixed four-rects-around-one-hole shape.
function walkthrough.wash(ctx, ws, win)
  if not ws or not ws.active then return end
  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww, wh = reaper.ImGui_GetWindowSize(ctx)
  hosts[win] = { x = wx, y = wy, w = ww, h = wh,
    frame = reaper.ImGui_GetFrameCount(ctx) }
  if not HAS_FG_LIST then return end

  local dl = reaper.ImGui_GetForegroundDrawList(ctx)
  local frame = reaper.ImGui_GetFrameCount(ctx)
  local id, cur = effective_target(ws)
  local target_win = "main"
  if cur and cur ~= "welcome" and not wt.is_frozen(ws) then target_win = cur.window end

  local holes, ring = {}, nil
  if id and win == target_win then
    local r = rects[id]
    if r and r.frame == frame then
      ring = inflate_clamped(r, wx, wy, ww, wh)
      holes[#holes + 1] = ring
    end
    local ctx_id = type(cur) == "table" and cur ~= "welcome" and cur.context or nil
    if ctx_id then
      local c = rects[ctx_id]
      if c and c.frame == frame then
        holes[#holes + 1] = inflate_clamped(c, wx, wy, ww, wh)
      end
    end
  end

  if #holes == 0 then
    reaper.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + ww, wy + wh, T.WALK_DIM)
  else
    -- Horizontal bands at every hole edge; inside each band, fill the x-gaps
    -- between the holes that span it. Handles one or two holes identically,
    -- and holes never double-dim anything because fills never overlap.
    local ys = { wy, wy + wh }
    for i = 1, #holes do
      ys[#ys + 1] = holes[i].y1; ys[#ys + 1] = holes[i].y2
    end
    table.sort(ys)
    for i = 1, #ys - 1 do
      local y1, y2 = ys[i], ys[i + 1]
      if y2 > y1 and y1 >= wy and y2 <= wy + wh then
        local spanning = {}
        for j = 1, #holes do
          local h = holes[j]
          if h.y1 <= y1 and h.y2 >= y2 then spanning[#spanning + 1] = h end
        end
        table.sort(spanning, function(a, b) return a.x1 < b.x1 end)
        local x = wx
        for j = 1, #spanning do
          local h = spanning[j]
          if h.x1 > x then
            reaper.ImGui_DrawList_AddRectFilled(dl, x, y1, h.x1, y2, T.WALK_DIM)
          end
          x = math.max(x, h.x2)
        end
        if x < wx + ww then
          reaper.ImGui_DrawList_AddRectFilled(dl, x, y1, wx + ww, y2, T.WALK_DIM)
        end
      end
    end
    -- Only the TARGET wears the ring — a ringed context would make two
    -- subjects out of one stop.
    if ring then
      reaper.ImGui_DrawList_AddRect(dl, ring.x1, ring.y1, ring.x2, ring.y2,
        T.ACCENT, 5, 0, 1)
    end
  end
end

-- Where the card may stand. The card is a real WINDOW, so a card over the stop's
-- target doesn't merely hide it — it swallows the click, and a stop that asks
-- for that click can never be finished (user-reported 2026-08-10: stop 1's
-- Library button was unpressable on the short docked strip, where the old
-- "clamp into the host window" rule parked the card straight over the bar).
--
-- So: sides are TRIED, and the first one that fits whole is taken — every
-- candidate clears the ring by construction. Two passes (below): inside the host
-- window first, so a roomy window keeps the card in the tool; then the screen's
-- work area, since the card owns an OS window of its own and can stand beside a
-- strip it cannot fit inside.
local HAS_VIEWPORT = reaper.ImGui_GetMainViewport ~= nil
  and reaper.ImGui_Viewport_GetWorkPos ~= nil and reaper.ImGui_Viewport_GetWorkSize ~= nil

local SIDES = { "above", "below", "right", "left" }

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- The card's corner for one side of the ring: above/below hug the ring's right
-- edge, left/right its top.
local function side_pos(side, ring, cw, ch, gap)
  if side == "above" then return ring.x2 - cw, ring.y1 - ch - gap end
  if side == "below" then return ring.x2 - cw, ring.y2 + gap end
  if side == "left"  then return ring.x1 - cw - gap, ring.y1 end
  return ring.x2 + gap, ring.y1
end

-- First side of `ring` on which the card fits whole inside the given bounds, or
-- nil. A candidate slides only along the axis its side did NOT use (an "above"
-- card slides sideways, never downward), so sliding can't walk it onto the ring.
local function place_in(ring, cw, ch, bx, by, bw, bh)
  local gap, m = M.WALK_RING_PAD * 2, M.WINDOW_PAD
  local x0, y0 = bx + m, by + m
  local x1, y1 = bx + bw - m - cw, by + bh - m - ch
  if x1 < x0 or y1 < y0 then return nil end
  for _, side in ipairs(SIDES) do
    local x, y = side_pos(side, ring, cw, ch, gap)
    if side == "above" or side == "below" then x = clamp(x, x0, x1) else y = clamp(y, y0, y1) end
    if x >= x0 and x <= x1 and y >= y0 and y <= y1 then return x, y end
  end
  return nil
end

-- A text-styled control (the Skip link): an InvisibleButton with the words
-- painted over it, dim at rest and bright under the cursor. `h` makes the hit
-- area a full control height with the words centred in it — that is what
-- keeps the footer on ONE line with no cursor nudging (SameLine would undo
-- any nudge when the next control joins the line).
local function text_button(ctx, label, h)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
  h = h or th
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local clicked = reaper.ImGui_InvisibleButton(ctx, "##" .. label, tw, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddText(dl, x, y + (h - th) / 2,
    hovered and T.TEXT_SECONDARY or T.TEXT_TERTIARY, label)
  return clicked
end

-- The card's height, worked out BEFORE the window is submitted.
--
-- It used to be last frame's `GetWindowSize`, and that is what made a stop
-- change flicker (user-reported 2026-08-10, stepping off the pin stop, where
-- the card also crosses the window's edge): the card is POSITIONED before it is
-- drawn, so the new stop was placed with the old stop's height, and an
-- auto-resizing window only takes its new size the frame AFTER its content
-- changed — two frames of wrong geometry, seen as a jump. Measuring instead of
-- remembering makes the first frame correct and deletes the settle entirely.
--
-- Every line below mirrors one submitted by the drawing code, in the same font
-- and the same order, so the two can't drift: title, body, optional note, the
-- 2px spacer, the footer's control-height line, plus ItemSpacing between each
-- and the window's own padding around the lot.
local function measure_card(ctx, title, body, note)
  local pad = M.WALK_CARD_PAD
  local wrap = M.WALK_CARD_W - pad * 2
  local sp = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local hd = theme.push_heading_font(ctx)
  local h = select(2, reaper.ImGui_CalcTextSize(ctx, title))
  if hd then reaper.ImGui_PopFont(ctx) end
  -- CalcTextSize's two OUT slots are real Lua arguments, passed as nil — the
  -- wrap width is the SIXTH argument, not the fourth (verified 2026-08-11
  -- against ReaImGui's own author's scripts after this crashed live: the C
  -- signature reads `ctx, text, wOut, hOut, hide…, wrap…`, and the Lua binding
  -- keeps the out params in the list instead of dropping them).
  h = h + sp + select(2, reaper.ImGui_CalcTextSize(ctx, body, nil, nil, false, wrap))
  if note then
    h = h + sp + select(2, reaper.ImGui_CalcTextSize(ctx, note, nil, nil, false, wrap))
  end
  return h + sp + 2 + sp + reaper.ImGui_GetFrameHeight(ctx) + pad * 2
end

-- The card, drawn ONCE per frame at app level (outside both hosts' scopes —
-- it is its own window). Returns a { type = "walkthrough", ev = ... } action
-- or nil; the entry script runs the state machine.
function walkthrough.card(ctx, ws)
  -- The tour ending takes the match window with it, opened by the tour or by
  -- hand (user's ask, 2026-08-11). Checked before the active guard below,
  -- because "the tour just ended" is exactly the state that guard returns on,
  -- and on the EDGE only — acting on "inactive" every frame would slam the
  -- window shut the moment anyone opened it outside a tour. Skip and Done both
  -- land here.
  local active = (ws and ws.active) or false
  if was_active and not active then matchwin.close() end
  was_active = active
  if not active or not CARD_OK then
    auto_done = nil
    return nil
  end
  local cur = wt.current(ws)
  if not cur then return nil end

  local frozen = cur ~= "welcome" and wt.is_frozen(ws)
  local frame = reaper.ImGui_GetFrameCount(ctx)

  -- Anchor host: the target's window, except welcome and frozen, which both
  -- belong to the main window. A host that didn't draw this frame (browser
  -- mid-close) falls back to main; no host at all (main hidden) = no card.
  local host_key = "main"
  if cur ~= "welcome" and not frozen and cur.window == "browser" then host_key = "browser" end
  local host = hosts[host_key]
  if not (host and host.frame == frame) then host = hosts.main end
  if not (host and host.frame == frame) then return nil end

  local cw = M.WALK_CARD_W
  local margin = M.WINDOW_PAD

  -- This stop's copy, settled here so the measurement and the drawing below
  -- read from one place (a card measured from different words than it draws is
  -- the flicker again, wearing a different hat).
  local title = cur == "welcome" and wt.WELCOME.title or cur.title
  local body = cur == "welcome" and wt.WELCOME.body
    or (frozen and wt.FROZEN_BODY or cur.body)
  local note = (cur ~= "welcome" and not frozen) and cur.note or nil
  local card_h = measure_card(ctx, title, body, note)

  -- The screen's usable area: the card is allowed to leave the tool window (see
  -- the placement helpers above), so this — not the host rect — is the outer
  -- fence. Without the viewport calls the host window is the whole world, which
  -- is what the old rule assumed.
  local vx, vy, vw, vh = host.x, host.y, host.w, host.h
  if HAS_VIEWPORT then
    local vp = reaper.ImGui_GetMainViewport(ctx)
    local px, py = reaper.ImGui_Viewport_GetWorkPos(vp)
    local pw, ph = reaper.ImGui_Viewport_GetWorkSize(vp)
    -- UNION with the host window, never the work area alone: that area is one
    -- monitor's, and with REAPER on a second screen a bare clamp would fling the
    -- card onto the other one, chasing the user away from the thing it points at.
    vx, vy = math.min(vx, px), math.min(vy, py)
    vw = math.max(host.x + host.w, px + pw) - vx
    vh = math.max(host.y + host.h, py + ph) - vy
  end

  local r = cur ~= "welcome" and rects[frozen and "library" or cur.id] or nil
  if r and r.frame ~= frame then r = nil end

  -- The finale's second bright region: the match panel, a window of its own.
  -- Opened here the moment the stop is reached (`auto`) and asked for its rect
  -- so the card can keep clear of it as well as of the ring. Fired ONCE per
  -- arrival — reopening it every frame would take the user's ✕ away from them.
  if cur ~= "welcome" and not frozen and cur.auto == "open_match" then
    if auto_done ~= ws.pos then
      auto_done = ws.pos
      if not matchwin.is_open() then
        -- Anchored on the RING, not on the button inside it: the ring stands
        -- WALK_RING_PAD proud of the ◎ on every side, so anchoring to the
        -- button left the panel 4px in from the ring's left edge and covered
        -- the ring's top (user-reported 2026-08-11 — it read as a misaligned
        -- panel sitting on the button).
        local p = M.WALK_RING_PAD
        matchwin.open_at(r and (r.x1 - p) or nil, r and (r.y1 - p) or nil,
          r and (r.y2 + p) or nil)
      end
    end
  else
    auto_done = nil
  end

  local x, y
  if r then
    -- Beside its target — inside the host if it fits there, otherwise anywhere
    -- on screen that clears the ring. The pin stop needs no exception any more:
    -- its ring IS the whole main window, so nothing fits inside and the card
    -- steps out beside it, leaving the drop area it talks about fully visible.
    local ring = { x1 = r.x1 - M.WALK_RING_PAD, y1 = r.y1 - M.WALK_RING_PAD,
                   x2 = r.x2 + M.WALK_RING_PAD, y2 = r.y2 + M.WALK_RING_PAD }
    -- A panel stop keeps clear of BOTH: the box to avoid is the two together.
    -- They stand one above the other (the panel opens off the ◎), so the union
    -- is a tall column and the card simply takes a side of it.
    --
    -- While the panel is OPENING its rect doesn't exist yet — it is set when the
    -- panel first draws, which is the frame after the request. Drawing the card
    -- against the ring alone for that one frame put it exactly where the panel
    -- was about to appear, and it visibly hopped aside the moment it did
    -- (user-reported 2026-08-11). So: no card that frame. One frame without it
    -- is invisible; one frame in the wrong place is not.
    if cur.panel == "match" then
      local p = matchwin.rect()
      if not p then
        if matchwin.is_open() then return nil end
      else
        ring.x1, ring.y1 = math.min(ring.x1, p.x1), math.min(ring.y1, p.y1)
        ring.x2, ring.y2 = math.max(ring.x2, p.x2), math.max(ring.y2, p.y2)
      end
    end
    x, y = place_in(ring, cw, card_h, host.x, host.y, host.w, host.h)
    if not x then x, y = place_in(ring, cw, card_h, vx, vy, vw, vh) end
    if not x then
      -- Nowhere clears it (a tiny screen): below the target, on screen. Overlap
      -- is unavoidable here, and a reachable card beats a hidden one.
      x = clamp(ring.x2 - cw, vx + margin, vx + vw - margin - cw)
      y = clamp(ring.y2 + M.WALK_RING_PAD * 2, vy + margin, vy + vh - margin - card_h)
    end
  else
    -- The welcome card, and any stop whose target didn't draw this frame (a
    -- narrow dock clipped it): centred on the tool, kept on screen — the tour
    -- never silently disappears.
    x = clamp(host.x + (host.w - cw) / 2, vx + margin, vx + vw - margin - cw)
    y = clamp(host.y + (host.h - card_h) / 2, vy + margin, vy + vh - margin - card_h)
  end

  reaper.ImGui_SetNextWindowPos(ctx, x, y, reaper.ImGui_Cond_Always())
  if reaper.ImGui_SetNextWindowSizeConstraints ~= nil
    and reaper.ImGui_NumericLimits_Float ~= nil then
    local _, flt_max = reaper.ImGui_NumericLimits_Float()
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, cw, 0, cw, flt_max)
  end

  -- Popup dressing, popped the moment Begin has taken it (the Begin-time-push
  -- rule): held across the contents these would restyle the card's own
  -- tooltips too.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), T.BG_POPUP)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), T.STROKE_PRIMARY)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 1)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),
    M.WALK_CARD_PAD, M.WALK_CARD_PAD)
  local visible = reaper.ImGui_Begin(ctx, "##yb_walkthrough", nil, CARD_FLAGS)
  reaper.ImGui_PopStyleVar(ctx, 3)
  reaper.ImGui_PopStyleColor(ctx, 2)
  if not visible then return nil end

  local action

  -- Title: the section-heading grammar (caps, small size, bold, full white).
  local hd = theme.push_heading_font(ctx)
  reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, title)
  if hd then reaper.ImGui_PopFont(ctx) end

  -- Body, wrapped to the card. Frozen replaces the stop's own lesson with the
  -- one thing that matters right now: how to get it back.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_SECONDARY)
  reaper.ImGui_TextWrapped(ctx, body)
  reaper.ImGui_PopStyleColor(ctx)

  -- The dim aside line (the finale's replay pointer; the drop and pin stops'
  -- library-vs-project facts).
  if note then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_TERTIARY)
    reaper.ImGui_TextWrapped(ctx, note)
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_Dummy(ctx, 0, 2)

  -- Footer (rebuilt 2026-08-10, `.brief/walkthrough-footer/`): DOTS on the left
  -- — one per stop, the current one accent — then Skip and one button hugging
  -- the right edge. The dots replaced "3 of 7" (progress read at a glance, not
  -- arithmetic) and the two footer texts came up to body size; the old
  -- smallest-size counter and "Skip walkthrough" both read as fine print.
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local x0 = reaper.ImGui_GetCursorPosX(ctx)
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)

  -- EVERY stop has a button now, and on a stop that waits for a real click it
  -- performs that click's own deed (`act`) rather than jumping the stop — so it
  -- wears the deed's name. The tour is then walked on by the resulting real
  -- event, which is also what the user's own click would have produced.
  local btn_label, act
  if cur == "welcome" then btn_label = "Start"
  elseif frozen then btn_label, act = wt.FROZEN_BUTTON, wt.FROZEN_ACT
  else btn_label, act = cur.button, cur.act end

  local skip_label = cur == "welcome" and "Not Now" or "Skip"
  local skip_w = select(1, reaper.ImGui_CalcTextSize(ctx, skip_label))

  -- The dots, painted over a reserved block so the footer stays one normal
  -- line of layout. Never for the welcome card: no stop has been reached yet.
  if cur ~= "welcome" then
    local n = #wt.STOPS
    local step = M.WALK_DOT_R * 2 + M.WALK_DOT_GAP
    local dx, dy = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_Dummy(ctx, n * step - M.WALK_DOT_GAP, frame_h)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    for i = 1, n do
      reaper.ImGui_DrawList_AddCircleFilled(dl,
        dx + M.WALK_DOT_R + (i - 1) * step, dy + frame_h / 2, M.WALK_DOT_R,
        i == ws.pos and T.ACCENT or T.WALK_DOT)
    end
  end

  -- Skip sits just left of the button; both hug the card's right edge — but
  -- never left of the dots' own end (the 230px round-1 card ran the counter
  -- into the link; the clamp makes crowding degrade into touching, never into
  -- overprinting).
  local skip_x = x0 + avail - M.POPUP_BTN_W - M.ITEM_SPACING_X * 2 - skip_w
  if cur ~= "welcome" then
    reaper.ImGui_SameLine(ctx)
    local after_dots = reaper.ImGui_GetCursorPosX(ctx)
    if skip_x < after_dots then skip_x = after_dots end
  end
  reaper.ImGui_SameLine(ctx, skip_x)
  if text_button(ctx, skip_label, frame_h) then
    action = { type = "walkthrough", ev = "skip" }
  end

  reaper.ImGui_SameLine(ctx, x0 + avail - M.POPUP_BTN_W)
  if reaper.ImGui_Button(ctx, btn_label, M.POPUP_BTN_W) then
    -- A stop with a deed reports THAT and lets the deed's own event walk the
    -- tour on (the entry script owns the browser); every other stop just walks.
    action = act and { type = act } or { type = "walkthrough", ev = "next" }
  end

  reaper.ImGui_End(ctx)
  return action
end

return walkthrough
