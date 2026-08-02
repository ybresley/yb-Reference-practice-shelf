-- 03_update_trick.lua — U3 (and reused for U7): the single-repo sync trick.
--   disable -> ProcessQueue -> enable with autoInstall=1 -> ProcessQueue
-- Expected: ReaPack's Progress window appears, the Report lists ONLY this dummy's
-- update (no other repo touched), and the poll below prints the registry change
-- within ~90s. Leaves the repo at autoInstall=1 - run 04 afterwards to restore.
--
-- Prereqs: a newer version is in the pushed catalog (Claude confirms before you run);
--          ReaPack's Manage/Browse windows are CLOSED.
-- U7 reuse: launch the dummy FIRST and leave its window open - it must keep showing
-- the old version while the Report says the new one installed; relaunch shows the new.

local REPO_NAME = "yb_update_test"
local REPO_URL  = "https://raw.githubusercontent.com/ybresley/yb-reapack-test/main/index.xml"
local SCRIPT_REL = "Scripts/yb_update_test/Test/yb_dummy_package.lua"

local function say(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

local function registry_snapshot()
  local ok, entry, err = pcall(reaper.ReaPack_GetOwner, reaper.GetResourcePath() .. "/" .. SCRIPT_REL)
  if not ok or not entry then return nil, "no owner (" .. tostring(ok and err or entry) .. ")" end
  local r = {pcall(reaper.ReaPack_GetEntryInfo, entry)}
  pcall(reaper.ReaPack_FreeEntry, entry)
  if not r[1] then return nil, "GetEntryInfo error: " .. tostring(r[2]) end
  local parts = {}
  for i = 2, #r do parts[#parts + 1] = tostring(r[i]) end
  -- r[8] is the version if the reconstruction (7th return) is right; snapshot works either way
  return table.concat(parts, " | "), nil, tostring(r[8])
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
say("=== 03_update_trick (U3 / U7) ===")
if not (reaper.APIExists and reaper.APIExists("ReaPack_AddSetRepository")) then
  say("FAIL: ReaPack API not found")
  return
end

local before, why, before_ver = registry_snapshot()
if not before then
  say("ABORT: can't read the installed dummy (" .. tostring(why) .. ") - finish the README setup first.")
  return
end
say("registry before: " .. before)

-- The trick. Both halves run in the same defer frame, like the real feature will:
-- the repo is genuinely disabled between the two calls (that's U9's crash window).
addset(false, 2)
process_queue()
addset(true, 1)   -- MUST be 1: 2 falls back to the global checkbox and the gate fails (U4)
process_queue()

say("WATCH NOW: a ReaPack Progress window should appear, then a Report window.")
say("The Report must list ONLY this dummy - check nothing from any other repo moved.")
say("Polling the registry (up to 90s)...")

local t0, next_check = reaper.time_precise(), 0
local function poll()
  local now = reaper.time_precise()
  if now >= next_check then
    next_check = now + 0.5
    local snap, _, ver = registry_snapshot()
    if snap and snap ~= before then
      say(string.format("REGISTRY CHANGED after %.1fs:", now - t0))
      say("  before: " .. before)
      say("  after:  " .. snap)
      local okc, cmp = pcall(reaper.ReaPack_CompareVersions, tostring(ver), tostring(before_ver))
      say(string.format("  CompareVersions(new, old) = %s (positive = a real upgrade)", tostring(okc and cmp or "ERROR")))
      say("NOTE: the repo is still at autoInstall=1 - run 04 to restore it to 'use global'.")
      say("=== 03 done - report what the Progress/Report windows showed ===")
      return
    end
  end
  if now - t0 > 90 then
    say("TIMED OUT: 90s passed and the registry never changed.")
    say("Report whether a Progress/Report appeared at all and what the Report said.")
    say("(The repo may now be at autoInstall=1 - run 04 to restore it either way.)")
    return
  end
  reaper.defer(poll)
end
reaper.defer(poll)
