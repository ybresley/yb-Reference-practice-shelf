-- browser: the LIBRARY popup — curation lives here. Rebuilt 2026-07-29 after the
-- full Lavish design review ("library panel redesign"): a full-bleed chrome
-- sidebar (pinned views, tight rows, per-category counts, a passive + New
-- category button on its bottom edge), a search-left / actions-right toolbar,
-- clean table rows (no category dots — the sidebar echoes the hovered/selected
-- row's category instead), a pin column, the audition strip at the BOTTOM, and
-- an info row (tech facts + the PREVIEW master fader) under it. The old
-- status/search/count row is gone: search lives in the toolbar, counts live in
-- the sidebar, and status/hints live in the strip's idle face / the info row.
--
-- A ui/ module: it may call reaper.ImGui_* only.

local theme = require("ui.theme")
local categories = require("core.categories")
local transport = require("ui.transport")
local waveform = require("ui.waveform")
local icons = require("ui.icons")
local dropzone = require("ui.dropzone")
local popups = require("ui.popups")
local T = theme.tokens
local M = theme.metrics

local browser = {}

-- Feature detection, checked once at load (same idiom as HAS_COL_HOVER below).
-- Each absent capability degrades on its own: no child padding = flush content,
-- no resize flag = fixed sidebar width, no custom headers = a blank pin header,
-- no context-window popups = the + New category button is the only entry point.
local HAS_CHILD_PAD    = reaper.ImGui_ChildFlags_AlwaysUseWindowPadding ~= nil
local HAS_CHILD_RESIZE = reaper.ImGui_ChildFlags_ResizeX ~= nil
local HAS_TABLE_HEADER = reaper.ImGui_TableHeader ~= nil and reaper.ImGui_TableRowFlags_Headers ~= nil
local HAS_SB_CTX       = reaper.ImGui_BeginPopupContextWindow ~= nil
  and reaper.ImGui_PopupFlags_MouseButtonRight ~= nil and reaper.ImGui_PopupFlags_NoOpenOverItems ~= nil
local HAS_TEXT_EX      = reaper.ImGui_DrawList_AddTextEx ~= nil

--------------------------------------------------------------- group rows

-- Grouping rows (categories and the two library views) are a different SPECIES
-- from sound rows, and they look it: SMALL-CAPS name at GROUP_FS, vs a sound's
-- mixed-case filename at the body size. Colour carries the meaning (sidebar
-- redesign, 2026-07-27, reconfirmed by the 2026-07-29 review):
--   coloured caps = a category (sub-categories wear a dimmer parent shade)
--   white caps    = a view — All sounds / Uncategorised, the ONLY uncoloured rows
-- Selection never recolours a name: the row fill alone marks the active view.
-- No swatches and no per-row dots anywhere — colour lives in the name itself.
--
-- Both views are TEXT_PRIMARY white as of 2026-08-01 (user's call). They used to
-- be two different grays, which made Uncategorised — a row you reach for all the
-- time — the hardest thing in the sidebar to read, and made a category whose
-- stored colour was gray indistinguishable from a view (that gray is gone too;
-- see the schema's v1 -> v2 migration).

-- One grouping row. opts:
--   color    - tint the caps name (categories; theme.dim(parent) for subs).
--              Absent = a view, drawn white.
--   selected - the active-view fill (fill only, the colour stands)
--   count    - right-aligned sound count, in the row's OWN colour (2026-08-01:
--              it used to be a flat dim gray on every row, which read as
--              unrelated to the name it belongs to)
--   echo     - the sidebar echo (2026-07-29): the category of the sound the
--              table's cursor is on lights up here — a quiet fill, weaker than
--              selection, so "where does this sound live?" is answered without
--              any mark on the row itself
local function group_row(ctx, id, name, opts)
  opts = opts or {}
  local pushed = theme.push_small_font(ctx)
  local col = opts.color or T.TEXT_PRIMARY
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col)
  -- upper() is byte-wise, so non-ASCII letters simply keep their case — fine
  -- for a purely visual treatment.
  reaper.ImGui_Selectable(ctx, name:upper() .. "##" .. id, opts.selected or false)
  -- The click is read on PRESS, not on the Selectable's own release (2026-08-01:
  -- the sidebar felt a beat behind). Two waits stack otherwise — waiting for the
  -- button to come back up, then one more frame for the entry script to rebuild
  -- the list — and the row is what the user is aiming at, so there is nothing a
  -- release could still cancel. Selecting on press is what file lists do.
  local clicked = reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 0)
  reaper.ImGui_PopStyleColor(ctx)

  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  -- The echo fill is drawn over the row (translucent, so the name reads through
  -- it) rather than as a second Selectable state — ImGui has no "half selected".
  if opts.echo and not opts.selected then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, T.FILL_TERTIARY, 4)
  end
  if opts.count then
    local text = tostring(opts.count)
    local tw, th = reaper.ImGui_CalcTextSize(ctx, text) -- small font still pushed
    reaper.ImGui_DrawList_AddText(dl, x1 - tw - 6, (y0 + y1) * 0.5 - th * 0.5, col, text)
  end

  if pushed then reaper.ImGui_PopFont(ctx) end
  return clicked
end

-- Transient edit scratch (in-progress popup text, which popup to open next frame).
-- View-only state that never belongs in the shared library — kept here, not on
-- `state`, so nothing outside ui/ sees it.
local edit = { new_cat = "", new_sub = "", rename = "", query = "", sub_parent = nil, rename_id = nil, open = nil,
  -- The sound a delete confirmation is about. Kept apart from `open` above, which
  -- belongs to the sidebar: the sidebar is drawn first each frame and would consume
  -- a request meant for a popup that lives in the list panel.
  del = nil,
  -- Settings: open request (the modal lives in the main panel) and the typed
  -- library-path fallback used when there's no OS folder picker.
  settings_open = false, libdir = "" }

-- The sidebar echo (2026-07-29): which category row lights up because the table's
-- cursor (hover, else the browsed selection) sits on one of its sounds. Written
-- by draw_sound_list each frame and read by draw_sidebar on the NEXT frame — the
-- sidebar draws first, so the echo always trails by one frame, which is
-- imperceptible and keeps the draw order simple. UI-local like `edit`.
local echo = { cat = nil, sub = nil, unc = false }

local function set_echo(s)
  if s.subcategory then
    echo.sub = s.subcategory
  elseif s.category then
    echo.cat = s.category
  else
    echo.unc = true
  end
end

local function clear_echo()
  echo.cat, echo.sub, echo.unc = nil, nil, false
end

--------------------------------------------------------------- small helpers

local function fmt_duration(sec)
  local s = math.floor((sec or 0) + 0.5)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function fmt_channels(n)
  return tostring(n or 0) -- raw channel count (1 = mono, 2 = stereo)
end

-- The three measurements the Loudness column can show, in the order the menu lists
-- them. `field` matches the record field the analysis stores. The header label is
-- kept short so the column never has to grow to fit it; the menu spells each out.
local LOUD_UNITS = {
  { field = "lufs_i",     header = "LUFS-I", menu = "Overall loudness (LUFS-I)" },
  { field = "lufs_m_max", header = "LUFS-M", menu = "Loudest moment (LUFS-M max)" },
  { field = "true_peak",  header = "dBTP",   menu = "True peak (dBTP)" },
}

local function loud_unit(state)
  for _, u in ipairs(LOUD_UNITS) do
    if u.field == state.loud_unit then return u end
  end
  return LOUD_UNITS[1]
end

-- The Loudness cell. Three honest states, no layout shift between them: a measured
-- number, "…" while it is still queued behind the background analysis, and "—" when
-- the file couldn't be measured (or holds nothing measurable, like pure silence).
local function fmt_loudness(s, field)
  if s.analysis ~= "done" then
    return s.analysis == "failed" and "—" or "\u{2026}"
  end
  if type(s[field]) ~= "number" then return "—" end
  return string.format("%.1f", s[field])
end

local function view_is(state, scope, id)
  local v = state.view
  return v.scope == scope and (id == nil or v.id == id)
end

-- Which category/sub a sound dropped in the current view should be filed under.
local function view_target(lib, v)
  if v.scope == "category" then return v.id, nil end
  if v.scope == "subcategory" then
    local sub = categories.get(lib, v.id)
    if sub then return sub.parent, sub.id end
  end
  return nil, nil -- "all" / "uncategorised" -> Uncategorised
end

-- A number in a table cell, right-aligned so digits stack by place value (the
-- one alignment every reference app agrees on — 2026-07-29 review) and centred
-- in `row_h`, the row's full height — a row is taller than one line of text
-- (see draw_sound_list), so laid-out text would otherwise sit at its top edge
-- while the name beside it is centred.
local function num_cell(ctx, color, text, row_h)
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  if avail > tw then
    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + avail - tw)
  end
  if row_h and row_h > th then
    reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + (row_h - th) * 0.5)
  end
  reaper.ImGui_TextColored(ctx, color, text)
end

-- How much of the pin column's right edge belongs to ImGui's sort arrow, now
-- that the column sorts (2026-08-01). The arrow is ~0.65 of the font size plus
-- its inner spacing; reserved ALWAYS, not only while that column is the sorted
-- one, so the pushpins never shift when the sort changes.
local function pin_arrow_zone(ctx)
  local fs = reaper.ImGui_GetFontSize(ctx)
  local inner = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemInnerSpacing()))
  return math.floor(fs * 0.65) + inner * 2
end

-- The pushpin, painted over the item submitted just before this call, centred in
-- the part of it left of the sort arrow. Falls back to the drawn shape when the
-- Lucide font is absent.
local function pin_glyph(ctx, font, color, size, inset_right)
  inset_right = inset_right or 0
  if not icons.paint_over_item(ctx, font, "pin",
      { glyph_size = size, color = color, inset_right = inset_right }) then
    local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    icons.draw_pin(reaper.ImGui_GetWindowDrawList(ctx),
      (x0 + x1 - inset_right) * 0.5, (y0 + y1) * 0.5, color)
  end
end

--------------------------------------------------------------- sidebar

-- Right-click menu for a category row. Add-sub/rename can't OpenPopup directly
-- (they run inside the closing context popup), so they stash which popup to open
-- and the entry data; draw_sidebar opens it at its own scope.
local function category_menu(ctx, cat)
  local action
  if reaper.ImGui_BeginPopupContextItem(ctx, "ctx_" .. cat.id) then
    if reaper.ImGui_MenuItem(ctx, "Add sub-category\u{2026}") then
      edit.sub_parent, edit.new_sub, edit.open = cat.id, "", "add_sub"
    end
    if reaper.ImGui_MenuItem(ctx, "Rename\u{2026}") then
      edit.rename_id, edit.rename, edit.open = cat.id, cat.name, "rename_cat"
    end
    if reaper.ImGui_MenuItem(ctx, "Delete") then
      action = { type = "remove_category", id = cat.id }
    end
    reaper.ImGui_EndPopup(ctx)
  end
  return action
end

local function subcategory_menu(ctx, sub)
  local action
  if reaper.ImGui_BeginPopupContextItem(ctx, "ctx_" .. sub.id) then
    if reaper.ImGui_MenuItem(ctx, "Rename\u{2026}") then
      edit.rename_id, edit.rename, edit.open = sub.id, sub.name, "rename_cat"
    end
    if reaper.ImGui_MenuItem(ctx, "Delete") then
      action = { type = "remove_category", id = sub.id }
    end
    reaper.ImGui_EndPopup(ctx)
  end
  return action
end

-- Right-click on empty sidebar space: the secondary way to add a category (the
-- passive button below is the primary). NoOpenOverItems keeps the row menus in
-- charge of their own rows.
local function sidebar_context(ctx)
  if not HAS_SB_CTX then return end
  if reaper.ImGui_BeginPopupContextWindow(ctx, "sb_ctx",
      reaper.ImGui_PopupFlags_MouseButtonRight() | reaper.ImGui_PopupFlags_NoOpenOverItems()) then
    if reaper.ImGui_MenuItem(ctx, "New category\u{2026}") then
      edit.new_cat, edit.open = "", "add_cat"
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

-- The category list that scrolls between the pinned views. Its own child so All
-- sounds (above) and Uncategorised + the New-category button (below) stay put at
-- any list length (2026-07-29 review — "Uncategorised will end up hidden below").
local function draw_categories(ctx, state)
  local action
  local lib = state.library
  local counts = state.counts

  for _, cat in ipairs(categories.children(lib, nil)) do
    if group_row(ctx, "cat_" .. cat.id, cat.name,
        { color = cat.color, selected = view_is(state, "category", cat.id),
          count = counts and counts.by_id[cat.id],
          echo = echo.cat == cat.id }) then
      action = { type = "select_view", view = { scope = "category", id = cat.id } }
    end
    if dropzone.sound_drop_target(ctx, state) then
      action = { type = "refile_sound", id = state.drag.sound_id, category = cat.id, wins_release = true }
    end
    action = dropzone.read_file_drop(ctx, state, { category = cat.id }) or action
    action = category_menu(ctx, cat) or action

    for _, sub in ipairs(categories.children(lib, cat.id)) do
      reaper.ImGui_Indent(ctx, M.INDENT)
      -- A sub wears a DIMMER shade of the parent's colour (never its own): the
      -- family reads at a glance, and the parent stays the strongest row.
      if group_row(ctx, "sub_" .. sub.id, sub.name,
          { color = theme.dim(cat.color), selected = view_is(state, "subcategory", sub.id),
            count = counts and counts.by_id[sub.id],
            echo = echo.sub == sub.id }) then
        action = { type = "select_view", view = { scope = "subcategory", id = sub.id } }
      end
      if dropzone.sound_drop_target(ctx, state) then
        action = { type = "refile_sound", id = state.drag.sound_id, category = cat.id, subcategory = sub.id, wins_release = true }
      end
      action = dropzone.read_file_drop(ctx, state, { category = cat.id, subcategory = sub.id }) or action
      action = subcategory_menu(ctx, sub) or action
      reaper.ImGui_Unindent(ctx, M.INDENT)
    end
  end

  sidebar_context(ctx) -- this child's own empty space (the sidebar shell has its own)
  return action
end

local function draw_sidebar(ctx, state)
  local action
  local counts = state.counts

  -- Rows sit tight (2026-07-29, "we don't need an empty row between
  -- subcategories") — only the two deliberate view/category separators breathe.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8, M.SB_ROW_GAP)

  -- Pinned top: All sounds. White caps = a view; every category is coloured.
  if group_row(ctx, "view_all", "All sounds",
      { selected = view_is(state, "all"), count = counts and counts.all }) then
    action = { type = "select_view", view = { scope = "all" } }
  end
  -- Files dropped on All sounds join the library at large — no category, same
  -- landing spot as the Uncategorised row (2026-08-01, user's call: every
  -- sidebar row should catch a drop, not just the categories).
  action = dropzone.read_file_drop(ctx, state) or action

  reaper.ImGui_Dummy(ctx, 0, 8)

  -- How much height the pinned bottom zone needs, measured at the small size the
  -- zone actually draws at: the Uncategorised row, the hairline with its
  -- breathing room, and the New-category button.
  local small = theme.push_small_font(ctx)
  local row_h = reaper.ImGui_GetTextLineHeight(ctx)
  local btn_h = reaper.ImGui_GetFrameHeight(ctx)
  if small then reaper.ImGui_PopFont(ctx) end
  -- Everything the pinned zone stacks below the category child: the two 4px
  -- Dummies, four ItemSpacing steps, the row, the button, plus 2px slack (too
  -- small clips the button's bottom; slightly too large is a harmless gap).
  local bottom_h = row_h + btn_h + 8 + 4 * M.SB_ROW_GAP + 2

  local avail_h = select(2, reaper.ImGui_GetContentRegionAvail(ctx))
  local cats_h = avail_h - bottom_h
  if cats_h < row_h then cats_h = row_h end
  -- EndChild only inside the `if`: ReaImGui's contract (see app.lua) — a fully
  -- clipped child returns false WITHOUT opening.
  if reaper.ImGui_BeginChild(ctx, "cats", 0, cats_h) then
    action = draw_categories(ctx, state) or action
    reaper.ImGui_EndChild(ctx)
  end

  -- Pinned bottom: Uncategorised (white caps like All sounds — the "everything
  -- else" bucket), also the no-category drop target, exactly as when it lived at
  -- the list's end.
  if group_row(ctx, "view_unc", "Uncategorised",
      { selected = view_is(state, "uncategorised"),
        count = counts and counts.uncat, echo = echo.unc }) then
    action = { type = "select_view", view = { scope = "uncategorised" } }
  end
  if dropzone.sound_drop_target(ctx, state) then
    action = { type = "refile_sound", id = state.drag.sound_id, wins_release = true }
  end
  action = dropzone.read_file_drop(ctx, state) or action

  -- The + New category button, behind a full-width hairline on the sidebar's
  -- bottom edge (2026-07-29 review, option G1). Standard theme button colours
  -- (2026-08-01, user's call — the original ghost styling read as disabled);
  -- still the small font, so the pinned zone's height budget above holds.
  reaper.ImGui_Dummy(ctx, 0, 4)
  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww = select(1, reaper.ImGui_GetWindowSize(ctx))
  local _, ly = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
    wx, ly, wx + ww, ly, T.STROKE_TERTIARY, 1)
  reaper.ImGui_Dummy(ctx, 0, 4)
  local small_btn = theme.push_small_font(ctx)
  local bw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  if reaper.ImGui_Button(ctx, "+ New category##newcat", bw) then
    edit.new_cat = ""
    reaper.ImGui_OpenPopup(ctx, "add_cat")
  end
  -- Files dropped on the button create a category AND file the files into it,
  -- one motion (2026-08-01, user's call). The entry script names it after the
  -- folder the files came from.
  action = dropzone.read_file_drop(ctx, state, { action_type = "import_new_category" }) or action
  if small_btn then reaper.ImGui_PopFont(ctx) end

  sidebar_context(ctx) -- empty space around the pinned rows

  -- Open a context-menu-requested popup (deferred so it isn't nested in the menu).
  if edit.open then
    reaper.ImGui_OpenPopup(ctx, edit.open)
    edit.open = nil
  end

  local newcat = popups.edit_popup(ctx, edit, "add_cat", "New category", "new_cat")
  if newcat then action = { type = "add_category", name = newcat } end
  local newsub = popups.edit_popup(ctx, edit, "add_sub", "New sub-category", "new_sub")
  if newsub then action = { type = "add_subcategory", parent = edit.sub_parent, name = newsub } end
  local renamed = popups.edit_popup(ctx, edit, "rename_cat", "Rename", "rename")
  if renamed then action = { type = "rename_category", id = edit.rename_id, name = renamed } end

  reaper.ImGui_PopStyleVar(ctx, 1)
  return action
end

--------------------------------------------------------------- sound list

-- Column user-ids (passed to TableSetupColumn) mapped to the sort keys core
-- understands. Reading the id, not the position, keeps sorting correct even if
-- the user reorders columns later. The pin column sorts too since 2026-08-01 —
-- core needs this project's pinned set handed in for it (see core/search.sort).
local SORT_COLS = { [1] = "name", [2] = "dur", [3] = "ch", [4] = "loud", [5] = "pin" }
local LOUD_COL = 3 -- 0-based column index of the Loudness column

-- Feature detection for the "Show in library" scroll (checked once at load, the
-- house idiom): without it the row is still selected, it just isn't scrolled to.
local HAS_CLIPPER_INCLUDE = reaper.ImGui_ListClipper_IncludeItemByIndex ~= nil
  and reaper.ImGui_SetScrollHereY ~= nil
local HAS_PREFER_DESC = reaper.ImGui_TableColumnFlags_PreferSortDescending ~= nil

-- The last "Show in library" request this table has already acted on. UI-local
-- scratch like `edit` and `echo`: the entry script counts requests up and never
-- has to be told when one has been served.
local revealed_seq = nil

-- Whether this ReaImGui can tell us a column is hovered. Without it (a much older
-- build) the header stays a plain header and the unit menu simply isn't offered —
-- the column still shows LUFS-I, nothing breaks.
local HAS_COL_HOVER = reaper.ImGui_TableColumnFlags_IsHovered ~= nil

-- The Loudness header's right-click menu, for switching which measurement the column
-- shows. Called once, INSIDE the table just before EndTable — NOT by hand-submitting
-- the header row, which crashed the tool on open.
--
-- `row_hovered` is true when the mouse is over one of the sound ROWS. A row already
-- carries its own right-click menu (Delete, via the full-width Name selectable), so
-- the unit menu must NOT also arm there — over a loudness cell the two would fight
-- and the row's Delete would win anyway. Restricting to "loudness column, but not a
-- row" leaves exactly the header, which is where the unit switch belongs.
--
-- The table is resizable, so right-clicking a header also arms ImGui's own "size
-- column to fit" menu. We open ours in the same frame; the last popup opened at a
-- level is the one shown. (Whether that reliably beats the built-in menu is the one
-- thing only a real REAPER right-click on the header can confirm.)
local function draw_loud_menu(ctx, state, row_hovered)
  local action
  local unit = loud_unit(state)

  if HAS_COL_HOVER and not row_hovered and reaper.ImGui_IsMouseClicked(ctx, 1)
    and (reaper.ImGui_TableGetColumnFlags(ctx, LOUD_COL) & reaper.ImGui_TableColumnFlags_IsHovered()) ~= 0 then
    reaper.ImGui_OpenPopup(ctx, "loud_unit")
  end

  if reaper.ImGui_BeginPopup(ctx, "loud_unit") then
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "SHOW")
    for _, u in ipairs(LOUD_UNITS) do
      if reaper.ImGui_MenuItem(ctx, u.menu, nil, u.field == unit.field) then
        action = { type = "set_loud_unit", field = u.field }
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end

  return action
end

-- The one confirmation a delete gets. Modal, so it can't be left half-answered
-- behind the list, and drawn after the table so it isn't tied to a row that the
-- clipper may scroll out of existence mid-decision.
local function draw_delete_confirm(ctx)
  local action
  local del = edit.del
  if not del then return nil end

  if del.open then
    reaper.ImGui_OpenPopup(ctx, "confirm_delete")
    del.open = false
  end

  if reaper.ImGui_BeginPopupModal(ctx, "confirm_delete", nil,
      reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, string.format("Delete \"%s\"?", del.name))
    reaper.ImGui_Dummy(ctx, 0, 4)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY,
      "It moves to the trash folder inside your library, with everything")
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY,
      "you've set on it, so you can put it back later.")
    reaper.ImGui_Dummy(ctx, 0, 8)
    if reaper.ImGui_Button(ctx, "Delete", M.POPUP_BTN_W) then
      action = { type = "delete_sound", id = del.id }
      edit.del = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Cancel", M.POPUP_BTN_W) then
      edit.del = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  elseif not del.open then
    -- Dismissed with Escape rather than a button: forget the sound, or the next
    -- right-click would find a stale one waiting.
    edit.del = nil
  end

  return action
end

local function draw_sound_list(ctx, state, res)
  local action
  local sounds = state.visible_sounds
  local unit = loud_unit(state)
  local font = res.icon_font

  -- The sidebar echo for this frame: rebuilt BEFORE the table so a table that
  -- fails to open (a clipped, zero-size main panel) darkens the echo rather
  -- than leaving the last frame's row lit for as long as the clipped state
  -- lasts (Codex, 2026-07-29 review). The browsed sound's category is the
  -- resting state; the row loop below overrides it with whichever row the
  -- mouse is on. The sidebar has already drawn (it read LAST frame's echo),
  -- so rebuilding here is race-free.
  clear_echo()
  if state.browse then set_echo(state.browse) end

  -- Flat rows (2026-07-29 review): no zebra striping (RowBg dropped — ImGui's
  -- default alt-row tint was faint zebra) and no vertical column lines. ImGui
  -- force-enables inner vertical borders whenever a table is Resizable, so the
  -- flag alone can't remove them — their COLOUR is pushed to transparent
  -- instead; the resize grab zones still work, invisibly. The header bg goes
  -- transparent too: the one hairline drawn under the header row (below) is
  -- all the separation the design wants.
  local flags = reaper.ImGui_TableFlags_Resizable()
    | reaper.ImGui_TableFlags_ScrollY()
    | reaper.ImGui_TableFlags_Sortable()

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderLight(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderStrong(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableHeaderBg(), 0)

  -- The selected row's fill used to bleed over the rows above and below it
  -- (reported 2026-08-01). ImGui grows a Selectable's rectangle by ItemSpacing.y
  -- — half above, half below — so that a LIST of them has no seams; inside a
  -- table, where rows already sit flush against each other, that overhang lands
  -- squarely on the neighbours. These two are pushed around the row Selectable
  -- ONLY (see the loop below), never across the whole table: held open they'd
  -- also land on the right-click menus submitted inside it, and the same menu
  -- would then look different depending on where it was opened from.
  local pad_y = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding()))
  local spacing_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))

  -- outer height 0 = fill the wrapping child region (see draw_main).
  if not reaper.ImGui_BeginTable(ctx, "sounds", 5, flags, 0, 0) then
    reaper.ImGui_PopStyleColor(ctx, 3)
    return nil
  end

  -- 5th arg is the column's stable user-id (see SORT_COLS). Name sorts by default.
  reaper.ImGui_TableSetupColumn(ctx, "Name",
    reaper.ImGui_TableColumnFlags_WidthStretch() | reaper.ImGui_TableColumnFlags_DefaultSort(), 0, 1)
  reaper.ImGui_TableSetupColumn(ctx, "Dur", reaper.ImGui_TableColumnFlags_WidthFixed(), M.COL_DUR_W, 2)
  reaper.ImGui_TableSetupColumn(ctx, "Ch", reaper.ImGui_TableColumnFlags_WidthFixed(), M.COL_CH_W, 3)
  reaper.ImGui_TableSetupColumn(ctx, unit.header, reaper.ImGui_TableColumnFlags_WidthFixed(), M.COL_LOUD_W, 4)
  -- The pin column (2026-07-29 review): pinned state moves out of the name cell
  -- into its own slim end column, labelled by a pushpin in the header — each
  -- mark now has one home, and nothing shifts when pinned toggles.
  -- Sortable since 2026-08-01, preferring DESCENDING so the first click on it
  -- brings the pinned sounds to the TOP (ascending would bury them, which is
  -- never what "sort by pinned" means).
  local pin_flags = reaper.ImGui_TableColumnFlags_WidthFixed()
  if HAS_PREFER_DESC then pin_flags = pin_flags | reaper.ImGui_TableColumnFlags_PreferSortDescending() end
  reaper.ImGui_TableSetupColumn(ctx, "##pin", pin_flags, M.PIN_COL_W, 5)
  reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)

  -- The pushpins (header and rows alike) centre in the part of the pin column
  -- left of the sort arrow, so the arrow has somewhere to go and the pins keep
  -- one axis whether or not that column is the one sorting.
  local arrow_zone = pin_arrow_zone(ctx)
  -- One row height for the whole table: the control height every button and
  -- input already uses, so a list row and a toolbar button read as the same
  -- scale. The Name cell asks for it explicitly (that is what the highlight
  -- fills); the cell padding above and below is what separates one row's
  -- highlight from the next.
  local row_h = reaper.ImGui_GetFrameHeight(ctx) - pad_y * 2
  if row_h < reaper.ImGui_GetTextLineHeight(ctx) then row_h = reaper.ImGui_GetTextLineHeight(ctx) end

  -- Header row, submitted by hand when the build allows it so the pin column's
  -- header can be the glyph itself; otherwise the stock row (blank pin header).
  if HAS_TABLE_HEADER then
    reaper.ImGui_TableNextRow(ctx, reaper.ImGui_TableRowFlags_Headers())
    reaper.ImGui_TableSetColumnIndex(ctx, 0); reaper.ImGui_TableHeader(ctx, "Name")
    local ux0, _ = reaper.ImGui_GetItemRectMin(ctx)
    reaper.ImGui_TableSetColumnIndex(ctx, 1); reaper.ImGui_TableHeader(ctx, "Dur")
    reaper.ImGui_TableSetColumnIndex(ctx, 2); reaper.ImGui_TableHeader(ctx, "Ch")
    reaper.ImGui_TableSetColumnIndex(ctx, 3); reaper.ImGui_TableHeader(ctx, unit.header)
    reaper.ImGui_TableSetColumnIndex(ctx, 4); reaper.ImGui_TableHeader(ctx, "##pin")
    pin_glyph(ctx, font, T.TEXT_QUATERNARY, 12, arrow_zone)
    -- The one hairline under the header (the flat-table separation the design
    -- calls for), spanning first column's left edge to last column's right.
    local ux1, uy1 = reaper.ImGui_GetItemRectMax(ctx)
    reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
      ux0, uy1 + 1.5, ux1, uy1 + 1.5, T.STROKE_TERTIARY, 1)
  else
    reaper.ImGui_TableHeadersRow(ctx)
  end

  -- Report the sort so the entry re-orders the cached list (it ignores a repeat of
  -- the current sort, so this is safe to emit whenever ImGui flags it). We never
  -- emit a "cleared" sort: a columned table always keeps one, and toggling to no
  -- sort and back re-shuffled the rows for a frame — that was the list "flashing".
  if reaper.ImGui_TableNeedSort(ctx) then
    local ok, _, col_user_id, dir = reaper.ImGui_TableGetColumnSortSpecs(ctx, 0)
    -- Sort wins over a unit pick in the (practically impossible) frame that has
    -- both: reading the sort specs clears ImGui's "needs sorting" flag, so a
    -- dropped sort is lost for good, while a dropped unit pick is one more click.
    if ok and SORT_COLS[col_user_id] then
      action = { type = "set_sort", col = SORT_COLS[col_user_id],
        asc = dir == reaper.ImGui_SortDirection_Ascending() }
    end
  end

  -- Whether the mouse is over any sound row this frame. The row carries the Delete
  -- menu; the loudness-header menu (drawn after the loop) uses this to stay off the
  -- rows and confine itself to the header.
  local row_hovered = false

  -- A pending "Show in library" (see the entry script's show_in_library): find
  -- the row's place in the list ONCE, on the frame the request is new — the scan
  -- itself happens for a click, never per frame. Marked handled either way, so a
  -- sound that somehow isn't in this view can't make it scan again and again.
  local reveal_row
  if state.reveal_seq ~= revealed_seq then
    revealed_seq = state.reveal_seq
    if state.reveal_id then
      -- The reveal may have cleared a search that was hiding the row; the box's
      -- own buffer is UI-local, so it has to be told (typing is the only other
      -- thing that changes it, and this only fires on a reveal).
      edit.query = state.query
      for i, s in ipairs(sounds) do
        if s.id == state.reveal_id then reveal_row = i - 1; break end
      end
    end
  end

  local span = reaper.ImGui_SelectableFlags_SpanAllColumns()
  reaper.ImGui_ListClipper_Begin(res.clipper, #sounds)
  -- The clipper only submits what's on screen, and the row we're revealing is
  -- exactly the one that usually isn't — this makes it submit that row too, so
  -- there's something for SetScrollHereY to aim at.
  if reveal_row and HAS_CLIPPER_INCLUDE then
    reaper.ImGui_ListClipper_IncludeItemByIndex(res.clipper, reveal_row)
  end
  while reaper.ImGui_ListClipper_Step(res.clipper) do
    local first, last = reaper.ImGui_ListClipper_GetDisplayRange(res.clipper)
    for i = first, last - 1 do -- clipper range is 0-based; sounds is 1-based
      local s = sounds[i + 1]
      reaper.ImGui_TableNextRow(ctx)

      reaper.ImGui_TableNextColumn(ctx)
      -- A clean name, nothing else (2026-07-29 review): the category dot is gone
      -- — the sidebar echo answers "where does this sound live?" — and the pin
      -- marker moved to its own column at the row's end.
      --
      -- Browsing is its OWN selection, independent of the working view's armed
      -- reference (Phase 5.9) — this row must never touch state.selected*, or
      -- clicking through the library while comparing would silently retarget
      -- (and re-audition) whatever the user has armed there.
      --
      -- This selectable IS the row highlight, so the row's look is decided right
      -- here (explicit height) rather than by however tall one line of text
      -- happens to be. Zero vertical ItemSpacing while it is submitted stops
      -- ImGui growing its rectangle into the rows above and below — the bleed the
      -- user reported — and the text align centres the name inside the taller
      -- rectangle. Both popped immediately, so nothing else in the table (the
      -- right-click menus especially) inherits them.
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), spacing_x, 0)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_SelectableTextAlign(), 0, 0.5)
      local picked = reaper.ImGui_Selectable(ctx, s.name .. "##" .. s.id, state.browse_id == s.id, span, 0, row_h)
      reaper.ImGui_PopStyleVar(ctx, 2)
      if picked then
        action = { type = "browse_sound", id = s.id }
      end
      -- Scroll the revealed row into the middle of the list, on the one frame
      -- the request is fresh.
      if reveal_row == i and HAS_CLIPPER_INCLUDE then
        reaper.ImGui_SetScrollHereY(ctx, 0.5)
      end
      -- The Name selectable spans the whole row (SpanAllColumns), so its hover
      -- marks the whole row as hovered — that keeps the header menu off the rows
      -- AND feeds the sidebar echo.
      if reaper.ImGui_IsItemHovered(ctx) then
        row_hovered = true
        clear_echo()
        set_echo(s)
      end
      -- Holding a row and moving the mouse starts a drag: out to REAPER's timeline,
      -- or onto the working view's reference row to pin it. ImGui's own drag-and-drop
      -- can't leave the window, so all this reports is "a drag has begun" — where it
      -- lands is worked out when the mouse is let go.
      if state.deps.drag_out and not state.drag
        and reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, 0) then
        action = action or { type = "drag_sound", id = s.id }
      end
      -- Right-click the row: pin it to (or unpin it from) the current project, or
      -- delete it. Like the category menus, the delete confirmation can't be opened
      -- from in here (we're inside the closing menu) — stash which sound it's about
      -- and open it below, once the table is finished.
      local pinned = state.pins and state.pins.by_origin[s.id]
      if reaper.ImGui_BeginPopupContextItem(ctx, "row_" .. s.id) then
        if pinned then
          if reaper.ImGui_MenuItem(ctx, "Unpin") then
            action = { type = "unpin", id = pinned.id }
          end
        elseif reaper.ImGui_MenuItem(ctx, "Pin to this project") then
          action = { type = "pin_sound", id = s.id }
        end
        if reaper.ImGui_MenuItem(ctx, "Delete\u{2026}") then
          edit.del = { id = s.id, name = s.name, open = true }
        end
        reaper.ImGui_EndPopup(ctx)
      end

      reaper.ImGui_TableNextColumn(ctx)
      num_cell(ctx, T.TEXT_TERTIARY, fmt_duration(s.duration), row_h)

      reaper.ImGui_TableNextColumn(ctx)
      num_cell(ctx, T.TEXT_TERTIARY, fmt_channels(s.channels), row_h)

      reaper.ImGui_TableNextColumn(ctx)
      -- A real measurement reads as data (tertiary); "…"/"—" stay dimmer so an
      -- unmeasured row doesn't look like a value.
      local measured = s.analysis == "done" and type(s[unit.field]) == "number"
      num_cell(ctx, measured and T.TEXT_TERTIARY or T.TEXT_QUATERNARY,
        fmt_loudness(s, unit.field), row_h)

      reaper.ImGui_TableNextColumn(ctx)
      -- The pin cell: an accent pushpin when pinned (matched by origin id via
      -- state.pins.by_origin — the SAME lookup the menu above uses, never
      -- re-derived by name), nothing otherwise. The Dummy reserves the cell
      -- either way, so a pin appearing can't move a single pixel.
      local cw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
      reaper.ImGui_Dummy(ctx, cw, row_h)
      if pinned then
        pin_glyph(ctx, font, T.ACCENT, 13, arrow_zone)
      end
    end
  end

  -- Header right-click menu, still inside the table (it queries column hover) but
  -- after the rows, so it knows whether the mouse is over one. Always CALLED (its
  -- popup must be submitted every frame), then merged without clobbering an action
  -- an earlier row already reported.
  local loud_action = draw_loud_menu(ctx, state, row_hovered)
  action = action or loud_action

  reaper.ImGui_EndTable(ctx)
  reaper.ImGui_PopStyleColor(ctx, 3)

  local confirmed = draw_delete_confirm(ctx)
  action = action or confirmed

  return action
end

--------------------------------------------------------------- settings

-- The Settings page: a modal, opened from the gear button, that will grow one
-- section per setting area. First resident: the library folder. Changing it
-- OPENS the library living in the picked folder (or starts a fresh one there) —
-- it never moves sounds — so it doubles as "open a shared/second library".
local function draw_settings(ctx, state)
  local action

  if edit.settings_open then
    reaper.ImGui_OpenPopup(ctx, "Settings")
    edit.settings_open = false
    edit.libdir = state.library_dir -- the typed-path fallback starts from the current folder
  end

  if reaper.ImGui_BeginPopupModal(ctx, "Settings", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "LIBRARY")
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "Library folder \u{2014} where your sounds and library data live:")
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, state.library_dir)
    reaper.ImGui_Dummy(ctx, 0, 4)
    if state.deps.folder_picker then
      if reaper.ImGui_Button(ctx, "Change\u{2026}", M.POPUP_BTN_W + 20) then
        action = { type = "change_library_dir" }
      end
    else
      -- No OS folder picker on this install (js_ReaScriptAPI missing) — take a
      -- typed path instead of hiding the setting.
      reaper.ImGui_SetNextItemWidth(ctx, M.FIELD_W + 160)
      local _, v = reaper.ImGui_InputText(ctx, "##libdir", edit.libdir or "")
      edit.libdir = v
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Use this folder") and edit.libdir ~= "" then
        action = { type = "change_library_dir", dir = edit.libdir }
      end
    end
    reaper.ImGui_Dummy(ctx, 0, 2)
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "Changing the folder never moves or copies sounds \u{2014} the tool opens whatever")
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "library lives in the folder you pick, or starts a new one there. Your current")
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "library stays where it is; picking its folder again brings it back.")
    -- Working-view layout (decided 2026-07-30). Auto measures the room each
    -- frame and picks; the two explicit choices pin it. The override exists
    -- because Auto can only guess at how a particular dock is being used — it's
    -- the escape hatch, not the expected setting.
    reaper.ImGui_Dummy(ctx, 0, 12)
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "WORKING VIEW")
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "Layout \u{2014} where the transport controls sit:")
    reaper.ImGui_Dummy(ctx, 0, 4)
    local modes = {
      { id = "auto",    label = "Automatic",   tip = "Stack the controls under the waveform when there's height for it, and move them into a side column when there isn't." },
      { id = "stacked", label = "Stacked",     tip = "Always below the waveform. In a short dock the waveform gets a thin band." },
      { id = "column",  label = "Side column", tip = "Always beside the waveform. Falls back to stacked when the window is too small for a column." },
    }
    local current = state.layout or "auto"
    for i, m in ipairs(modes) do
      if i > 1 then reaper.ImGui_SameLine(ctx) end
      -- Fixed-width buttons, state shown by fill only (UI-stability rule): the
      -- selected one never changes size or label.
      local on = current == m.id
      if on then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), T.FILL_PRIMARY)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_PRIMARY)
      end
      if reaper.ImGui_Button(ctx, m.label .. "##layout_" .. m.id, M.POPUP_BTN_W + 20) then
        action = { type = "set_layout_mode", mode = m.id }
      end
      if on then reaper.ImGui_PopStyleColor(ctx, 2) end
      if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, m.tip) end
    end

    -- UPDATES (DESIGN "Distribution, updates & versioning", user-decided
    -- 2026-08-02): a version line, the one Update-now button, and a one-line
    -- disclosure — deliberately NO off switch (the user's call: the daily check
    -- is an anonymous catalog read that fails silently, so a switch would guard
    -- nothing real). All state lives in state.update (lib/updater.lua); this
    -- only says what's true and reports the button press.
    reaper.ImGui_Dummy(ctx, 0, 12)
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "UPDATES")
    reaper.ImGui_Separator(ctx)
    local u = state.update
    if not u or not u.enabled then
      -- Standing down. Only "repo_off" is a state an end user can reach (they
      -- disabled our repo inside ReaPack — respected, with the way back shown);
      -- the rest are dev copies and missing-ReaPack installs.
      local reason = u and u.disabled_reason
      if reason == "repo_off" then
        reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "Update checking is paused \u{2014} this tool's download source is disabled in ReaPack.")
        reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "Re-enable it under Extensions \u{2192} ReaPack \u{2192} Manage repositories, then reopen the tool.")
      elseif reason == "noapi" then
        reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "Update checking needs the ReaPack extension, which isn't installed.")
      else -- "dev" / "norepo": not a ReaPack-owned copy, or its repo record is unreadable
        reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "Update checking is off \u{2014} this copy wasn't installed through ReaPack.")
      end
    elseif u.phase == "done" then
      -- The row's post-update face: the files on disk are new, this running
      -- code is old (live-proven U7) — only a relaunch finishes the job.
      reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY,
        string.format("Updated to v%s \u{2014} close and reopen the tool to finish.", u.installed or "?"))
    else
      local vline = "v" .. (u.installed or "?")
      if u.available then vline = vline .. "  \u{00B7}  v" .. u.available .. " available" end
      reaper.ImGui_TextColored(ctx, u.available and T.TEXT_PRIMARY or T.TEXT_SECONDARY, vline)
      if u.pinned then
        -- Say WHY one click won't install it (U8: ReaPack's syncs silently skip
        -- a pinned package) instead of offering a button that fails mysteriously.
        reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "Updates are paused \u{2014} this tool is pinned in ReaPack.")
        reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "Right-click it in Extensions \u{2192} ReaPack \u{2192} Browse packages and untick \"Pin to current version\".")
      elseif u.available then
        reaper.ImGui_Dummy(ctx, 0, 4)
        if u.phase == "sync" then
          -- Same footprint as the live button (stable-geometry rule) with the
          -- pressed-out face: fill and text dimmed, clicks meaningless.
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), T.FILL_QUATERNARY)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.FILL_QUATERNARY)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.FILL_QUATERNARY)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_QUATERNARY)
          reaper.ImGui_Button(ctx, "Updating\u{2026}", M.POPUP_BTN_W + 20)
          reaper.ImGui_PopStyleColor(ctx, 4)
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "ReaPack is installing the update \u{2014} its progress window shows the details.")
          end
        else
          if reaper.ImGui_Button(ctx, "Update now", M.POPUP_BTN_W + 20) then
            action = { type = "start_update" }
          end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "ReaPack installs just this tool's update, then you close and reopen it.")
          end
        end
      end
      if u.phase == "failed_browser" then
        reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "The update didn't finish. ReaPack's package browser has opened showing this tool \u{2014}")
        reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "right-click its row and choose Update. If it offers none, run Extensions \u{2192} ReaPack \u{2192} Synchronize packages.")
      elseif u.phase == "failed_manual" then
        reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "The update couldn't be completed from here \u{2014} run Extensions \u{2192} ReaPack \u{2192} Synchronize packages instead.")
      end
      reaper.ImGui_Dummy(ctx, 0, 2)
      reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "Checks for a newer version once a day \u{2014} a tiny read of the tool's own download catalog.")
      reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "Nothing about you or your projects is sent.")
    end

    reaper.ImGui_Dummy(ctx, 0, 8)
    if reaper.ImGui_Button(ctx, "Close", M.POPUP_BTN_W) then reaper.ImGui_CloseCurrentPopup(ctx) end
    reaper.ImGui_EndPopup(ctx)
  end

  return action
end

--------------------------------------------------------------- main panel

-- Fallback guidance for the strip's idle face — what the old status row's
-- default hint used to say, updated for the labelled Add button.
local IDLE_HINT = "Click a sound to audition it \u{00B7} drag audio files here, or use Add sounds"

-- The info row's tech-details line ("48 kHz · 24-bit · WAV · stereo"), rebuilt
-- only when the browsed sound changes — never formatted per frame (frame-
-- allocation rule). Keyed on the info TABLE as well as the id (Codex,
-- 2026-07-29 review): browse_sound builds a fresh info table on every pick, so
-- re-picking the same row after its file came back (or went away) invalidates
-- the cache — an id-only key kept showing the old answer.
local tech = { id = nil, info = nil, text = nil }
local function tech_line(state)
  local s, info = state.browse, state.browse_info
  if not s then
    tech.id, tech.info, tech.text = nil, nil, nil
    return nil
  end
  if tech.id ~= s.id or tech.info ~= info then
    tech.id, tech.info = s.id, info
    if not info then
      tech.text = nil
    else
      local parts = {}
      if info.rate and info.rate > 0 then parts[#parts + 1] = string.format("%g kHz", info.rate / 1000) end
      if info.bits then parts[#parts + 1] = info.bits .. "-bit" end
      if info.format and info.format ~= "" then parts[#parts + 1] = info.format end
      local ch = info.channels or 0
      parts[#parts + 1] = ch == 1 and "mono" or (ch == 2 and "stereo" or (ch .. " ch"))
      tech.text = table.concat(parts, "  \u{00B7}  ")
    end
  end
  return tech.text
end

-- The magnifier inside the search field's left padding (SEARCH_ICON_PAD clears
-- it). Drawn over the just-submitted input item.
local function search_icon(ctx, font)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local _, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local cy = (y0 + y1) * 0.5
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local cp = icons.NAMES["search"]
  if font and cp then
    local gs = 14
    local glyph = utf8.char(cp)
    reaper.ImGui_PushFont(ctx, font, gs)
    local tw, th = reaper.ImGui_CalcTextSize(ctx, glyph)
    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_DrawList_AddTextEx(dl, font, gs,
      x0 + (M.SEARCH_ICON_PAD - tw) * 0.5, cy - th * 0.5, T.TEXT_TERTIARY, glyph)
  else
    icons.draw_search(dl, x0 + M.SEARCH_ICON_PAD * 0.5, cy, T.TEXT_TERTIARY)
  end
end

-- Toolbar (2026-07-29 review): search top-left on the list it filters; the
-- global actions top-right — Add sounds labelled (the toolbar's one primary
-- action earns words), folder + gear as borderless icons that only show a fill
-- on hover.
local function draw_toolbar(ctx, state, res)
  local action

  -- The search field: filled, no outline, magnifier embedded in its left
  -- padding, hint dimmer than typed text (theme's TextDisabled) — a native-tool
  -- search, not a web form.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), M.SEARCH_ICON_PAD, 6)
  reaper.ImGui_SetNextItemWidth(ctx, M.SEARCH_W)
  -- Local buffer drives the box immediately; the entry re-filters next frame.
  local _, q = reaper.ImGui_InputTextWithHint(ctx, "##search", "Search name or note", edit.query or "")
  reaper.ImGui_PopStyleVar(ctx, 2)
  search_icon(ctx, res.icon_font)
  if q ~= (edit.query or "") then
    edit.query = q
    action = { type = "set_query", query = q }
  end

  -- Right cluster, placed by the measure-then-push idiom (same as the old master
  -- fader). If a narrow window leaves no room the cluster stays put and clips —
  -- nothing jumps.
  reaper.ImGui_SameLine(ctx)
  local add_label = "+ Add sounds"
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local gap = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local btn = reaper.ImGui_GetFrameHeight(ctx)
  local add_w = select(1, reaper.ImGui_CalcTextSize(ctx, add_label)) + pad_x * 2
  local cluster_w = add_w + gap + btn + gap + btn
  local cx = reaper.ImGui_GetCursorPosX(ctx)
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local target = cx + avail - cluster_w
  if target > cx then reaper.ImGui_SetCursorPosX(ctx, target) end

  if reaper.ImGui_Button(ctx, add_label) then
    local cat, sub = view_target(state.library, state.view)
    action = { type = "pick", category = cat, subcategory = sub }
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, "Add sound files to the current view\u{2026}")
  end

  -- Borderless utility icons: flat on the surface, hover fill only.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0)
  reaper.ImGui_SameLine(ctx)
  if icons.button(ctx, res.icon_font, "libfolder", "folder",
      { tip = "Show the library folder (and its trash) in Explorer", fallback = icons.draw_folder }) then
    action = action or { type = "reveal_library" }
  end
  reaper.ImGui_SameLine(ctx)
  -- The update notice (DESIGN "Distribution, updates & versioning"): an ACCENT
  -- dot over the gear's corner, and nothing else anywhere — the working view
  -- stays untouched, nothing moves or resizes, and the dot persists until the
  -- update is actually installed (state.update.available goes nil then).
  local update_due = state.update and state.update.available ~= nil
  if icons.button(ctx, res.icon_font, "settings", "settings",
      { tip = update_due and "Settings \u{2014} an update is available" or "Settings",
        fallback = icons.draw_gear }) then
    edit.settings_open = true
    -- Also reported as an action: the entry script refreshes the update
    -- feature's registry read, so the UPDATES section opens describing NOW
    -- (a pin set or cleared in ReaPack five minutes ago), not the last daily
    -- check. Losing this to an earlier same-frame action is harmless — the
    -- modal still opens, just on day-old facts.
    action = action or { type = "settings_opened" }
  end
  if update_due then
    local max_x = reaper.ImGui_GetItemRectMax(ctx)
    local _, min_y = reaper.ImGui_GetItemRectMin(ctx)
    local r = M.UPDATE_DOT_R
    reaper.ImGui_DrawList_AddCircleFilled(reaper.ImGui_GetWindowDrawList(ctx),
      max_x - r - 2, min_y + r + 2, r, T.ACCENT)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PopStyleVar(ctx, 1)

  return action
end

local function draw_main(ctx, state, res)
  local action = draw_toolbar(ctx, state, res)

  -- Height budget: the strip and the info row are anchored to the bottom, the
  -- table takes everything in between (the 2026-07-29 arrangement — results on
  -- top, preview at the bottom, mirroring the working view's waveform-then-
  -- controls order).
  local gap_y = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local info_h = reaper.ImGui_GetFrameHeight(ctx)
  local avail_h = select(2, reaper.ImGui_GetContentRegionAvail(ctx))
  local list_h = avail_h - (M.BROWSER_WAVE_H + gap_y) - (info_h + gap_y)
  if list_h < M.WAVE_MIN_H then list_h = M.WAVE_MIN_H end

  -- Wrap the list in a child so the whole area is one reliable drop target (a bare
  -- table isn't dependable across ReaImGui versions, and dropping into an empty view
  -- is normal). The wrapper must NOT scroll itself — the table inside owns ScrollY,
  -- and two scroll owners at an exact-fit height fight for the boundary and make
  -- the list flicker frame-to-frame.
  local no_scroll = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  -- EndChild only inside the `if`: ReaImGui's contract (see app.lua) — a fully
  -- clipped child (window squashed to zero width) returns false WITHOUT opening,
  -- and an unmatched EndChild is a hard assertion that kills the script.
  -- This child takes no padding of its own, so there is nothing to push here —
  -- and nothing that could reach the row menus drawn inside it.
  local list_open = reaper.ImGui_BeginChild(ctx, "listarea", 0, list_h, 0, no_scroll)
  if list_open then
    -- Always draw the list (never short-circuit it behind `action or ...`, which
    -- would blank the list for a frame whenever the search box set an action).
    local list_action = draw_sound_list(ctx, state, res)
    action = action or list_action
    reaper.ImGui_EndChild(ctx)
  end
  -- The main panel's drop target spans the list AND the audition strip below
  -- it (2026-08-01, user's call) — the list rect is captured here, the one
  -- rect-based target (dropzone.file_drop_over_rect, the same mechanism as the
  -- working view) is submitted after the strip is drawn, once the combined
  -- rect is known. Guarded by list_open so a clipped-away child can't leave a
  -- stale rect.
  local list_rect
  if list_open then
    local lx0, ly0 = reaper.ImGui_GetItemRectMin(ctx)
    list_rect = { x0 = lx0, y0 = ly0 }
  end

  -- Compact audition strip, now the bottom pane (2026-07-29): the exact same
  -- waveform WIDGET as the working view — click-to-seek, playhead, loop visuals
  -- — at a fixed browsing height. It draws the BROWSER's own selection
  -- (state.browse_id/browse_waveform), never the working view's armed reference
  -- (Phase 5.9 — independent selections). Deliberately no REF latch and no trim
  -- here (DESIGN — browsing can never surprise-mute). The returned seek is
  -- tagged target="browse" so the entry script acts on the BROWSED sound.
  --
  -- No `trim_db` on purpose (2026-07-30): a browse audition plays at no trim, so
  -- the strip draws the sound as recorded to match. Passing the stored trim here
  -- would draw a level nobody is hearing.
  local wave_action = waveform.draw(ctx, state, M.BROWSER_WAVE_H,
    { id = state.browse_id, waveform = state.browse_waveform })
  if wave_action then wave_action.target = "browse" end
  action = action or wave_action
  -- The strip's rect (the waveform widget's own item), for the combined list +
  -- strip drop target submitted below the idle-face drawing.
  local sx0, sy0 = reaper.ImGui_GetItemRectMin(ctx)
  local sx1, sy1 = reaper.ImGui_GetItemRectMax(ctx)

  -- The strip's idle face carries what the retired status row used to say:
  -- the drag hint while one is in flight, a standing status message, else the
  -- how-to line. Drawn over the empty strip (its InvisibleButton was the last
  -- item), never laid out — so nothing can shift.
  if not state.browse then
    local msg = (state.drag and state.drag.hint) or state.status or IDLE_HINT
    local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local col = state.drag and T.TEXT_PRIMARY or T.TEXT_TERTIARY
    if HAS_TEXT_EX then
      local small = theme.push_small_font(ctx)
      local tw, th = reaper.ImGui_CalcTextSize(ctx, msg)
      if small then reaper.ImGui_PopFont(ctx) end
      local tx = x0 + ((x1 - x0) - tw) * 0.5
      if tx < x0 + 12 then tx = x0 + 12 end -- a long message left-aligns instead of vanishing off both ends
      reaper.ImGui_DrawList_AddTextEx(dl, nil, M.GROUP_FS, tx, (y0 + y1) * 0.5 - th * 0.5, col, msg)
    else
      local tw, th = reaper.ImGui_CalcTextSize(ctx, msg)
      local tx = x0 + ((x1 - x0) - tw) * 0.5
      if tx < x0 + 12 then tx = x0 + 12 end
      reaper.ImGui_DrawList_AddText(dl, tx, (y0 + y1) * 0.5 - th * 0.5, col, msg)
    end
  end

  -- The combined list + audition-strip drop target (see the list_rect capture
  -- above). Falls back to the strip alone when the list child was clipped away.
  -- The target names where a drop will file: the viewed (sub-)category, or the
  -- library at large when viewing All/Uncategorised.
  do
    local x0 = list_rect and list_rect.x0 or sx0
    local y0 = list_rect and list_rect.y0 or sy0
    local cat, sub = view_target(state.library, state.view)
    local dest = categories.get(state.library, sub or cat)
    local drop_action = dropzone.file_drop_over_rect(ctx, state, x0, y0, sx1, sy1,
      { category = cat, subcategory = sub,
        label = "Add to " .. (dest and dest.name or "your library") })
    action = action or drop_action
  end

  -- The info row under the strip (2026-07-29): the browsed sound's technical
  -- facts on the left (or the standing status/drag hint while one applies —
  -- same slot, so nothing moves), the PREVIEW master fader on the right. The
  -- left text lives in a zero-padding child clipped to the space the fader
  -- leaves, so a long line can never draw over the control (the transport
  -- readout's idiom).
  local small = theme.push_small_font(ctx)
  local label_w = select(1, reaper.ImGui_CalcTextSize(ctx, "Preview")) -- must match transport.draw_master
  if small then reaper.ImGui_PopFont(ctx) end
  local fader_block = state.deps.sws and (label_w + 6 + M.SLIDER_W) or 0
  local row_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local left_w = row_w - fader_block - (fader_block > 0 and 8 or 0)
  if left_w > 0 then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
    local info_open = reaper.ImGui_BeginChild(ctx, "browserinfo", left_w, info_h, 0, no_scroll)
    reaper.ImGui_PopStyleVar(ctx, 1)
    if info_open then
      local msg, col
      if state.drag and state.drag.hint and state.browse then
        -- The strip's idle face already shows the hint when nothing is browsed;
        -- with a waveform on the strip this row is the hint's visible home.
        msg, col = state.drag.hint, T.TEXT_PRIMARY
      elseif state.status then
        msg, col = state.status, T.TEXT_SECONDARY
      else
        msg, col = tech_line(state), T.TEXT_TERTIARY
      end
      if msg then
        reaper.ImGui_AlignTextToFramePadding(ctx)
        local sp = theme.push_small_font(ctx)
        reaper.ImGui_TextColored(ctx, col, msg)
        if sp then reaper.ImGui_PopFont(ctx) end
      end
      reaper.ImGui_EndChild(ctx)
    end
  end
  -- Preview-only, so hidden without SWS — the info text then keeps the row.
  -- IMPORTANT: never write `action = action or draw(...)` — Lua short-circuits,
  -- so once an earlier widget has an action the draw call is SKIPPED and its
  -- widget vanishes for that frame. Always draw, then merge.
  if state.deps.sws then
    if left_w > 0 then reaper.ImGui_SameLine(ctx) end
    local master_action = transport.draw_master(ctx, state)
    action = action or master_action
  end

  -- The Settings modal lives in this panel's scope (the gear that opens it is in
  -- the toolbar above). Drawn last so it overlays everything; always called, so
  -- its popup is submitted every frame.
  local settings_action = draw_settings(ctx, state)
  action = action or settings_action

  return action
end

--------------------------------------------------------------- draw

-- Merge one panel's action into the frame's. A drop that consumed the mouse
-- release (`wins_release`) must survive to the END of the frame: a later
-- panel's same-frame action may not displace it — two release-consuming drops
-- can't co-fire (one release lands on one target).
local function merge_action(prev, new)
  if prev and prev.wins_release then return prev end
  return new or prev
end

-- Draws the browser's whole content (sidebar + main panel). The window's own
-- Begin/End is owned by ui/app.lua — this only fills what's between them. The
-- window comes with ZERO padding (see app.lua): the sidebar bleeds to the true
-- window edges (the 2026-07-29 review's headline fix — the old 12px padding
-- showed as a lighter frame around it), and each panel pads itself instead.
function browser.draw(ctx, state, res)
  local action

  -- Sidebar: full-bleed chrome. Square corners (it meets the window edges), its
  -- own inner padding, and a drag-resizable right edge where the build supports
  -- it (ImGui's own ini remembers the width the user leaves it at).
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), T.BG_CHROME)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), M.SB_PAD, M.SB_PAD)
  local sb_flags = 0
  if HAS_CHILD_PAD then sb_flags = reaper.ImGui_ChildFlags_AlwaysUseWindowPadding() end
  if HAS_CHILD_RESIZE then sb_flags = sb_flags | reaper.ImGui_ChildFlags_ResizeX() end
  -- Style vars popped the instant the child has taken them (ImGui reads
  -- WindowPadding once, at Begin). Held across the contents, the sidebar's
  -- tighter padding would also land on every right-click menu inside it, so the
  -- same menu would look different depending on which panel it was opened from.
  local sb_open = reaper.ImGui_BeginChild(ctx, "sidebar", M.SIDEBAR_W, 0, sb_flags)
  reaper.ImGui_PopStyleVar(ctx, 2)
  if sb_open then
    action = merge_action(action, draw_sidebar(ctx, state))
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx)

  -- One hairline on the seam (the only separation the two surfaces need), then
  -- the main panel flush against it.
  local sx1, sy1 = reaper.ImGui_GetItemRectMax(ctx)
  local _, sy0 = reaper.ImGui_GetItemRectMin(ctx)
  reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
    sx1 + 0.5, sy0, sx1 + 0.5, sy1, T.STROKE_TERTIARY, 1)

  reaper.ImGui_SameLine(ctx, 0, 0)

  -- The main panel never scrolls (its list scrolls internally). Forbidding a
  -- scrollbar keeps its content width fixed — a scrollbar toggling on/off would
  -- change the width every frame and jitter the right-aligned toolbar cluster
  -- and fader that are sized from it.
  local main_flags = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 12, 12)
  local main_child_flags = HAS_CHILD_PAD and reaper.ImGui_ChildFlags_AlwaysUseWindowPadding() or 0
  local main_open = reaper.ImGui_BeginChild(ctx, "main", 0, 0, main_child_flags, main_flags)
  reaper.ImGui_PopStyleVar(ctx, 1)
  if main_open then
    action = merge_action(action, draw_main(ctx, state, res))
    reaper.ImGui_EndChild(ctx)
  end

  return action
end

return browser
