-- Import logic: name derivation, collision-safe filenames, dedup detection, and
-- building the per-sound record.
--
-- Pure Lua. No reaper.*, no disk access — the caller (reaper layer) copies the
-- audio file in and probes its duration/channels/size, then passes those in as
-- data. That split is what keeps import policy unit-testable outside REAPER.
--
-- Import ORDER (enforced by the caller, not here): copy the audio file into the
-- library folder FIRST, then call add_sound to write the record LAST. A crash in
-- between leaves at worst an orphan file a startup sweep can report — never a
-- record pointing at a file that was never copied.

local categories = require("core.categories")

local importer = {}

-- Filename (with extension) from a full path. Handles both separators because
-- source paths arrive from Windows Explorer/pickers ("\") but tests and any
-- future platform may use "/".
function importer.basename(path)
  return (path:gsub("^.*[\\/]", ""))
end

-- Split "Kick_01.wav" -> "Kick_01", ".wav". A name with no extension, or a
-- leading-dot name (".hidden"), yields an empty extension — we never treat the
-- whole name as an extension, so the base is always usable for a display name.
function importer.split_ext(filename)
  local base, ext = filename:match("^(.+)(%.[^%.\\/]*)$")
  if base then return base, ext end
  return filename, ""
end

-- Display name for a freshly imported file: filename without folder or extension.
-- Design keeps this literal ("starts as file name, editable") — no underscore
-- prettifying that could surprise the user.
function importer.derive_name(path)
  return (importer.split_ext(importer.basename(path)))
end

-- Names Windows treats as devices rather than files, whatever extension follows.
local RESERVED = {
  CON = true, PRN = true, AUX = true, NUL = true,
  COM1 = true, COM2 = true, COM3 = true, COM4 = true, COM5 = true,
  COM6 = true, COM7 = true, COM8 = true, COM9 = true,
  LPT1 = true, LPT2 = true, LPT3 = true, LPT4 = true, LPT5 = true,
  LPT6 = true, LPT7 = true, LPT8 = true, LPT9 = true,
}

-- Is this a plain filename living directly in the library folder? Import always
-- produces one (it derives from basename), but a record read back from a hand-
-- edited or damaged library file might not — and a name carrying a path, a stream
-- or a device would send a file operation somewhere else entirely. Checked before
-- anything acts on a stored filename; fail loud rather than touch a stranger's file.
--
-- Deliberately strict by Windows' rules on every platform. Being refused a delete
-- is a nuisance; deleting the wrong file is not, and every name this tool creates
-- itself passes easily.
function importer.is_safe_filename(name)
  if type(name) ~= "string" or name == "" then return false end
  if name == "." or name == ".." then return false end
  if name:find("[\\/]") then return false end       -- a path, not a name
  -- ":" also hides alternate data streams ("Kick.wav:something"), which name a
  -- different thing on disk than they appear to.
  if name:find('[<>:"|?*]') then return false end
  if name:find("%c") then return false end          -- control characters
  if name:find("[%. ]$") then return false end      -- Windows silently strips these
  local stem = name:match("^([^%.]*)") or ""
  if RESERVED[stem:upper()] then return false end
  return true
end

-- The set of library filenames already spoken for by existing records, keyed
-- lowercase (Windows filenames are case-insensitive, so "Kick.wav" collides with
-- "kick.wav"). The caller unions this with the actual directory listing before
-- resolving a name, so an orphan file on disk can't be silently overwritten.
function importer.taken_filenames(lib)
  local set = {}
  for _, s in ipairs(lib.sounds) do
    if s.filename then set[s.filename:lower()] = true end
  end
  return set
end

local function is_taken(taken, name)
  return taken[name:lower()] == true
end

-- Given a desired filename and a set of taken names, return the desired name if
-- free, else the first "<base>_N.<ext>" that isn't taken (N starts at 2). Never
-- returns a name already in the set, so a copy can never overwrite an existing
-- file.
function importer.unique_filename(desired, taken)
  taken = taken or {}
  if not is_taken(taken, desired) then return desired end
  local base, ext = importer.split_ext(desired)
  local n = 2
  while true do
    local candidate = base .. "_" .. n .. ext
    if not is_taken(taken, candidate) then return candidate end
    n = n + 1
  end
end

-- Find an already-imported copy of the same source file, matched on original
-- basename + byte size. Cheap and good enough for a hand-curated library of a few
-- hundred sounds; the caller uses this to ASK before importing a duplicate rather
-- than silently making a second copy. nil source_name/size never matches.
function importer.find_duplicate(lib, source_name, size_bytes)
  if source_name == nil or size_bytes == nil then return nil end
  for _, s in ipairs(lib.sounds) do
    if s.source_name == source_name and s.size_bytes == size_bytes then
      return s
    end
  end
  return nil
end

local function next_id(lib)
  lib.seq.sound = lib.seq.sound + 1
  return "s" .. lib.seq.sound
end

-- Build and insert a sound record, returning it. `opts.filename` is the
-- library-relative filename the caller has ALREADY resolved (via unique_filename)
-- and copied to; everything else is optional with sensible defaults.
--
-- Filing: pass `category` for a top-level home, or both `category` and
-- `subcategory` where the sub belongs to that category. This validates that link
-- and the categories' existence — fail loud rather than orphan a sound under an
-- id that doesn't resolve.
--
-- Loudness fields are intentionally absent until Phase 5 analysis fills them; the
-- `analysis = "pending"` flag is how the list knows to show "—" for now.
function importer.add_sound(lib, opts)
  local filename = opts.filename
  if type(filename) ~= "string" or filename:match("^%s*$") then
    error("sound filename cannot be empty")
  end

  local category = opts.category
  local subcategory = opts.subcategory
  if category ~= nil and not categories.get(lib, category) then
    error("category does not exist: " .. tostring(category))
  end
  if subcategory ~= nil then
    local sub = categories.get(lib, subcategory)
    if not sub then
      error("sub-category does not exist: " .. tostring(subcategory))
    end
    if sub.parent ~= category then
      error("sub-category does not belong to the chosen category")
    end
  end

  local record = {
    id = next_id(lib),
    filename = filename,
    name = opts.name or importer.derive_name(filename),
    category = category, -- nil = Uncategorised
    subcategory = subcategory, -- nil unless filed in a sub
    note = opts.note or "",
    trim_db = opts.trim_db or 0,
    added = opts.added or os.date("%Y-%m-%d"), -- os.date is pure Lua, not reaper.*
    duration = opts.duration or 0, -- seconds; probed by the reaper layer
    channels = opts.channels or 0,
    analysis = "pending", -- pending | done | failed (loudness filled in Phase 5)
    source_name = opts.source_name, -- original basename, for dedup
    size_bytes = opts.size_bytes, -- for dedup
  }
  table.insert(lib.sounds, record)
  return record
end

return importer
