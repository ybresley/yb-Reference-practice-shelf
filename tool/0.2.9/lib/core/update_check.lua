-- update_check: the pure half of the in-app update feature (RESEARCH.md "In-app
-- update check + one-button update via ReaPack"). Handed a ReaPack catalog
-- (index.xml) as plain text, it answers the badge's one question: what is the
-- newest version published for this package, and is it newer than what's
-- installed? The fetch, the registry reads and the actual update live in
-- lib/updater.lua — this layer never touches reaper.* and is fully unit-tested.
--
-- Parsing is a targeted scan, not a real XML parser, on purpose: the catalog is
-- machine-generated (reapack-index, or the same shape written by hand) with a
-- fixed nesting — index > category > reapack > version — and double-quoted
-- attributes. Anything that doesn't look like that simply yields no versions,
-- which the caller must treat as "no badge", never as an error: a broken or
-- half-downloaded catalog has to fail silent (the design's rule for every part
-- of the check).

local update_check = {}

-- One attribute out of a tag's attribute text. The leading %s anchors the match
-- to a whole attribute name — ` name="…"` can never match inside ` filename="…"`.
-- (The captures below always include the space before the first attribute.)
local function attr(s, name)
  return s:match("%s" .. name .. '%s*=%s*"([^"]*)"')
end

-- A version string split into comparable segments: runs of digits become
-- numbers, runs of letters become lowercased strings, everything else (dots,
-- dashes, underscores) just separates. "1.10rc2" -> { 1, 10, "rc", 2 }.
local function segments(v)
  local out = {}
  for num, alpha in tostring(v):gmatch("(%d*)(%a*)") do
    if num ~= "" then out[#out + 1] = tonumber(num) end
    if alpha ~= "" then out[#out + 1] = alpha:lower() end
  end
  return out
end

-- One segment pair. Two rules beyond plain ordering:
--   * an absent numeric segment counts as 0, so "1.0" == "1.0.0";
--   * letters rank BELOW numbers and below absence, so "1.0beta" < "1.0" and
--     "1.0beta" < "1.0.1" — the pre-release reading, and the safe one: a beta
--     left in the catalog must never out-rank the release already installed.
local function cmp_seg(x, y)
  local xs, ys = type(x) == "string", type(y) == "string"
  if xs ~= ys then
    return xs and -1 or 1
  end
  if not xs then
    x, y = x or 0, y or 0
  end
  if x == y then return 0 end
  return x < y and -1 or 1
end

-- Compare two version strings: -1 / 0 / 1 as a is older / same / newer than b.
-- Matches ReaPack's own ReaPack_CompareVersions on the plain numeric versions
-- this project ships (the U2 prototype cases are pinned in the spec); ReaPack's
-- own call remains the authority REAPER-side, where it exists — this exists so
-- the pure layer can pick a newest without an API handle.
function update_check.compare(a, b)
  local sa, sb = segments(a), segments(b)
  for i = 1, math.max(#sa, #sb) do
    local c = cmp_seg(sa[i], sb[i])
    if c ~= 0 then return c end
  end
  return 0
end

-- Every version name the catalog lists for one package, in document order.
-- `package_file` is the package's file name exactly as ReaPack's registry
-- reports it (GetEntryInfo return #4) — which is exactly how this catalog
-- spelled it, so the match is byte-exact. `category` (registry return #3)
-- narrows the search when given; nil searches every category.
--
-- Known limits, accepted for a catalog we generate ourselves: attributes must
-- be double-quoted, and a changelog CDATA containing a literal "</reapack>"
-- would end the package's block early.
function update_check.versions(xml, package_file, category)
  local out = {}
  if type(xml) ~= "string" or type(package_file) ~= "string" then return out end
  for cat_attrs, cat_body in xml:gmatch("<category(%s[^>]*)>(.-)</category>") do
    if category == nil or attr(cat_attrs, "name") == category then
      for rp_attrs, rp_body in cat_body:gmatch("<reapack(%s[^>]*)>(.-)</reapack>") do
        if attr(rp_attrs, "name") == package_file then
          for v_attrs in rp_body:gmatch("<version(%s[^>]*)>") do
            local name = attr(v_attrs, "name")
            if name and name ~= "" then out[#out + 1] = name end
          end
        end
      end
    end
  end
  return out
end

-- The newest of a list of version names — by compare(), never by list position:
-- catalog order is whatever the generator wrote, not a promise.
function update_check.newest(list)
  local best
  for _, v in ipairs(list or {}) do
    if not best or update_check.compare(v, best) > 0 then best = v end
  end
  return best
end

-- The badge's answer: the newest catalog version STRICTLY newer than
-- `installed`, or nil — including nil for every failure shape (no catalog, the
-- package missing from it, a published rollback older than what's installed).
-- "Newer or nothing" means a bad state can only ever cost the badge, never
-- show a false one.
function update_check.newer_available(xml, package_file, category, installed)
  if type(installed) ~= "string" or installed == "" then return nil end
  local best = update_check.newest(update_check.versions(xml, package_file, category))
  if best and update_check.compare(best, installed) > 0 then return best end
  return nil
end

return update_check
