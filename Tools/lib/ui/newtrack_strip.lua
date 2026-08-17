-- newtrack_strip: the "New Track /" band that appears over REAPER's arrange
-- while a drag hovers the top slice of a track, saying the drop will make a new
-- track there. A ui/ module — reaper.ImGui_* only; the entry script hands it a
-- screen rectangle on `state.drag.newtrack` and this just paints it.
--
-- WHY WE PAINT THIS ONE, having refused to paint the waveform ghost. REAPER
-- draws its own version of this band, and there is no API to ask for it — the
-- full export lists were read (docs/RESEARCH.md). Every route where REAPER
-- would draw something instead takes up LAYOUT and therefore shoves the
-- timeline down as it appears, moving the target out from under the pointer: a
-- real temporary track was prototyped and failed on exactly that, and a track
-- spacer fails the same way. So it is paint it or show nothing, and the user
-- chose paint after seeing it (prototypes/proto_paint_strip.lua, 2026-08-08).
-- The waveform ghost is different and stays REAPER's own work: it goes INSIDE
-- an existing track, so it costs no layout at all.
--
-- HOW. Not js/LICE — that flickers on Windows and can be invisible entirely on
-- Macs with GPU acceleration on. This is a second ReaImGui window with no
-- decoration, no background and no inputs, parked over the arrange: a sheet of
-- glass we draw on and the mouse passes straight through. ReaImGui is already
-- a hard dependency, so it adds nothing to install.
--
-- Known and accepted: the colours are approximated from REAPER's default theme
-- rather than sampled, so a light theme will look wrong; and the band is one
-- frame behind the pointer. Both were shown to the user before this was built.

local newtrack_strip = {}

-- Resolved once at load, the house idiom. An older ReaImGui missing any one of
-- these would leave a grey box sitting over the timeline, so a missing flag
-- switches the whole thing off rather than degrading into a mess.
local FLAGS, OK = 0, true
for _, name in ipairs({ "NoDecoration", "NoMove", "NoBackground", "NoInputs",
                        "NoSavedSettings", "NoFocusOnAppearing", "NoNav" }) do
  local fn = reaper["ImGui_WindowFlags_" .. name]
  if fn then FLAGS = FLAGS | fn() else OK = false end
end
if reaper.ImGui_WindowFlags_NoDocking then
  FLAGS = FLAGS | reaper.ImGui_WindowFlags_NoDocking()
end

-- REAPER's own band, read off the user's screenshot: a dark strip with a
-- hairline top and bottom, filled with the label repeating across it. These are
-- deliberately NOT the app's own tokens — this thing lives inside REAPER's
-- window and has to look like REAPER, not like us.
local STRIP_BG   = 0x2B2B2BFF
local STRIP_EDGE = 0x151515FF
local STRIP_TEXT = 0x9E9E9EFF
local UNIT = "New Track / "

-- `zone` is { x, y, w, h } in SCREEN pixels, or nil for "nothing to show".
function newtrack_strip.draw(ctx, zone)
  if not OK or not zone then return end
  if zone.w < 1 or zone.h < 1 then return end

  reaper.ImGui_SetNextWindowPos(ctx, zone.x, zone.y, reaper.ImGui_Cond_Always())
  reaper.ImGui_SetNextWindowSize(ctx, zone.w, zone.h, reaper.ImGui_Cond_Always())
  if not reaper.ImGui_Begin(ctx, "##yb_newtrack_strip", nil, FLAGS) then return end

  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local x, y, w, h = zone.x, zone.y, zone.w, zone.h
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, STRIP_BG)
  reaper.ImGui_DrawList_AddLine(dl, x, y, x + w, y, STRIP_EDGE)
  reaper.ImGui_DrawList_AddLine(dl, x, y + h - 1, x + w, y + h - 1, STRIP_EDGE)

  -- Measured ONCE and then stepped — never measured per repetition (the band
  -- spans the whole arrange, so that would be a text measurement every few
  -- pixels, every frame of a drag).
  local uw, uh = reaper.ImGui_CalcTextSize(ctx, UNIT)
  if uw > 0 then
    local ty = y + (h - uh) * 0.5
    local tx = x + 4
    while tx < x + w do
      reaper.ImGui_DrawList_AddText(dl, tx, ty, STRIP_TEXT, UNIT)
      tx = tx + uw
    end
  end

  reaper.ImGui_End(ctx)
end

return newtrack_strip
