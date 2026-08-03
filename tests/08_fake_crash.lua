-- 08_fake_crash.lua — U16: stage "the tool died mid-update" for the REAL
-- yb_Reference, then prove its startup rescue. The update button's one
-- dangerous moment disables this repo for a split second; a crash exactly
-- there leaves it unticked. The tool journals what it was doing BEFORE that
-- moment and repairs it on the next launch — this script fakes the aftermath:
--
--   1) disables the yb_update_test repo (what a mid-update crash leaves), and
--   2) writes the tool's own recovery note (the length-prefixed one-line form
--      lib/updater.lua stores in persistent ExtState).
--
-- THEN: check Extensions > ReaPack > Manage repositories — yb_update_test is
-- UNTICKED. Now just open yb_Reference (the ReaPack-installed copy) and look
-- again: the repo is silently re-ticked, auto-install on "Use global setting",
-- and nothing visible happened. That is the whole rescue.
--
-- (Contrast with U17: unticking the repo YOURSELF, with no note written, must
-- stay unticked — the tool only repairs what it broke.)

local NAME = "yb_update_test"
local URL  = "https://raw.githubusercontent.com/ybresley/yb-reapack-test/main/index.xml"

local function say(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

say("")
say("=== 08_fake_crash (U16) ===")
if not (reaper.APIExists and reaper.APIExists("ReaPack_AddSetRepository")) then
  say("FAIL: ReaPack API not found")
  return
end

local ok, ret, err = pcall(reaper.ReaPack_AddSetRepository, NAME, URL, false, 2)
say(string.format("AddSetRepository(enable=false) -> ok=%s, ret=%s, err=%s",
  tostring(ok), tostring(ret), tostring(err)))
local okq, errq = pcall(reaper.ReaPack_ProcessQueue, true)
say("ProcessQueue(true) -> " .. (okq and "ok" or ("ERROR: " .. tostring(errq))))

-- The recovery note, exactly as lib/updater.lua encodes it: <name length>:<name><url>.
local note = #NAME .. ":" .. NAME .. URL
reaper.SetExtState("yb_Reference", "update_trick_recovery", note, true)
say("recovery note written: " .. note)

say("")
say("NOW: 1) Manage repositories -> yb_update_test should be UNTICKED.")
say("     2) Open yb_Reference (the installed copy). Nothing should appear.")
say("     3) Manage repositories again -> re-ticked, auto-install 'Use global setting'.")
say("Report what each step showed.")
say("=== 08 done ===")
