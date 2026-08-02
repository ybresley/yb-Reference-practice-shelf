-- 04_restore.lua — U5: restore autoInstall to "use global setting" (2) with no sync.
-- Also the RECOVERY step for U9: re-enables the repo silently after the simulated crash.
-- Expected: completely silent - no Progress, no Report, no dialogs. Afterwards
-- Extensions > ReaPack > Manage repositories shows yb_update_test ENABLED with
-- "Install new packages: Use global setting".

local REPO_NAME = "yb_update_test"
local REPO_URL  = "https://raw.githubusercontent.com/ybresley/yb-reapack-test/main/index.xml"

local function say(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

say("")
say("=== 04_restore (U5 / U9 recovery) ===")
if not (reaper.APIExists and reaper.APIExists("ReaPack_AddSetRepository")) then
  say("FAIL: ReaPack API not found")
  return
end

local ok, ret, err = pcall(reaper.ReaPack_AddSetRepository, REPO_NAME, REPO_URL, true, 2)
say(string.format("AddSetRepository(enable=true, autoInstall=2) -> ok=%s, ret=%s, err=%s",
  tostring(ok), tostring(ret), tostring(err)))
local okq, errq = pcall(reaper.ReaPack_ProcessQueue, true)
say("ProcessQueue(true) -> " .. (okq and "ok" or ("ERROR: " .. tostring(errq))))

say("EXPECTED: nothing visible happened just now.")
say("Check Manage repositories: the repo should be ticked, auto-install back on 'Use global setting'.")
say("=== 04 done - report whether anything appeared ===")
