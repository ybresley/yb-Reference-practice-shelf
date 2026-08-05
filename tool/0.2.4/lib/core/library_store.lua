-- Library persistence: turn the in-memory library table into JSON on disk and
-- back, safely.
--
-- Pure Lua plus the standard io/os library only (no reaper.*, no ImGui) so it
-- runs under Busted. The parent folder must already exist — creating the library
-- folder is the reaper layer's job (RecursiveCreateDirectory); this module only
-- reads and writes files inside it.

local json = require("vendor.json")
local schema = require("core.schema")

local store = {}

-- Encode a library table to a JSON string. Pure.
function store.encode(data)
  return json.encode(data)
end

-- Decode a JSON string into a validated, migrated library table. Pure.
-- Raises a clear error on broken JSON or a non-library shape rather than
-- returning half-parsed data (fail loud — never silently wipe a bad file).
function store.decode(text)
  if type(text) ~= "string" or text == "" then
    error("library file is empty")
  end
  local ok, result = pcall(json.decode, text)
  if not ok then
    error("library file is not valid JSON: " .. tostring(result))
  end
  return schema.migrate(result)
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- Does a library file exist at this path?
function store.exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

-- Is SOMETHING at this path, even if it can't be opened right now (an exclusive
-- lock by a backup or sync tool)? Renaming a name to itself only succeeds when a
-- real entry is there. The distinction matters exactly once, at startup: only a
-- path that is truly EMPTY may become a fresh library. Treating a locked library
-- as missing would create an empty one in memory — and the first save after the
-- lock clears would then replace the user's real library with that emptiness.
function store.present(path)
  if store.exists(path) then return true end
  return os.rename(path, path) == true
end

-- Load a library from disk. Returns the migrated table, or raises if the file is
-- missing or corrupt. The caller decides whether "missing" means create a new one.
function store.load(path)
  local text = read_file(path)
  if text == nil then
    error("library file not found: " .. tostring(path))
  end
  return store.decode(text)
end

-- Write `text` to "<path>.tmp" completely, or raise having removed the partial
-- file. Checking the CLOSE matters as much as the write: close is when buffered
-- bytes actually reach the disk, so that's where a full disk surfaces. Nothing
-- existing is touched here, so a failure always leaves the old file intact.
local function write_temp(path, text, what)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then
    error("could not open temp file for writing: " .. tostring(err))
  end
  local wrote, werr = f:write(text)
  if not wrote then
    f:close()
    os.remove(tmp)
    error("could not write " .. what .. ": " .. tostring(werr))
  end
  local closed, cerr = f:close()
  if not closed then
    os.remove(tmp)
    error("could not finish writing " .. what .. " (disk full?): " .. tostring(cerr))
  end
  return tmp
end

-- Save a library to disk atomically: fully write a temp file, then swap it into
-- place, so a crash mid-write can never leave a half-written library.
--
-- Windows caveat: os.rename won't overwrite an existing file, so we move the
-- current file aside to a .bak first, then rename the temp into place, then drop
-- the backup. If the swap fails partway, the old file is restored here; if REAPER
-- is killed mid-swap (old file already moved to .bak, new file not yet in place),
-- store.recover() rescues the .bak on next startup.
function store.save(path, data)
  local text = store.encode(data)
  local tmp = write_temp(path, text, "library data")
  local bak = path .. ".bak"
  if store.exists(path) then
    os.remove(bak) -- clear any stale backup from a previous interrupted save
    local ok = os.rename(path, bak)
    if not ok then
      os.remove(tmp)
      error("could not back up existing library before saving")
    end
  end

  local ok, rerr = os.rename(tmp, path)
  if not ok then
    -- Swap failed: put the old file back so the on-disk library stays intact.
    if store.exists(bak) then os.rename(bak, path) end
    os.remove(tmp)
    error("could not save library: " .. tostring(rerr))
  end

  os.remove(bak) -- success: the backup is no longer needed
end

-- Write a standalone JSON file (today: a trash note) the same careful way — temp
-- file first, then swap — so a crash can't leave half a record behind.
--
-- No .bak dance, unlike the library: there is no previous version of this file
-- worth rescuing, and the caller writes it BEFORE destroying anything.
function store.write_json(path, data)
  local tmp = write_temp(path, store.encode(data), "record")
  os.remove(path) -- Windows: os.rename won't overwrite (no-op if absent)
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    error("could not save record: " .. tostring(rerr))
  end
end

-- Repair the aftermath of a save that a crash interrupted mid-swap. Call once at
-- startup, before deciding whether a library exists.
--
--   * Main file gone but a .bak present  -> we crashed after moving the old file
--     aside but before the new one landed. The .bak is the last complete library;
--     promote it back. (Without this, startup would see no file, create an empty
--     library, and the next save would delete the .bak — silent data loss.)
--   * A leftover .tmp  -> an interrupted write; it is always incomplete, drop it.
function store.recover(path)
  local bak = path .. ".bak"
  if not store.exists(path) and store.exists(bak) then
    -- Raise if the promotion doesn't take. Carrying on would be silent data loss of
    -- the worst kind: the caller sees no library, creates an empty one, and saving
    -- THAT deletes the .bak this backup rescue exists to protect. Better to stop and
    -- let the user move the file back by hand.
    local ok, err = os.rename(bak, path)
    if not ok then
      error("could not restore the library from its backup (" .. bak .. "): " .. tostring(err))
    end
  end
  os.remove(path .. ".tmp") -- no-op if absent
end

return store
