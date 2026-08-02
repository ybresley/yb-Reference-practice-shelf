-- 07_crash_window.lua — U9: simulate a crash in the middle of the sync trick.
-- Runs ONLY the trick's first half (disable + ProcessQueue) then stops dead -
-- exactly the state a crash between the two halves would leave behind.
--
-- Afterwards, check and report each of these:
--   1) Extensions > ReaPack > Manage repositories: yb_update_test is UNTICKED.
--   2) (optional) Extensions > ReaPack > Synchronize packages: our repo is
--      skipped, every other repo behaves normally.
--   3) RECOVER: run 04_restore (should silently re-tick it) - or tick it by
--      hand in Manage repositories. Confirm it's enabled again.

local REPO_NAME = "yb_update_test"
local REPO_URL  = "https://raw.githubusercontent.com/ybresley/yb-reapack-test/main/index.xml"

local function say(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

say("")
say("=== 07_crash_window (U9) ===")
if not (reaper.APIExists and reaper.APIExists("ReaPack_AddSetRepository")) then
  say("FAIL: ReaPack API not found")
  return
end

local ok, ret, err = pcall(reaper.ReaPack_AddSetRepository, REPO_NAME, REPO_URL, false, 2)
say(string.format("AddSetRepository(enable=false) -> ok=%s, ret=%s, err=%s",
  tostring(ok), tostring(ret), tostring(err)))
local okq, errq = pcall(reaper.ReaPack_ProcessQueue, true)
say("ProcessQueue(true) -> " .. (okq and "ok" or ("ERROR: " .. tostring(errq))))

say("The repo is now DISABLED - this is the crash window's leftover state.")
say("Work through the 3 checks in this script's header and report each.")
say("=== 07 done ===")
