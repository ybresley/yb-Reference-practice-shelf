-- yb_dummy_package.lua — throwaway ReaPack update-test dummy for the yb_Reference
-- update-feature prototype (HANDOFF.md items U0-U9). Nothing here ships; delete when done.
-- The window shows the version baked into THIS file next to what ReaPack's registry
-- says is installed — during U7 the file on disk updates while this keeps running old code.
local VERSION = "1.0"
local BG = {0.20, 0.20, 0.20}  -- 1.0 grey · 1.1 blue · 1.2 green · 1.3 red: instant visual version cue

local self_path = ({reaper.get_action_context()})[2]

-- Read our own installed version from ReaPack's registry — the exact pattern the real
-- update feature will use (GetOwner -> GetEntryInfo, version = 7th return -> FreeEntry).
local registry_line
if not (reaper.APIExists and reaper.APIExists("ReaPack_GetOwner")) then
  registry_line = "registry: ReaPack API not found"
else
  local ok, entry, err = pcall(reaper.ReaPack_GetOwner, self_path)
  if not ok then
    registry_line = "registry: GetOwner errored: " .. tostring(entry)
  elseif not entry then
    registry_line = "registry: no owner (" .. tostring(err) .. ")"
  else
    local r = {pcall(reaper.ReaPack_GetEntryInfo, entry)}
    if r[1] then
      registry_line = "registry says installed version: " .. tostring(r[8])
    else
      registry_line = "registry: GetEntryInfo errored: " .. tostring(r[2])
    end
    pcall(reaper.ReaPack_FreeEntry, entry)
  end
end

reaper.ShowConsoleMsg(("[dummy] FILE v%s | %s | path: %s\n"):format(VERSION, registry_line, self_path))

gfx.init("ReaPack dummy v" .. VERSION, 480, 200)
local function loop()
  gfx.set(BG[1], BG[2], BG[3])
  gfx.rect(0, 0, gfx.w, gfx.h, true)
  gfx.set(1, 1, 1)
  gfx.setfont(1, "Arial", 36)
  gfx.x, gfx.y = 18, 16
  gfx.drawstr("FILE version " .. VERSION)
  gfx.setfont(1, "Arial", 16)
  gfx.x, gfx.y = 18, 72
  gfx.drawstr(registry_line)
  gfx.x, gfx.y = 18, 104
  gfx.drawstr("U7: leave this open during the update - it must keep saying v" .. VERSION ..
              "\nuntil relaunched. Close: Esc or the window's X.")
  gfx.setfont(1, "Arial", 12)
  gfx.x, gfx.y = 18, 162
  gfx.drawstr("..." .. self_path:sub(-64))
  gfx.update()
  local c = gfx.getchar()
  if c ~= 27 and c >= 0 then reaper.defer(loop) end
end
loop()
