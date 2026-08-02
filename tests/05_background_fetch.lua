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
  cmd = 'powershell.exe -windowstyle hidden -command "(new-object System.Net.WebClient).DownloadFile(\'' .. REPO_URL .. '\', \'' .. out_path .. '\')"'
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
    if content:find("<index", 1, true) then
      say(string.format("file arrived after %d defer frames (%.2fs), %d bytes", frames, reaper.time_precise() - t0, #content))
      say("starts with: " .. content:sub(1, 50):gsub("[\r\n].*", ""))
      say("looks like the ReaPack index: YES")
      say("file kept for inspection at: " .. out_path)
      say("=== 05 (" .. MODE .. ") done - now the next MODE / the offline run ===")
      return
    end
    -- file exists but isn't the index yet: still downloading, or a failed fetch
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
