-- 09_pin_probe.lua — U15 diagnostic: does ReaPack's registry actually say the
-- installed yb_Reference is PINNED right now? Splits the failed pin test in
-- two: flags=1 means the pin took and the tool's Settings page is at fault
-- (report that — it's a real bug); flags=0 means the pin never registered —
-- ReaPack's browser stages changes until OK/Apply, so pin again and APPLY.

local SCRIPT_REL = "Scripts/yb_update_test/Tools/yb_Reference.lua"

local function say(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

say("")
say("=== 09_pin_probe (U15 diagnostic) ===")
if not (reaper.APIExists and reaper.APIExists("ReaPack_GetOwner")) then
  say("FAIL: ReaPack API not found")
  return
end

local abs = reaper.GetResourcePath() .. "/" .. SCRIPT_REL
local ok, entry, err = pcall(reaper.ReaPack_GetOwner, abs)
if not ok or not entry then
  say("no registry owner for " .. abs)
  say("(err = " .. tostring(ok and err or entry) .. ") - is the installed copy really at that path?")
  return
end

local r = { pcall(reaper.ReaPack_GetEntryInfo, entry) }
pcall(reaper.ReaPack_FreeEntry, entry)
if not r[1] or not r[2] then
  say("GetEntryInfo failed: " .. tostring(r[2]))
  return
end

say("installed version (return #7): " .. tostring(r[8]))
say("flags field      (return #9): " .. tostring(r[10]))
say("")
if type(r[10]) == "number" and r[10] ~= 0 then
  say("-> ReaPack REALLY HAS IT PINNED. If Settings (closed + reopened via the")
  say("   gear) still shows an Update button instead of the paused lines,")
  say("   that is a BUG in the tool - report exactly that.")
else
  say("-> NOT pinned in the registry. The browser stages changes until OK/Apply -")
  say("   pin again, hit Apply, rerun this probe.")
end
say("=== 09 done ===")
