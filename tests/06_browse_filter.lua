-- 06_browse_filter.lua — U8: the official fallback path - open ReaPack's browser
-- pre-filtered to exactly our package (used by the real feature only if the sync
-- trick ever stops working).
-- Expected: the browser opens showing EXACTLY ONE row (the dummy); right-click
-- offers Update/Install + a Versions submenu.
--
-- The filter uses the package's DISPLAY name (its desc). If the browser opens
-- EMPTY, swap the FILTER lines below and rerun; report which form worked.

local FILTER = '^"YB Dummy Package"$ ^"yb_update_test"$'
-- local FILTER = '^"yb_dummy_package.lua"$ ^"yb_update_test"$'   -- the filename form

local function say(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

say("")
say("=== 06_browse_filter (U8) ===")
if not (reaper.APIExists and reaper.APIExists("ReaPack_BrowsePackages")) then
  say("FAIL: ReaPack API not found")
  return
end

say("filter passed: " .. FILTER)
local ok, err = pcall(reaper.ReaPack_BrowsePackages, FILTER)
say("BrowsePackages -> " .. (ok and "called ok" or ("ERROR: " .. tostring(err))))
say("EXPECTED: browser open with exactly ONE row. Try right-click on it.")
say("=== 06 done - report the row count + which FILTER form worked ===")
