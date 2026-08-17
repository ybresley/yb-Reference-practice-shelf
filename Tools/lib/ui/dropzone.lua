-- dropzone: the shared drag/drop visual treatment and reading — the dashed accent
-- outline + wash a hovered target draws, the hand/no-entry cursor swap, and
-- reading an OS file drop or an internal sound drag off "the last item". Used by
-- both the working view's reference row (ui/window.lua) and the browser's
-- sidebar/list (ui/browser.lua), so the treatment can't drift between the two
-- windows. A ui/ module: it may call reaper.ImGui_* only.

local theme = require("ui.theme")
local T = theme.tokens

local dropzone = {}

-- The drop-target treatment while a file drag hovers it: dashed accent outline +
-- accent wash, and — for a big area — a centred pill naming where the files will
-- be filed. No "+" glyphs (user's call, 2026-07-27 mockup review). Pure overlay
-- drawing on the already-laid-out item rect, so nothing shifts.
local function dashed_rect(dl, x0, y0, x1, y1, col)
  local dash, gap, th = 5, 4, 1.5
  local x = x0
  while x < x1 do
    local xe = math.min(x + dash, x1)
    reaper.ImGui_DrawList_AddLine(dl, x, y0, xe, y0, col, th)
    reaper.ImGui_DrawList_AddLine(dl, x, y1, xe, y1, col, th)
    x = x + dash + gap
  end
  local y = y0
  while y < y1 do
    local ye = math.min(y + dash, y1)
    reaper.ImGui_DrawList_AddLine(dl, x0, y, x0, ye, col, th)
    reaper.ImGui_DrawList_AddLine(dl, x1, y, x1, ye, col, th)
    y = y + dash + gap
  end
end

-- The treatment on an explicit rect. The foreground list draws over the
-- target's own content (rows, child background) rather than under it. It
-- ignores window clipping, so the rect is CLAMPED by hand to the current
-- window's visible bounds — that both stops a half-scrolled row painting past
-- the window's edge and keeps every side of the outline on screen (an item rect
-- that reaches the window edge was losing its right border to clipping).
function dropzone.draw_drop_rect(ctx, x0, y0, x1, y1, label)
  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww, wh = reaper.ImGui_GetWindowSize(ctx)
  x0, y0 = math.max(x0 + 1, wx + 2), math.max(y0 + 1, wy + 2)
  x1, y1 = math.min(x1 - 1, wx + ww - 2), math.min(y1 - 1, wy + wh - 2)
  if x1 <= x0 or y1 <= y0 then return end
  local dl = reaper.ImGui_GetForegroundDrawList(ctx)
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, T.ACCENT_WASH, 4)
  dashed_rect(dl, x0, y0, x1, y1, T.ACCENT)
  if label then
    -- "Add to Whooshes" — the filing destination, named before the drop lands.
    -- Skipped when the target is too small to host it (a tiny docked strip).
    local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
    if (x1 - x0) > tw + 48 and (y1 - y0) > th + 48 then
      local cx, cy = (x0 + x1) * 0.5, (y0 + y1) * 0.5
      local px, py = 12, 4
      reaper.ImGui_DrawList_AddRectFilled(dl, cx - tw * 0.5 - px, cy - th * 0.5 - py,
        cx + tw * 0.5 + px, cy + th * 0.5 + py, T.BG_POPUP, 999)
      reaper.ImGui_DrawList_AddRect(dl, cx - tw * 0.5 - px, cy - th * 0.5 - py,
        cx + tw * 0.5 + px, cy + th * 0.5 + py, T.STROKE_SECONDARY, 999)
      reaper.ImGui_DrawList_AddText(dl, cx - tw * 0.5, cy - th * 0.5, T.TEXT_PRIMARY, label)
    end
  end
end

-- The treatment on the LAST ITEM's rect.
function dropzone.draw_drop_zone(ctx, label)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  dropzone.draw_drop_rect(ctx, x0, y0, x1, y1, label)
end

-- Did a valid in-window target light up this frame? Every internal target that
-- offers the hand goes through show_hand_cursor below, so this one flag covers
-- all of them.
--
-- It has to travel all the way back out to the entry script, which is why it's
-- here rather than staying inside ui/: while a drag is live, the entry script
-- asserts REAPER's OWN cursor once per frame (reaper_api.show_drag_cursor), and
-- an OS-level cursor beats anything ImGui sets. That call only knew about the
-- arrange view, so it painted the no-entry circle over our own windows —
-- including targets that accept the drop perfectly well (user-reported
-- 2026-08-07). ui/app hands this to the entry script alongside the frame's
-- action; the same answer also stops the drag tag claiming "anywhere else
-- cancels" while hovering somewhere that doesn't.
local hand_shown = false

-- Read and clear, once per frame.
function dropzone.take_hand_shown()
  local v = hand_shown
  hand_shown = false
  return v
end

-- Over a valid in-window target the honest cursor is the hand, not the
-- window-wide no-entry (this call wins over ImGui's: it runs after app.frame's).
function dropzone.show_hand_cursor(ctx)
  hand_shown = true
  if reaper.ImGui_MouseCursor_Hand ~= nil then
    reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
  end
end

-- Internal drag: a sound being pulled from the table (or a reference tab) can
-- land on a target in EITHER window — both share one ImGui context, and ImGui's
-- hover/active-item bookkeeping isn't scoped per window, so this works the same
-- whether the drag started in the working view or the browser (unverified in
-- REAPER until manually checked — see HANDOFF). sound_drop_state reads the LAST
-- ITEM's part in that without drawing: (hovered, released this frame).
-- sound_drop_target is the whole deal for a self-contained row — treatment +
-- hand cursor — returning nil when not hovered, false while hovering, true on
-- the release that drops here.
local HAS_HOVER_BLOCKED = reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem ~= nil
function dropzone.sound_drop_state(ctx, state)
  -- The drag's source row is ImGui's "active item", which normally suppresses
  -- hover everywhere else — this flag is what makes other rows hoverable
  -- mid-drag. Without it (ancient build) rows just aren't internal targets.
  if not state.drag or not HAS_HOVER_BLOCKED then return false, false end
  if not reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem()) then
    return false, false
  end
  return true, reaper.ImGui_IsMouseReleased(ctx, 0)
end

function dropzone.sound_drop_target(ctx, state)
  local hovered, released = dropzone.sound_drop_state(ctx, state)
  if not hovered then return nil end
  dropzone.draw_drop_zone(ctx)
  dropzone.show_hand_cursor(ctx)
  return released
end

-- Whether this ReaImGui can suppress ImGui's own yellow target rectangle (ours
-- replaces it). Without the flag, both show — harmless, just doubled.
local HAS_NO_RECT = reaper.ImGui_DragDropFlags_AcceptNoDrawDefaultRect ~= nil

-- Read the files from an OS drop over the last-drawn item. Returns (action or
-- nil, hovered) — `hovered` is true whenever a files drag is over the item this
-- frame, so a caller drawing a multi-row zone knows without any treatment being
-- drawn here. Guarded by the drop capability so an older ReaImGui (no file-drop
-- calls) just relies on the Add-sounds picker.
-- opts: category/subcategory (where an import files), label (the destination
-- pill), no_draw (caller draws the zone), action_type (defaults to "import" —
-- the working view asks for "import_and_pin" instead, one motion).
--
-- Peeking "is an OS files drag in flight?" MUST use GetDragDropPayloadFile,
-- never GetDragDropPayload: the latter filters out ReaImGui's internal FILES
-- payload by design (api/dragndrop.cpp `isUserType`, verified 2026-08-01) and
-- so returns false for the whole of every OS file drag — a gate built on it
-- never opens, which is why no rect target ever lit up. GetDragDropPayloadFile
-- checks the FILES payload directly; index 0 exists whenever files are in
-- flight, and it returns false during script-made payload drags.
local HAS_PAYLOAD_PEEK = reaper.ImGui_GetDragDropPayloadFile ~= nil
local function files_payload_in_flight(ctx)
  return (reaper.ImGui_GetDragDropPayloadFile(ctx, 0)) == true
end

-- A file-drop target over an explicit rect — for a zone bigger than any one
-- item (the whole working view, the browser's list area; Codex, 2026-07-28:
-- per-item targets left the blank space between them silently dropping the
-- drop). An InvisibleButton is the standard ImGui idiom for "make this whole
-- area a drag-drop target" — waveform.draw uses the same call for its own hit
-- test. Drawn, then the cursor is put straight back where it was, so the
-- target never reserves layout space or shifts anything after it.
--
-- Submitted ONLY while a files payload is actually in flight (peeked with
-- GetDragDropPayload, feature-detected). This isn't an optimisation: ImGui
-- gives hover to the FIRST item that claims it each frame, so an area-sized
-- InvisibleButton submitted during an ordinary frame would swallow every click
-- meant for the controls beneath it. During a payload drag nothing is being
-- clicked, and drop DELIVERY resolves by smallest hovered target rect — so a
-- smaller target inside the rect (a sidebar row) still wins the actual drop.
-- Internal row drags never use ImGui payloads in this tool (they're
-- hand-rolled off IsItemActive), so any live payload means an OS files drag.
function dropzone.file_drop_over_rect(ctx, state, x0, y0, x1, y1, opts)
  if not state.deps.imgui_drop or not HAS_PAYLOAD_PEEK then return nil end
  if state.drag then return nil end
  if not files_payload_in_flight(ctx) then return nil end
  local w, h = x1 - x0, y1 - y0
  if w < 1 or h < 1 then return nil end
  local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, x0, y0)
  reaper.ImGui_InvisibleButton(ctx, "##file_drop_rect", w, h)
  local action = dropzone.read_file_drop(ctx, state, opts)
  reaper.ImGui_SetCursorScreenPos(ctx, cx, cy)
  return action
end

function dropzone.read_file_drop(ctx, state, opts)
  opts = opts or {}
  if not state.deps.imgui_drop then return nil, false end
  if not reaper.ImGui_BeginDragDropTarget(ctx) then return nil, false end
  if not opts.no_draw then dropzone.draw_drop_zone(ctx, opts.label) end
  local action
  -- The binding's second slot is the count OUT-placeholder — the flags ride in
  -- the THIRD slot (verified against the ReaImGui source; putting them second
  -- would silently pass default flags and keep the yellow rect).
  local ok, count = reaper.ImGui_AcceptDragDropPayloadFiles(ctx, nil,
    HAS_NO_RECT and reaper.ImGui_DragDropFlags_AcceptNoDrawDefaultRect() or nil)
  if ok and count then
    local paths = {}
    for i = 0, count - 1 do
      local got, fn = reaper.ImGui_GetDragDropPayloadFile(ctx, i)
      if got and fn then paths[#paths + 1] = fn end
    end
    if #paths > 0 then
      action = { type = opts.action_type or "import", paths = paths,
        category = opts.category, subcategory = opts.subcategory }
    end
  end
  reaper.ImGui_EndDragDropTarget(ctx)
  return action, true
end

return dropzone
