-- focus: decides, once per frame, whether keyboard focus should be handed back
-- to REAPER — so the user's REAPER hotkeys keep working after they click around
-- the tool (2026-08-08, user's ask). The tool never keeps OS focus for itself
-- except where the keyboard is genuinely in use HERE:
--
--   * a text field is mid-edit (the search box, a rename popup) — covered by
--     "any item still active",
--   * a popup/menu/modal is open — losing OS focus snaps popups shut (upstream
--     Dear ImGui behaviour, see docs/RESEARCH.md "Keyboard focus"), so a frame
--     with one up never hands focus away,
--   * the click landed in a browsing pane (the browser's sidebar or sound
--     list), where the arrow keys step the selection — those panes register
--     themselves as keep-zones each frame.
--
-- This module only DECIDES; the entry script performs the handoff via
-- reaper_api.focus_arrange() (a ui/ module may not call reaper.* beyond ImGui).
--
-- Why reactive — a just-finished click on us — and never continuous: an idle
-- "always refocus REAPER" loop steals focus from plugin windows and other
-- scripts, a documented failure of exactly that design in other REAPER tools
-- (docs/RESEARCH.md). A release only counts when its PRESS landed on one of our
-- windows: at that moment the click had already given us focus, so handing it
-- to REAPER takes nothing from anyone else. A press that lands on REAPER (for
-- example clicking out of our search box into a track name being renamed) must
-- never make us yank focus around — the user put it where they want it.
--
-- WHY THE HANDOFF IS DELAYED A FRAME (2026-08-08, user-reported live): ImGui
-- moves OS focus of its own accord at the END of a frame, after this module
-- has already decided — a closing popup (the reference picker is one, and its
-- popups are real OS windows here) hands focus back to its parent window, and
-- a newly appearing window (the match window) claims focus outright. A
-- same-frame handoff lost to both every time. So a passed verdict fires on the
-- NEXT frame instead — after ImGui's own focus moves have landed — and a short
-- BOUNCE WATCH after each fire re-fires once if one of our windows snatches
-- focus back with no new user interaction. That watch is what keeps the match
-- window from holding focus while it stands open (the user's ask: popups must
-- not cost REAPER its keyboard).

local focus = {}

-- The whole feature stands down on a ReaImGui too old to answer the questions
-- it depends on. Popup detection is non-negotiable: without it a focus handoff
-- could close an open menu, which is worse than the feature not existing.
local ENABLED = reaper.ImGui_IsWindowHovered ~= nil
  and reaper.ImGui_HoveredFlags_AnyWindow ~= nil
  and reaper.ImGui_IsPopupOpen ~= nil
  and reaper.ImGui_PopupFlags_AnyPopupId ~= nil
  and reaper.ImGui_PopupFlags_AnyPopupLevel ~= nil
  and reaper.ImGui_IsAnyItemActive ~= nil
  and reaper.ImGui_IsWindowFocused ~= nil
  and reaper.ImGui_FocusedFlags_AnyWindow ~= nil

-- Which mouse buttons' current press started on one of our windows (any ImGui
-- window — popups and the match window included). Indexed by button; nil once
-- the release has been consumed.
local pressed_on_us = {}

-- Keep-zones registered for THIS frame (screen rects). A release inside one
-- keeps focus here — the zone's pane wants the arrow keys afterwards.
local zones, zone_n = {}, 0

-- A one-shot "hand focus back now" request from ui code for non-click paths
-- (Esc closing the browser or the match window). Still subject to the same
-- popup/active-item safety checks at frame end.
local want_request = false

-- The delayed fire and its aftermath (see the header): `fire_delay` counts
-- frames until a passed verdict is acted on; `watch` counts frames of
-- bounce-watching after a fire. `was_popup_open` spots popups closed by the
-- KEYBOARD (Esc, Enter committing a rename), which have no release to arm on.
local fire_delay = nil
local watch = 0
local was_popup_open = false
local WATCH_FRAMES = 5

-- KEY FORWARDING (2026-08-08, round 3 — user: "spacebar isn't working when
-- I'm browsing the asset list", "the pin selector dropdown steals focus").
-- The states where the tool deliberately HOLDS focus (browsing panes, an open
-- dropdown/popup) must still cost the user nothing: every key the tool does
-- not use itself is handed to REAPER's shortcut system, resolved and run by
-- SWS CF_SendActionShortcut (reaper_api.send_key_to_main) — no OS focus
-- involved, so Space plays the project mid-browse. What is NOT forwarded:
--   * anything while a text field is active — typed letters are typing,
--   * the arrows — the browser's own browsing keys,
--   * Esc / Enter / Tab — the UI's popup-and-field keys,
--   * Delete / Backspace — forwarding those would let a stray press while
--     browsing OUR list delete items in the user's PROJECT, a destructive
--     surprise nothing can undo being worth (they simply do nothing here).
-- Modifiers ride along physically (send_key_to_main reads the live keyboard),
-- so Ctrl+Z forwarded as Z undoes in REAPER, exactly as bound.
--
-- The map is built once at load: each ImGui key constant that this ReaImGui
-- knows, paired with its Windows virtual-key code. Missing constants are
-- simply skipped (the house degrade rule).
local FWD = {}
local function fwd_key(name, vk)
  local ctor = reaper["ImGui_Key_" .. name]
  if ctor ~= nil then FWD[#FWD + 1] = { key = ctor(), vk = vk } end
end
do
  fwd_key("Space", 0x20)
  for i = 0, 25 do fwd_key(string.char(65 + i), 0x41 + i) end   -- A..Z
  for i = 0, 9 do fwd_key(tostring(i), 0x30 + i) end            -- 0..9
  for i = 1, 12 do fwd_key("F" .. i, 0x6F + i) end              -- F1..F12
  for i = 0, 9 do fwd_key("Keypad" .. i, 0x60 + i) end          -- numpad 0..9
  fwd_key("KeypadAdd", 0x6B); fwd_key("KeypadSubtract", 0x6D)
  fwd_key("KeypadMultiply", 0x6A); fwd_key("KeypadDivide", 0x6F)
  fwd_key("KeypadDecimal", 0x6E)
  fwd_key("Home", 0x24); fwd_key("End", 0x23)
  fwd_key("PageUp", 0x21); fwd_key("PageDown", 0x22)
  fwd_key("Comma", 0xBC); fwd_key("Period", 0xBE); fwd_key("Slash", 0xBF)
  fwd_key("Semicolon", 0xBA); fwd_key("Apostrophe", 0xDE)
  fwd_key("LeftBracket", 0xDB); fwd_key("RightBracket", 0xDD)
  fwd_key("Backslash", 0xDC); fwd_key("Minus", 0xBD); fwd_key("Equal", 0xBB)
  fwd_key("GraveAccent", 0xC0)
end

function focus.frame_begin(ctx)
  zone_n = 0
  if not ENABLED then return end
  local any = reaper.ImGui_HoveredFlags_AnyWindow()
  for b = 0, 2 do
    if reaper.ImGui_IsMouseClicked(ctx, b) then
      pressed_on_us[b] = reaper.ImGui_IsWindowHovered(ctx, any)
      -- A fresh press on us is the user interacting again: whatever the last
      -- fire was watching for is stale — this press's own release decides next.
      if pressed_on_us[b] then watch = 0 end
    end
  end
end

-- Register a screen rect whose clicks keep focus (called during draw, cleared
-- every frame). Overlapping or duplicate rects are fine.
function focus.keep_zone(x0, y0, x1, y1)
  zone_n = zone_n + 1
  zones[zone_n] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

function focus.request()
  want_request = true
end

local function in_keep_zone(mx, my)
  for i = 1, zone_n do
    local z = zones[i]
    if mx >= z.x0 and mx < z.x1 and my >= z.y0 and my < z.y1 then return true end
  end
  return false
end

-- The safety checks every fire must pass at the moment it happens: no button
-- mid-gesture, no popup that focus loss would close, no text field keeping its
-- cursor. Checked both when a verdict is armed AND again when it fires a frame
-- later — the world can change in between.
local function conditions_ok(ctx)
  for b = 0, 2 do
    if reaper.ImGui_IsMouseDown(ctx, b) then return false end
  end
  if reaper.ImGui_IsPopupOpen(ctx, "",
      reaper.ImGui_PopupFlags_AnyPopupId() | reaper.ImGui_PopupFlags_AnyPopupLevel()) then
    return false
  end
  if reaper.ImGui_IsAnyItemActive(ctx) then return false end
  return true
end

-- Called after every window has drawn. Returns two things for the entry
-- script: whether to hand keyboard focus back to REAPER this frame, and the
-- list of key presses (Windows VK codes) to forward to REAPER's shortcut
-- system — nil on the overwhelming majority of frames.
function focus.frame_end(ctx)
  if not ENABLED then want_request = false; return false, nil end

  -- A release whose press was ours ends that press either way — consumed here
  -- so a refused frame (popup open, text field active) can't fire later on a
  -- release that already happened.
  local released = false
  for b = 0, 2 do
    if reaper.ImGui_IsMouseReleased(ctx, b) then
      if pressed_on_us[b] then released = true end
      pressed_on_us[b] = nil
    end
  end
  local requested = want_request
  want_request = false

  local popup_now = reaper.ImGui_IsPopupOpen(ctx, "",
    reaper.ImGui_PopupFlags_AnyPopupId() | reaper.ImGui_PopupFlags_AnyPopupLevel())

  -- 1) A fire armed last frame comes due — re-validated, since a popup may
  -- have opened or a field grabbed the keyboard in the meantime (then it is
  -- dropped, not retried; the next interaction re-arms).
  local fire = false
  if fire_delay then
    fire_delay = fire_delay - 1
    if fire_delay <= 0 then
      fire_delay = nil
      if conditions_ok(ctx) then
        fire = true
        watch = WATCH_FRAMES
      end
    end
  end

  -- 2) This frame's own verdict arms a fire for the NEXT frame (see header).
  if released or requested then
    local keep = false
    if released and not requested then
      -- Clicks in a browsing pane keep focus so the arrow keys work there.
      -- Only a real release has a position to test; an explicit request (Esc
      -- paths) already knows what it wants.
      local mx, my = reaper.ImGui_GetMousePos(ctx)
      keep = in_keep_zone(mx, my)
    end
    if not keep and conditions_ok(ctx) then
      fire_delay = 1
      watch = 0 -- superseded: this verdict's own fire brings a fresh watch
    end
  end

  -- 3) A popup that closed with NO release and NO request was closed by the
  -- keyboard (Esc, Enter committing a rename). ImGui hands focus back to the
  -- popup's parent — one of our windows — which would strand the keyboard
  -- here until the next click. Hand it on, unless the mouse sits over a
  -- browsing pane (a row menu dismissed mid-browse should keep the arrows).
  if was_popup_open and not popup_now and not released and not requested
    and not fire_delay and not fire then
    if conditions_ok(ctx)
      and reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_AnyWindow()) then
      local mx, my = reaper.ImGui_GetMousePos(ctx)
      if not in_keep_zone(mx, my) then fire_delay = 1 end
    end
  end
  was_popup_open = popup_now

  -- 4) The bounce watch: for a few frames after each fire, if one of our
  -- windows regains focus with no new press (ImGui restoring a closed popup's
  -- parent, a newly appeared window claiming focus), fire once more. A real
  -- user click on us cancels the watch in frame_begin instead.
  if not fire and not fire_delay and watch > 0 then
    watch = watch - 1
    if reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_AnyWindow())
      and conditions_ok(ctx) then
      fire = true
      watch = 0
    end
  end

  -- 5) Key forwarding (see FWD above): only while one of our windows actually
  -- holds focus — otherwise REAPER is hearing the keyboard itself and a
  -- forward would run the action TWICE — and never while a text field is
  -- active (typed letters are typing, not hotkeys).
  local keys
  if not reaper.ImGui_IsAnyItemActive(ctx)
    and reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_AnyWindow()) then
    for i = 1, #FWD do
      if reaper.ImGui_IsKeyPressed(ctx, FWD[i].key, true) then
        keys = keys or {}
        keys[#keys + 1] = FWD[i].vk
      end
    end
  end

  return fire, keys
end

return focus
