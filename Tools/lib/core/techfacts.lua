-- techfacts: one sound's technical facts as a line of text — "48 kHz · 24-bit ·
-- WAV · stereo". Pure formatting, shared by the browser's info row and the
-- working-view bar (2026-08-07, the horizontal-layout brief): two copies of the
-- same wording would drift the day one of them is edited, exactly the reason
-- widgets.ellipsize exists.
--
-- Core module: plain Lua, no reaper.*. The info table itself comes from
-- reaper_api.source_info — the caller passes it in as data.

local techfacts = {}

-- Facts joined by a spaced middle dot — the browser info row's voice.
-- (A WIDEST reservation string lived here for one day — the 2026-08-08
-- bar-space brief removed the bar's held seat, so the line is measured at its
-- real width and drawn only into genuinely spare room.)
local SEP = "  \u{00B7}  "

-- info = { rate?, bits?, format?, channels? } (reaper_api.source_info's shape).
-- Every field is optional — a fact that isn't there is simply left out, and a
-- nil info (file couldn't be opened) returns nil so callers show nothing.
function techfacts.format(info)
  if not info then return nil end
  local parts = {}
  if info.rate and info.rate > 0 then
    parts[#parts + 1] = string.format("%g kHz", info.rate / 1000)
  end
  if info.bits then parts[#parts + 1] = info.bits .. "-bit" end
  if info.format and info.format ~= "" then parts[#parts + 1] = info.format end
  -- Zero/absent channels is "no meaningful answer" (Codex, 2026-08-07): print
  -- nothing rather than a "0 ch" that reads as a fact.
  local ch = info.channels or 0
  if ch > 0 then
    parts[#parts + 1] = ch == 1 and "mono" or (ch == 2 and "stereo" or (ch .. " ch"))
  end
  if #parts == 0 then return nil end
  return table.concat(parts, SEP)
end

return techfacts
