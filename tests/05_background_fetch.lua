-- 05_background_fetch.lua — U6: the update badge's download mechanism.
-- Fires curl (or the PowerShell fallback) WITHOUT waiting, then watches for the
-- file across defer frames - REAPER's UI must never hitch.
--
-- Run it THREE times:
--   1) MODE = "curl"        - watch for any black console-window flash + UI stutter
--   2) MODE = "powershell"  - edit the line below, run again, same checks
--   3) offline              - turn Wi-Fi off, run once more: expect the 20s timeout
--                             line, no error dialogs, nothing else.

local MODE = "curl"   -- "curl" or "powershell"

-- The catalog stage that should be live when this test runs (step 5 of the README
-- runs it after Claude pushed the v1.1 catalog). Only informational: if the file
-- arrives without it, that's GitHub's ~5-min cache lag, not a failure.
local EXPECTED_VERSION = "1.1"

local REPO_URL = "https://raw.githubusercontent.com/ybresley/yb-reapack-test/main/index.xml"

local function say(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

say("")
say("=== 05_background_fetch (U6) - MODE = " .. MODE .. " ===")

local out_path = reaper.GetResourcePath() .. "/yb_update_check_test.xml"
os.remove(out_path)

local cmd
if MODE == "curl" then
  -- The exact shipped pattern from RESEARCH.md: -f fail-on-HTTP-error, -L follow
  -- redirects, NEVER -k (it would disable TLS certificate checks).
  cmd = 'curl -f -L -o "' .. out_path .. '" "' .. REPO_URL .. '"'
else
  -- Single quotes inside the PowerShell string are escaped by doubling them, so a
  -- quote in the resource path can't break out of the string.
  local ps_url = (REPO_URL:gsub("'", "''"))
  local ps_out = (out_path:gsub("'", "''"))
  cmd = 'powershell.exe -windowstyle hidden -command "(new-object System.Net.WebClient).DownloadFile(\'' .. ps_url .. '\', \'' .. ps_out .. '\')"'
end

say("cmd: " .. cmd)
local ret = reaper.ExecProcess(cmd, -1)   -- -1 = fire and forget, returns instantly
say("ExecProcess returned instantly: [" .. type(ret) .. "] " .. tostring(ret))
say("WATCH: did a black console window flash? Did the UI stutter at all?")

local t0, frames = reaper.time_precise(), 0
local function poll()
  frames = frames + 1
  local f = io.open(out_path, "rb")
  if f then
    local content = f:read("a") or ""
    f:close()
    -- Only the CLOSING tag proves the download finished - "<index" alone can be
    -- a partial file still being written.
    if content:find("</index>", 1, true) then
      say(string.format("file arrived COMPLETE after %d defer frames (%.2fs), %d bytes", frames, reaper.time_precise() - t0, #content))
      say("starts with: " .. content:sub(1, 50):gsub("[\r\n].*", ""))
      if content:find('name="' .. EXPECTED_VERSION .. '"', 1, true) then
        say("lists the expected stage (v" .. EXPECTED_VERSION .. "): YES")
      else
        say("lists the expected stage (v" .. EXPECTED_VERSION .. "): NO - likely GitHub's ~5-min cache still serving the old catalog. Wait a few minutes and rerun if you want, or just report it.")
      end
      say("file kept for inspection at: " .. out_path)
      say("=== 05 (" .. MODE .. ") done - now the next MODE / the offline run ===")
      return
    end
    -- file exists but isn't complete yet: still downloading, or a failed fetch
    -- left a partial - keep watching until the timeout says which.
  end
  if reaper.time_precise() - t0 > 20 then
    if f then
      say("TIMEOUT: a file exists but never became the index - report its size/content.")
    else
      say("TIMEOUT: no file after 20s.")
      say("If you're OFFLINE right now, this silent nothing is EXACTLY the wanted behaviour.")
      say("If you're online, that's a finding - report it.")
    end
    say("=== 05 (" .. MODE .. ") done ===")
    return
  end
  reaper.defer(poll)
end
reaper.defer(poll)
