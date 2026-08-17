-- Pins: the per-project working set of references. The library is global and
-- personal; a pin is a project's OWN copy of a sound — its audio lives in a
-- References/ folder beside the project file, and the records below travel inside
-- the project file itself. That's what makes a project self-contained: a teammate
-- (or an empty library on a fresh machine) can open it and every pin still plays.
--
-- Pure Lua. No reaper.*, no ImGui, no disk access — the service layer copies the
-- audio and reads/writes the project's stored text; this module only knows what a
-- valid pin state looks like. A pin record is a SNAPSHOT of the sound it came
-- from (name, note, trim, measurements): later library edits deliberately don't
-- reach it, and its own edits never reach the library.
--
-- Pin ids get their own prefix ("p1", "p2", …) so they can never collide with
-- library sound ids ("s1", …) — the entry script routes lookups by that prefix.

local json = require("vendor.json")
local importer = require("core.importer")

local pins = {}

-- Bump when the stored shape changes; add a matching migration below.
pins.VERSION = 4

-- A project with no pins yet.
function pins.new_state()
  return {
    version = pins.VERSION,
    pins = {},
    -- Monotonic, never reused — same reasoning as the library's id counters.
    seq = { pin = 0 },
    -- The last selected reference in this project (a pin id). Only PIN ids are
    -- ever remembered here: a library id would name a different sound on a
    -- teammate's machine, and silently selecting the wrong audio is worse than
    -- selecting nothing.
    selected = nil,
  }
end

-- Migrations, keyed by the version they upgrade FROM. Mirrors core/schema.lua;
-- each step gets a fixture test with real old-format text.
local migrations = {}

-- v1 -> v2: Contexts arrive. Old data simply has none.
migrations[1] = function(data)
  data.contexts = {}
  data.seq.context = 0
  data.version = 2
  return data
end

-- v2 -> v3: Contexts die; a labeled Context becomes its pin's own `label`
-- instead (DESIGN, decided 2026-07-28 — one concept, the labeled pin, replaces
-- pin + Context + armed reference). The first Context in list order wins if
-- two designated the same pin — as truthful a choice as any, and the same rule
-- the readout used to resolve "what armed it". A Context with no resolvable
-- pin (empty, or pointing at nothing) simply vanishes: there's no pin left for
-- an orphaned label to describe.
migrations[2] = function(data)
  for _, c in ipairs(data.contexts) do
    if c.pin_id then
      local p = pins.find(data, c.pin_id)
      if p and not p.label then p.label = c.name end
    end
  end
  data.contexts = nil
  data.seq.context = nil
  data.version = 3
  return data
end

-- v3 -> v4: the snapshot learns the three new measurements (LUFS-S max, sample
-- peak, RMS) and the start/end span. All five fields are optional, so old
-- records need no touching — the bump only marks that pins may now carry them.
-- Old pins deliberately KEEP their three numbers and are not re-measured: a
-- pin's snapshot is the deal (later library edits don't reach it, and nothing
-- ever analyses References-folder audio), so the new units simply have no
-- value for a pre-v4 pin and the UI shows them as unmeasured.
migrations[3] = function(data)
  data.version = 4
  return data
end

local ANALYSIS_STATES = { pending = true, done = true, failed = true }

local function check_number(v, what)
  if v ~= nil and type(v) ~= "number" then
    error("a pin's " .. what .. " isn't a number (project data is corrupt)")
  end
end

-- Same structural checks the library gets — and stricter where the entry script
-- leans on the shape: this text lives inside the .RPP where hand-editing and
-- merge damage are possible. Ids must carry the "p" prefix (the entry routes
-- lookups by it — an id like "s1" here would be sent to the library), names and
-- numbers must be the types the UI formats, and filenames must be unique the way
-- WINDOWS thinks (two records naming what Windows calls one file would make one
-- pin's audio secretly shared). Fail loud, never guess.
function pins.validate(data)
  if type(data.pins) ~= "table" then
    error("pin data is missing its pins list (project data is corrupt)")
  end
  if type(data.seq) ~= "table" or type(data.seq.pin) ~= "number" then
    error("pin data is missing its id counter (project data is corrupt)")
  end
  local keys = 0
  for _ in pairs(data.pins) do keys = keys + 1 end
  if keys ~= #data.pins then
    error("pin list is not a plain list (project data is corrupt)")
  end
  local seen, names, max_num = {}, {}, 0
  for _, p in ipairs(data.pins) do
    if type(p) ~= "table" or type(p.id) ~= "string" then
      error("a pin record is missing its id (project data is corrupt)")
    end
    local num = tonumber(p.id:match("^p(%d+)$"))
    if not num then
      error("a pin record's id (" .. p.id .. ") isn't a pin id (project data is corrupt)")
    end
    if seen[p.id] then
      error("two pin records share the id \"" .. p.id .. "\" (project data is corrupt)")
    end
    seen[p.id] = true
    if num > max_num then max_num = num end
    if not importer.is_safe_filename(p.filename) then
      error("a pin's stored file name (" .. tostring(p.filename) ..
        ") isn't a plain file name inside the References folder (project data is corrupt)")
    end
    local lower = p.filename:lower()
    if names[lower] then
      error("two pin records point at the same file (" .. p.filename .. ") (project data is corrupt)")
    end
    names[lower] = true
    if type(p.name) ~= "string" or p.name == "" then
      error("a pin record has no name (project data is corrupt)")
    end
    if p.note ~= nil and type(p.note) ~= "string" then
      error("a pin's note isn't text (project data is corrupt)")
    end
    -- Duplicate labels are ALLOWED, including case-insensitive duplicates — a
    -- label describes a job ("Fire"), not an identity, so nothing stops two
    -- designed sounds sharing one.
    if p.label ~= nil and (type(p.label) ~= "string" or p.label == "") then
      error("a pin's label isn't a non-empty string (project data is corrupt)")
    end
    check_number(p.trim_db, "volume trim")
    check_number(p.duration, "duration")
    check_number(p.channels, "channel count")
    check_number(p.lufs_i, "loudness (LUFS-I)")
    check_number(p.lufs_m_max, "loudness (LUFS-M max)")
    check_number(p.lufs_s_max, "loudness (LUFS-S max)")
    check_number(p.true_peak, "true peak")
    check_number(p.peak, "sample peak")
    check_number(p.rms, "average level (RMS)")
    check_number(p.size_bytes, "file size")
    check_number(p.span_start, "start point")
    check_number(p.span_end, "end point")
    -- Playback runs start -> end, so the pair must describe a forward stretch of
    -- the file. Either handle may be absent (start defaults to 0, end to the
    -- file's end) — but a start below zero, an end at or below zero, or a start
    -- meeting/passing its end would give playback nothing to play.
    if (p.span_start and p.span_start < 0)
      or (p.span_end and p.span_end <= 0)
      or (p.span_start and p.span_end and p.span_start >= p.span_end) then
      error("a pin's start/end points don't describe a forward span (project data is corrupt)")
    end
    if p.analysis ~= nil and not ANALYSIS_STATES[p.analysis] then
      error("a pin's analysis state (" .. tostring(p.analysis) .. ") isn't one the tool knows (project data is corrupt)")
    end
  end
  if data.seq.pin < max_num then
    error("pin id counter is behind its records (project data is corrupt) — a new pin could take an existing pin's id")
  end
  if data.selected ~= nil and not seen[data.selected] then
    error("pin data remembers a selection (" .. tostring(data.selected) ..
      ") that isn't one of its pins (project data is corrupt)")
  end
  return data
end

-- Bring loaded pin data up to the current version, or raise a clear error.
function pins.migrate(data)
  if type(data) ~= "table" then
    error("pin data is not a table (project data is corrupt)")
  end
  local v = data.version
  if type(v) ~= "number" then
    error("pin data has no version field (project data is corrupt)")
  end
  if v > pins.VERSION then
    error(string.format(
      "this project's pins were saved by a newer version of the tool (data version %d, this tool understands up to %d) — update the tool",
      v, pins.VERSION))
  end
  while v < pins.VERSION do
    local step = migrations[v]
    if not step then
      error(string.format("no migration path from pin data version %d", v))
    end
    data = step(data)
    v = data.version
  end
  return pins.validate(data)
end

-- Encode to the single JSON line stored in the project. json.encode never emits
-- newlines, which matters here: the project's stored values are line-oriented
-- inside the .RPP, so a value with a newline in it would not survive a round trip.
function pins.encode(data)
  return json.encode(data)
end

-- Decode stored text into validated, migrated pin data. Raises on damage rather
-- than returning half-parsed records (fail loud, like the library).
function pins.decode(text)
  if type(text) ~= "string" or text == "" then
    error("pin data is empty")
  end
  local ok, result = pcall(json.decode, text)
  if not ok then
    error("pin data is not valid JSON: " .. tostring(result))
  end
  return pins.migrate(result)
end

function pins.find(data, id)
  for _, p in ipairs(data.pins) do
    if p.id == id then return p end
  end
  return nil
end

-- The snapshot a library sound contributes to its pin: everything the pin needs
-- to stand alone, plus where it came from (origin_id) and the dedup facts
-- (source_name, size_bytes) so "save to my library" can recognise it later.
-- The pin's filename is NOT set here — the service resolves a collision-free
-- name inside the References folder and passes it to pins.add.
function pins.snapshot(sound)
  return {
    name        = sound.name,
    note        = sound.note or "",
    trim_db     = sound.trim_db or 0,
    duration    = sound.duration or 0,
    channels    = sound.channels or 0,
    lufs_i      = sound.lufs_i,
    lufs_m_max  = sound.lufs_m_max,
    lufs_s_max  = sound.lufs_s_max,
    true_peak   = sound.true_peak,
    peak        = sound.peak,
    rms         = sound.rms,
    span_start  = sound.span_start,
    span_end    = sound.span_end,
    analysis    = sound.analysis,
    origin_id   = sound.id,
    source_name = sound.source_name,
    size_bytes  = sound.size_bytes,
  }
end

-- Does this pin genuinely come from this library sound? The origin id alone is
-- NOT enough: library ids are local counters, so a teammate's pin of THEIR "s7"
-- would collide with an unrelated "s7" in your library. The id only counts when
-- the content facts (original name + byte size) are present on both sides and
-- agree — the same facts import dedup already trusts.
function pins.origin_match(pin, sound)
  if not pin.origin_id or pin.origin_id ~= sound.id then return false end
  return pin.source_name ~= nil and pin.size_bytes ~= nil
    and pin.source_name == sound.source_name
    and pin.size_bytes == sound.size_bytes
end

-- Is this library sound already pinned here? Matched by verified origin first,
-- then by content facts alone — which also catches a teammate's pin of a file
-- you happen to own under a different record.
function pins.already_pinned(data, sound)
  for _, p in ipairs(data.pins) do
    if pins.origin_match(p, sound) then return p end
  end
  if sound.source_name ~= nil and sound.size_bytes ~= nil then
    for _, p in ipairs(data.pins) do
      if p.source_name == sound.source_name and p.size_bytes == sound.size_bytes then
        return p
      end
    end
  end
  return nil
end

-- References-folder filenames already spoken for by pin records, keyed lowercase
-- (Windows). The service unions this with the real folder listing before naming a
-- new copy, so a crash-orphaned file can't be overwritten — same rule as import.
function pins.taken_filenames(data)
  local set = {}
  for _, p in ipairs(data.pins) do
    if p.filename then set[p.filename:lower()] = true end
  end
  return set
end

-- Build and insert a pin record. `opts.filename` is the References-relative name
-- the service has ALREADY resolved and copied to (copy first, record last — a
-- crash in between leaves at worst an orphan file beside the project).
function pins.add(data, opts)
  if not importer.is_safe_filename(opts.filename) then
    error("pin filename must be a plain file name: " .. tostring(opts.filename))
  end
  data.seq.pin = data.seq.pin + 1
  local record = {
    id          = "p" .. data.seq.pin,
    filename    = opts.filename,
    name        = opts.name or importer.derive_name(opts.filename),
    note        = opts.note or "",
    trim_db     = opts.trim_db or 0,
    duration    = opts.duration or 0,
    channels    = opts.channels or 0,
    lufs_i      = opts.lufs_i,
    lufs_m_max  = opts.lufs_m_max,
    lufs_s_max  = opts.lufs_s_max,
    true_peak   = opts.true_peak,
    peak        = opts.peak,
    rms         = opts.rms,
    span_start  = opts.span_start,
    span_end    = opts.span_end,
    analysis    = opts.analysis or "pending",
    origin_id   = opts.origin_id,
    source_name = opts.source_name,
    size_bytes  = opts.size_bytes,
  }
  table.insert(data.pins, record)
  return record
end

-- Remove a pin, returning (removed record, the position it held). Also forgets
-- it as the remembered selection. The position lets the service put it back
-- EXACTLY where it was if storing the removal fails.
function pins.remove(data, id)
  for i, p in ipairs(data.pins) do
    if p.id == id then
      table.remove(data.pins, i)
      if data.selected == id then data.selected = nil end
      return p, i
    end
  end
  return nil
end

-- Where a pin sits in the stored order (1-based), or nil when it isn't one of
-- this project's pins. The stored order IS the order the picker's arrows step
-- through and the order its list shows, so position is meaningful data now, not
-- just insertion history.
function pins.index_of(data, id)
  for i, p in ipairs(data.pins) do
    if p.id == id then return i end
  end
  return nil
end

-- The next (delta 1) or previous (delta -1) pin in stored order, WRAPPING at
-- both ends — the list is a loop, so with two pins one arrow is an A/B toggle
-- (picker brief page 13). Returns nil only when there are no pins at all.
--
-- A `current_id` that isn't one of these pins (a library sound is selected, or
-- the armed pin was just unpinned) enters the list at the end the direction
-- comes from, rather than refusing to move.
function pins.step(data, current_id, delta)
  local n = #data.pins
  if n == 0 then return nil end
  local i = pins.index_of(data, current_id)
  if not i then return data.pins[delta < 0 and n or 1].id end
  return data.pins[(i - 1 + delta) % n + 1].id
end

-- Move a pin to another position in the stored order (the picker's edit mode,
-- dragging a row by its handle). `to_index` is clamped into range rather than
-- refused — a drag past the last row means "put it last". Returns the position
-- it CAME FROM so a failed store can put it back exactly, or nil when nothing
-- moved (already there).
function pins.reorder(data, id, to_index)
  local from = pins.index_of(data, id)
  if not from then
    error("pin \"" .. tostring(id) .. "\" isn't one of this project's pins")
  end
  if type(to_index) ~= "number" then
    error("a pin's new position must be a number")
  end
  to_index = math.floor(to_index)
  local n = #data.pins
  if to_index < 1 then to_index = 1 elseif to_index > n then to_index = n end
  if to_index == from then return nil end
  table.insert(data.pins, to_index, table.remove(data.pins, from))
  return from
end

-- Turn a drag's INSERTION GAP into the final position `pins.reorder` wants.
-- The picker's list reports the gap the mouse is hovering (1 = above the first
-- row, #pins + 1 = below the last); a pin dragged DOWNWARD leaves its own slot
-- before it lands, so everything below shifts up one and the gap the user is
-- pointing at is one lower than it looks. Getting this wrong drops a
-- dragged-down pin one row too far — which is exactly what happened before
-- 2026-08-06's Codex review caught it.
--
-- Returns nil when the move would change nothing (dropping a pin into either
-- gap touching its own row), so the caller can skip a pointless save.
function pins.drop_target(from, gap)
  if type(from) ~= "number" or type(gap) ~= "number" then return nil end
  local to = (gap > from) and (gap - 1) or gap
  if to == from then return nil end
  return to
end

-- Set (or clear) a pin's job label — the one optional field that turns a plain
-- pinned sound into a named trigger ("Fire"). `label` nil or "" clears it, same
-- as a pin that never had one. Duplicate labels are allowed on purpose: a
-- label describes a job, not an identity, so two pins can legitimately share
-- one — the service is where a corrupt/missing pin id gets a friendly message.
function pins.set_label(data, pin_id, label)
  local p = pins.find(data, pin_id)
  if not p then
    error("pin \"" .. tostring(pin_id) .. "\" isn't one of this project's pins")
  end
  if label ~= nil and type(label) ~= "string" then
    error("a pin's label must be text")
  end
  -- Trimmed the way the old Context names were: an all-whitespace label would
  -- pass validation (non-empty string) yet render a blank tab, so surrounding
  -- space goes and whatever's left decides — nothing left means "clear it".
  label = label and label:gsub("^%s+", ""):gsub("%s+$", "") or nil
  if label == "" then label = nil end
  p.label = label
  return p
end

-- Which library sounds are pinned here, for the list's pin markers:
-- { [sound_id] = pin }. Built against the actual library so an id-only
-- coincidence (a teammate's "s7" vs your unrelated "s7") never lights a marker —
-- only verified origins count. A teammate's pins simply don't appear in this map.
function pins.markers(data, sounds)
  local map = {}
  for _, p in ipairs(data.pins) do
    if p.origin_id then
      for _, s in ipairs(sounds) do
        if pins.origin_match(p, s) then
          map[s.id] = p
          break
        end
      end
    end
  end
  return map
end

return pins
