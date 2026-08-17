-- tips: the app's one tooltip. Every tip in the UI goes through here, so they
-- all wait the same beat before appearing (user's ask, 2026-08-07 — showing
-- instantly meant tips flashing up while the cursor merely crossed the bar).
--
-- Its own module rather than a function in widgets.lua because icons.lua needs
-- it too, and widgets.lua already requires icons — one more edge there would be
-- a cycle. Nothing requires this file back.
--
-- The wait is timed HERE rather than handed to ImGui's own hover delay flag:
-- most callers already know they are hovered (a row works it out once, for its
-- hover fill and its tip together), and asking ImGui again at tooltip time
-- would answer about whatever item was submitted LAST — which inside an
-- edit-mode row is a different control entirely.
--
-- A ui/ module: it may call reaper.ImGui_* only.

local tips = {}

tips.DELAY = 0.15 -- seconds of continuous hover before a tip appears

-- Both are needed to time anything; an older ReaImGui without them simply
-- shows tips the way it always did.
local HAS_CLOCK = reaper.ImGui_GetTime ~= nil and reaper.ImGui_GetFrameCount ~= nil

-- Identity defaults to the tooltip TEXT: moving onto a control that says
-- something else restarts the wait. A frame in which nobody calls this means the
-- cursor is over nothing, so the next hover starts from zero instead of
-- appearing instantly — that is what `frame` is for.
local key_now, since, last_frame = nil, 0, -2

-- `hovered` is the caller's own answer, not re-derived here. A nil or empty
-- text is normal (a control with nothing to say this frame) and does nothing,
-- including not disturbing anyone else's timer.
--
-- `key` is for a tip whose TEXT changes while the cursor stays on the same
-- thing — the waveform's time readout rewrites itself every pixel, and keyed on
-- its text it would restart the wait forever and never appear. Give those a
-- fixed key and the wait runs on the control, not on the words.
function tips.show(ctx, hovered, text, key)
  if not hovered or not text or text == "" then return end
  if not HAS_CLOCK then
    reaper.ImGui_SetTooltip(ctx, text)
    return
  end
  key = key or text
  local now, frame = reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx)
  if key ~= key_now or frame > last_frame + 1 then
    key_now, since = key, now
  end
  last_frame = frame
  if now - since >= tips.DELAY then reaper.ImGui_SetTooltip(ctx, text) end
end

return tips
