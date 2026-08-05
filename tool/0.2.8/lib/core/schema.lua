-- Schema: the on-disk shape of the library and how older files migrate forward.
--
-- Pure Lua. No reaper.*, no ImGui, no disk access. This module only knows what a
-- valid library table looks like and how to bring an older one up to date, so it
-- can be unit-tested outside REAPER.

local importer = require("core.importer")
local categories = require("core.categories")

local schema = {}

-- Bump this whenever the stored shape changes; add a matching migration below.
schema.VERSION = 2

-- A brand-new, empty library.
function schema.new_library()
  return {
    version = schema.VERSION,
    categories = {}, -- see core/categories.lua for the record shape
    sounds = {}, -- populated in Phase 2 (import)
    -- Monotonic id counters. Ids are never reused, so they survive deletes and
    -- stay stable across renames (max-existing+1 would collide after deleting
    -- the highest id).
    seq = { category = 0, sound = 0 },
  }
end

-- Migrations upgrade a library table by exactly one version. Keyed by the version
-- they upgrade FROM; each returns the table at version+1 (and must set .version).
local migrations = {}

-- v1 -> v2: every category wears a colour from the palette. v1 could store a
-- gray one (the default from before gray was banned from the palette), and gray
-- is what the sidebar uses to mark a VIEW — so a category in it read as All
-- sounds / Uncategorised rather than as a category. Nothing else about the
-- stored shape changes; only category colours are touched.
migrations[1] = function(data)
  if type(data.categories) == "table" then
    categories.normalise_colors(data)
  end
  data.version = 2
  return data
end

-- One list, checked as a real array of records with unique string ids. JSON that
-- decodes to an object, a sparse list, or duplicated ids would all "load" fine and
-- then surface as vanishing rows or two rows answering to one click — silent
-- corruption the core layer must catch and fail loud on instead.
-- Returns the highest number found in the records' ids ("s12" -> 12), so the
-- caller can check the id counter hasn't fallen behind them.
local function check_records(list, what)
  local keys = 0
  for _ in pairs(list) do keys = keys + 1 end
  if keys ~= #list then
    error("library " .. what .. " list is not a plain list (file is corrupt)")
  end
  local seen, max_num = {}, 0
  for _, rec in ipairs(list) do
    if type(rec) ~= "table" or type(rec.id) ~= "string" then
      error("a " .. what .. " record is missing its id (file is corrupt)")
    end
    if seen[rec.id] then
      error("two " .. what .. " records share the id \"" .. rec.id .. "\" (file is corrupt)")
    end
    seen[rec.id] = true
    local num = tonumber(rec.id:match("^%a(%d+)$"))
    if num and num > max_num then max_num = num end
  end
  return max_num
end

-- Check that a current-version library has the shape the rest of the tool leans
-- on. Beyond the core tables existing: ids must be unique (they name rows, files
-- and selections), the id counters must not have fallen behind the records (a
-- counter behind hands an existing id to the next import), and every stored
-- filename must be a plain name inside the library folder (one carrying a path
-- would send playback, analysis and drag-out somewhere else entirely — delete
-- already refuses these, and what is refused on the way out is refused on the way
-- in). All of it only reachable through a hand-edited or damaged file; fail loud
-- rather than guess.
function schema.validate(data)
  if type(data.categories) ~= "table" then
    error("library is missing its categories list (file is corrupt)")
  end
  if type(data.sounds) ~= "table" then
    error("library is missing its sounds list (file is corrupt)")
  end
  if type(data.seq) ~= "table"
    or type(data.seq.category) ~= "number"
    or type(data.seq.sound) ~= "number" then
    error("library is missing its id counters (file is corrupt)")
  end
  local max_cat = check_records(data.categories, "category")
  local max_sound = check_records(data.sounds, "sound")
  if data.seq.category < max_cat or data.seq.sound < max_sound then
    error("library id counters are behind its records (file is corrupt) — a new sound could take an existing sound's id")
  end
  for _, s in ipairs(data.sounds) do
    if not importer.is_safe_filename(s.filename) then
      error("a sound's stored file name (" .. tostring(s.filename) ..
        ") isn't a plain file name inside the library folder (file is corrupt or was hand-edited)")
    end
  end
  return data
end

-- Bring a loaded library up to the current version, or raise a clear error.
-- Fails loud on anything that isn't a recognisable library rather than guessing —
-- a corrupt file must never be silently "repaired" into an empty one.
function schema.migrate(data)
  if type(data) ~= "table" then
    error("library data is not a table (file is corrupt or not a library)")
  end
  local v = data.version
  if type(v) ~= "number" then
    error("library data has no version field (file is corrupt or not a library)")
  end
  if v > schema.VERSION then
    error(string.format(
      "library was written by a newer version of the tool (file version %d, this tool understands up to %d) — update the tool",
      v, schema.VERSION))
  end
  while v < schema.VERSION do
    local step = migrations[v]
    if not step then
      error(string.format("no migration path from library version %d", v))
    end
    data = step(data)
    v = data.version
  end
  return schema.validate(data)
end

return schema
