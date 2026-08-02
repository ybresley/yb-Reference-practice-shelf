-- 02_gate_check.lua — U4: prove that re-enabling with autoInstall=2 ("use global")
-- while the global "Install new packages when synchronizing" checkbox is OFF
-- syncs NOTHING - this documents why the real update code must pass 1, not 2.
--
-- Prereqs: dummy installed at 1.0; Claude has pushed the catalog listing 1.1;
--          the global checkbox is UNTICKED (README setup step 1);
--          ReaPack's Manage/Browse windows are CLOSED.
-- Expected: NO Progress window, NO Report, and after ~12s this prints "gate held".

local REPO_NAME = "yb_update_test"
local REPO_URL  = "https://raw.githubusercontent.com/ybresley/yb-reapack-test/main/index.xml"
local SCRIPT_REL = "Scripts/yb_update_test/Test/yb_dummy_package.lua"

local function say(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

-- One string capturing every GetEntryInfo return - position-proof change detection.
local function registry_snapshot()
  local ok, entry, err = pcall(reaper.ReaPack_GetOwner, reaper.GetResourcePath() .. "/" .. SCRIPT_REL)
  if not ok or not entry then return "no owner (" .. tostring(ok and err or entry) .. ")" end
  local r = {pcall(reaper.ReaPack_GetEntryInfo, entry)}
  pcall(reaper.ReaPack_FreeEntry, entry)
  if not r[1] then return "GetEntryInfo error: " .. tostring(r[2]) end
  local parts = {}
  for i = 2, #r do parts[#parts + 1] = tostring(r[i]) end
  return table.concat(parts, " | ")
end

local function addset(enable, auto)
  local ok, ret, err = pcall(reaper.ReaPack_AddSetRepository, REPO_NAME, REPO_URL, enable, auto)
  say(string.format("AddSetRepository(enable=%s, autoInstall=%d) -> ok=%s, ret=%s, err=%s",
    tostring(enable), auto, tostring(ok), tostring(ret), tostring(err)))
  return ok
end

local function process_queue()
  local ok, err = pcall(reaper.ReaPack_ProcessQueue, true)
  say("ProcessQueue(true) -> " .. (ok and "ok" or ("ERROR: " .. tostring(err))))
end

say("")
say("=== 02_gate_check (U4) ===")
if not (reaper.APIExists and reaper.APIExists("ReaPack_AddSetRepository")) then
  say("FAIL: ReaPack API not found")
  return
end

say("Reminder: the global 'Install new packages when synchronizing' checkbox must be OFF.")
local before = registry_snapshot()
say("registry before: " .. before)

addset(false, 2)
process_queue()
addset(true, 2)   -- the deliberate mistake this test documents: 2 falls back to the global (off)
process_queue()

say("Watching the registry for 12s - EXPECTED: no Progress window, no change...")
local t0, next_check = reaper.time_precise(), 0
local function poll()
  local now = reaper.time_precise()
  if now >= next_check then
    next_check = now + 1.0
    local snap = registry_snapshot()
    if snap ~= before then
      say("FINDING: the registry CHANGED - the gate did NOT hold. Report this + whatever windows appeared.")
      say("registry after: " .. snap)
      say("(Most likely cause: the global checkbox was actually ON. If so: untick it and tell Claude - the spare v1.3 stage covers redoing this.)")
      return
    end
  end
  if now - t0 > 12 then
    say("Gate held: 12s passed, registry unchanged, and you should have seen NO windows.")
    say("=== 02 done - report, then run 03 ===")
    return
  end
  reaper.defer(poll)
end
reaper.defer(poll)
