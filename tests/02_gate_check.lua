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
-- Returns nil on any read failure so a transient hiccup can't fake a "change".
local function registry_snapshot()
  local ok, entry, err = pcall(reaper.ReaPack_GetOwner, reaper.GetResourcePath() .. "/" .. SCRIPT_REL)
  if not ok or not entry then return nil, "no owner (" .. tostring(ok and err or entry) .. ")" end
  local r = {pcall(reaper.ReaPack_GetEntryInfo, entry)}
  pcall(reaper.ReaPack_FreeEntry, entry)
  if not r[1] then return nil, "GetEntryInfo error: " .. tostring(r[2]) end
  if r[2] == false or r[2] == 0 or r[2] == nil then
    return nil, "GetEntryInfo returned failure (retval = " .. tostring(r[2]) .. ")"
  end
  local parts = {}
  for i = 2, #r do parts[#parts + 1] = tostring(r[i]) end
  return table.concat(parts, " | ")
end

-- true only when the call ran AND the API itself didn't answer false/0/nil.
local function addset(enable, auto)
  local ok, ret, err = pcall(reaper.ReaPack_AddSetRepository, REPO_NAME, REPO_URL, enable, auto)
  say(string.format("AddSetRepository(enable=%s, autoInstall=%d) -> ok=%s, ret=%s, err=%s",
    tostring(enable), auto, tostring(ok), tostring(ret), tostring(err)))
  return ok and ret ~= false and ret ~= 0 and ret ~= nil
end

local function process_queue()
  local ok, err = pcall(reaper.ReaPack_ProcessQueue, true)
  say("ProcessQueue(true) -> " .. (ok and "ok" or ("ERROR: " .. tostring(err))))
  return ok
end

say("")
say("=== 02_gate_check (U4) ===")
if not (reaper.APIExists and reaper.APIExists("ReaPack_AddSetRepository")) then
  say("FAIL: ReaPack API not found")
  return
end

say("Reminder: the global 'Install new packages when synchronizing' checkbox must be OFF.")
local before, why = registry_snapshot()
if not before then
  say("ABORT: can't read the installed dummy (" .. tostring(why) .. ") - finish the README setup first.")
  return
end
say("registry before: " .. before)

if not addset(false, 2) then
  say("ABORT: the disable call FAILED (see the line above) - nothing was changed, so this test proves nothing. Report this.")
  return
end
if not process_queue() then
  say("ABORT: ProcessQueue failed after the disable - repo state uncertain. Run 04 to re-enable, and report this.")
  return
end
if not addset(true, 2) then   -- the deliberate mistake this test documents: 2 falls back to the global (off)
  say("ABORT: the re-enable call FAILED - the repo is likely left DISABLED. Run 04 to re-enable, and report this.")
  return
end
if not process_queue() then
  say("ABORT: ProcessQueue failed after the re-enable - repo state uncertain. Run 04, and report this.")
  return
end

say("Watching the registry for 12s - EXPECTED: no Progress window, no change...")
local t0, next_check = reaper.time_precise(), 0
local function poll()
  local now = reaper.time_precise()
  if now >= next_check then
    next_check = now + 1.0
    local snap = registry_snapshot()
    if snap and snap ~= before then
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
