-- reference: the reference-mode adapter (a sibling of reaper_api/preview — one of
-- the few modules allowed to call reaper.*). It owns the crash-safe "latch": while
-- ON, the project's master is muted so pressing play in REAPER auditions the chosen
-- reference sound instead of the project. The preview playback itself is driven by
-- the entry script (it owns the single preview and the one defer loop); this module
-- owns only the safety machinery, so a crash can never leave a master silently muted.
--
-- THE ONE INVARIANT: a master we muted is never left muted without a way to undo it.
-- Everything below exists to keep that true. Three ideas carry it:
--
-- 1. TWO RECORDS, each good at a different job, both written BEFORE the mute lands:
--    * A marker inside the project (project ExtState) holding the prior mute value.
--      This is the authoritative record. It travels WITH the project — through "Save
--      As", through a rename, and it works for a never-saved project — because it is
--      stored in the same place as the mute itself. If the mute survived, the marker
--      survived; if the marker is gone, the mute went with it. A file path can't do
--      this: renaming the project would strand it.
--    * A queue on disk (the journal) saying which obligations are outstanding,
--      plus each project's path. Needed because a project that isn't open can't be
--      scanned for markers. One active latch may hand over to another project while
--      any closed projects wait safely in this queue.
--    NOT ExtState for the disk note: persistent ExtState is only flushed on a clean
--    REAPER exit, so it would not survive the crash it exists to recover from.
--
-- 2. AN OBLIGATION IS ONLY FORGOTTEN ONCE IT IS PROVABLY DISCHARGED. Every restore is
--    read back to confirm it took, and the note is deleted last (and verified gone).
--    If a project is closed we KEEP its entry and recover it when it reopens. A real
--    write/restore failure still blocks new latches; a routine queued recovery does
--    not. Losing an entry is the only truly unrecoverable outcome, so we never remove
--    one on a guess.
--
-- 3. RESTORE-IF-UNCHANGED, always: if the user unmuted the master by hand, that is
--    their call and we leave it alone.
--
-- Why muting the master gives a clean A/B: the preview routes to a hardware output
-- (through Monitor FX), NOT through the master track, so muting the master silences
-- the PROJECT while the reference preview stays audible.
--
-- Known limitation (documented, not an oversight): if two copies of yb-Reference run
-- at once, the second sees the first's live marker and restores it. The latch then
-- stops working in the first window (its restore-if-unchanged check correctly declines
-- to re-mute), which is visible rather than dangerous. REAPER's own "script already
-- running" prompt makes this rare, so it isn't worth an ownership lease and the
-- staleness bugs that come with one.

local reference = {}

local SEP = package.config:sub(1, 1)

local JOURNAL = reaper.GetResourcePath() .. SEP .. "yb-Reference_ref_journal.txt"
local JOURNAL_TMP = JOURNAL .. ".tmp"
local JOURNAL_BAK = JOURNAL .. ".bak"

-- The marker lives in the project's own ExtState, so it is saved into the .rpp
-- alongside the mute it describes.
local PROJ_SECTION = "yb-Reference"
local PROJ_KEY     = "ref_recovery"

-- The companion action (a separate one-line script the user binds to a hotkey) pulses
-- this ExtState value to "1"; the main script sees it, toggles the latch, and clears
-- it. The main script also clears it at startup and exit, so a press made while the
-- tool was closed can't silently latch on the next launch.
local EXT_SECTION = "yb-Reference"
local EXT_TOGGLE  = "ref_toggle_request"

-- Live latch state. At most one OPEN project drives reference playback. Closed
-- owners leave this slot and keep only their journal entry, so another project
-- can latch without overwriting their recovery.
local latch = {
  on = false, proj = nil, path = "", prev_mute = nil, token = nil,
  preview_allowed = false,
}

-- The last verified journal contents. Every active or queued obligation is one
-- entry. The file is loaded during startup recovery before latching is possible.
local journal_entries = {}
local journal_loaded = false

-- Set only for a genuine safety failure: unreadable journal, refused restore, or
-- journal rewrite that could not be verified. A normally closed project is queued,
-- not pending, and does not block another project's latch.
local pending = nil

--------------------------------------------------------------- projects

-- REAPER lets the user switch project tabs at any moment, so "the master track" is an
-- ambiguous thing to hold on to. We pin the project we latched and only ever act on
-- THAT one; using whichever project happens to be in front would unmute the wrong
-- project and leave the latched one muted for good.
local function current_project()
  local proj, path = reaper.EnumProjects(-1)
  return proj, path or ""
end

-- A stored project pointer goes stale if the user closes that tab, and touching freed
-- memory is a crash — so every later use is validated first.
local function project_alive(proj)
  if not proj then return false end
  return reaper.ValidatePtr2(0, proj, "ReaProject*")
end

local function path_for_project(wanted)
  local i = 0
  while true do
    local proj, path = reaper.EnumProjects(i)
    if not proj then return nil end
    if proj == wanted then return path or "" end
    i = i + 1
  end
end

local function project_name(path)
  if not path or path == "" then return "Unsaved project" end
  local name = path:match("([^/\\]+)$") or path
  return (name:gsub("%.[Rr][Pp][Pp]$", ""))
end

local function get_master_mute(proj)
  return reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(proj), "B_MUTE")
end

-- Set the mute and READ IT BACK. A write we merely asked for isn't proof: if it
-- silently didn't take and we deleted the recovery note on that assumption, the mute
-- would be stranded with nothing left to fix it.
local function set_master_mute(proj, v)
  reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(proj), "B_MUTE", v)
  return get_master_mute(proj) == v
end

--------------------------------------------------------------- the project marker

-- Write the marker and READ IT BACK, for the same reason every mute write is read
-- back: this is the AUTHORITATIVE record, and a write we merely asked for is not
-- proof. If the marker never landed and we muted anyway, a later recovery would find
-- the note's project open but carrying no marker, conclude it had reloaded clean,
-- delete the note and walk away — leaving the master muted with nothing left to
-- describe it. That is the one unrecoverable outcome.
local function marker_write(proj, token, prev_mute)
  local value = ("%s|%d"):format(token, prev_mute)
  reaper.SetProjExtState(proj, PROJ_SECTION, PROJ_KEY, value)
  local _, got = reaper.GetProjExtState(proj, PROJ_SECTION, PROJ_KEY)
  return got == value
end

local function marker_read(proj)
  local _, v = reaper.GetProjExtState(proj, PROJ_SECTION, PROJ_KEY)
  if not v or v == "" then return nil, "absent" end
  local token, prev = v:match("^([^|]*)|(%d+)$")
  prev = tonumber(prev)
  if not token or token == "" or (prev ~= 0 and prev ~= 1) then
    return nil, "damaged"
  end
  return { token = token, prev = prev }, "valid"
end

-- Clear the marker and confirm it is gone — same reasoning as verifying the note's
-- deletion. A marker left behind describes a mute we have already put back, so a
-- later startup would "restore" it over whatever the user has deliberately chosen
-- since (deliberately muting their own master, say).
local function marker_clear(proj)
  reaper.SetProjExtState(proj, PROJ_SECTION, PROJ_KEY, "")
  local _, state = marker_read(proj)
  return state == "absent"
end

--------------------------------------------------------------- journal

-- Version 1 was one key=value record. Version 2 keeps several tab-separated
-- entries in the SAME permanent file. Windows project paths cannot contain tabs
-- or newlines, so the format is reversible without escaping and an old journal
-- can be loaded and rewritten as v2 the first time another project is added.
local function journal_parse(txt)
  if type(txt) ~= "string" then return nil, "unreadable" end

  if txt:match("^version=2\r?\n") then
    local entries, seen = {}, {}
    for line in txt:gmatch("[^\r\n]+") do
      if line ~= "version=2" then
        local prev, token, project = line:match("^entry=([01])\t([^\t]+)\t(.*)$")
        if not token or seen[token] then return nil, "damaged" end
        seen[token] = true
        entries[#entries + 1] = {
          prev = tonumber(prev), token = token, project = project,
        }
      end
    end
    return entries
  end

  local set = tonumber(txt:match("set_mute=(%d+)"))
  local prev = tonumber(txt:match("prev_mute=(%d+)"))
  local token = txt:match("token=([^\r\n]*)")
  local project = txt:match("project=([^\r\n]*)") or ""
  if set ~= 1 or (prev ~= 0 and prev ~= 1) or not token or token == "" then
    return nil, "damaged"
  end
  return { { prev = prev, token = token, project = project } }
end

local function journal_encode(entries)
  local out = { "version=2\n" }
  for i = 1, #entries do
    local e = entries[i]
    if (e.prev ~= 0 and e.prev ~= 1) or type(e.token) ~= "string" or e.token == ""
      or e.token:find("[\t\r\n]") or type(e.project) ~= "string"
      or e.project:find("[\t\r\n]") then
      return nil
    end
    out[#out + 1] = ("entry=%d\t%s\t%s\n"):format(e.prev, e.token, e.project)
  end
  return table.concat(out)
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local txt = f:read("*a")
  f:close()
  return type(txt) == "string" and txt or ""
end

local function file_exists(path)
  local f = io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

-- If REAPER died during the Windows remove-then-rename swap, the old complete
-- journal is in .bak and the new complete journal is still in .tmp. No mute can
-- land until a save returns, so restoring .bak is the only safe interpretation.
local function journal_load()
  local txt = read_file(JOURNAL)
  if txt ~= nil then
    local entries, err = journal_parse(txt)
    if not entries then return nil, err end
    os.remove(JOURNAL_TMP)
    os.remove(JOURNAL_BAK)
    return entries
  end

  local bak = read_file(JOURNAL_BAK)
  if bak ~= nil then
    local entries, err = journal_parse(bak)
    if not entries then return nil, err end
    os.remove(JOURNAL_TMP)
    if not os.rename(JOURNAL_BAK, JOURNAL) then return nil, "repair failed" end
    if read_file(JOURNAL) ~= bak then return nil, "repair failed" end
    return entries
  end

  os.remove(JOURNAL_TMP)
  return {}
end

local function ensure_journal_loaded()
  if journal_loaded then return true end
  local entries, err = journal_load()
  if not entries then
    pending = "Reference mode can't check its recovery journal (" .. JOURNAL ..
      "). Check the master track in any project that may be muted, then email " ..
      "yoni.ybtools@gmail.com before deleting the journal."
    return false, err
  end
  journal_entries, journal_loaded = entries, true
  return true
end

-- Atomically replace the whole queue. On Windows the existing file must move
-- aside first. The new file is read back before the backup is discarded.
local function journal_save(entries)
  if #entries == 0 then
    os.remove(JOURNAL_TMP)
    os.remove(JOURNAL)
    os.remove(JOURNAL_BAK)
    if file_exists(JOURNAL) or file_exists(JOURNAL_BAK) then return false end
    journal_entries = {}
    return true
  end

  local encoded = journal_encode(entries)
  if not encoded then return false end
  local f = io.open(JOURNAL_TMP, "w")
  if not f then return false end
  local written = f:write(encoded)
  local closed = f:close()
  if not written or not closed or read_file(JOURNAL_TMP) ~= encoded then
    os.remove(JOURNAL_TMP)
    return false
  end

  os.remove(JOURNAL_BAK)
  if file_exists(JOURNAL_BAK) then os.remove(JOURNAL_TMP); return false end

  local had_main = file_exists(JOURNAL)
  if had_main and not os.rename(JOURNAL, JOURNAL_BAK) then
    os.remove(JOURNAL_TMP)
    return false
  end
  if not os.rename(JOURNAL_TMP, JOURNAL) or read_file(JOURNAL) ~= encoded then
    os.remove(JOURNAL)
    if had_main then os.rename(JOURNAL_BAK, JOURNAL) end
    os.remove(JOURNAL_TMP)
    return false
  end

  os.remove(JOURNAL_BAK)
  journal_entries = entries
  return true
end

local function journal_add(entry)
  if not ensure_journal_loaded() then return false end
  local next_entries = {}
  for i = 1, #journal_entries do
    local e = journal_entries[i]
    if e.token == entry.token then return false end
    next_entries[#next_entries + 1] = e
  end
  next_entries[#next_entries + 1] = entry
  return journal_save(next_entries)
end

local function journal_remove(token)
  if not ensure_journal_loaded() then return false end
  local next_entries, found = {}, false
  for i = 1, #journal_entries do
    local e = journal_entries[i]
    if e.token == token then found = true else next_entries[#next_entries + 1] = e end
  end
  return not found or journal_save(next_entries)
end

local function journal_update_path(token, path)
  if not ensure_journal_loaded() then return false end
  local next_entries, found, changed = {}, false, false
  for i = 1, #journal_entries do
    local e = journal_entries[i]
    if e.token == token then
      found = true
      if e.project ~= path then
        e = { prev = e.prev, token = e.token, project = path }
        changed = true
      end
    end
    next_entries[#next_entries + 1] = e
  end
  return found and (not changed or journal_save(next_entries))
end

--------------------------------------------------------------- latch

-- A valid pointer is not enough ownership proof: REAPER may replace a tab and
-- later present the same pointer value for a different project. The marker token
-- is the identity that was written before the mute. A changed path with no token
-- means the old project is gone; the same path with a missing/damaged token is a
-- safety failure, because quietly calling that project clean could strand its mute.
local function live_owner_state(proj, old_path, token)
  if not project_alive(proj) then return "gone" end
  local path = path_for_project(proj)
  if path == nil then return "gone" end
  local marker, marker_state = marker_read(proj)
  if marker and marker.token == token then return "owned", path end
  if path ~= old_path then return "gone", path end
  return "marker_error", path, marker_state
end

local function clear_live_latch()
  latch.on, latch.proj, latch.path, latch.prev_mute, latch.token,
    latch.preview_allowed = false, nil, "", nil, nil, false
end

function reference.is_latched() return latch.on end

-- The outstanding-obligation message, or nil when everything is settled.
function reference.pending() return pending end

local token_seq = 0
local function new_token()
  local token, used
  repeat
    token_seq = token_seq + 1
    token = ("%d-%d-%d"):format(
      os.time(), math.floor(reaper.time_precise() * 1000) % 1000000, token_seq)
    used = false
    for i = 1, #journal_entries do
      if journal_entries[i].token == token then used = true; break end
    end
  until not used
  return token
end

-- Latch ON: silence the project. Returns (false, reason) having changed NOTHING if the
-- records can't be laid down first, or if a genuine recovery error is outstanding.
-- Routine closed-project obligations remain in the queue and do not block this latch.
-- Silencing happens here, never at play-detection, so no blip of project audio can
-- leak out before the mute lands.
function reference.latch_on()
  -- A reopened queued project must be restored before a new marker can replace
  -- its old one. In the normal app loop refresh already ran this frame; keeping
  -- it here makes the safety interface correct for cleanup/tests too.
  reference.refresh()
  if pending then return false, pending end
  local proj, path = current_project()
  if not proj then return false, "Reference mode couldn't find the current project." end

  if latch.on and latch.proj == proj then return true end
  if latch.on then
    local ok = reference.latch_off()
    if not ok then return false, pending end
  end

  -- A marker already sitting in this project is a crash survivor: the project was
  -- saved while latched, then crashed, and was only reopened after startup recovery
  -- had already settled the disk note (an unsaved-at-the-time project's note carries
  -- no path, so recovery can't wait for it). That marker's prior value is the truth
  -- about this master — the CURRENT mute is our own crash residue, and recording it
  -- as "prior" would restore the mute on un-latch and strand the master muted with
  -- both records gone. Adopting the surviving value makes pressing REF the rescue.
  --
  -- Adopted ONLY while the residue is still in place (master still muted). If the
  -- master is unmuted, the user already resolved the crash by hand, and their
  -- latest choice — not the marker's memory of an older one — is what un-latch must
  -- restore. The stale marker is then simply replaced by the new latch's own.
  local survivor, survivor_state = marker_read(proj)
  if survivor_state == "damaged" then
    pending = "Reference mode found a damaged recovery marker inside " ..
      project_name(path) .. ". Check its master track, then email yoni.ybtools@gmail.com " ..
      "before turning on Reference mode."
    return false, pending
  end
  local current = get_master_mute(proj)
  local prev = (survivor and current == 1) and survivor.prev or current
  local token = new_token()

  -- Both records go down BEFORE the mute, and both are verified. If we die between
  -- them they describe a mute that never happened — and restore-if-unchanged then
  -- correctly does nothing. If either can't be laid down, nothing is muted at all.
  if not marker_write(proj, token, prev) then
    return false, "Reference mode couldn't start because it couldn't save a recovery marker " ..
      "in your project. Your project was not changed."
  end
  local entry = { prev = prev, token = token, project = path }
  if not journal_add(entry) then
    marker_clear(proj)
    return false, "Reference mode couldn't start because it couldn't save its recovery journal. " ..
      "Your project was not changed."
  end

  if not set_master_mute(proj, 1) then
    marker_clear(proj)
    -- Only THIS entry describes the mute that never landed. Other closed
    -- projects' recovery entries stay untouched.
    if not journal_remove(token) then
      pending = "Reference mode couldn't mute the project's master track. Your project was not changed, " ..
        "but its recovery journal entry couldn't be removed (" .. JOURNAL .. "). Reopen " ..
        "yb-Reference to retry. Email yoni.ybtools@gmail.com before deleting the journal manually."
      return false, pending
    end
    return false, "Reference mode couldn't mute the project's master track. Your project was not changed. " ..
      "Reopen yb-Reference to retry."
  end

  latch.on, latch.proj, latch.path, latch.prev_mute, latch.token =
    true, proj, path, prev, token
  -- Latching is an explicit request: if this project's transport is already
  -- rolling, the reference may start immediately. Leaving the project later
  -- disarms this until the user returns and stops/starts its transport.
  latch.preview_allowed = true
  return true
end

-- Latch OFF: put the master back the way we found it, then forget the obligation —
-- but only once it is provably discharged. Returns true when fully settled.
function reference.latch_off()
  if not latch.on then return true end
  local proj, path, prev, token = latch.proj, latch.path, latch.prev_mute, latch.token
  local owner_state = live_owner_state(proj, path, token)
  clear_live_latch()

  -- The project we muted has been closed. If it was saved while latched, that mute is
  -- in the file and outlives us, so the note MUST stay — dropping it here is what
  -- would strand the user's master for good.
  if owner_state == "gone" then
    -- The entry was written before the mute and is already in the queue. This
    -- is routine recovery, not an error, so another project may latch now.
    return true, "queued", project_name(path)
  end

  if owner_state == "marker_error" then
    pending = "Reference mode lost its verified recovery marker inside " ..
      project_name(path) .. ". Its journal entry was kept. Keep the project open, check its " ..
      "master track, then email yoni.ybtools@gmail.com."
    return false, pending
  end

  -- Restore-if-unchanged: only put our value back if the master still holds the mute
  -- we set. If the user unmuted it by hand, that's theirs to keep.
  if get_master_mute(proj) == 1 and not set_master_mute(proj, prev) then
    pending = "Reference mode couldn't restore the master track's previous mute state. The master " ..
      "track is still muted. Unmute it manually or reopen the project so yb-Reference can try again."
    return false
  end

  -- Both records have to be provably gone before the obligation is forgotten — the
  -- note is kept either way, so the next run retries the cleanup.
  if not marker_clear(proj) then
    pending = "Reference mode restored the project's master track to its previous mute state, but couldn't " ..
      "clear its recovery marker. Save the project or restart REAPER to retry recovery cleanup."
    return false
  end
  if not journal_remove(token) then
    pending = "Reference mode restored the project's master track to its previous mute state, but couldn't " ..
      "remove its entry from the recovery journal (" .. JOURNAL .. "). Restart yb-Reference to retry. Email " ..
      "yoni.ybtools@gmail.com before deleting the journal manually."
    return false
  end
  pending = nil
  return true
end

--------------------------------------------------------------- startup recovery

local function recovery_message(names)
  if #names == 1 then
    return "Reference mode restored the master track in " .. names[1] .. " to its previous mute state."
  elseif #names > 1 then
    return "Reference mode restored the master tracks in " .. #names .. " projects to their previous mute states."
  end
  return nil
end

-- Restore queued entries whose projects are open. `include_unknown` is true at
-- startup: project markers are authoritative and must be honoured even when an
-- old/pathless journal could not name them. During a live latch, only tokens in
-- the queue are touched, so recovering A can never stop or restore active B.
local function recover_entries(include_unknown, stop_previews)
  local journal_ok = ensure_journal_loaded()
  if not journal_ok and not include_unknown then return pending, true end
  if stop_previews and reaper.APIExists("CF_Preview_StopAll") then
    reaper.CF_Preview_StopAll()
  end

  local by_token, by_path, pathless_count, active_token =
    {}, {}, 0, latch.on and latch.token or nil
  for i = 1, #journal_entries do
    local e = journal_entries[i]
    by_token[e.token] = e
    if e.token ~= active_token and e.project ~= "" then
      by_path[e.project] = by_path[e.project] or {}
      by_path[e.project][#by_path[e.project] + 1] = e
    elseif e.token ~= active_token then
      pathless_count = pathless_count + 1
    end
  end

  local resolved, seen, clean_paths, names = {}, {}, {}, {}
  local failed_restore, failed_marker, failed_marker_data, missing_marker_data = 0, 0, 0, 0
  local i = 0
  while true do
    local proj, path = reaper.EnumProjects(i)
    if not proj then break end
    path = path or ""
    local m, marker_state = marker_read(proj)
    local expected_here = by_path[path]
    local recover_marker = m and m.token ~= active_token and by_token[m.token]
    local marker_expected_here = false
    if m and expected_here then
      for j = 1, #expected_here do
        if expected_here[j].token == m.token then marker_expected_here = true; break end
      end
    end
    if marker_state == "absent" then
      clean_paths[path] = { mute = get_master_mute(proj) }
    elseif marker_state == "damaged" then
      -- Non-empty but unreadable is never "clean". If a queued entry names this
      -- project (or this is the startup sweep), losing it silently could strand a mute.
      if expected_here or pathless_count > 0 or include_unknown then
        failed_marker_data = failed_marker_data + 1
      end
    elseif m.token ~= active_token and ((expected_here and not marker_expected_here)
      or (pathless_count > 0 and not recover_marker)) then
      -- A valid marker with the wrong token is equally unsafe: do not choose one
      -- record over the other and certainly do not delete the journal by path.
      failed_marker_data = failed_marker_data + 1
    elseif m.token ~= active_token and (recover_marker or include_unknown) then
      seen[m.token] = true
      local ok = true
      if get_master_mute(proj) == 1 then ok = set_master_mute(proj, m.prev) end
      if not ok then
        failed_restore = failed_restore + 1
      elseif not marker_clear(proj) then
        failed_marker = failed_marker + 1
      else
        resolved[m.token] = true
        names[#names + 1] = project_name(path)
      end
    end
    i = i + 1
  end

  -- A damaged disk journal may hide obligations for closed projects, so it must
  -- stay in place and remain an urgent error. Open project markers are independent
  -- copies, however: honouring them here still rescues every project we can prove.
  if not journal_ok then return pending, true end

  -- An open project with a provably ABSENT marker reloaded clean: muting the master
  -- never dirties a project, so neither our mute nor marker reached its .RPP. A
  -- pathless entry is kept: the project may have received its first Save As between
  -- our last frame and a crash, in which case its marker is the only later identity.
  local remaining, changed = {}, false
  for i = 1, #journal_entries do
    local e = journal_entries[i]
    local clean = e.project ~= "" and clean_paths[e.project] or nil
    if e.token == active_token then
      remaining[#remaining + 1] = e
    elseif resolved[e.token] then
      changed = true
    elseif not seen[e.token] and clean then
      -- An absent marker only proves a clean reload when the master is not still
      -- holding the mute we set. With prior=0/current=1, deleting the journal could
      -- strand exactly the mute it describes, so keep it and fail visibly.
      if e.prev == 0 and clean.mute == 1 then
        remaining[#remaining + 1] = e
        missing_marker_data = missing_marker_data + 1
      else
        changed = true
      end
    else
      remaining[#remaining + 1] = e
    end
  end

  if changed and not journal_save(remaining) then
    pending = "Reference mode restored a project's master track to its previous mute state, but couldn't " ..
      "update its recovery journal (" .. JOURNAL .. "). Do not delete the journal. Restart " ..
      "yb-Reference to retry."
    return pending, true
  end
  if failed_restore > 0 then
    pending = "Reference mode couldn't restore a project's master track to its previous mute state. Check " ..
      "its master track and unmute it manually. Leave the project open so Reference mode can " ..
      "verify the change."
    return pending, true
  end
  if failed_marker > 0 then
    pending = "Reference mode restored a project's master track to its previous mute state, but couldn't " ..
      "clear its recovery marker. Save the project or restart REAPER to retry recovery cleanup."
    return pending, true
  end
  if failed_marker_data > 0 then
    pending = "Reference mode found a damaged or mismatched recovery marker in an open project. " ..
      "Its journal entry was kept. Keep the project open, check its master track, then email " ..
      "yoni.ybtools@gmail.com."
    return pending, true
  end
  if missing_marker_data > 0 then
    pending = "Reference mode found a muted project with no recovery marker. Its journal entry " ..
      "was kept. Unmute that project's master track manually, then leave the project open so " ..
      "Reference mode can verify the change."
    return pending, true
  end

  pending = nil
  return recovery_message(names), false
end

-- Startup recovery runs before every dependency gate. It stops previews left by
-- the dead instance, honours every open marker, and leaves closed entries queued.
function reference.recover()
  if latch.on then return nil end
  journal_loaded = false
  return recover_entries(true, true)
end

local function queued_count()
  local n, active = 0, latch.on and latch.token or nil
  for i = 1, #journal_entries do
    if journal_entries[i].token ~= active then n = n + 1 end
  end
  return n
end

-- Called once per frame. A closed live owner becomes an ordinary queued entry;
-- reopened queued projects restore automatically. The returned latch state is
-- deliberately CURRENT-PROJECT-specific, so every other tab's L button stays
-- off and usable.
function reference.refresh()
  ensure_journal_loaded()
  local current, current_path = current_project()
  local live_ended, immediate_error = false, nil

  if latch.on then
    local owner_state, owner_path = live_owner_state(latch.proj, latch.path, latch.token)
    if owner_state == "owned" then
      if current ~= latch.proj then
        -- Merely returning to a still-rolling owner is not a new Play request.
        -- Disarm as soon as the front tab changes; the owner must be observed
        -- stopped in front again before a later Play may start its reference.
        latch.preview_allowed = false
      end
      if owner_path ~= latch.path then
        if journal_update_path(latch.token, owner_path) then
          latch.path = owner_path
        else
          pending = "Reference mode couldn't update its recovery journal after " ..
            project_name(owner_path) .. " changed name. Its master track is still muted. Keep " ..
            "the project open, then email yoni.ybtools@gmail.com."
          immediate_error = pending
        end
      end
    else
      local ok = reference.latch_off() -- gone owner queues; marker trouble stays visible
      if not ok then immediate_error = pending end
      live_ended = true
    end
  end

  local msg, urgent
  if not immediate_error and (queued_count() > 0 or pending) then
    msg, urgent = recover_entries(false, false)
    current, current_path = current_project()
  end

  return {
    latched = latch.on and current == latch.proj,
    live = latch.on,
    pending = pending ~= nil,
    owner_name = latch.on and project_name(latch.path) or nil,
    queued_count = queued_count(),
  }, immediate_error or msg, immediate_error ~= nil or urgent,
    { live_ended = live_ended }
end

--------------------------------------------------------------- transport + hotkey

-- Should the live owner's transport be driving reference audio THIS frame?
-- Deliberately current-project-specific, and edge-aware across tab switches:
-- returning to an owner that never stopped is not treated as another Play press.
function reference.transport_preview_wanted()
  if not latch.on or not project_alive(latch.proj) then return false end
  local marker = marker_read(latch.proj)
  if not marker or marker.token ~= latch.token then return false end
  local current = current_project()
  if current ~= latch.proj then
    -- A background project's transport must never start reference audio. More
    -- importantly, returning while it is still rolling is not a new Play press.
    latch.preview_allowed = false
    return false
  end
  local playing = reaper.GetPlayStateEx(latch.proj) & 1 == 1
  if not playing then
    latch.preview_allowed = true
    return false
  end
  return latch.preview_allowed
end

-- Read and clear the companion hotkey's toggle pulse.
function reference.take_toggle_request()
  if reaper.GetExtState(EXT_SECTION, EXT_TOGGLE) == "1" then
    reaper.DeleteExtState(EXT_SECTION, EXT_TOGGLE, false)
    return true
  end
  return false
end

-- Clear any stale toggle pulse (at startup and exit, so a press made while the tool was
-- closed can't latch it on launch).
function reference.clear_toggle_request()
  reaper.DeleteExtState(EXT_SECTION, EXT_TOGGLE, false)
end

-- Best-effort exit cleanup (window closed or script unloaded normally). Never runs on a
-- crash — that is what the records are for — but on a clean exit it restores the master
-- immediately rather than leaving it to the next startup.
function reference.cleanup()
  if latch.on then reference.latch_off() end
  reference.clear_toggle_request()
end

return reference
