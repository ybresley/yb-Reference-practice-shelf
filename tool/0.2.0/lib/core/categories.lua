-- Category tree: two levels max (top-level and one level of sub-categories),
-- each with a permanent id so renaming a category never touches sound records.
--
-- Pure Lua. Operates in place on a library table (see core/schema.lua). A sound
-- references a category by id, so display names can change freely.

local categories = {}

-- Auto-assign colours by cycling this palette (swatch values from the UI tokens,
-- 0xRRGGBBAA). The chosen colour is copied onto the category when it's created,
-- so it stays stable even if this list is later reordered.
-- Gray is deliberately absent: in the sidebar gray text means "a view" (All
-- sounds / Uncategorised), so no category may ever wear it (decided 2026-07-27).
categories.PALETTE = {
  0x9386F2FF, -- purple
  0x3FA266FF, -- green
  0xF1B467FF, -- yellow
  0xFC6B83FF, -- red
  0x81A1C1FF, -- cyan
  0xB48EADFF, -- pink
  0x7BAFE9FF, -- blue
  0xDD7F76FF, -- orange
}

local function in_palette(color)
  for _, c in ipairs(categories.PALETTE) do
    if c == color then return true end
  end
  return false
end

-- Give every category a real palette colour. The earliest libraries stored a
-- gray default, and gray is the sidebar's "this row is a view" signal (All
-- sounds / Uncategorised) — a category wearing it reads as one of those instead
-- of as a category, which is exactly what the user saw.
--
-- A replacement takes the first colour NOBODY else is wearing, so fixing one
-- category can't hand it the colour of the category sitting right beside it (a
-- position-based cycle did exactly that on the user's own library: the gray
-- category was given the palette's first colour, which its neighbour already
-- had). Only once the palette is used up does it fall back to the position
-- cycle `add` uses. Colours already in the palette are left alone — repeats
-- among those are `add`'s normal wrap-around, not damage.
--
-- Returns how many categories were changed.
function categories.normalise_colors(lib)
  local taken = {}
  for _, c in ipairs(lib.categories) do
    if in_palette(c.color) then taken[c.color] = true end
  end
  local changed = 0
  for i, c in ipairs(lib.categories) do
    if not in_palette(c.color) then
      local pick
      for _, p in ipairs(categories.PALETTE) do
        if not taken[p] then pick = p break end
      end
      c.color = pick or categories.PALETTE[((i - 1) % #categories.PALETTE) + 1]
      taken[c.color] = true
      changed = changed + 1
    end
  end
  return changed
end

local function blank(name)
  return type(name) ~= "string" or name:match("^%s*$") ~= nil
end

local function next_id(lib)
  lib.seq.category = lib.seq.category + 1
  return "c" .. lib.seq.category
end

-- Find a category record by id. Returns the record or nil.
function categories.get(lib, id)
  for _, c in ipairs(lib.categories) do
    if c.id == id then return c end
  end
  return nil
end

-- Direct children of a category id, or the top-level categories when id is nil.
function categories.children(lib, parent_id)
  local out = {}
  for _, c in ipairs(lib.categories) do
    if c.parent == parent_id then out[#out + 1] = c end
  end
  return out
end

-- Add a category. parent_id nil => top level; otherwise a sub-category of that
-- parent, which must itself be top-level (the tree is two levels only).
-- Returns the new category record.
function categories.add(lib, name, parent_id)
  if blank(name) then
    error("category name cannot be empty")
  end
  if parent_id ~= nil then
    local parent = categories.get(lib, parent_id)
    if not parent then
      error("parent category does not exist: " .. tostring(parent_id))
    end
    if parent.parent ~= nil then
      error("categories can only be two levels deep")
    end
  end
  local color = categories.PALETTE[(#lib.categories % #categories.PALETTE) + 1]
  local record = {
    id = next_id(lib),
    name = name,
    parent = parent_id, -- nil for top-level
    color = color,
  }
  table.insert(lib.categories, record)
  return record
end

-- Rename a category in place. Id and colour are untouched, so sound records and
-- swatches are unaffected.
function categories.rename(lib, id, new_name)
  if blank(new_name) then
    error("category name cannot be empty")
  end
  local c = categories.get(lib, id)
  if not c then error("category does not exist: " .. tostring(id)) end
  c.name = new_name
  return c
end

-- Remove an empty category. Refuses if it still has sub-categories or any sound
-- filed under it. Reparenting or trashing the contents is Phase 2 work; until
-- then this fails loud rather than orphaning sounds.
function categories.remove(lib, id)
  local c = categories.get(lib, id)
  if not c then error("category does not exist: " .. tostring(id)) end
  if #categories.children(lib, id) > 0 then
    error("cannot delete a category that still has sub-categories")
  end
  for _, s in ipairs(lib.sounds) do
    if s.category == id or s.subcategory == id then
      error("cannot delete a category that still contains sounds")
    end
  end
  for i, cat in ipairs(lib.categories) do
    if cat.id == id then
      table.remove(lib.categories, i)
      return
    end
  end
end

-- Sidebar/header totals: how many sounds sit in the whole library, how many
-- have no category, and how many sit under each category id.
--
-- A TOP-LEVEL category's count folds in every sound filed in its sub-categories
-- too; a SUB-category's count is only its own direct sounds. That fold is
-- nearly free here: a sound's `category` field already holds the top-level id
-- even when it is filed in a sub (see core/search.lua's note on `in_view`), so
-- counting straight off `category` IS the top-level total already — no
-- separate descendant walk needed. One pass over the sounds, one over the
-- categories: O(sounds + categories), never O(sounds * categories).
--
-- A sound whose `category` no longer names a real category is folded into
-- `uncat` rather than raising — this is a display total, not a data gate.
-- That id can only be dangling through a hand-edited or corrupted file:
-- categories.remove refuses to delete a category still holding sounds, so the
-- running tool can never produce this itself. A dangling `subcategory` on an
-- otherwise-valid sound is dropped the same way: the sound still counts
-- toward its real top-level category, it just lands in no sub bucket.
function categories.counts(lib)
  local by_id = {}
  for _, c in ipairs(lib.categories) do
    by_id[c.id] = 0
  end

  local all, uncat = 0, 0
  for _, s in ipairs(lib.sounds) do
    all = all + 1
    if s.category == nil or by_id[s.category] == nil then
      uncat = uncat + 1
    else
      by_id[s.category] = by_id[s.category] + 1
      if s.subcategory ~= nil and by_id[s.subcategory] ~= nil then
        by_id[s.subcategory] = by_id[s.subcategory] + 1
      end
    end
  end

  return { all = all, uncat = uncat, by_id = by_id }
end

return categories
