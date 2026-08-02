-- 03_update_trick.lua — U3 (and reused for U7): the single-repo sync trick.
--   disable -> ProcessQueue -> enable with autoInstall=1 -> ProcessQueue
-- Expected: ReaPack's Progress window appears, the Report lists ONLY this dummy's
-- update (no other repo touched), and the poll below prints the version advancing
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

-- Full GetEntryInfo state as one string (position-proof change detection) + the
-- version at the reconstructed position. nil on ANY failure, incl. the API's own
-- success flag (return #1) coming back false/0/nil.
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
  return table.concat(parts, " | "), nil, tostring(r[8])
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

-- Pin heuristic: besides the success flag, no boolean should read true on a fresh
-- install. If one does, it may be ReaPack's pin flag - which makes syncs skip the
-- package and would time this test out through no fault of the trick.
do
  local ok, entry = pcall(reaper.ReaPack_GetOwner, reaper.GetResourcePath() .. "/" .. SCRIPT_REL)
  if ok and entry then
    local r = {pcall(reaper.ReaPack_GetEntryInfo, entry)}
    pcall(reaper.ReaPack_FreeEntry, entry)
    if r[1] then
      local extra_true = 0
      for i = 3, #r do if r[i] == true then extra_true = extra_true + 1 end end
      if extra_true > 0 then
        say("NOTE: " .. extra_true .. " boolean flag(s) besides the success flag read TRUE - one may be the PIN flag.")
        say("If this test times out, right-click the dummy in ReaPack's browser, un-pin it, rerun, and report.")
      end
    end
  end
end

-- The trick. Both halves run in the same defer frame, like the real feature will:
-- the repo is genuinely disabled between the two calls (that's U9's crash window).
if not addset(false, 2) then
  say("ABORT: the disable call FAILED (see the line above) - nothing was changed. Report this.")
  return
end
if not process_queue() then
  say("ABORT: ProcessQueue failed after the disable - the repo state is uncertain. Run 04 to re-enable, and report this.")
  return
end
if not addset(true, 1) then   -- MUST be 1: 2 falls back to the global checkbox and the gate fails (U4)
  say("ABORT: the re-enable call FAILED - the repo is likely left DISABLED. Run 04 to re-enable, and report this.")
  return
end
if not process_queue() then
  say("ABORT: ProcessQueue failed after the re-enable - the repo state is uncertain. Run 04, and report this.")
  return
end

say("WATCH NOW: a ReaPack Progress window should appear, then a Report window.")
say("The Report must list ONLY this dummy - check nothing from any other repo moved.")
say("Polling the registry for the VERSION to advance (up to 90s)...")

local t0, next_check = reaper.time_precise(), 0
local last_snap = before
local function poll()
  local now = reaper.time_precise()
  if now >= next_check then
    next_check = now + 0.5
    local snap, _, ver = registry_snapshot()
    if snap then
      last_snap = snap
      if ver ~= before_ver then
        say(string.format("VERSION CHANGED after %.1fs:", now - t0))
        say("  before: " .. before)
        say("  after:  " .. snap)
        local okc, cmp = pcall(reaper.ReaPack_CompareVersions, ver, before_ver)
        if okc and type(cmp) == "number" and cmp > 0 then
          say(string.format("  CompareVersions(%s, %s) = %s -> a real upgrade. PASS.", ver, before_ver, tostring(cmp)))
          say("NOTE: the repo is still at autoInstall=1 - run 04 to restore it.")
          say("=== 03 done - report what the Progress/Report windows showed ===")
        else
          say(string.format("  FINDING: CompareVersions did NOT confirm an upgrade (ok=%s, cmp=%s, old=%s, new=%s).",
            tostring(okc), tostring(cmp), tostring(before_ver), tostring(ver)))
          say("  Report this + the Progress/Report contents. Run 04 to restore the repo either way.")
        end
        return
      end
    end
  end
  if now - t0 > 90 then
    if last_snap ~= before then
      say("TIMED OUT: the version never advanced, but OTHER registry data changed:")
      say("  before: " .. before)
      say("  after:  " .. last_snap)
      say("That is a FINDING (metadata moved without an update) - report it.")
    else
      say("TIMED OUT: 90s passed with no registry change at all.")
    end
    say("Report whether a Progress/Report appeared and what the Report said.")
    say("(The repo may now be at autoInstall=1 - run 04 to restore it either way.)")
    return
  end
  reaper.defer(poll)
end
reaper.defer(poll)
