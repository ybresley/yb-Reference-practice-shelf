-- search: turns the full library into the subset the list should show — the
-- category filter behind the sidebar, a name/note text filter behind the search
-- box, and the column sort behind the header clicks.
--
-- Pure Lua. Filing stores a sound's parent category on `category` and its
-- sub-category (if any) on `subcategory`, so a sound filed in a sub still carries
-- its parent id — that is why "show a whole category" is a simple `category` match
-- and naturally includes everything in its sub-categories.

local search = {}

-- A view is one of:
--   { scope = "all" }                    every sound
--   { scope = "uncategorised" }          sounds with no category
--   { scope = "category", id = "c1" }    c1 and everything in its sub-categories
--   { scope = "subcategory", id = "c2" } only that sub-category
local function in_view(s, view)
  local scope = view.scope
  if scope == "uncategorised" then return s.category == nil end
  if scope == "category" then return s.category == view.id end
  if scope == "subcategory" then return s.subcategory == view.id end
  return true -- "all" (or anything unrecognised) shows everything
end

-- Name/note substring match, case-insensitive. Empty query matches everything.
-- Plain find (no pattern magic) so a query like "hit (2)" behaves literally.
local function in_text(s, query)
  if query == nil or query == "" then return true end
  local q = query:lower()
  return ((s.name or ""):lower():find(q, 1, true) ~= nil)
    or ((s.note or ""):lower():find(q, 1, true) ~= nil)
end

-- Public: does this one sound survive the search box? Exported so a caller that
-- is about to REVEAL a specific sound ("Show in library") can tell whether the
-- running query would hide it, without re-implementing the match.
function search.matches(s, query)
  return in_text(s, query)
end

-- Return a new list of the sounds matching the view AND the query, in library
-- order (sort is applied separately so the two concerns stay independent).
function search.filter(lib, view, query)
  view = view or { scope = "all" }
  local out = {}
  for _, s in ipairs(lib.sounds) do
    if in_view(s, view) and in_text(s, query) then out[#out + 1] = s end
  end
  return out
end

--------------------------------------------------------------- sorting

-- Per-column ordering. Each returns -1/0/1 for a < b in ASCENDING terms; the
-- direction is applied by search.sort. Unmeasured loudness (nil) is handled in
-- sort itself so it always sinks to the bottom regardless of direction.
local function cmp_number(x, y)
  if x < y then return -1 elseif x > y then return 1 else return 0 end
end

local COMPARE = {
  name = function(a, b)
    local la, lb = (a.name or ""):lower(), (b.name or ""):lower()
    if la < lb then return -1 elseif la > lb then return 1 else return 0 end
  end,
  dur  = function(a, b) return cmp_number(a.duration or 0, b.duration or 0) end,
  ch   = function(a, b) return cmp_number(a.channels or 0, b.channels or 0) end,
}

search.DEFAULT_LOUD_FIELD = "lufs_i"

-- Sort a list of sounds in place by one column. `col` is a COMPARE key (or
-- "loud"); an unknown key (or nil) leaves the list in library order. Ties break
-- by id so the order is deterministic (table.sort is not stable on its own).
--
-- `loud_field` names WHICH stored measurement the loudness column sorts by, so the
-- order always matches the unit currently on screen (the list header can show any
-- of the three). Sorting by a unit that isn't displayed would look plain wrong.
--
-- `pinned` is the "which of these sounds are pinned in the project in front of the
-- user" lookup (sound id -> pin). That fact lives OUTSIDE the library — it belongs
-- to one project — so the pin column can only be sorted with it handed in; absent,
-- nothing counts as pinned. The pin column prefers DESCENDING (see the browser's
-- column setup), so the first click puts the pinned sounds on top.
function search.sort(list, col, asc, loud_field, pinned)
  local field = loud_field or search.DEFAULT_LOUD_FIELD
  local compare = COMPARE[col]
  if col == "loud" then
    compare = function(a, b) return cmp_number(a[field], b[field]) end -- both present (nils handled below)
  elseif col == "pin" then
    local marks = pinned or {}
    compare = function(a, b)
      return cmp_number(marks[a.id] and 1 or 0, marks[b.id] and 1 or 0)
    end
  end
  if not compare then return list end
  table.sort(list, function(a, b)
    if col == "loud" then
      -- Unmeasured loudness always at the bottom, independent of direction.
      local anil, bnil = a[field] == nil, b[field] == nil
      if anil ~= bnil then return bnil end -- the non-nil one comes first
      if anil and bnil then return a.id < b.id end
    end
    local r = compare(a, b)
    if r ~= 0 then
      if asc then return r < 0 else return r > 0 end
    end
    return a.id < b.id -- stable, deterministic tiebreak
  end)
  return list
end

return search
