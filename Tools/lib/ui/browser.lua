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
local tips = require("ui.tips")
local categories = require("core.categories")
local techfacts = require("core.techfacts")
local transport = require("ui.transport")
local waveform = require("ui.waveform")
local icons = require("ui.icons")
local dropzone = require("ui.dropzone")
local popups = require("ui.popups")
local widgets = require("ui.widgets")
local focus = require("ui.focus")
local walkthrough_ui = require("ui.walkthrough")
local T = theme.tokens
local M = theme.metrics

local browser = {}

-- Feature detection, checked once at load.
-- Each absent capability degrades on its own: no child padding = flush content,
-- no resize flag = fixed sidebar width, no custom headers = a blank pin header,
-- no context-window popups = the + New category button is the only entry point.
local HAS_CHILD_PAD    = reaper.ImGui_ChildFlags_AlwaysUseWindowPadding ~= nil
local HAS_CHILD_RESIZE = reaper.ImGui_ChildFlags_ResizeX ~= nil
local HAS_SIZE_CONSTRAINTS = reaper.ImGui_SetNextWindowSizeConstraints ~= nil
local HAS_TABLE_HEADER = reaper.ImGui_TableHeader ~= nil and reaper.ImGui_TableRowFlags_Headers ~= nil
local HAS_SB_CTX       = reaper.ImGui_BeginPopupContextWindow ~= nil
  and reaper.ImGui_PopupFlags_MouseButtonRight ~= nil and reaper.ImGui_PopupFlags_NoOpenOverItems ~= nil
local HAS_TEXT_EX      = reaper.ImGui_DrawList_AddTextEx ~= nil
-- The audition strip's resize cursor, resolved once at load (the house
-- feature-detection idiom). nil on an older ReaImGui — the drag still works,
-- it just doesn't change the pointer.
local RESIZE_CURSOR    = reaper.ImGui_MouseCursor_ResizeNS and reaper.ImGui_MouseCursor_ResizeNS() or nil
local HAS_NEXT_SCROLL  = reaper.ImGui_SetNextWindowScroll ~= nil

-- Face for the info row's loop toggle when the Lucide icon font isn't
-- available; the same fallback the working view's bar uses.
local LOOP = "\u{21BB}" -- ↻

-- The rail scrollbars' bridges between frames (brief `table-scrollbar`,
-- 2026-08-09): each thumb lives OUTSIDE the window it steers — the sound
-- table's in the reserved strip beside the table, the sidebar's beside the
-- category child — but the scroll belongs to that window, only reachable while
-- it is current. So each frame the scrolled window records its numbers here,
-- and a drag on the thumb parks the wanted value in `pending` for the window's
-- next frame to apply. Declared up here because the sidebar (drawn well above
-- the table in this file) shares the idiom.
local list_scroll = { y = 0, max = 0 }
local cats_scroll = { y = 0, max = 0 }
-- What the sound list was showing last frame (view + search), for the
-- new-view-starts-at-the-top rule in draw_sound_list. nil until first seen.
local last_view_key = nil

--------------------------------------------------------------- arrow browsing

-- (2026-08-08, part of the keyboard-focus work.) While the browser window is
-- focused, Up/Down step the selection exactly as clicking the next row would —
-- in the sound list, or in the sidebar when that was clicked last ("browse the
-- side column", the user's ask). Clicks in those two panes deliberately KEEP
-- OS focus (focus.keep_zone, registered in the draw below) precisely so these
-- keys have somewhere to live; everywhere else a finished click hands focus
-- straight back to REAPER and the arrow keys are REAPER's again (ui/focus.lua).

local HAS_ARROW_NAV = reaper.ImGui_IsKeyPressed ~= nil
  and reaper.ImGui_Key_DownArrow ~= nil and reaper.ImGui_Key_UpArrow ~= nil
  and reaper.ImGui_Key_LeftArrow ~= nil and reaper.ImGui_Key_RightArrow ~= nil
  and reaper.ImGui_IsWindowFocused ~= nil
  and reaper.ImGui_FocusedFlags_RootAndChildWindows ~= nil
  and reaper.ImGui_IsAnyItemActive ~= nil
local HAS_POPUP_ANY = reaper.ImGui_IsPopupOpen ~= nil
  and reaper.ImGui_PopupFlags_AnyPopupId ~= nil and reaper.ImGui_PopupFlags_AnyPopupLevel ~= nil
local HAS_SCROLL_FOLLOW = reaper.ImGui_SetScrollHereY ~= nil

-- Which pane the arrows drive: the pane of the last row the user clicked.
-- Starts on the sound list — the thing arrow-browsing is for — and RESETS to
-- it whenever the window reopens or the search box is in use (Codex,
-- 2026-08-08 review: a sidebar claim from before the window closed surviving
-- into a fresh session — type a search, press Down, and the CATEGORY moves —
-- reads as plain wrong).
local nav_owner = "list"

-- ImGui's frame counter from the last browser.draw, to spot a reopen: this
-- draw only runs while the window is open, so a gap of more than one frame
-- means it was closed in between.
local last_draw_frame = nil

-- One-frame scroll-follow request from a key step: `list_row` (0-based, the
-- table clipper's numbering) or `view` (the stepped-to sidebar entry), plus the
-- step direction so the row lands at the edge it entered from. Cleared at the
-- end of every browser.draw — never carried across frames.
local nav = { list_row = nil, view = nil, dir = 0 }

-- Scroll the just-submitted (key-stepped) row into view — only when it sits
-- outside the current window's visible band, so a step between two already-
-- visible rows never jolts the scroll. `top_inset` masks a band at the top of
-- the window that doesn't scroll with the rows (the table's frozen header).
local function scroll_follow(ctx, dir, top_inset)
  if not HAS_SCROLL_FOLLOW then return end
  local iy0 = select(2, reaper.ImGui_GetItemRectMin(ctx))
  local iy1 = select(2, reaper.ImGui_GetItemRectMax(ctx))
  local wy = select(2, reaper.ImGui_GetWindowPos(ctx))
  local wh = select(2, reaper.ImGui_GetWindowSize(ctx))
  if iy0 < wy + (top_inset or 0) or iy1 > wy + wh then
    reaper.ImGui_SetScrollHereY(ctx, dir > 0 and 1 or 0)
  end
end

-- Step the sound list: the row `step` away from the browse selection (Down
-- from nothing enters at the top, Up from nothing at the bottom), clamped at
-- the ends. Returns the exact action clicking that row would.
local function step_list(state, step)
  local sounds = state.visible_sounds
  if not sounds or #sounds == 0 then return nil end
  local idx
  if state.browse_id then
    for i, s in ipairs(sounds) do
      if s.id == state.browse_id then idx = i; break end
    end
  end
  local to = idx and idx + step or (step > 0 and 1 or #sounds)
  if to < 1 then to = 1 elseif to > #sounds then to = #sounds end
  if sounds[to].id == state.browse_id then return nil end -- already at that edge
  nav.list_row, nav.dir = to - 1, step
  return { type = "browse_sound", id = sounds[to].id }
end

-- The sidebar's rows as one flat sequence, in the order the eye reads them
-- (2026-08-10 reorder, user's ask: Uncategorised moved up beside All sounds —
-- the two views lead, then every category with its sub-categories).
local function sidebar_entries(lib)
  local out = { { scope = "all" }, { scope = "uncategorised" } }
  for _, cat in ipairs(categories.children(lib, nil)) do
    out[#out + 1] = { scope = "category", id = cat.id }
    for _, sub in ipairs(categories.children(lib, cat.id)) do
      out[#out + 1] = { scope = "subcategory", id = sub.id }
    end
  end
  return out
end

-- Step the sidebar the same way. A view that somehow isn't in the sequence
-- (can't happen today) steps to All sounds rather than nowhere.
local function step_sidebar(state, step)
  local entries = sidebar_entries(state.library)
  local idx
  for i, e in ipairs(entries) do
    if e.scope == state.view.scope and e.id == state.view.id then idx = i; break end
  end
  local to = idx and idx + step or 1
  if to < 1 then to = 1 elseif to > #entries then to = #entries end
  if idx == to then return nil end -- already at that edge
  nav.view, nav.dir = entries[to], step
  return { type = "select_view", view = { scope = entries[to].scope, id = entries[to].id } }
end

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
--   indent   - px to push the drawn NAME in by (sub-categories only). The
--              Selectable underneath always spans the row's full width flush to
--              the left edge — only the text moves — so a sub-category's fill
--              and click area reach the panel edge exactly like a top-level
--              category's (2026-08-05: was Indent()/Unindent() wrapping the
--              whole row, which shrank both to start where the indented text
--              did instead of the panel edge)
-- Sidebar rows draw at the BODY size, not the small one (2026-08-07, user
-- reported them hard to read after the density pass — "are they the same size
-- as the asset table text? maybe they should be slightly bigger"). They are the
-- library's navigation, read as often as the sound names beside them, so they
-- get the same size those do; SMALL CAPS still tells a grouping from a sound,
-- which was always the real signal — the smaller size was only ever reinforcing
-- it, and at 11px it was costing legibility to say something caps already say.
local function group_row(ctx, id, name, opts)
  opts = opts or {}
  local col = opts.color or T.TEXT_PRIMARY
  -- No visible label on the Selectable itself — the name is hand-drawn below at
  -- its own (possibly indented) position, so indenting the text can never also
  -- shrink the row's fill/hit-area the way ImGui's own label layout would.
  -- The text anchors to the CURSOR captured here, not to the item rect: a
  -- Selectable widens its rect by half an ItemSpacing step on each side (that
  -- is what lets rows sit flush with no click-gaps), so rect-min sits left of
  -- the window's clip edge and text hung on it loses its first pixels
  -- (2026-08-05, user-reported on every non-indented row).
  local text_x = select(1, reaper.ImGui_GetCursorScreenPos(ctx))
  -- The Selectable's OWN fill is suppressed and repainted by hand (2026-08-10,
  -- round 3, user-reported "the background doesn't go all the way to the edge"):
  -- a Selectable's rect overhangs the window on both sides by half an
  -- ItemSpacing step — what lets rows sit flush — so its fill has to be drawn to
  -- the window's TRUE right edge instead.
  --
  -- Since 2026-08-11 that edge is the same one for every sidebar row: the
  -- category list gave up the strip it used to reserve for the slim scrollbar
  -- (the fills' old `fill_ext` escape hatch went with it), because reserving it
  -- inside the list alone left the category counts a strip short of the pinned
  -- views' counts above them, with a band of empty chrome after each. The thumb
  -- floats over the rows' right end instead, like an overlay scrollbar, and
  -- SB_COUNT_PAD keeps the digits clear of it.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(), 0)
  reaper.ImGui_Selectable(ctx, "##" .. id, opts.selected or false)
  reaper.ImGui_PopStyleColor(ctx, 3)
  -- The click is read on PRESS, not on the Selectable's own release (2026-08-01:
  -- the sidebar felt a beat behind). Two waits stack otherwise — waiting for the
  -- button to come back up, then one more frame for the entry script to rebuild
  -- the list — and the row is what the user is aiming at, so there is nothing a
  -- release could still cancel. Selecting on press is what file lists do.
  local clicked = reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 0)
  -- A sidebar row click hands the arrow keys to the side column (see
  -- "arrow browsing" above). Every sidebar row goes through here.
  if clicked then nav_owner = "sidebar" end

  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  -- The hand-drawn fills (see the suppression above). Square corners — these
  -- run flush to the strip's edges now, the Settings-nav look; the echo stays
  -- a translucent overlay-tint (the name reads through it) rather than a
  -- second Selectable state — ImGui has no "half selected".
  local win_r = select(1, reaper.ImGui_GetWindowPos(ctx))
    + select(1, reaper.ImGui_GetWindowWidth(ctx))
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if opts.selected then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, win_r, y1, T.FILL_SECONDARY)
  elseif hovered then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, win_r, y1, T.FILL_TERTIARY)
  end
  if opts.echo and not opts.selected then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, win_r, y1, T.FILL_TERTIARY)
  end
  -- The COUNT owns the row's right end and the name is cut to whatever is left
  -- (2026-08-07, user-reported: dragging the sidebar narrow ran the category
  -- name straight underneath the number). Two runs of text must never compete
  -- for the same pixels, so the count's zone is measured BEFORE the name is
  -- laid out and the name can never reach it. The count is also drawn LAST, so
  -- even a rounding error leaves the number legible on top rather than under.
  --
  -- Sub-category rows indent the NAME only (the row's fill and hit area still
  -- span the panel), so the indent comes out of the name's share, not the count's.
  --
  -- The panel carries ZERO padding since 2026-08-10 (fills flush to its edges,
  -- the Settings nav's grammar), so the name takes its SB_PAD inset HERE,
  -- inside the row. And the text maths use the window's true right edge, not
  -- the Selectable's rect: the rect overhangs by half an ItemSpacing step
  -- (what lets rows sit flush), and without the old padding that overhang
  -- would hang the count past the visible edge.
  local name_x = text_x + M.SB_PAD + (opts.indent or 0)
  local tx1 = math.min(x1, win_r)
  local count_text = opts.count and tostring(opts.count) or nil
  local count_w = count_text and select(1, reaper.ImGui_CalcTextSize(ctx, count_text)) or 0
  local name_max = (tx1 - M.SB_COUNT_PAD) - name_x
  if count_text then name_max = name_max - count_w - M.SB_COUNT_GAP end

  -- upper() is byte-wise, so non-ASCII letters simply keep their case — fine
  -- for a purely visual treatment.
  local label = widgets.ellipsize(ctx, name:upper(), name_max)
  local _, lh = reaper.ImGui_CalcTextSize(ctx, label)
  reaper.ImGui_DrawList_AddText(dl, name_x, (y0 + y1) * 0.5 - lh * 0.5, col, label)
  if count_text then
    local th = select(2, reaper.ImGui_CalcTextSize(ctx, count_text))
    reaper.ImGui_DrawList_AddText(dl, tx1 - count_w - M.SB_COUNT_PAD,
      (y0 + y1) * 0.5 - th * 0.5, col, count_text)
  end

  return clicked
end

-- Transient edit scratch (in-progress popup text, which popup to open next frame).
-- View-only state that never belongs in the shared library — kept here, not on
-- `state`, so nothing outside ui/ sees it.
local edit = { new_cat = "", new_sub = "", rename = "", query = "", sub_parent = nil, rename_id = nil, open = nil,
  -- The sound a delete confirmation is about. Kept apart from `open` above, which
  -- belongs to the sidebar: the sidebar is drawn first each frame and would consume
  -- a request meant for a popup that lives in the list panel.
  del = nil }

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

-- The audition strip's top-edge drag (2026-08-06): scratch for the in-flight
-- gesture only. `start_h`/`start_my` = the strip height and mouse y when the
-- seam was grabbed (absolute-anchored, so clamping at a limit and coming back
-- can't drift the height); `live` = what's shown while the mouse is still down
-- — state.browser_wave_h is only written on release, one action instead of
-- sixty a second; `hold` = a reset fired mid-grab, so the release that follows
-- must not commit the drag value over it (the faders' reset_hold idiom).
local split = { start_h = nil, start_my = nil, live = nil, hold = false }

--------------------------------------------------------------- small helpers

local function fmt_duration(sec)
  local s = math.floor((sec or 0) + 0.5)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function fmt_channels(n)
  return tostring(n or 0) -- raw channel count (1 = mono, 2 = stereo)
end

-- The six measurements the Loudness column can show, in the order the menu lists
-- them — peaks first, then LUFS shortest-window to longest, then RMS. `field`
-- matches the record field the analysis stores. The header label is kept short so
-- the column never has to grow to fit it.
local LOUD_UNITS = {
  { field = "peak",       header = "Peak",   menu = "Peak" },
  { field = "true_peak",  header = "dBTP",   menu = "True Peak" },
  { field = "lufs_m_max", header = "LUFS-M", menu = "LUFS-M" },
  { field = "lufs_s_max", header = "LUFS-S", menu = "LUFS-S" },
  { field = "lufs_i",     header = "LUFS-I", menu = "LUFS-I" },
  { field = "rms",        header = "RMS",    menu = "RMS" },
}

local function loud_unit(state)
  local fallback
  for _, u in ipairs(LOUD_UNITS) do
    if u.field == state.loud_unit then return u end
    -- The fallback stays the headline number, not the menu's first row — the
    -- menu is ordered for reading, not for rank.
    if u.field == "lufs_i" then fallback = u end
  end
  return fallback
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

-- A value in a table cell: LEFT-aligned under its own header (2026-08-11, the
-- user's call — this replaces the right-alignment the 2026-07-29 review put
-- here, where digits stacked by place value but every column read as detached
-- from the word naming it), and centred in `row_h`, the row's full height — a
-- row is taller than one line of text (see draw_sound_list), so laid-out text
-- would otherwise sit at its top edge while the name beside it is centred.
-- These columns are resizable, so a value IS cut to its cell (2026-08-12) rather
-- than clipped mid-digit: a half-drawn number reads as a different number, which
-- is worse than no number. The Loudness column's own "\u{2026}" for a pending
-- measurement stays distinguishable from a cut value by its dimmer colour — at
-- the width where a real reading cuts down to bare "\u{2026}" nothing in the
-- column is readable anyway.
local function num_cell(ctx, color, text, row_h)
  text = widgets.ellipsize(ctx, text, select(1, reaper.ImGui_GetContentRegionAvail(ctx)))
  local th = select(2, reaper.ImGui_CalcTextSize(ctx, text))
  if row_h and row_h > th then
    reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + (row_h - th) * 0.5)
  end
  reaper.ImGui_TextColored(ctx, color, text)
end

-- How much of the pin column's right edge belongs to the sort arrow, now that
-- the column sorts (2026-08-01). Reserved ALWAYS, not only while that column is
-- the sorted one, so the pushpins never shift when the sort changes.
local function pin_arrow_zone()
  return M.SORT_ARROW_W + M.SORT_ARROW_GAP * 2
end

-- THE ONE X EVERY PUSHPIN IN THE COLUMN SHARES, read from the item submitted
-- just before this call and snapped to a whole pixel (2026-08-11, user's ask
-- that the header's pin line up perfectly with the ones under it).
--
-- Each pin used to centre itself in ITS OWN cell, and the header's cell is not
-- the same rectangle as a row's: a header spans the column edge to edge, while a
-- row's content sits inside the cell padding, and ImGui pads the table's last
-- column differently on each side. Two pins centred "correctly" that way still
-- land a pixel or so apart — and at 11px, on fractional coordinates, a pixel is
-- the difference between a crisp mark and a soft one. So the column measures the
-- axis ONCE per frame and everything paints on it.
local function pin_axis(ctx, arrow_zone)
  local x0 = select(1, reaper.ImGui_GetItemRectMin(ctx))
  local x1 = select(1, reaper.ImGui_GetItemRectMax(ctx))
  return math.floor((x0 + x1 - arrow_zone) * 0.5)
end

-- The pushpin, painted over the item submitted just before this call: on the
-- column's shared `cx`, at the middle of whatever that item is. Falls back to the
-- drawn shape when the Lucide font is absent.
local function pin_glyph(ctx, font, color, size, cx)
  local y0 = select(2, reaper.ImGui_GetItemRectMin(ctx))
  local y1 = select(2, reaper.ImGui_GetItemRectMax(ctx))
  local cy = math.floor((y0 + y1) * 0.5)
  if not icons.paint_glyph(ctx, font, "pin", cx, cy, color, size) then
    icons.draw_pin(reaper.ImGui_GetWindowDrawList(ctx), cx, cy, color)
  end
end

--------------------------------------------------------------- sidebar

-- Right-click menu for a category row. Add-sub/rename can't OpenPopup directly
-- (they run inside the closing context popup), so they stash which popup to open
-- and the entry data; draw_sidebar opens it at its own scope.
local function category_menu(ctx, cat)
  local action
  if reaper.ImGui_BeginPopupContextItem(ctx, "ctx_" .. cat.id) then
    if reaper.ImGui_MenuItem(ctx, "Add Subcategory\u{2026}") then
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
    if reaper.ImGui_MenuItem(ctx, "New Category\u{2026}") then
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
    -- Keep a key-stepped row in view (the group_row's Selectable is still the
    -- last item here — the drop target and menu below add none of their own).
    if nav.view and nav.view.scope == "category" and nav.view.id == cat.id then
      scroll_follow(ctx, nav.dir)
    end
    if dropzone.sound_drop_target(ctx, state) then
      action = { type = "refile_sound", id = state.drag.sound_id, category = cat.id, wins_release = true }
    end
    action = dropzone.read_file_drop(ctx, state, { category = cat.id }) or action
    action = category_menu(ctx, cat) or action

    for _, sub in ipairs(categories.children(lib, cat.id)) do
      -- A sub wears a DIMMER shade of the parent's colour (never its own): the
      -- family reads at a glance, and the parent stays the strongest row. Only
      -- the drawn NAME is indented (opts.indent) — the row itself spans the
      -- full sidebar width flush left, same as a top-level category.
      if group_row(ctx, "sub_" .. sub.id, sub.name,
          { color = theme.dim(cat.color), selected = view_is(state, "subcategory", sub.id),
            count = counts and counts.by_id[sub.id],
            echo = echo.sub == sub.id, indent = M.INDENT }) then
        action = { type = "select_view", view = { scope = "subcategory", id = sub.id } }
      end
      if nav.view and nav.view.scope == "subcategory" and nav.view.id == sub.id then
        scroll_follow(ctx, nav.dir)
      end
      if dropzone.sound_drop_target(ctx, state) then
        action = { type = "refile_sound", id = state.drag.sound_id, category = cat.id, subcategory = sub.id, wins_release = true }
      end
      action = dropzone.read_file_drop(ctx, state, { category = cat.id, subcategory = sub.id }) or action
      action = subcategory_menu(ctx, sub) or action
    end
  end

  sidebar_context(ctx) -- this child's own empty space (the sidebar shell has its own)
  return action
end

local function draw_sidebar(ctx, state)
  local action
  local counts = state.counts

  -- Rows sit tight (2026-07-29, "we don't need an empty row between
  -- subcategories") — only the deliberate block separators breathe.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), M.ITEM_SPACING_X, M.SB_ROW_GAP)

  -- Pinned top block (2026-08-10 reorder, the user's ask — Uncategorised used
  -- to be pinned at the BOTTOM): the two views lead, then the new-category
  -- button directly above the list it adds to, then the categories scroll in
  -- whatever height is left. White caps = a view; every category is coloured.
  if group_row(ctx, "view_all", "All sounds",
      { selected = view_is(state, "all"), count = counts and counts.all }) then
    action = { type = "select_view", view = { scope = "all" } }
  end
  -- Files dropped on All sounds join the library at large — no category, same
  -- landing spot as the Uncategorised row (2026-08-01, user's call: every
  -- sidebar row should catch a drop, not just the categories).
  action = dropzone.read_file_drop(ctx, state) or action

  if group_row(ctx, "view_unc", "Uncategorised",
      { selected = view_is(state, "uncategorised"),
        count = counts and counts.uncat, echo = echo.unc }) then
    action = { type = "select_view", view = { scope = "uncategorised" } }
  end
  if dropzone.sound_drop_target(ctx, state) then
    action = { type = "refile_sound", id = state.drag.sound_id, wins_release = true }
  end
  action = dropzone.read_file_drop(ctx, state) or action

  -- The + New category button, inset SB_PAD from the flush edges the rows now
  -- own (the child carries zero padding — see the Begin site). A hairline
  -- under it fences the views-and-actions block off from the scrolling list.
  reaper.ImGui_Dummy(ctx, 0, M.SB_ROW_GAP)
  reaper.ImGui_SetCursorPosX(ctx, M.SB_PAD)
  local bw = select(1, reaper.ImGui_GetContentRegionAvail(ctx)) - M.SB_PAD
  if reaper.ImGui_Button(ctx, "+ New Category##newcat", bw) then
    edit.new_cat = ""
    reaper.ImGui_OpenPopup(ctx, "add_cat")
  end
  -- Files dropped on the button create a category AND file the files into it,
  -- one motion (2026-08-01, user's call). The entry script names it after the
  -- folder the files came from.
  action = dropzone.read_file_drop(ctx, state, { action_type = "import_new_category" }) or action

  -- No hairline under the button (offered, removed at the user's ask —
  -- round 3): the button's own frame already ends the pinned block.
  reaper.ImGui_Dummy(ctx, 0, M.SB_PAD - M.SB_ROW_GAP)

  -- The categories take every pixel left below the pinned block.
  local row_h = reaper.ImGui_GetTextLineHeight(ctx)
  local cats_h = select(2, reaper.ImGui_GetContentRegionAvail(ctx))
  if cats_h < row_h then cats_h = row_h end
  -- EndChild only inside the `if`: ReaImGui's contract (see app.lua) — a fully
  -- clipped child returns false WITHOUT opening.
  --
  -- The category list wears the SAME slim scrollbar as the sound table (brief
  -- `table-scrollbar`, 2026-08-09), with one difference since 2026-08-11: here
  -- the thumb OVERLAYS the rows instead of the child giving up a reserved strip
  -- for it. Reserving it made every category count sit a strip left of the two
  -- pinned views' counts above them, which is exactly the misalignment the user
  -- reported; the rows now run the panel's full width and SB_COUNT_PAD keeps the
  -- digits clear of the thumb. The child still hides its own bar outright
  -- (NoScrollbar — wheel scrolling is untouched).
  -- The thumb is submitted BEFORE the child, exactly as the table's rail is
  -- (Codex 2026-08-10 — drawn after it, a drag took two frames to land), and
  -- its answer is handed to the child's own Begin, so a drag steers with no
  -- round trip. It draws from last frame's numbers — one frame of thumb lag,
  -- imperceptible.
  local cats_x, cats_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local cats_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  if cats_scroll.max > 0 and cats_w > M.SCROLL_RAIL_W * 3 then
    local new = widgets.scrollbar(ctx, "catscroll",
      cats_x + cats_w - M.SCROLL_RAIL_W, cats_y, M.SCROLL_RAIL_W, cats_h,
      cats_scroll.y, cats_scroll.max)
    if new then cats_scroll.pending = new end
  end
  if cats_scroll.pending and HAS_NEXT_SCROLL then
    reaper.ImGui_SetNextWindowScroll(ctx, -1, cats_scroll.pending)
    cats_scroll.pending = nil
  end
  if reaper.ImGui_BeginChild(ctx, "cats", 0, cats_h, 0,
      reaper.ImGui_WindowFlags_NoScrollbar()) then
    -- Fallback only, for a ReaImGui without SetNextWindowScroll (a frame late).
    if cats_scroll.pending then
      reaper.ImGui_SetScrollY(ctx, cats_scroll.pending)
      cats_scroll.pending = nil
    end
    action = draw_categories(ctx, state) or action
    cats_scroll.y = reaper.ImGui_GetScrollY(ctx)
    cats_scroll.max = reaper.ImGui_GetScrollMaxY(ctx)
    reaper.ImGui_EndChild(ctx)
  end

  sidebar_context(ctx) -- empty space around the pinned rows

  -- Open a context-menu-requested popup (deferred so it isn't nested in the menu).
  if edit.open then
    reaper.ImGui_OpenPopup(ctx, edit.open)
    edit.open = nil
  end

  local newcat = popups.edit_popup(ctx, edit, "add_cat", "New Category", "new_cat")
  if newcat then action = { type = "add_category", name = newcat } end
  local newsub = popups.edit_popup(ctx, edit, "add_sub", "New Subcategory", "new_sub")
  if newsub then action = { type = "add_subcategory", parent = edit.sub_parent, name = newsub } end
  local renamed = popups.edit_popup(ctx, edit, "rename_cat", "Rename Category", "rename")
  if renamed then action = { type = "rename_category", id = edit.rename_id, name = renamed } end

  reaper.ImGui_PopStyleVar(ctx, 1)
  return action
end

--------------------------------------------------------------- sound list

-- Column user-ids (passed to TableSetupColumn) mapped to the sort keys core
-- understands. Reading the id, not the position, keeps sorting correct even if
-- the user reorders columns later. Only the old-build fallback header row still
-- reads this (see draw_sound_list) — the hand-drawn header names its own key.
local SORT_COLS = { [1] = "name", [2] = "dur", [3] = "ch", [4] = "loud", [5] = "pin" }
local COL_COUNT = 5
local LOUD_COL = 3 -- 0-based column index of the Loudness column

-- Which way a column sorts on its FIRST click. Pin prefers descending so that
-- click brings the pinned sounds to the TOP (ascending would bury them, which is
-- never what "sort by pinned" means — 2026-08-01); everything else starts
-- ascending. Clicking the column that is already sorting flips it instead.
local PREFER_DESC = { pin = true }

-- Feature detection for the "Show in library" scroll (checked once at load, the
-- house idiom): without it the row is still selected, it just isn't scrolled to.
local HAS_CLIPPER_INCLUDE = reaper.ImGui_ListClipper_IncludeItemByIndex ~= nil
  and reaper.ImGui_SetScrollHereY ~= nil
local HAS_PREFER_DESC = reaper.ImGui_TableColumnFlags_PreferSortDescending ~= nil

-- The last "Show in library" request this table has already acted on. UI-local
-- scratch like `edit` and `echo`: the entry script counts requests up and never
-- has to be told when one has been served.
local revealed_seq = nil

-- Which column the open header menu was armed over. The Loudness header offers the
-- measurement list on top of the width reset; every other header offers the reset
-- alone.
local menu_col = nil

-- Arms the header menu for `col`, and is why ImGui's own header menu never reaches
-- the screen. Call it IMMEDIATELY after that column's TableHeader — three details
-- have to line up, and all three are ImGui's, not ours:
--
--  * RELEASE, not press. ImGui arms its menu on the release, so a menu opened on the
--    press is simply replaced a moment later.
--  * Hover tested with AllowWhenBlockedByPopup, which is how ImGui tests it too. The
--    plain test (and the whole column-hover flag) goes dead while ANY popup is open,
--    so a fast second right-click — press and release inside one frame, with the last
--    menu still up — would arm ImGui's menu and not ours.
--  * Right after TableHeader. ImGui opens its popup inside that call; the last popup
--    opened at a level is the one that survives, so ours must be opened after it, in
--    the same frame.
--
-- What we are replacing: ImGui's "size all columns to default" doesn't restore the
-- widths TableSetupColumn asks for — in a resizable table ImGui reads "default" as
-- "shrink each column to fit its contents", which collapses the pin column (its
-- header is a drawn glyph, so ImGui measures it as empty).
local function arm_header_menu(ctx, col)
  if reaper.ImGui_IsMouseReleased(ctx, 1)
    and reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenBlockedByPopup()) then
    menu_col = col
    reaper.ImGui_OpenPopup(ctx, "hdr_menu")
  end
end

-- The sort arrow, painted at `x` and centred between `y0`/`y1`. Up = ascending,
-- ImGui's own convention. Points are given bottom-left, bottom-right, apex (the
-- waveform's playhead caret's winding).
--
-- BOTH COORDINATES ARE SNAPPED TO WHOLE PIXELS (2026-08-11, user-reported: "the
-- sort arrow looks different for the pin column"). Every column draws the same
-- triangle, but the pin column's x came out of a cell edge — a round number —
-- while a text column's was a measured text width added to a cursor, landing
-- part-way across a pixel. A 7×4 shape smeared over two pixel columns really
-- does look like a different, softer arrow. The pin column's crisp one is the
-- one the user picked, so all of them snap to that grid now.
local function sort_arrow(ctx, x, y0, y1, asc, color)
  local w = M.SORT_ARROW_W
  local h = math.floor(w * 0.6)
  x = math.floor(x + 0.5)
  local cy = math.floor((y0 + y1) * 0.5)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if asc then
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      x, cy + h * 0.5, x + w, cy + h * 0.5, x + w * 0.5, cy - h * 0.5, color)
  else
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      x, cy - h * 0.5, x + w, cy - h * 0.5, x + w * 0.5, cy + h * 0.5, color)
  end
end

-- One header cell: the stock TableHeader — which keeps the hover highlight, the
-- resize grip and our own right-click menu — plus the sort arrow painted BY US,
-- immediately after the label (2026-08-11, user-reported: ImGui draws its arrow
-- hard against the cell's right edge, "far away from the text", which on the
-- stretched Name column is most of the window away).
--
-- That position isn't configurable, and ImGui draws the arrow whenever it owns
-- the sorting — so the table is no longer Sortable and the click is read here
-- instead. Nothing changes outside this file: the same `set_sort` action goes to
-- the entry script, which has always been the one doing the actual ordering.
--
-- `arrow_zone`, when given, centres the arrow in that many pixels at the cell's
-- RIGHT end instead of placing it after the label — for the pin column, whose
-- "label" is a glyph painted over the header afterwards.
local function header_cell(ctx, state, idx, label, key, arrow_zone)
  reaper.ImGui_TableSetColumnIndex(ctx, idx)
  -- The label's own origin: TableHeader draws it at the cursor, exactly as
  -- group_row's hand-drawn name does (never from the item rect, which starts at
  -- the cell's padding edge).
  local text_x = select(1, reaper.ImGui_GetCursorScreenPos(ctx))
  reaper.ImGui_TableHeader(ctx, label)
  arm_header_menu(ctx, idx)

  local action
  -- A PRESS THAT IMGUI GAVE TO THIS HEADER, not "the mouse came up over it"
  -- (2026-08-12, user-reported: dragging a column's edge to resize it also
  -- re-sorted that column — two separate gestures landing as one).
  --
  -- The resize grip is a separate invisible item that ImGui submits BEFORE the
  -- header row and that OVERLAPS both headers it sits between. It declares
  -- itself as an overlapping item, which switches OFF the "another item is
  -- active" guard inside IsItemHovered — so the header answers "the cursor is on
  -- me" for the whole drag, and a hover+release test fires on the mouse-up that
  -- ends the resize. What the grip can't do is take the header ACTIVE: only a
  -- press ImGui routes to the header itself does that. So the sort waits for
  -- this header to go active and then be let go on top of itself, which is
  -- exactly what ImGui's own header does with the click it keeps for sorting.
  if key and reaper.ImGui_IsItemDeactivated(ctx) and reaper.ImGui_IsItemHovered(ctx) then
    -- NOT the `cond and a or b` idiom: flipping a column that is currently
    -- ASCENDING wants `false`, which that idiom silently discards.
    local asc
    if state.sort.col == key then asc = not state.sort.asc
    else asc = not PREFER_DESC[key] end
    action = { type = "set_sort", col = key, asc = asc }
  end

  if key and state.sort.col == key then
    local x1 = select(1, reaper.ImGui_GetItemRectMax(ctx))
    local y0, y1 = select(2, reaper.ImGui_GetItemRectMin(ctx)), select(2, reaper.ImGui_GetItemRectMax(ctx))
    local ax = arrow_zone
      and (x1 - arrow_zone * 0.5 - M.SORT_ARROW_W * 0.5)
      or (text_x + select(1, reaper.ImGui_CalcTextSize(ctx, label)) + M.SORT_ARROW_GAP)
    -- Never past the cell: a header squeezed narrow ellipsises its own label,
    -- and an arrow drawn beyond that would sit in the next column.
    local max_x = x1 - M.SORT_ARROW_W - 2
    if ax > max_x then ax = max_x end
    sort_arrow(ctx, ax, y0, y1, state.sort.asc, T.TEXT_SECONDARY)
  end

  return action
end

-- The menu itself, submitted once INSIDE the table just before EndTable — the popup
-- has to be submitted every frame, whether or not it is open.
local function draw_header_menu(ctx, state)
  local action
  local unit = loud_unit(state)

  if reaper.ImGui_BeginPopup(ctx, "hdr_menu") then
    if menu_col == LOUD_COL then
      for _, u in ipairs(LOUD_UNITS) do
        if reaper.ImGui_MenuItem(ctx, u.menu, nil, u.field == unit.field) then
          action = { type = "set_loud_unit", field = u.field }
        end
      end
      reaper.ImGui_Separator(ctx)
    end
    if reaper.ImGui_MenuItem(ctx, "Reset Column Widths") then
      action = { type = "reset_columns" }
    end
    reaper.ImGui_EndPopup(ctx)
  end

  return action
end

-- The one confirmation a delete gets. Modal, so it can't be left half-answered
-- behind the list, and drawn after the table so it isn't tied to a row that the
-- clipper may scroll out of existence mid-decision.
--
-- ONE string for OpenPopup and BeginPopupModal, and it must be the SAME string.
-- ImGui's "###" does NOT strip down to the id for matching — a label
-- "DELETE SOUND###confirm_delete" hashes as "###confirm_delete", which is a
-- DIFFERENT id from plain "confirm_delete". The 2026-08-08 recasing changed
-- only the Begin side, so OpenPopup fired at an id no popup owned and Delete
-- silently stopped working (caught by the 2026-08-09 Fable review; the same
-- misconception is corrected in the UI skill's Window titles section).
local DELETE_MODAL = "DELETE SOUND###confirm_delete"
local function draw_delete_confirm(ctx)
  local action
  local del = edit.del
  if not del then return nil end

  if del.open then
    reaper.ImGui_OpenPopup(ctx, DELETE_MODAL)
    del.open = false
  end

  -- The one titled panel that doesn't come through theme.begin_window (a modal
  -- begins itself), so it pushes the centred title by hand rather than being
  -- the single panel in the tool wearing its name on the left.
  local centred = theme.push_title_center(ctx)
  local modal_open = reaper.ImGui_BeginPopupModal(ctx, DELETE_MODAL, nil,
    reaper.ImGui_WindowFlags_AlwaysAutoResize())
  theme.pop_title_center(ctx, centred)
  if modal_open then
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, string.format("Delete \"%s\"?", del.name))
    reaper.ImGui_Dummy(ctx, 0, 4)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY,
      "The sound and its Library record move to this Library's")
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY,
      "trash folder.")
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY,
      "yb-Reference can't restore deleted sounds yet.")
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

-- The table's INTERNAL NAME, which is also its identity in ImGui's own settings
-- file: ImGui saves the widths a user drags there, keyed by a hash of this
-- string, and hands them straight back the next time a table of that name is
-- created — in this REAPER session or any later one. "Reset column widths" works
-- by asking for a name ImGui has never seen, since a table with nothing saved
-- starts at the widths TableSetupColumn asks for (there is no call that sets a
-- column's width directly).
--
-- Two parts, and BOTH are needed for a reset to mean the same thing every time
-- (2026-08-11, user-reported: "it gives a different effect based on which header
-- you right click"; it was really a different effect on each PRESS):
--
--  * COL_LAYOUT — bumped BY HAND here whenever the default widths in theme.lua
--    change. Without it, widths a user dragged to suit the old layout are
--    restored over the new defaults and the change never reaches them.
--  * state.col_gen — the user's own reset count, now persisted (see
--    reaper_api.get_col_gen). It used to restart at 0 each run, so a reset
--    stepped back onto names this REAPER had already saved widths under and
--    restored those instead of the defaults — a different set each press, until
--    it walked past the last one.
--
-- The name is rebuilt only when the count changes, never per frame.
-- 1 = the original widths; 2 = the 2026-08-11 shorter Ch/Loudness; 3 = the same
-- widths again, bumped 2026-08-12 at the user's ask to drop the widths that got
-- dragged around while the resize-also-sorts bug above was being found (one set
-- had reached 139/117). Bumping is the ONLY way to put a column back — ImGui has
-- no "set this width" call — so the stamp means "the defaults this build asks
-- for", and re-landing everyone on them is the same operation as changing them.
local COL_LAYOUT = 3
local table_id, table_id_gen = nil, nil
local function sounds_table_id(state)
  local gen = state.col_gen or 0
  if gen ~= table_id_gen then
    table_id, table_id_gen = "sounds##" .. COL_LAYOUT .. "." .. gen, gen
  end
  return table_id
end

local function draw_sound_list(ctx, state, res)
  local action
  local sounds = state.visible_sounds
  local unit = loud_unit(state)
  local font = res.icon_font

  -- A NEW VIEW STARTS AT THE TOP (2026-08-10, user-reported: switching away
  -- from a deeply-scrolled category "glitched the whole browser" — the table
  -- kept the OLD scroll for a frame, drew the new short list somewhere past
  -- its own end (a blank flash), then clamped). This watch fires on the first
  -- frame the new list exists, whatever changed it — a sidebar click, search,
  -- nav arrows, a deleted category — and the reset is handed to the table's
  -- own Begin below, so that same first frame already draws at the top. A
  -- reveal ("Show in library") survives it: its SetScrollHereY runs later
  -- inside the same table and overwrites this.
  local vk = (state.view and (tostring(state.view.scope) .. "\0" .. tostring(state.view.id)) or "")
    .. "\0" .. (state.query or "")
  if vk ~= last_view_key then
    if last_view_key ~= nil then list_scroll.pending = 0 end
    last_view_key = vk
  end

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
  -- NOT Sortable on a build that can draw its own headers: ImGui draws the sort
  -- arrow itself whenever it owns the sorting, always at the cell's right edge,
  -- and 2026-08-11 moved that arrow next to the label (see header_cell). The
  -- clicks are read there instead. The old fallback row can't be armed per
  -- column, so on those builds ImGui keeps both its sorting and its arrow.
  if not HAS_TABLE_HEADER then flags = flags | reaper.ImGui_TableFlags_Sortable() end

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
  local spacing_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))

  -- THE ROW'S HIGHLIGHT NOW FILLS THE WHOLE ROW (2026-08-08, user-reported: "a
  -- bit of empty space between each row, you can tell from the row background
  -- highlights"). The cause was a split of duties: the highlight is the Name
  -- cell's Selectable, sized to one line of TEXT, while the row's own pitch came
  -- from that line PLUS the table's CellPadding above and below it — so every
  -- row wore an unfilled band of exactly CellPadding.y at each end.
  --
  -- The fix moves the padding INSIDE the highlight rather than removing it:
  -- CellPadding.y goes to 0 and the same number is added to `row_h` below. Row
  -- pitch is arithmetically identical to before — the user's explicit ask ("make
  -- the overall spacing the same, just make the rows make up for it") — and the
  -- fill now spans it. CellPadding.x is untouched: that is column gutter, and
  -- nothing is wrong with it.
  local cellpad_x, cellpad_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding())
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding(), cellpad_x, 0)

  -- One row height for the whole table (2026-08-05: tightened from control
  -- height, which read as too spaced out for a dense data list — that number was
  -- sized for a click target, not a line of text). It is the text's own line
  -- height PLUS the cell padding the push above just took away, so the row is
  -- exactly as tall as it always was and the Name cell's Selectable — which IS
  -- the highlight — now covers all of it instead of just the text band.
  local row_h = reaper.ImGui_GetTextLineHeight(ctx) + cellpad_y * 2

  -- THE RAIL (brief `table-scrollbar`, 2026-08-09 — supersedes the width
  -- prediction that briefly lived here): the scrollbar's strip is reserved
  -- ALWAYS. The table is drawn SCROLL_RAIL_W narrower and widgets.scrollbar
  -- puts a slim thumb in the strip, starting under the frozen header — so the
  -- columns never hear about scrolling at all: they sit identically in every
  -- category, and nothing jumps on the changeover (the reported glitch: ImGui's
  -- own bar took its width out of the Name column, one frame out of step with
  -- the prediction). The thumb is submitted BEFORE the table so its drag can
  -- steer this frame's scroll; it draws from last frame's numbers — one frame
  -- of thumb lag, imperceptible.
  local table_x, table_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  -- outer width/height 0 = fill the wrapping child region (see draw_main); a
  -- window squashed too thin skips the rail rather than starving the columns.
  local outer_w = 0
  if avail_w > M.SCROLL_RAIL_W * 3 then outer_w = avail_w - M.SCROLL_RAIL_W end
  if outer_w > 0 then
    -- Rail top sits below the header row and the hairline drawn under it.
    local rail_top = table_y + row_h + 3
    local new = widgets.scrollbar(ctx, "soundscroll", table_x + outer_w, rail_top,
      M.SCROLL_RAIL_W, avail_h - row_h - 3, list_scroll.y, list_scroll.max)
    if new then list_scroll.pending = new end
  end

  -- The parked scroll is handed to the table's own Begin, which applies it
  -- THIS frame (Codex 2026-08-10 — the in-table SetScrollY it replaces landed
  -- a frame late, so the fallback view reset above still flashed one stale
  -- frame, and a thumb drag steered with a round trip). SetNextWindowScroll
  -- reaches the ScrollY table's inner child — verified against imgui v1.90.9:
  -- BeginTable only ADDS a content-size hint to the same next-window data
  -- before BeginChildEx consumes it all. -1 leaves the x axis untouched.
  -- (Rare leak, accepted: a table culled before creating its child leaves the
  -- hint for the next window Begun — which here doesn't scroll, so a stray
  -- scroll-to-top target clamps to where it already is.)
  if list_scroll.pending and HAS_NEXT_SCROLL then
    reaper.ImGui_SetNextWindowScroll(ctx, -1, list_scroll.pending)
    list_scroll.pending = nil
  end

  -- ImGui's own bar can't be told to hold its space open or start below the
  -- header, and ScrollbarSize 0 trips an assert upstream (verified against
  -- imgui v1.90.9: Begin calls Scrollbar() whenever content overflows, and
  -- GetWindowScrollbarRect asserts the size is positive — ReaImGui arms those
  -- asserts as script errors). So the bar is reduced to an invisible sliver —
  -- SUB-pixel (0.02, the smallest that safely clears the assert; it was 1px
  -- until 2026-08-10, and the user could SEE the columns lose that pixel when
  -- a category started scrolling) — with every scrollbar colour transparent.
  -- Popped the moment BeginTable has taken them (the Begin-time-push idiom).
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize(), 0.02)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarBg(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabHovered(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabActive(), 0)

  if not reaper.ImGui_BeginTable(ctx, sounds_table_id(state), COL_COUNT, flags, outer_w, 0) then
    reaper.ImGui_PopStyleVar(ctx, 2)   -- ScrollbarSize + CellPadding
    reaper.ImGui_PopStyleColor(ctx, 7) -- 4 scrollbar + the 3 table colours
    return nil
  end
  reaper.ImGui_PopStyleVar(ctx, 1)   -- ScrollbarSize (CellPadding stays for the rows)
  reaper.ImGui_PopStyleColor(ctx, 4) -- the scrollbar sliver's colours

  -- Fallback only, for a ReaImGui without SetNextWindowScroll: applied from
  -- inside the table (the one scope where its scrolling window is current),
  -- landing a frame late — the degrade, not the design.
  if list_scroll.pending then
    reaper.ImGui_SetScrollY(ctx, list_scroll.pending)
    list_scroll.pending = nil
  end

  -- 5th arg is the column's stable user-id (see SORT_COLS). The sort flags below
  -- only reach ImGui on the old fallback path — where it is still the one
  -- sorting; the hand-drawn header carries the same two rules itself (Name is
  -- state.sort's own default, pin prefers descending — see PREFER_DESC).
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
  -- never what "sort by pinned" means — PREFER_DESC says the same thing to the
  -- hand-drawn header).
  local pin_flags = reaper.ImGui_TableColumnFlags_WidthFixed()
  if HAS_PREFER_DESC then pin_flags = pin_flags | reaper.ImGui_TableColumnFlags_PreferSortDescending() end
  reaper.ImGui_TableSetupColumn(ctx, "##pin", pin_flags, M.PIN_COL_W, 5)
  reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)

  -- The pushpins (header and rows alike) centre in the part of the pin column
  -- left of the sort arrow, so the arrow has somewhere to go and the pins keep
  -- one axis whether or not that column is the one sorting. `pin_cx` is that
  -- axis, measured once from the header (or from the first row on a build with
  -- no custom header) and shared by every pin drawn this frame — see pin_axis.
  local arrow_zone = pin_arrow_zone()
  local pin_cx
  -- The frozen header's height, for scroll_follow's top inset: rows scroll under
  -- it, so "visible" for a key-stepped row starts below it, not at the table's
  -- true top edge. It matches a body row now — with CellPadding.y at 0 the
  -- header takes its height from the explicit one passed to TableNextRow below.
  local header_h = row_h

  -- Header row, submitted by hand when the build allows it so the pin column's
  -- header can be the glyph itself; otherwise the stock row (blank pin header).
  -- Each header arms our own right-click menu the moment it is submitted, which is
  -- the only order that keeps ImGui's out (see arm_header_menu). The stock row
  -- can't be armed per column, so on those old builds ImGui's menu is what shows.
  if HAS_TABLE_HEADER then
    -- Explicit height: with CellPadding.y pushed to 0 the header would otherwise
    -- shrink to bare text and sit cramped against its own underline.
    reaper.ImGui_TableNextRow(ctx, reaper.ImGui_TableRowFlags_Headers(), row_h)
    action = header_cell(ctx, state, 0, "Name", "name") or action
    local ux0, _ = reaper.ImGui_GetItemRectMin(ctx)
    action = header_cell(ctx, state, 1, "Dur", "dur") or action
    action = header_cell(ctx, state, 2, "Ch", "ch") or action
    action = header_cell(ctx, state, LOUD_COL, unit.header, "loud") or action
    -- The pin column's "label" is the pushpin painted over the header below, so
    -- its arrow goes in the zone the pins already leave clear at the cell's
    -- right end — immediately right of the pin, wherever a resize puts it. The
    -- header pin is WHITE (2026-08-11, user's ask): it names the column, and
    -- TEXT_QUATERNARY is reserved for what nobody has to read.
    action = header_cell(ctx, state, 4, "##pin", "pin", arrow_zone) or action
    pin_cx = pin_axis(ctx, arrow_zone)
    pin_glyph(ctx, font, T.TEXT_PRIMARY, M.ICON_PIN_FS, pin_cx)
    -- The one hairline under the header (the flat-table separation the design
    -- calls for), spanning first column's left edge to last column's right.
    local ux1, uy1 = reaper.ImGui_GetItemRectMax(ctx)
    reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
      ux0, uy1 + 1.5, ux1, uy1 + 1.5, T.STROKE_TERTIARY, 1)
  else
    reaper.ImGui_TableHeadersRow(ctx)
  end

  -- OLD BUILDS ONLY (the stock header row above): there ImGui still owns the
  -- sorting, and this reports it so the entry re-orders the cached list — it
  -- ignores a repeat of the current sort, so emitting whenever ImGui flags it is
  -- safe. We never emit a "cleared" sort: a columned table always keeps one, and
  -- toggling to no sort and back re-shuffled the rows for a frame — that was the
  -- list "flashing". Asked only when the table IS sortable: ImGui hands back no
  -- sort specs at all otherwise.
  if not HAS_TABLE_HEADER and reaper.ImGui_TableNeedSort(ctx) then
    local ok, _, col_user_id, dir = reaper.ImGui_TableGetColumnSortSpecs(ctx, 0)
    -- Sort wins over a unit pick in the (practically impossible) frame that has
    -- both: reading the sort specs clears ImGui's "needs sorting" flag, so a
    -- dropped sort is lost for good, while a dropped unit pick is one more click.
    if ok and SORT_COLS[col_user_id] then
      action = { type = "set_sort", col = SORT_COLS[col_user_id],
        asc = dir == reaper.ImGui_SortDirection_Ascending() }
    end
  end

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
  -- The Name cell's usable width, measured off the first row submitted and shared
  -- by every row after it (one column, one width — asking per row would be the
  -- same answer at a per-frame cost). A SpanAllColumns Selectable renders its
  -- label against the WHOLE row, not its own cell, so a long name would otherwise
  -- run straight under Dur/Ch — the same "two runs of text competing for the same
  -- pixels" rule the sidebar's count/name split answers.
  local name_w
  reaper.ImGui_ListClipper_Begin(res.clipper, #sounds)
  -- The clipper only submits what's on screen, and the row we're revealing is
  -- exactly the one that usually isn't — this makes it submit that row too, so
  -- there's something for SetScrollHereY to aim at.
  if reveal_row and HAS_CLIPPER_INCLUDE then
    reaper.ImGui_ListClipper_IncludeItemByIndex(res.clipper, reveal_row)
  end
  -- Same for a key-stepped row: it's usually the one just OUTSIDE the clipped
  -- band, and scroll_follow needs it submitted to have a rect to test. Without
  -- IncludeItemByIndex the step still happens — the list just doesn't scroll
  -- until the selection re-enters view (the house degrade-don't-break rule).
  if nav.list_row and HAS_CLIPPER_INCLUDE then
    reaper.ImGui_ListClipper_IncludeItemByIndex(res.clipper, nav.list_row)
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
      name_w = name_w or select(1, reaper.ImGui_GetContentRegionAvail(ctx))
      -- Only the visible half is cut; the id after ## is the untouched sound id,
      -- so a name that changes its cut can never change the row's identity.
      local picked = reaper.ImGui_Selectable(ctx,
        widgets.ellipsize(ctx, s.name, name_w) .. "##" .. s.id,
        state.browse_id == s.id, span, 0, row_h)
      reaper.ImGui_PopStyleVar(ctx, 2)
      if picked then
        action = { type = "browse_sound", id = s.id }
        nav_owner = "list" -- the arrows follow the last-clicked pane
      end
      -- Scroll the revealed row into the middle of the list, on the one frame
      -- the request is fresh.
      if reveal_row == i and HAS_CLIPPER_INCLUDE then
        reaper.ImGui_SetScrollHereY(ctx, 0.5)
      end
      -- A key-stepped row scrolls into view at the edge it entered from; the
      -- frozen header row masks the table's top band (scroll_follow's inset).
      if nav.list_row == i then
        scroll_follow(ctx, nav.dir, header_h)
      end
      -- The Name selectable spans the whole row (SpanAllColumns), so its hover
      -- marks the whole row as hovered — that is what feeds the sidebar echo.
      if reaper.ImGui_IsItemHovered(ctx) then
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
          if reaper.ImGui_MenuItem(ctx, "Unpin (Keep Audio Copy)") then
            action = { type = "unpin", id = pinned.id }
          end
        elseif reaper.ImGui_MenuItem(ctx, "Pin To This Project") then
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
      -- The axis, if the header didn't set it (no custom header row on this
      -- build): the first row submitted stands in, and every later one shares it.
      pin_cx = pin_cx or pin_axis(ctx, arrow_zone)
      if pinned then
        pin_glyph(ctx, font, T.ACCENT, M.ICON_PIN_FS, pin_cx)
      end
    end
  end

  -- The header right-click menu, submitted last so its own items sit at the end of
  -- the table's id stack (it is armed up at the header row). Always CALLED — the
  -- popup must be submitted every frame — then merged without clobbering an action
  -- an earlier row already reported.
  local hdr_action = draw_header_menu(ctx, state)
  action = action or hdr_action

  -- What the rail thumb reads next frame — taken here because this is the
  -- scrolling window (BeginTable leaves its inner child current through row
  -- submission; verified upstream 2026-08-09).
  list_scroll.y = reaper.ImGui_GetScrollY(ctx)
  list_scroll.max = reaper.ImGui_GetScrollMaxY(ctx)

  reaper.ImGui_EndTable(ctx)
  reaper.ImGui_PopStyleVar(ctx, 1) -- the CellPadding pushed before BeginTable
  reaper.ImGui_PopStyleColor(ctx, 3)

  local confirmed = draw_delete_confirm(ctx)
  action = action or confirmed

  return action
end

--------------------------------------------------------------- main panel

-- Fallback guidance for the strip's idle face — what the old status row's
-- default hint used to say, updated for the labelled Add button.
local IDLE_HINT = "Choose a sound to audition it. Drag audio files here or use + Add Sounds."

-- The info row's tech-details line ("48 kHz · 24-bit · WAV · stereo"), rebuilt
-- only when the browsed sound changes — never formatted per frame (frame-
-- allocation rule). The wording itself is core.techfacts.format, shared with
-- the working-view bar since 2026-08-07 so the two lines can't drift apart.
-- Keyed on the info TABLE as well as the id (Codex, 2026-07-29 review):
-- browse_sound builds a fresh info table on every pick, so re-picking the same
-- row after its file came back (or went away) invalidates the cache — an
-- id-only key kept showing the old answer.
local tech = { id = nil, info = nil, text = nil }
local function tech_line(state)
  local s, info = state.browse, state.browse_info
  if not s then
    tech.id, tech.info, tech.text = nil, nil, nil
    return nil
  end
  if tech.id ~= s.id or tech.info ~= info then
    tech.id, tech.info = s.id, info
    tech.text = techfacts.format(info)
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
    local gs = M.ICON_SM_FS
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

-- Toolbar (2026-07-29 review): search top-left on the list it filters; the one
-- global action top-right — Add sounds, labelled. The folder and gear squares
-- that used to follow it left on 2026-08-10 (`.brief/settings-move`): the gear
-- lives in the working view's bar now, and the folder became a Settings row.
local function draw_toolbar(ctx, state, res)
  local action

  -- The search field: filled, no outline, magnifier embedded in its left
  -- padding, hint dimmer than typed text (theme's TextDisabled) — a native-tool
  -- search, not a web form.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), M.SEARCH_ICON_PAD, M.FRAME_PAD_Y)
  reaper.ImGui_SetNextItemWidth(ctx, M.SEARCH_W)
  -- Local buffer drives the box immediately; the entry re-filters next frame.
  local _, q = reaper.ImGui_InputTextWithHint(ctx, "##search", "Search names and notes", edit.query or "")
  reaper.ImGui_PopStyleVar(ctx, 2)
  search_icon(ctx, res.icon_font)
  -- Searching means the SOUND LIST is what's being narrowed — while the box is
  -- active the arrows step results, whatever pane was clicked before.
  if reaper.ImGui_IsItemActive(ctx) then nav_owner = "list" end
  if q ~= (edit.query or "") then
    edit.query = q
    action = { type = "set_query", query = q }
  end

  -- The one global action, placed by the measure-then-push idiom (same as the
  -- old master fader). If a narrow window leaves no room the button stays put
  -- and clips — nothing jumps.
  reaper.ImGui_SameLine(ctx)
  local add_label = "+ Add Sounds"
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local add_w = select(1, reaper.ImGui_CalcTextSize(ctx, add_label)) + pad_x * 2
  local cx = reaper.ImGui_GetCursorPosX(ctx)
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local target = cx + avail - add_w
  if target > cx then reaper.ImGui_SetCursorPosX(ctx, target) end

  local cat, sub = view_target(state.library, state.view)
  local dest = categories.get(state.library, sub or cat)
  if reaper.ImGui_Button(ctx, add_label) then
    action = { type = "pick", category = cat, subcategory = sub }
  end
  local add_tip = dest
    and ("Choose audio files to add to " .. dest.name .. ".")
    or "Choose audio files to add as Uncategorised."
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), add_tip)

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

  -- The strip's height (drag-resizable since 2026-08-06): the in-flight drag
  -- value while the seam is held, else the remembered preference, else the
  -- default. Clamped EVERY frame, display only — never below the floor, and
  -- never so tall the table above loses its header plus a couple of sound
  -- rows, measured from the live row metrics so the ceiling follows the
  -- window (a bigger window allows a bigger strip). The stored preference is
  -- left alone by the clamp: squeezing the window only compresses the strip
  -- for as long as the window stays small.
  local cellpad_y = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding()))
  local row_block = reaper.ImGui_GetTextLineHeight(ctx) + cellpad_y * 2
  local min_list_h = row_block * (M.BROWSER_LIST_MIN_ROWS + 1) -- +1 = the header row
  local wave_max = avail_h - min_list_h - gap_y - M.RULER_H - (info_h + gap_y)
  local wave_h = split.live or state.browser_wave_h or M.BROWSER_WAVE_H
  if wave_h > wave_max then wave_h = wave_max end
  if wave_h < M.BROWSER_WAVE_MIN_H then wave_h = M.BROWSER_WAVE_MIN_H end

  local list_h = avail_h - (wave_h + M.RULER_H + gap_y) - (info_h + gap_y)
  if list_h < min_list_h then list_h = min_list_h end

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
    -- The categories stop keeps the list BRIGHT (context, not ringed) so a
    -- category click visibly filters it.
    walkthrough_ui.note(ctx, state.walkthrough, "list")
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
    local lx1, ly1 = reaper.ImGui_GetItemRectMax(ctx)
    -- The list is a browsing pane: a click inside it keeps OS focus so the
    -- arrow keys can step the rows afterwards (ui/focus.lua).
    focus.keep_zone(lx0, ly0, lx1, ly1)
    list_rect = { x0 = lx0, y0 = ly0 }
  end

  -- The seam between the list and the strip is the strip's resize handle
  -- (2026-08-06): an InvisibleButton laid exactly over the ItemSpacing gap,
  -- submitted out of flow — the cursor is put back afterwards — so the layout
  -- the budget above counted on doesn't move by a pixel. Dragging it moves the
  -- strip's top edge (seam up = strip taller); the result is committed on
  -- release and remembered like the sidebar width. Right-click or double-click
  -- snaps back to the default height — the same reset gesture every fader
  -- answers to (widgets.wants_reset).
  if list_open then
    local seam_x, seam_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local seam_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    if seam_w >= 1 then
      reaper.ImGui_SetCursorScreenPos(ctx, seam_x, seam_y - gap_y)
      reaper.ImGui_InvisibleButton(ctx, "##strip_seam", seam_w, gap_y)
      local hovered = reaper.ImGui_IsItemHovered(ctx)
      local active = reaper.ImGui_IsItemActive(ctx)
      if hovered or active then
        -- Feature-detected: an older ReaImGui defines no ResizeNS cursor, and
        -- calling it raises mid-drag (Codex, 2026-08-06). No cursor is a
        -- cosmetic loss; a raise kills the script.
        if RESIZE_CURSOR then reaper.ImGui_SetMouseCursor(ctx, RESIZE_CURSOR) end
        -- The affordance: a hairline across the seam, accent while grabbed.
        -- Drawn over the gap, never laid out — nothing shifts.
        reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
          seam_x, seam_y - gap_y * 0.5, seam_x + seam_w, seam_y - gap_y * 0.5,
          active and T.ACCENT or T.STROKE_PRIMARY, 1)
      end
      if widgets.wants_reset(ctx) then
        -- No height in the action = "back to whatever the default is", so the
        -- stored slot is cleared rather than frozen at a copy of the default.
        action = action or { type = "set_browser_wave_h" }
        split.hold, split.live, split.start_h = active, nil, nil
      elseif reaper.ImGui_IsItemActivated(ctx) then
        -- Anchor on the CLAMPED on-screen height, not the stored one: a value
        -- saved on a big screen must start dragging from where the eye sees it.
        split.start_h = wave_h
        split.start_my = select(2, reaper.ImGui_GetMousePos(ctx))
        split.hold = false
      elseif active and not split.hold and split.start_h then
        local my = select(2, reaper.ImGui_GetMousePos(ctx))
        local live = split.start_h - (my - split.start_my)
        if live > wave_max then live = wave_max end
        if live < M.BROWSER_WAVE_MIN_H then live = M.BROWSER_WAVE_MIN_H end
        split.live = live
      elseif reaper.ImGui_IsItemDeactivated(ctx) then
        if split.live and not split.hold and split.live ~= split.start_h then
          action = action or { type = "set_browser_wave_h", h = split.live }
        end
        split.start_h, split.start_my, split.live, split.hold = nil, nil, nil, false
      end
      reaper.ImGui_SetCursorScreenPos(ctx, seam_x, seam_y)
    end
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
  --
  -- The strip carries the same time ruler as the working view since 2026-08-06
  -- (user reversal of the original strip-stays-bare brief pick, after living
  -- with the working-view ruler). The bars keep their full height (wave_h —
  -- BROWSER_WAVE_H by default, drag-resizable via the seam above): the block
  -- grows by RULER_H and the table above pays for it (list_h). Its own cache
  -- slot ("browse") so the two windows never thrash one entry.
  local wave_action = waveform.draw(ctx, state, wave_h,
    { id = state.browse_id, waveform = state.browse_waveform,
      ruler = true, slot = "browse",
      duration = state.browse and state.browse.duration or nil })
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
        label = "Add to " .. (dest and dest.name or "your Library") })
    action = action or drop_action
    -- The walkthrough's add-sounds stop rings THIS rect — the real drop
    -- target (list + strip), not the button, so "where exactly?" is shown.
    walkthrough_ui.note_rect(ctx, state.walkthrough, "drop", x0, y0, sx1, sy1)
  end

  -- The info row under the strip (2026-07-29): the browsed sound's technical
  -- facts on the left (or the standing status/drag hint while one applies —
  -- same slot, so nothing moves), and on the right the transport pair, the loop
  -- and auto-audition toggles and the PREVIEW master fader. The left text lives
  -- in a zero-padding child clipped to the space that block leaves, so a long
  -- line can never draw over the controls (the transport readout's idiom).
  local small = theme.push_small_font(ctx)
  local label_w = select(1, reaper.ImGui_CalcTextSize(ctx, "Preview")) -- must match transport.draw_master
  if small then reaper.ImGui_PopFont(ctx) end
  local btn = reaper.ImGui_GetFrameHeight(ctx)
  local gap_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  -- The right block is play/pause + stop + loop + the ear + the PREVIEW fader.
  -- (The ear joined 2026-08-07, moved out of the working view's bar:
  -- auto-audition only ever governed THIS window's click-to-hear, so it sits
  -- beside the audition strip it controls; loop joined it 2026-08-11 so
  -- browsing doesn't need the other window to repeat a sound; the transport
  -- pair joined 2026-08-12 — until then the Library could start a sound but
  -- had no way to stop one.)
  --
  -- Four squares now, and the block is what the tech line on the left is sized
  -- AGAINST (left_w, below), so those ~54px come out of the text's share: it
  -- truncates a little sooner on a narrow window, and the two never share a
  -- pixel. The row's HEIGHT is a control either way, so the pane budget above
  -- is untouched.
  local squares = btn * 4 + gap_x * 4
  local fader_block = squares + label_w + 6 + M.SLIDER_W
  local row_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local left_w = row_w - fader_block - 8
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
  -- IMPORTANT: never write `action = action or draw(...)` — Lua short-circuits,
  -- so once an earlier widget has an action the draw call is SKIPPED and its
  -- widget vanishes for that frame. Always draw, then merge.
  if left_w > 0 then reaper.ImGui_SameLine(ctx) end
  -- The four squares, pushed right so they sit against the fader (which
  -- right-aligns itself in whatever remains — the measure-then-push idiom).
  local cx = reaper.ImGui_GetCursorPosX(ctx)
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local target = cx + avail - fader_block
  if target > cx then reaper.ImGui_SetCursorPosX(ctx, target) end
  -- The transport pair (2026-08-12), leading the block in the working view's
  -- own order — play/pause, stop, then loop — and drawn by the SAME two
  -- functions that view's cluster uses (ui/transport.lua), so the two
  -- windows' transports cannot drift apart. Pointed at the "browse" slot:
  -- they act on the sound on the strip, and the pause they park is the
  -- Library's own, never the working view's.
  --
  -- Clicking a row still auditions from the start, exactly as before — this
  -- pair is how you stop one, and how you pick a paused audition back up.
  local browse_slot = { slot = "browse", id = state.browse_id, sound = state.browse }
  local play_action = transport.draw_play(ctx, state, res.icon_font, browse_slot)
  action = action or play_action
  reaper.ImGui_SameLine(ctx)
  local stop_action = transport.draw_stop(ctx, state, res.icon_font, browse_slot)
  action = action or stop_action
  reaper.ImGui_SameLine(ctx)
  -- The SAME loop setting the working view's bar carries (state.loop): one
  -- truth, reachable from whichever window you're listening in.
  if widgets.toggle(ctx, "browseloop", LOOP, state.loop,
      "Loop: keep the sound repeating until you stop it",
      res.icon_font, "repeat") then
    action = action or { type = "toggle_loop" }
  end
  reaper.ImGui_SameLine(ctx)
  if widgets.toggle(ctx, "auto", "A", state.auto_audition,
      "Auto-audition: play a sound the moment you click it in this browser",
      res.icon_font, "ear") then
    action = action or { type = "toggle_auto" }
  end
  reaper.ImGui_SameLine(ctx)
  local master_action = transport.draw_master(ctx, state)
  action = action or master_action

  -- Settings is drawn by ui/app.lua, not here: since 2026-08-08 it is a real
  -- top-level window rather than a modal inside this panel, so closing the
  -- browser must not take it with it. Since 2026-08-10 nothing in this window
  -- touches it at all — the gear lives in the working view's bar.

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

  -- A reopened window starts arrow-browsing back on the sound list (see
  -- nav_owner above). Frame-count gap = the window wasn't drawn last frame.
  if reaper.ImGui_GetFrameCount ~= nil then
    local frame = reaper.ImGui_GetFrameCount(ctx)
    if last_draw_frame ~= frame - 1 then nav_owner = "list" end
    last_draw_frame = frame
  end

  -- Arrow-key browsing, read at the top of the draw so this same frame's panes
  -- can scroll-follow the step. Only while this window (or a child of it)
  -- holds focus, no popup is up (an open menu's arrow keys must stay its own),
  -- and no drag is in flight. The search box deliberately does NOT block
  -- stepping: a single-line field ignores Up/Down, so refining a search and
  -- walking its results coexist — the Media Explorer's behaviour.
  if HAS_ARROW_NAV and not state.drag
    and reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows()) then
    local popup_up = HAS_POPUP_ANY and reaper.ImGui_IsPopupOpen(ctx, "",
      reaper.ImGui_PopupFlags_AnyPopupId() | reaper.ImGui_PopupFlags_AnyPopupLevel())
    if not popup_up then
      -- Left/Right drive the audition itself (2026-08-08, the user's ask —
      -- "standard stuff"): Left restarts the browsed sound, Right jumps to the
      -- end of playback. Same seek action a click on the strip's waveform
      -- reports, so reference-mode refusal and auditioning behave identically.
      -- Skipped while ANY item is active — unlike Up/Down, these two are the
      -- text cursor's own keys in the search box.
      if state.browse and not reaper.ImGui_IsAnyItemActive(ctx) then
        if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_LeftArrow()) then
          action = { type = "seek", fraction = 0, target = "browse" }
        elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_RightArrow()) then
          action = { type = "seek", fraction = 1, target = "browse" }
        end
      end
      local step = 0
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_DownArrow()) then step = 1
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow()) then step = -1 end
      if step ~= 0 then
        -- NOT the `cond and a or b` idiom: a step refused at a list edge
        -- returns nil, which would wrongly fall through to the other pane.
        if nav_owner == "sidebar" then
          action = step_sidebar(state, step)
        else
          action = step_list(state, step)
        end
        -- Precedence, decided (Codex, 2026-08-08 review): a panel action in
        -- the SAME frame replaces this step (merge_action below prefers new).
        -- Deliberate — the collisions that can really happen (a keystroke's
        -- set_query, a header click's set_sort) stay wrong until the next
        -- interaction if dropped, while a dropped arrow press is one missed
        -- step. The step's scroll-follow may then run without its selection
        -- change: one frame of scroll, self-corrected on the next press.
      end
    end
  end

  -- Sidebar: full-bleed chrome. Square corners (it meets the window edges) and
  -- a drag-resizable right edge where the build supports it (ImGui's own ini
  -- remembers the width the user leaves it at). ZERO inner padding since
  -- 2026-08-10 (user-reported: "the category backgrounds start slightly
  -- further in" — the old SB_PAD padding inset every row's fill from the
  -- panel edges): a row's fill now runs the strip's full width and the first
  -- row butts the top edge, the Settings nav's own grammar. The NAME is inset
  -- SB_PAD inside the row instead (group_row), never by padding the panel.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), T.BG_CHROME)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 0)
  local sb_flags = 0
  if HAS_CHILD_RESIZE then sb_flags = reaper.ImGui_ChildFlags_ResizeX() end
  -- The drag has a FLOOR (2026-08-07, user's ask). A child window goes through
  -- the same Begin path as a real one, so the standard size constraint applies
  -- to its resize edge; the ceiling is left effectively open, since a wide
  -- sidebar costs nothing but the list's width, which the user can see.
  -- Guarded like every other optional call: on a build without it the edge just
  -- keeps its old unbounded drag.
  --
  -- This floor is also an INPUT to theme.BROWSER_MIN_W (the browser window's
  -- own width floor, next to MIN_WIN_H in theme.lua): that number assumes the
  -- sidebar can never be narrower than SIDEBAR_MIN_W, so the info row always
  -- gets at least the room BROWSER_MIN_W was sized for. Raising this value
  -- without revisiting that derivation would let the splitter eat into room
  -- the row's floor already promised it.
  if HAS_SIZE_CONSTRAINTS then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, M.SIDEBAR_MIN_W, 0, 10000, 10000)
  end
  -- Style var popped the instant the child has taken it (a Begin-time read).
  local sb_open = reaper.ImGui_BeginChild(ctx, "sidebar", M.SIDEBAR_W, 0, sb_flags)
  reaper.ImGui_PopStyleVar(ctx, 1)
  if sb_open then
    action = merge_action(action, draw_sidebar(ctx, state))
    reaper.ImGui_EndChild(ctx)
    -- Walkthrough stop 3 rings the whole sidebar (the closed child is the
    -- last item here — the seam line below reads the same rect).
    walkthrough_ui.note(ctx, state.walkthrough, "sidebar")
  end
  reaper.ImGui_PopStyleColor(ctx)

  -- One hairline on the seam (the only separation the two surfaces need), then
  -- the main panel flush against it.
  local sx1, sy1 = reaper.ImGui_GetItemRectMax(ctx)
  local _, sy0 = reaper.ImGui_GetItemRectMin(ctx)
  -- The sidebar is a browsing pane too: clicks inside keep OS focus so the
  -- arrows can step the side column afterwards (ui/focus.lua).
  if sb_open then
    focus.keep_zone(select(1, reaper.ImGui_GetItemRectMin(ctx)), sy0, sx1, sy1)
  end
  reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
    sx1 + 0.5, sy0, sx1 + 0.5, sy1, T.STROKE_TERTIARY, 1)

  reaper.ImGui_SameLine(ctx, 0, 0)

  -- The main panel never scrolls (its list scrolls internally). Forbidding a
  -- scrollbar keeps its content width fixed — a scrollbar toggling on/off would
  -- change the width every frame and jitter the right-aligned toolbar cluster
  -- and fader that are sized from it.
  local main_flags = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), M.WINDOW_PAD, M.WINDOW_PAD)
  local main_child_flags = HAS_CHILD_PAD and reaper.ImGui_ChildFlags_AlwaysUseWindowPadding() or 0
  local main_open = reaper.ImGui_BeginChild(ctx, "main", 0, 0, main_child_flags, main_flags)
  reaper.ImGui_PopStyleVar(ctx, 1)
  if main_open then
    action = merge_action(action, draw_main(ctx, state, res))
    reaper.ImGui_EndChild(ctx)
  end

  -- The one-frame scroll-follow requests have been served (or their pane was
  -- clipped away this frame) — never carried across frames.
  nav.list_row, nav.view = nil, nil

  return action
end

return browser
