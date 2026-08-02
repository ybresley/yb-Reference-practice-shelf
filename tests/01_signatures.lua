-- 01_signatures.lua — U1 + U2: validate the reconstructed ReaPack Lua signatures live.
-- Prereq: the dummy is installed via ReaPack at v1.0 (README setup steps).
-- Copy ALL console output back to Claude.

-- If script 01 can't find the dummy at the guessed path, paste the real path here
-- (the dummy's own window shows it) between the quotes, keeping double backslashes or /:
local PATH_OVERRIDE = ""

local SCRIPT_REL = "Scripts/yb_update_test/Test/yb_dummy_package.lua"

local function say(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

say("")
say("=== 01_signatures (U1 + U2) ===")

if not (reaper.APIExists and reaper.APIExists("ReaPack_GetOwner")) then
  say("FAIL: ReaPack API not found - is ReaPack installed in this REAPER?")
  return
end

local abs = PATH_OVERRIDE ~= "" and PATH_OVERRIDE
  or (reaper.GetResourcePath() .. "/" .. SCRIPT_REL)

local f = io.open(abs, "rb")
say("dummy file on disk: " .. abs)
say("  -> " .. (f and "EXISTS" or "MISSING - install the dummy first (README step 3), or set PATH_OVERRIDE at the top of this script"))
if f then f:close() end

-- U1: GetOwner -> entry handle
local function try_getowner(label, path)
  say("")
  say("GetOwner (" .. label .. "): " .. path)
  local ok, entry, err = pcall(reaper.ReaPack_GetOwner, path)
  if not ok then
    say("  pcall ERROR: " .. tostring(entry))
    return nil
  end
  say("  entry = " .. tostring(entry) .. " (type " .. type(entry) .. "), err = " .. tostring(err))
  if entry then return entry end
  return nil
end

local entry = try_getowner("absolute path", abs)
if not entry then entry = try_getowner("resource-relative path", SCRIPT_REL) end
if not entry then entry = try_getowner("absolute, backslashes", (abs:gsub("/", "\\"))) end

if entry then
  local r = {pcall(reaper.ReaPack_GetEntryInfo, entry)}
  if r[1] then
    say("")
    say("GetEntryInfo returned " .. (#r - 1) .. " values:")
    for i = 2, #r do
      say(string.format("  return #%d: [%s] %s", i - 1, type(r[i]), tostring(r[i])))
    end
    say("  -> the reconstruction expects return #1 to be the API's own success flag (true)")
    say("     and return #7 to be the installed version ('1.0').")
    say("     If either sits at a DIFFERENT position, that's the finding to report.")
  else
    say("GetEntryInfo pcall ERROR: " .. tostring(r[2]))
  end
  local okf, errf = pcall(reaper.ReaPack_FreeEntry, entry)
  say("FreeEntry: " .. (okf and "ok (no error)" or ("ERROR: " .. tostring(errf))))
else
  say("")
  say("U1 FAIL: no entry from either path form - report both GetOwner lines above.")
end

-- U2: CompareVersions sanity
say("")
say("U2 CompareVersions - expected signs: positive / zero / negative / negative / positive")
local cases = { {"1.10", "1.9"}, {"1.0", "1.0"}, {"1.9", "1.10"}, {"1.0", "1.1"}, {"1.1", "1.0"} }
for _, c in ipairs(cases) do
  local ok, ret, err = pcall(reaper.ReaPack_CompareVersions, c[1], c[2])
  if ok then
    say(string.format("  compare(%-4s, %-4s) = %s   (err = %s)", c[1], c[2], tostring(ret), tostring(err)))
  else
    say(string.format("  compare(%-4s, %-4s) pcall ERROR: %s", c[1], c[2], tostring(ret)))
  end
end

say("")
say("=== 01 done - send everything above to Claude, who then pushes the v1.1 catalog ===")
