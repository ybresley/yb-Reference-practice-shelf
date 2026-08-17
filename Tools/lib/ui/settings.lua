-- settings: the Settings window, opened from the gear in the working view's
-- bar (moved there from the browser toolbar 2026-08-10, `.brief/settings-move`).
--
-- Rebuilt 2026-08-08 from `.brief/settings-layout` (six pages, every answer the
-- user's own). It used to be one auto-resizing page of stacked labels and
-- paragraphs — two settings and seventy-five words of explanation, with five
-- more settings already promised in DESIGN (UI size, walkthrough replay, send
-- feedback, What's New, purchase code). Four decisions replaced it:
--
--   1. A section LIST down the left, one section's rows in the pane beside it —
--      the browser window's own shape, and REAPER's own Preferences. Adding a
--      section is one entry in SECTIONS; nothing else moves.
--   2. A FIXED window (SET_WIN_W x SET_WIN_H). Auto-sizing would stretch and
--      shrink the nav list on every section click.
--   3. One line per setting: name left in a fixed column, value in the middle
--      cut to fit, control on the right.
--   4. At most ONE dim line of explanation, and only where a setting could be
--      misread. Everything else moved into hovers. Warnings are the exception —
--      they stay full sentences, and only appear when they are true.
--
-- A ui/ module: it may call reaper.ImGui_* only. It never touches the library or
-- the filesystem — user intent leaves as an action for the entry script to run.

local theme = require("ui.theme")
local tips = require("ui.tips")
local widgets = require("ui.widgets")
local icons = require("ui.icons")
local focus = require("ui.focus")
local whatsnew = require("ui.whatsnew")
local fb_core = require("core.feedback") -- message cap for the Help composer
local T = theme.tokens
local M = theme.metrics

local settings = {}

-- Feature detection, checked once at load (the house idiom). Without
-- AlignTextToFramePadding a row's label sits a couple of pixels high beside its
-- button — cosmetic, so the row still draws rather than being dropped.
local HAS_ALIGN_TEXT = reaper.ImGui_AlignTextToFramePadding ~= nil
local HAS_CHILD_PAD  = reaper.ImGui_ChildFlags_AlwaysUseWindowPadding ~= nil
local HAS_WRAP_POS   = reaper.ImGui_PushTextWrapPos ~= nil and reaper.ImGui_PopTextWrapPos ~= nil
local HAS_ESCAPE     = reaper.ImGui_IsKeyPressed ~= nil and reaper.ImGui_Key_Escape ~= nil
-- The Help composer's conveniences, each optional: without multiline the box
-- falls back to a single-line field (ancient ReaImGui), without the clipboard
-- call the failure warning still shows the address to copy by hand, and
-- Ctrl+Enter simply doesn't send where the key APIs are missing.
local HAS_MULTILINE  = reaper.ImGui_InputTextMultiline ~= nil
local HAS_HINT       = reaper.ImGui_InputTextWithHint ~= nil
local HAS_READONLY   = reaper.ImGui_InputTextFlags_ReadOnly ~= nil
local HAS_CLIPBOARD  = reaper.ImGui_SetClipboardText ~= nil
local HAS_CTRL_ENTER = reaper.ImGui_GetKeyMods ~= nil and reaper.ImGui_Mod_Ctrl ~= nil
  and reaper.ImGui_IsKeyPressed ~= nil and reaper.ImGui_Key_Enter ~= nil
  and reaper.ImGui_IsItemFocused ~= nil
-- First-open placement: centred on REAPER's own window. Only used once — after
-- that ImGui's ini remembers wherever the user dragged it to.
local HAS_VIEWPORT   = reaper.ImGui_GetMainViewport ~= nil and reaper.ImGui_Viewport_GetCenter ~= nil

-- View state only: which section the list is on, whether the window stands
-- open, and the typed-path fallback's buffer. Survives a close so reopening
-- lands where the user left off.
local ui = { open = false, section = "library", libdir = "" }

-- The browser's gear calls this. A real window, not a modal (2026-08-08, user's
-- call): the rest of the tool stays live and clickable behind it — "just make it
-- open like a normal popup basically" — so opening is a plain flag, not an
-- OpenPopup that has to be issued inside an owning window.
function settings.open(state)
  ui.open = true
  ui.libdir = state.library_dir -- the typed-path fallback starts from the current folder
end

-- The entry script uses this after the frame has drawn to decide whether a
-- failed report was actually visible to the user. "Settings is open" is not
-- enough: the window may be showing Library, Updates or Help instead.
function settings.feedback_visible()
  return ui.open and ui.section == "feedback"
end

--------------------------------------------------------------- the row grammar

-- ONE setting = a NAME line, then a VALUE line (2026-08-10,
-- `.brief/settings-row-shape` — supersedes the 08-08 one-line grammar: its
-- fixed `SET_LABEL_W` name column measured nothing, so "Project References"
-- overprinted its own path the day it arrived. Two runs of text must never
-- compete for pixels — the name now owns a line, so no name can ever reach a
-- value again):
--
--   NAME
--   value                                        [ button ][icon]
--   one line of explanation, only where it's needed
--   ────────────────────────────────── hairline, then the next row
--
--   * The NAME has its own line, in THE HEADING VOICE — the bold cut at
--     GROUP_FS, ALL CAPS, TEXT_PRIMARY (`theme.push_heading_font`; 2026-08-10,
--     `.brief/settings-headings`): a stacked setting is a small section, and
--     the tool has ONE voice that leads sections (the Loudness panel's, What's
--     New's). It wore the dim body label voice for a few hours and the user
--     called it out — the white path under it outranked its own name. Callers
--     still pass Title Case; this file uppercases at draw.
--   * The VALUE takes the control line's full width up to the controls —
--     at the window's 620px most real paths show uncut. The controls ride
--     the VALUE's line, not the name's (the user's own amendment on the
--     brief's answer), the value centred to their height.
--   * A row with NO value keeps its controls on the name line — a one-line
--     row, never an empty second line — and they sit BESIDE the name, not at
--     the far edge (2026-08-10, user-reported: flush right put Show ~400px
--     from "Walkthrough", the exact name-to-control gulf this grammar exists
--     to prevent; proximity wins, as it did for values on 08-08).
--   * The CONTROL has exactly TWO sizes: a button with a word on it is always
--     `SET_ACTION_W`, and a bare "…" is a control-height square (`opts.compact`).
--     Sizing each button by its own text meant no two ever matched.
--   * A HAIRLINE opens every row but the first — never a trailing one.
--   * FACTS ARE NOT ROWS. Things you read go on one line at the section's end
--     (`draw_facts`), so a count never has to pretend to be a setting.
--   * EVERY WORD IS AT THE BODY SIZE. Hierarchy is colour only — the explanation
--     lines were `GROUP_FS` until the user reported them unreadable (the third
--     time 11px has drawn that complaint; see the UI skill).
--
-- opts.button   a label; the row returns true on the frame it is clicked
-- opts.beside   the button rides right beside the value instead of at the far
--               edge — for a row whose "value" is a sentence about what the
--               button does, where the far edge would put the control a pane's
--               width from the words that explain it (2026-08-11, the
--               Walkthrough row; same proximity rule as a value-less row)
-- opts.compact  that button is a control-height square, not a full-width action
-- opts.dead     draw the button pressed-out and ignore clicks (same footprint —
--               a control must never change size with state)
-- opts.input    take a typed value instead of showing one; returns nil, text
-- opts.box      show a read-only, selectable text box instead of painted text
-- opts.cut      where the value's ellipsis goes: "middle" for a path, "front"
--               to keep only its tail; omitted = the normal cut at the end
-- opts.tip      hover text for the whole row
-- opts.warn     a full-sentence message under the row, TEXT_SECONDARY, wrapped
-- opts.note     the one dim line of explanation, TEXT_TERTIARY, wrapped
-- opts.icon     { id, name, tip, fallback, dead } — a compact ICON square at
--               the row's FAR EDGE, the control (when there is one) stepping
--               one slot in beside it (icon outermost: the user's swap,
--               2026-08-10, same day the square arrived). The row's third
--               return is true the frame it is clicked. Added 2026-08-10
--               (`.brief/settings-move`, the user's pick): the Folder row
--               wears open-in-Explorer beside its "…", so a row may carry ONE
--               worded/compact control plus ONE icon square — never a third,
--               and never two worded buttons.

-- Whether the next row opens the pane. Reset by settings.draw before the
-- section draws, so the first row never gets a rule above it and the last never
-- gets one below.
local first_row = true

-- The Lucide font, handed in once per frame by settings.draw (the icon squares
-- need it; text rows never touch it). nil is fine — icons.button falls back to
-- its drawn shape.
local icon_font = nil

local function row(ctx, label, value, opts)
  opts = opts or {}
  local clicked, typed, icon_clicked = false, nil, false

  -- The rule between rows is pushed to STROKE_SECONDARY, the weight every
  -- control's border wears. The theme paints Separator in STROKE_TERTIARY — 8%
  -- white, which at 1px on this background is invisible, so the rules were being
  -- drawn and nobody could see them (user-reported 2026-08-08 from the running
  -- build). This tool learned the same lesson once already: the ruler's minor
  -- ticks left TERTIARY on 2026-08-06 for exactly this reason.
  --
  -- Pushed HERE rather than raising the token, because STROKE_TERTIARY also
  -- draws the nav seam and the sound table's header underline, which sit on
  -- different backgrounds and nobody has complained about.
  if not first_row then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), T.STROKE_SECONDARY)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_PopStyleColor(ctx)
  end
  first_row = false

  local x0 = reaper.ImGui_GetCursorPosX(ctx)
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local gap = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))

  -- The control's width is one of two fixed numbers, never its text's — so it is
  -- known before the value is laid out and the value can never reach it. The
  -- icon square (when asked for) widens the reserved right zone the same way.
  local btn_w = 0
  if opts.button then
    btn_w = opts.compact and reaper.ImGui_GetFrameHeight(ctx) or M.SET_ACTION_W
  end
  local right_w = btn_w
  if opts.icon then
    right_w = right_w + (right_w > 0 and gap or 0) + reaper.ImGui_GetFrameHeight(ctx)
  end
  -- The value line's zone: the pane's left edge to just left of the control(s).
  local val_x1 = x0 + avail - (right_w > 0 and (right_w + gap) or 0)

  -- THE NAME LINE, in the heading voice (see the grammar above). With a value
  -- (or input) coming below, the name stands alone — that is the whole fix: it
  -- has nothing on its line to crash into. Only a value-less row keeps its
  -- controls up here, so it doesn't pay for an empty second line.
  local has_value_line = (value ~= nil) or (opts.input ~= nil)
  if HAS_ALIGN_TEXT and not has_value_line then
    reaper.ImGui_AlignTextToFramePadding(ctx)
  end
  local hd = theme.push_heading_font(ctx)
  reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, label:upper())
  if hd then reaper.ImGui_PopFont(ctx) end

  if opts.input or opts.box then
    -- `input_w` caps the field instead of letting it run to the control edge —
    -- a box sized for a whole pane reads as wanting a paragraph (the Reply
    -- Email field, user-reported 2026-08-09). The cap loses to a narrow pane.
    local in_w = val_x1 - x0
    if opts.input_w and opts.input_w < in_w then in_w = opts.input_w end
    reaper.ImGui_SetNextItemWidth(ctx, in_w)
    if opts.value_color then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), opts.value_color)
    end
    local _, v
    if opts.box and HAS_READONLY then
      _, v = reaper.ImGui_InputText(ctx, "##" .. label, value or "",
        reaper.ImGui_InputTextFlags_ReadOnly())
    elseif opts.box then
      reaper.ImGui_BeginDisabled(ctx)
      _, v = reaper.ImGui_InputText(ctx, "##" .. label, value or "")
      reaper.ImGui_EndDisabled(ctx)
    else
      _, v = reaper.ImGui_InputText(ctx, "##" .. label, value or "")
    end
    if opts.value_color then reaper.ImGui_PopStyleColor(ctx) end
    if opts.input then typed = v end
    tips.show(ctx, opts.tip and reaper.ImGui_IsItemHovered(ctx), opts.tip)
  elseif value then
    -- Centred to the control height beside it — laid-out text positions from
    -- FramePadding, so without this the value sits a couple of pixels above
    -- the buttons sharing its line.
    if HAS_ALIGN_TEXT then reaper.ImGui_AlignTextToFramePadding(ctx) end
    local shown = widgets.ellipsize(ctx, value, val_x1 - x0, opts.cut)
    reaper.ImGui_TextColored(ctx, opts.value_color or T.TEXT_PRIMARY, shown)
    -- Only spell it out when it was actually cut, or when the caller asked for a
    -- hover — a tooltip repeating what is already readable is noise.
    local was_cut = shown ~= value
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx),
      was_cut and (value .. (opts.tip and ("\n\n" .. opts.tip) or "")) or opts.tip)
  end

  if opts.button then
    -- On a value line the control keeps the far edge (the icon outermost —
    -- see opts.icon above); on a value-less row it sits right BESIDE the
    -- name instead (see the grammar above — proximity, never a gulf).
    if has_value_line and not opts.beside then
      reaper.ImGui_SameLine(ctx, x0 + avail - right_w)
    else
      reaper.ImGui_SameLine(ctx)
    end
    if opts.dead then
      -- The pressed-out face: same footprint, fill and text dimmed, clicks
      -- meaningless. Never a smaller or absent button.
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), T.FILL_QUATERNARY)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.FILL_QUATERNARY)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.FILL_QUATERNARY)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_QUATERNARY)
      reaper.ImGui_Button(ctx, opts.button, btn_w)
      reaper.ImGui_PopStyleColor(ctx, 4)
    else
      clicked = reaper.ImGui_Button(ctx, opts.button, btn_w)
    end
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), opts.button_tip)
  end

  if opts.icon then
    local ic = opts.icon
    if has_value_line then
      reaper.ImGui_SameLine(ctx, x0 + avail - reaper.ImGui_GetFrameHeight(ctx))
    else
      reaper.ImGui_SameLine(ctx) -- beside the name, outermost of the pair
    end
    if ic.dead then
      -- The icon's pressed-out face: the button-fill pushes the dead action
      -- button gets, plus the glyph handed to icons.button in the dead text
      -- colour (the glyph is painted on the draw list, so Col_Text can't
      -- reach it). The tip stays on — it carries the reason.
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), T.FILL_QUATERNARY)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.FILL_QUATERNARY)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.FILL_QUATERNARY)
      icons.button(ctx, icon_font, ic.id, ic.name,
        { tip = ic.tip, fallback = ic.fallback, color = T.TEXT_QUATERNARY })
      reaper.ImGui_PopStyleColor(ctx, 3)
    else
      icon_clicked = icons.button(ctx, icon_font, ic.id, ic.name,
        { tip = ic.tip, fallback = ic.fallback })
    end
  end

  -- The lines under the row sit at the NAME's own left edge, taking the full
  -- width to wrap in — the value column is on the far side of the row now, so
  -- there is nothing over here to line up with.
  --
  -- AT THE BODY SIZE, dim rather than small (2026-08-08, user: "very difficult
  -- to read because of how small it is"). These are whole sentences somebody has
  -- to read, and `GROUP_FS` is documented in the UI skill as metadata beside
  -- something louder — never a thing you actually read. **Colour alone marks
  -- them subordinate**, exactly as the sidebar's category rows resolved the same
  -- complaint on 2026-08-07: the smaller size was only reinforcing what dimness
  -- already said, and it was costing legibility to say it twice.
  --
  -- Written out rather than looped over a {text, colour} list, so nothing is
  -- allocated in the frame loop.
  if opts.warn or opts.note then
    if HAS_WRAP_POS then reaper.ImGui_PushTextWrapPos(ctx, x0 + avail) end
    if opts.warn then reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, opts.warn) end
    if opts.note then reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, opts.note) end
    if HAS_WRAP_POS then reaper.ImGui_PopTextWrapPos(ctx) end
  end

  return clicked, typed, icon_clicked
end

--------------------------------------------------------------- the sections

-- Each section draws its own rows and returns an action (or nil). Adding a
-- section is one entry in SECTIONS below — that is the whole point of the
-- redesign, and the reason the old inline version had to go.

-- "1.24 GB" / "860 MB" / "12.4 kB". Whole numbers past a thousand of a unit —
-- a settings row is a glance, and "1240.7 MB" is not one.
local function human_size(bytes)
  if not bytes or bytes <= 0 then return "0 MB" end
  local units = { "bytes", "kB", "MB", "GB", "TB" }
  local i, n = 1, bytes
  while n >= 1024 and i < #units do n, i = n / 1024, i + 1 end
  if i <= 2 or n >= 100 then return string.format("%.0f %s", n, units[i]) end
  return string.format("%.2f %s", n, units[i])
end

-- THE FACTS LINE (2026-08-08, `.brief/settings-rows`, the user's pick from six
-- shapes). What's in the library is ONE dim line, not three setting rows:
--
--     15 sounds  ·  7 categories  ·  4.80 MB on disk
--
-- A folder you CHANGE and a count you READ are different things. Dressing a
-- count as a setting is what put a name and its value at opposite ends of a
-- 480px pane in the first place — this shape makes that gap impossible rather
-- than tuning it. Numbers at the body size in TEXT_PRIMARY, the words around
-- them small and dim, so the line reads as facts at a glance.
--
-- Held as ONE runs table mutated in place, never rebuilt: the strings change
-- only when the library does, and building a fresh list every frame is the
-- allocation-in-the-frame-loop this project forbids.
local lib_facts = { key = nil, n = 0, runs = {} }

local function put(i, text, num)
  local r = lib_facts.runs[i]
  if not r then r = {}; lib_facts.runs[i] = r end
  r.text, r.num = text, num
  return i + 1
end

local function library_facts(state)
  local lib = state.library
  local total = state.counts and state.counts.all or 0
  -- The measuring tail is part of the key: it changes as analysis drains, and
  -- it is the one part of this line that moves while you watch it.
  local left = state.analysis_queue and #state.analysis_queue or 0
  local key = (state.library_dir or "") .. "\0" .. total .. "\0" .. left
  if lib_facts.key == key then return lib_facts end
  lib_facts.key = key

  local cats = 0
  for _, c in ipairs(lib and lib.categories or {}) do cats = cats + 1 end
  local bytes = 0
  for _, s in ipairs(lib and lib.sounds or {}) do bytes = bytes + (s.size_bytes or 0) end

  -- Sub-categories are counted in but not named: a count of only the top level
  -- would undercount a two-level library by most of it.
  local i = 1
  i = put(i, tostring(total), true)
  i = put(i, total == 1 and " sound  \u{00B7}  " or " sounds  \u{00B7}  ", false)
  i = put(i, tostring(cats), true)
  i = put(i, cats == 1 and " category  \u{00B7}  " or " categories  \u{00B7}  ", false)
  i = put(i, human_size(bytes), true)
  i = put(i, " on disk", false)
  -- Loudness still running. It rides the end of this line rather than taking a
  -- row of its own — nothing sits below the line, so its coming and going can't
  -- push anything.
  if left > 0 then
    i = put(i, "  \u{00B7}  measuring ", false)
    i = put(i, tostring(left), true)
  end
  lib_facts.n = i - 1
  return lib_facts
end

-- Draw the runs on one line. ONE SIZE, hierarchy by colour: the numbers are
-- TEXT_PRIMARY, the words around them TEXT_TERTIARY.
--
-- The words were `GROUP_FS` until 2026-08-08, when the user reported Settings'
-- small text as very difficult to read. That also removed the reason this had to
-- be hand-positioned — two font sizes on one line need their baselines squared
-- up by hand, because ImGui positions laid-out text from FramePadding and drops
-- a small run about a pixel off a body-size one beside it. At one size the
-- library lays them out correctly itself, so this is now the plain loop it
-- looks like. Don't reintroduce the size contrast without reintroducing the
-- baseline arithmetic with it.
local function draw_facts(ctx, facts)
  for i = 1, facts.n do
    local r = facts.runs[i]
    if i > 1 then reaper.ImGui_SameLine(ctx, 0, 0) end
    reaper.ImGui_TextColored(ctx, r.num and T.TEXT_PRIMARY or T.TEXT_TERTIARY, r.text)
  end
end

-- The one standing line under the Folder row. It read "Opens the library in
-- another folder — your sounds are never moved", which the user found confusing
-- (2026-08-08): "opens the library in another folder" sounds like it PUTS the
-- library somewhere else, which is the exact fear the sentence exists to calm.
-- "Switches which library" names the action; the reassurance follows it.
local NOTE_FOLDER =
  "Switches which library you're using. Your sounds are never moved or copied."

-- The reveal square the Folder row wears (2026-08-10, `.brief/settings-move`,
-- the user's pick over an "Open in Explorer" row and a Folders section): the
-- browser toolbar's folder button became this. One table, hoisted — never
-- rebuilt in the frame loop.
local ICON_REVEAL_LIB = {
  id = "set_libfolder", name = "folder", fallback = icons.draw_folder,
  tip = "Open this folder and its trash in File Explorer.",
}

-- The References row's two faces, hoisted for the same reason.
local ICON_REFS = {
  id = "set_refsfolder", name = "folder", fallback = icons.draw_folder,
  tip = "Open this project's References folder",
}
local ICON_REFS_DEAD = {
  id = "set_refsfolder", name = "folder", fallback = icons.draw_folder,
  dead = true,
  tip = "Save your project first. It has no References folder yet",
}

local function draw_library(ctx, state)
  local action

  if state.deps.folder_picker then
    -- A bare "…" means pick a new location (2026-08-08, user's call — it read
    -- "Change…"). The folder square beside it opens the current folder.
    local hit, _, reveal = row(ctx, "Library Folder", state.library_dir, {
      button = "\u{2026}", compact = true, box = true,
      note = NOTE_FOLDER,
      icon = ICON_REVEAL_LIB,
      tip = "Switches which library you're using. The library you're using now stays on disk.",
      button_tip = "Choose a different library folder",
    })
    if hit then action = { type = "change_library_dir" } end
    if reveal then action = action or { type = "reveal_library" } end
  else
    -- No OS folder picker on this install (js_ReaScriptAPI missing) — take a
    -- typed path rather than hiding the setting. The reveal square still
    -- draws: opening Explorer doesn't need the picker dialog.
    local hit, typed, reveal = row(ctx, "Library Folder", ui.libdir, {
      input = true, button = "Use This",
      icon = ICON_REVEAL_LIB,
      note = NOTE_FOLDER,
    })
    if typed then ui.libdir = typed end
    if hit and ui.libdir ~= "" then action = { type = "change_library_dir", dir = ui.libdir } end
    if reveal then action = action or { type = "reveal_library" } end
  end

  -- This project's References folder — the working view's folder square until
  -- 2026-08-10 (`.brief/settings-move`): the bar keeps working controls; the
  -- folders live where their paths do. Dead with the reason while the project
  -- has never been saved (the old button dimmed for the same case) — the row
  -- itself never comes or goes.
  local refs_dir = state.pins and state.pins.dir
  local _, _, open_refs = row(ctx, "Project References", refs_dir or "\u{2014}", {
    box = true,
    value_color = refs_dir and T.TEXT_PRIMARY or T.TEXT_QUATERNARY,
    icon = refs_dir and ICON_REFS or ICON_REFS_DEAD,
    note = refs_dir and "Pinned reference audio is stored here, beside your project file." or nil,
    warn = (not refs_dir) and "Save your project first. It has no References folder yet." or nil,
  })
  if open_refs then action = action or { type = "open_refs_folder" } end

  -- What's in the library, as one line under a rule (see library_facts). The
  -- rule is drawn by hand rather than by starting another row: nothing follows
  -- it, so `row`'s own opens-every-row-but-the-first bookkeeping doesn't apply.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), T.STROKE_SECONDARY)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  draw_facts(ctx, library_facts(state))

  return action
end

-- THE RELEASE-NOTES row (reworked 2026-08-09, `.brief/changelog-reading/` —
-- supersedes the previous day's dropdown-plus-inline-notes, which crammed the
-- reading into a ~180px box under two rows of furniture; the user's words were
-- "super cramped"). It lives in UPDATES — version, update button and history are
-- one subject — but the READING happens in the same window the post-update card
-- uses: the View button opens it over the whole history, every release in one
-- scroll, newest first (whatsnew.open_history).
--
-- One rendering for both surfaces, so they cannot drift — and the card became
-- summonable at will, which also answered "how do I judge a popup that marks
-- itself read the moment it appears".
--
-- No row at all while the changelog holds no releases (the beta ships with an
-- empty one): a View button over nothing is a broken promise.
local function notes_row(ctx, state)
  if not state.changelog or #state.changelog == 0 then return end
  -- The VALUE is the newest release and its date (2026-08-09, user-reported:
  -- with no value the row was "Release notes …hole… [View]" — the one row in
  -- the pane with nothing bridging the name and its far-edge control). The
  -- Version row above shows what's INSTALLED in PRIMARY; this shows what the
  -- notes run up to, quieter, so the two version strings can't be read as one.
  local newest = state.changelog[1]
  local vline = "v" .. (newest.version or "?")
  if newest.date then
    vline = vline .. "  \u{00B7}  " .. whatsnew.human_date(newest.date)
  end
  if row(ctx, "Release notes", vline, {
    value_color = T.TEXT_SECONDARY,
    button = "View",
    button_tip = "Every release, newest first. The same notes the update popup shows.",
  }) then
    whatsnew.open_history()
  end
end

local function draw_updates(ctx, state)
  local action
  local u = state.update

  -- Standing down. Only "repo_off" is a state an end user can reach (they
  -- disabled our repo inside ReaPack — respected, with the way back shown); the
  -- rest are dev copies and missing-ReaPack installs.
  if not u or not u.enabled then
    local reason = u and u.disabled_reason
    local warn, note
    if reason == "repo_off" then
      warn = "Paused. yb-Reference's repository is disabled in ReaPack."
      note = "Re-enable the repository under Extensions \u{2192} ReaPack \u{2192} Manage repositories, then reopen the tool."
    elseif reason == "noapi" then
      warn = "Updates are unavailable because ReaPack isn't installed."
    else -- "dev" / "norepo": not a ReaPack-owned copy, or its repo record is unreadable
      warn = "Updates are unavailable because this copy wasn't installed through ReaPack."
    end
    row(ctx, "Version", "v" .. ((u and u.installed) or "?"),
      { value_color = T.ACCENT, warn = warn, note = note })
    -- The history still draws. Release notes are worth reading on a dev copy or
    -- a hand-installed one — they describe the code that is running, which has
    -- nothing to do with whether ReaPack can update it.
    notes_row(ctx, state)
    return nil
  end

  -- The post-update face. Reached only where the tool COULDN'T restart itself
  -- (an old REAPER, or no real action id): everywhere else a landed update
  -- relaunches immediately and this section never draws in the "done" state.
  -- The files on disk are new and this running code is old — live-proven U7 —
  -- so the reminder stands until the user closes and reopens.
  if u.phase == "done" then
    row(ctx, "Version", "v" .. (u.installed or "?"),
      { value_color = T.ACCENT, warn = "Updated. Close and reopen the tool to finish." })
    notes_row(ctx, state)
    return nil
  end

  local vline = "v" .. (u.installed or "?")
  if u.available then vline = vline .. "  \u{00B7}  v" .. u.available .. " available" end

  -- A version number is ACCENT wherever the tool prints one (2026-08-11, the
  -- user's ask — it matches the release headings in the What's New card and the
  -- history pane). It no longer shifts PRIMARY/SECONDARY with whether an update
  -- is waiting: "v… available" on the same line and the Update button below it
  -- carry that, and one colour per kind of thing beats a second, quieter signal
  -- saying what those already say.
  local opts = {
    value_color = T.ACCENT,
    note = "Checks once a day for a new version. It doesn't send project data.",
  }
  if u.pinned then
    -- Say WHY one click won't install it (U8: ReaPack's syncs silently skip a
    -- pinned package) instead of offering a button that fails mysteriously.
    opts.warn = "Paused. This tool is pinned in ReaPack."
    opts.note = "Right-click it in Extensions \u{2192} ReaPack \u{2192} Browse packages and untick \"Pin to current version\"."
  elseif u.available then
    if u.phase == "sync" then
      opts.button, opts.dead = "Updating\u{2026}", true
      opts.button_tip = "ReaPack is installing the update. Its progress window shows the details."
    else
      opts.button = "Update Now"
      -- The promise follows the machine (Codex, 2026-08-09): with the relaunch
      -- mechanism the tool finishes the update itself; without it the old
      -- close-and-reopen wording stays the honest one.
      opts.button_tip = state.can_restart
        and "ReaPack installs the yb-Reference update, then the tool restarts."
        or "ReaPack installs the yb-Reference update, then you close and reopen the tool."
    end
  end
  if u.phase == "failed_browser" then
    opts.warn = "The update wasn't completed. ReaPack's package browser is open to this tool. Right-click its row and choose Update."
    opts.note = "If no update is listed, run Extensions \u{2192} ReaPack \u{2192} Synchronize packages."
  elseif u.phase == "failed_manual" then
    opts.warn = "The update couldn't be completed from here. Run Extensions \u{2192} ReaPack \u{2192} Synchronize packages instead."
  end

  if row(ctx, "Version", vline, opts) then action = { type = "start_update" } end

  notes_row(ctx, state)
  return action
end

--------------------------------------------------------------- help: send feedback

-- The Send-feedback composer (2026-08-09, `.brief/_done/send-feedback/`;
-- reshaped the same day by `.brief/feedback-pane` — both rounds every answer
-- the user's own). The pane IS the form, three blocks tall and NEVER
-- scrolling: the message box filling every spare pixel (character count riding
-- its bottom-right corner), ONE status line, and one bottom line — Email address
-- beside Send.
--
--   * The DRAFT is module-local: it survives closing Settings and switching
--     tabs, and is gone when the tool closes — decided exactly so. It clears
--     ONLY on "sent"; a failure keeps every word.
--   * The STATUS LINE is always exactly one line, blank or not — a warning
--     appearing must never resize the message box above it (controls never
--     move with state). The attach line that used to idle on it ("Sends with
--     v… · REAPER … · ReaPack install") is GONE — user's call, feedback-pane
--     round 2: "the user doesn't need to see this". The payload it described
--     is unchanged.
--   * The EMAIL says it is optional INSIDE the empty field (the hint shows
--     exactly while the fact matters), never as a second line of prose — the
--     first build said it twice and paid two lines of box height for it.
--   * On FAILURE nothing opens by itself (the user's reversal of the old
--     browser-form fallback): the message is copied to the clipboard the
--     moment the failure lands, and the fallback address rides the status
--     line — click it to copy the address instead.
--   * While SENDING the box goes read-only: the message "stays on screen" as
--     decided, and a mid-send edit can't be swallowed by the clear-on-sent.

-- The pane's opening line — ABOVE the box since 2026-08-10 (user's call: the
-- in-box placeholder moved out, so the pane says what it is for before the
-- box, and stays said once there's text in it).
local FB_INTRO = "Bug, idea, or anything else? Let me know!"

local fbui = { draft = "", email = nil, last_phase = nil }

-- SOFT WRAP for the message box (2026-08-10, "the textbox must wrap" — the
-- user's call after the probe). ImGui's box has no wrap and REFUSES a value
-- rewritten from outside while active (RESEARCH.md), so this rides the ONE
-- sanctioned mid-typing edit path: an InputText CALLBACK. The callback can't
-- replace the buffer either (Buf is read-only in every event), but it may call
-- ImGui's own InputTextCallback_DeleteChars/InsertChars — so the wrap is a
-- space swapped for a newline, a same-length edit that always fits (scripts
-- get no CallbackResize, so only net-zero edits are guaranteed) with the
-- cursor adjusted by ImGui itself.
--
-- Division of labour: EEL can't measure text, Lua can't touch the live
-- buffer. So Lua finds the byte of the space to swap (find_wrap_at below,
-- last frame's text — a stale byte no longer holding a space is a no-op by
-- the callback's own guard) and hands it to the EEL program; the callback
-- performs the swap inside the widget. A real newline lands in the draft,
-- which is exactly what should travel with the report.
--
-- DELETE ALL OF THIS the day ReaImGui exposes upstream's WordWrap flag
-- (imgui 1.92.3+; ReaImGui 0.10.0.5 still bundles 1.92.1) — it then costs
-- one flag bit.
local WRAP_EEL = [[
EventFlag == CallbackAlways && WrapAt >= 0 ? (
  str_getchar(#Buf, WrapAt) == 32 ? (
    InputTextCallback_DeleteChars(WrapAt, 1);
    InputTextCallback_InsertChars(WrapAt, #nl);
  );
);
]]
local wrap_cb            -- the compiled EEL callback, made lazily per context
local wrap_dirty = false -- an edit happened: re-scan for an overflowing line

local HAS_WRAP_CB = reaper.ImGui_CreateFunctionFromEEL ~= nil
  and reaper.ImGui_Function_SetValue ~= nil
  and reaper.ImGui_Function_SetValue_String ~= nil
  and reaper.ImGui_ValidatePtr ~= nil and reaper.ImGui_Attach ~= nil
  and reaper.ImGui_InputTextFlags_CallbackAlways ~= nil

-- The 0-based BYTE of the first space whose swap for a newline brings the
-- first overflowing line back inside `max_w` — nil when every line fits. One
-- line per call: the callback applies one swap per frame, and the edit it
-- makes re-arms the scan, so a paste converges over a few frames. A line with
-- no space to give (one enormous word) is skipped and left to pan — a swap
-- there would need a net +1 byte, the one edit scripts can't be guaranteed.
local function find_wrap_at(ctx, text, max_w)
  local pos = 0 -- byte offset of the current line's start
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if select(1, reaper.ImGui_CalcTextSize(ctx, line)) > max_w then
      local best
      for sp in line:gmatch("() ") do
        if select(1, reaper.ImGui_CalcTextSize(ctx, line:sub(1, sp - 1))) <= max_w then
          best = sp
        else
          break
        end
      end
      if best then return pos + best - 1 end
    end
    pos = pos + #line + 1
  end
  return nil
end

-- HELP: the walkthrough replay (add-on status joins here when it lands).
-- Split from the composer on 2026-08-10 (`.brief/walkthrough-2`, the user's
-- pick over renaming one shared tab): a feedback form under "Help" read odd,
-- and the composer was designed to BE its pane, not to share it.
local function draw_help(ctx, state)
  -- Play starts at stop 1, not the welcome card: pressing the button IS the
  -- consent the welcome exists to ask for. The sentence takes the value line
  -- and the button rides beside it (`opts.beside`) — up on the name's line the
  -- control read as belonging to the heading rather than to the thing it plays
  -- (user, 2026-08-11). It doesn't list the stops: naming them dates the line
  -- every time the tour changes, and the tour introduces itself.
  if row(ctx, "Walkthrough", "A short walkthrough of how to use the tool.",
      { button = "Replay", button_tip = "Replay the walkthrough",
        beside = true, value_color = T.TEXT_TERTIARY }) then
    return { type = "walkthrough", ev = "show" }
  end
  return nil
end

-- FEEDBACK: the composer — the pane IS the form (2026-08-09 design, unchanged
-- by the split; it just has the whole pane to itself again).
local function draw_feedback(ctx, state)
  local fbs = state.feedback
  if not fbs then return nil end
  local action

  -- The remembered email seeds the field once per session; after that the
  -- field's own text is the truth (it rides back on the next send action).
  if fbui.email == nil then fbui.email = fbs.email or "" end

  -- The sender's phase edges, reacted to exactly once each.
  if fbui.last_phase ~= fbs.phase then
    if fbs.phase == "sent" then
      fbui.draft = ""
    elseif fbs.phase == "failed" and HAS_CLIPBOARD and fbui.draft ~= "" then
      reaper.ImGui_SetClipboardText(ctx, fbui.draft)
    end
    fbui.last_phase = fbs.phase
  end

  local sending = fbs.phase == "sending"

  -- Geometry bottom-up: the intro line above, one status line and the bottom
  -- line (email + Send) below are fixed costs; the box takes every pixel left
  -- (floored for tiny panes).
  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local line_h = reaper.ImGui_GetTextLineHeight(ctx)
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)
  local gap = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  -- Floored: an exact-fit stack that lands on a fraction reads as taller than
  -- the pane by under a pixel, which is all a child needs to grow a scrollbar.
  local box_h = math.floor(avail_h - frame_h - 2 * line_h - 3 * gap)
  if box_h < 60 then box_h = 60 end

  -- The intro, where the in-box placeholder used to live: what this pane is
  -- FOR, said before the box and still said while it holds text.
  reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, FB_INTRO)

  -- The soft wrap, armed BEFORE the box draws (see the block above draw_help).
  -- Only while the box is being edited: the scan runs on edit frames and stops
  -- the moment every line fits, so an idle pane measures nothing.
  local flags = (sending and HAS_READONLY) and reaper.ImGui_InputTextFlags_ReadOnly() or 0
  local use_wrap = HAS_WRAP_CB and HAS_MULTILINE and not sending
  if use_wrap then
    if not (wrap_cb and reaper.ImGui_ValidatePtr(wrap_cb, "ImGui_Function*")) then
      wrap_cb = reaper.ImGui_CreateFunctionFromEEL(WRAP_EEL)
      reaper.ImGui_Function_SetValue(wrap_cb, "CallbackAlways",
        reaper.ImGui_InputTextFlags_CallbackAlways())
      -- The newline travels in as a string slot — sidesteps EEL escape rules.
      reaper.ImGui_Function_SetValue_String(wrap_cb, "#nl", "\n")
      reaper.ImGui_Attach(ctx, wrap_cb)
    end
    -- No is-the-box-active gate here on purpose (2026-08-10, first live run:
    -- nothing wrapped): IsItemActive after a MULTILINE input misreports — the
    -- text area is an inner child window, so "the last item" isn't the thing
    -- holding the keyboard. `wrap_dirty` alone bounds the cost: it arms on an
    -- edit and clears the moment every line fits (or only unbreakable words
    -- remain), so an idle pane still measures nothing.
    local wrap_at = -1
    if wrap_dirty then
      -- Inside the frame both sides, less the lane its scrollbar takes.
      local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
      local sb_w = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize()))
      wrap_at = find_wrap_at(ctx, fbui.draft, avail_w - 2 * pad_x - sb_w - 2) or -1
      if wrap_at < 0 then wrap_dirty = false end
    end
    reaper.ImGui_Function_SetValue(wrap_cb, "WrapAt", wrap_at)
    flags = flags | reaper.ImGui_InputTextFlags_CallbackAlways()
  end

  -- The message box. Read-only while a send is in flight — never disabled or
  -- absent, the text must stay readable exactly as it is being sent.
  local changed, txt
  if HAS_MULTILINE then
    changed, txt = reaper.ImGui_InputTextMultiline(ctx, "##fbmsg", fbui.draft,
      avail_w, box_h, flags, use_wrap and wrap_cb or nil)
  else
    reaper.ImGui_SetNextItemWidth(ctx, avail_w)
    changed, txt = reaper.ImGui_InputText(ctx, "##fbmsg", fbui.draft, flags)
  end
  if changed and not sending then
    -- Taken as typed, NOT clipped (2026-08-10, settled by the wrap probe:
    -- ImGui's box refuses an externally rewritten value while it is active —
    -- it answers with its own text again — so a live clip can't actually stop
    -- typing; it only made the box and the draft disagree, and truncated the
    -- overflow the moment focus left. Over the cap the counter goes red and
    -- Send goes dead instead; fb_core.clip still guards the payload itself.)
    fbui.draft = txt
    wrap_dirty = true
  end

  -- Ctrl+Enter sends from inside the box (Enter alone stays a newline).
  local send_now = false
  if HAS_CTRL_ENTER and reaper.ImGui_IsItemFocused(ctx)
    and (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl()) ~= 0
    and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) then
    send_now = true
  end

  -- The character count rides the box's own bottom-right corner (decided
  -- 2026-08-09: no height there for it to cost). Counted in CHARACTERS — the
  -- unit the core cap measures by — so the two can never disagree; invalid
  -- UTF-8 falls back to bytes, exactly as the cap does. Past the cap the
  -- number turns DANGER_RED and Send below goes dead — the honest stop, since
  -- the box itself can't be made to refuse keystrokes (see the draft note).
  local msg_chars = utf8.len(fbui.draft) or #fbui.draft
  local over_cap = msg_chars > fb_core.MAX_MESSAGE
  do
    local count_txt = msg_chars .. " / " .. fb_core.MAX_MESSAGE
    local bx1, by1 = reaper.ImGui_GetItemRectMax(ctx)
    local px, py = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding())
    local cw = select(1, reaper.ImGui_CalcTextSize(ctx, count_txt))
    reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx),
      bx1 - px - cw, by1 - py - line_h,
      over_cap and T.DANGER_RED or T.TEXT_QUATERNARY, count_txt)
  end

  -- The status line — failure, thanks, or blank, always exactly one line so
  -- the box above never moves. The failure carries its whole way out here:
  -- the warning, then the fallback address (click to copy it).
  if fbs.phase == "failed" then
    reaper.ImGui_TextColored(ctx, T.DANGER_RED,
      HAS_CLIPBOARD and "Couldn't send. Your message has been copied."
      or "Couldn't send. Copy your message before leaving.")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "Email it to: ")
    reaper.ImGui_SameLine(ctx, 0, 0)
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, fbs.address or "")
    local hov = reaper.ImGui_IsItemHovered(ctx)
    tips.show(ctx, hov and HAS_CLIPBOARD, "Click to copy the address.")
    if HAS_CLIPBOARD and hov and reaper.ImGui_IsMouseClicked(ctx, 0) then
      reaper.ImGui_SetClipboardText(ctx, fbs.address or "")
    end
  elseif fbs.phase == "sent" and fbui.draft == "" then
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "Sent. Thank you.")
  else
    reaper.ImGui_Text(ctx, "")
  end

  -- The bottom line, the TIGHT shape (2026-08-10, `.brief/feedback-pane` p.06,
  -- user's pick over the stretched field and a note line): "Email address" with
  -- its field welded right beside it — NO label column; the first build's
  -- `SET_LABEL_W` gap plus a fixed `SET_INPUT_W` read as holes either side,
  -- and its field CUT OFF the hint. The field is now sized to the hint that
  -- lives inside it, so the hint can never be cut again; the leftover space
  -- sits in the middle of the line as air (the PICK_MAX_W lesson: with an
  -- anchored left group and an anchored right control, spare room reads as
  -- margin). Send keeps the far edge. The right edge is measured BEFORE the
  -- line's first item — row()'s own idiom.
  local FB_EMAIL_HINT = "Optional · Add an email address if you'd like a reply."
  if HAS_ALIGN_TEXT then reaper.ImGui_AlignTextToFramePadding(ctx) end
  local x0 = reaper.ImGui_GetCursorPosX(ctx)
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "Email address")
  reaper.ImGui_SameLine(ctx)
  -- Wide enough for its own hint plus the frame's padding — measured, not a
  -- token, so a reworded hint can't reintroduce the cut — and clamped so it
  -- can never run under Send on a narrow pane.
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local gap_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local field_w = select(1, reaper.ImGui_CalcTextSize(ctx, FB_EMAIL_HINT)) + 2 * pad_x + 6
  local field_max = (x0 + avail - M.SET_ACTION_W - gap_x) - reaper.ImGui_GetCursorPosX(ctx)
  if field_w > field_max then field_w = field_max end
  reaper.ImGui_SetNextItemWidth(ctx, field_w)
  local typed
  if HAS_HINT then
    local _, v = reaper.ImGui_InputTextWithHint(ctx, "##fbemail", FB_EMAIL_HINT, fbui.email)
    typed = v
  else
    local _, v = reaper.ImGui_InputText(ctx, "##fbemail", fbui.email)
    typed = v
  end
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), "Saved after you send your first report.")
  if typed then fbui.email = typed end

  -- Send: the standard action width, flush right, and only ever one of three
  -- faces — live, pressed-out "Sending…", or pressed-out "Send" while there is
  -- nothing to send or the message is over the cap. Same footprint in every
  -- state (dead-face rule); the dead face says why on hover.
  local can_send = not sending and not over_cap and fbui.draft:match("%S") ~= nil
  reaper.ImGui_SameLine(ctx, x0 + avail - M.SET_ACTION_W)
  local label = sending and "Sending\u{2026}" or "Send"
  if can_send then
    if reaper.ImGui_Button(ctx, label, M.SET_ACTION_W) then send_now = true end
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), T.FILL_QUATERNARY)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.FILL_QUATERNARY)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.FILL_QUATERNARY)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_QUATERNARY)
    reaper.ImGui_Button(ctx, label, M.SET_ACTION_W)
    reaper.ImGui_PopStyleColor(ctx, 4)
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx),
      (sending and "Sending your report\u{2026}")
      or (over_cap and "Your message is over the 1,000-character limit. Shorten it before sending.")
      or nil)
    send_now = false
  end

  if send_now and can_send then
    action = { type = "send_feedback", message = fbui.draft, email = fbui.email }
  end
  return action
end

-- The list, in the user's chosen order. Five sections were decided
-- (Library · Appearance · Updates · Help · About); the two not yet built have
-- nothing to draw, and an empty section is never shown — they arrive here with
-- the features, one line each.
local SECTIONS = {
  { id = "library", name = "Library", draw = draw_library },
  { id = "updates", name = "Updates", draw = draw_updates },
  { id = "help", name = "Help", draw = draw_help },
  { id = "feedback", name = "Feedback", draw = draw_feedback },
}

--------------------------------------------------------------- the window

-- A nav row: BOLD CAPS at the body size (2026-08-10, `.brief/_done/settings-tabs/`,
-- the user's pick over the heading voice and mixed case — the tabs were the
-- flattest text in the window once the pane's names went bold; bold at the
-- body size keeps them clearly louder than the pane's smaller headings).
-- Drawn as a Selectable with the name painted by hand at the captured cursor,
-- because a Selectable's own rect overhangs by half an ItemSpacing step and
-- text hung on it loses its first pixels (the sidebar's 2026-08-05 fix).
--
-- These read as TABS, not as a list of text (2026-08-08, the user's first live
-- look): an explicit `SET_NAV_ROW_H` rather than a control-height row, and an
-- unselected name at `TEXT_SECONDARY` — the sidebar's own `TEXT_TERTIARY` is for
-- metadata beside something louder, and there is nothing louder here.
--
-- THE LIT TAB ALSO WEARS AN ACCENT EDGE (same brief, the user's pick with the
-- cost stated): a `SET_TAB_STRIPE_W` bar down its left, over the fill. This is
-- a DELIBERATE second meaning for ACCENT — "where you are", alongside its
-- active/playing job everywhere else — accepted for the settings nav only;
-- don't spread it to the browser sidebar, whose selection stays fill-only.
--
-- The FILL spans the strip edge to edge; only the NAME is inset (`SB_PAD` each
-- side). The nav child therefore carries zero window padding — padding it would
-- have shortened the fill too, leaving a gutter of chrome down both sides of
-- every tab, which is what the user reported on the second live look. Same
-- split the browser sidebar makes for its indented sub-categories: the indent
-- comes out of the name's share, never the row's.
local function nav_row(ctx, id, name, selected, first)
  local x0 = select(1, reaper.ImGui_GetCursorScreenPos(ctx))
  reaper.ImGui_Selectable(ctx, "##nav_" .. id, selected, 0, 0, M.SET_NAV_ROW_H)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local clicked = hovered and reaper.ImGui_IsMouseClicked(ctx, 0)

  local _, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if selected then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + M.SET_TAB_STRIPE_W, y1, T.ACCENT)
  end

  -- THE TOP TAB'S FIRST PIXEL (2026-08-10, user-reported sliver; mechanism
  -- verified against Dear ImGui 1.92.1 source — docs/RESEARCH.md "The 1px
  -- content clip inset under a title bar"): with FrameBorderSize 1, ImGui's
  -- content clip starts one pixel BELOW the title bar, and every child
  -- inherits it — this row is POSITIONED flush, but its fill's top pixel is
  -- clipped away and the window background shows through as a sliver. No
  -- layout can fix that (a cursor pin was tried first and did nothing);
  -- the row's own top edge is repainted here with the clip widened — the
  -- hand-drawn ✕'s technique. Idempotent over the row's visible pixels, so a
  -- fractional window position can't leave a seam.
  if first then
    -- ONLY THE TOP of the clip is widened; both horizontal edges must stay
    -- exactly where normal drawing is cut, because everything this band
    -- repaints is drawn 1px NARROWER than the naive rects say:
    --   * right — ImGui grows a Selectable's reported rect by half an
    --     ItemSpacing step each side (imgui_widgets.cpp:7141-7154), so
    --     bounding by `x1` painted ~3px into the pane (user screenshot #1);
    --   * left — the window border's half-width inset floors the clip 1px in
    --     from the window edge, so the stripe below starts 1px right of `x0`,
    --     and a band painted from `x0` stuck out blue past the stripe's top
    --     (user screenshot #2).
    -- The live clip is the truth for both; asked from the draw list where the
    -- build offers it, else rebuilt from the strip edges and the theme's
    -- fixed 1px window border.
    local clip_x0, clip_x1
    if reaper.ImGui_DrawList_GetClipRectMin ~= nil
      and reaper.ImGui_DrawList_GetClipRectMax ~= nil then
      clip_x0 = select(1, reaper.ImGui_DrawList_GetClipRectMin(dl))
      clip_x1 = select(1, reaper.ImGui_DrawList_GetClipRectMax(dl))
    else
      clip_x0 = x0 + 1
      clip_x1 = select(1, reaper.ImGui_GetWindowPos(ctx))
        + reaper.ImGui_GetWindowWidth(ctx)
    end
    reaper.ImGui_DrawList_PushClipRect(dl, clip_x0, y0, clip_x1, y0 + 2, false)
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, clip_x1, y0 + 2, T.BG_CHROME)
    -- The fill the Selectable itself would have drawn there, from the live
    -- style rather than re-derived tokens, so the two can never disagree —
    -- in the Selectable's own precedence (Codex review, 2026-08-10): held
    -- wears HeaderActive and hovered wears HeaderHovered even on a selected
    -- row; Header is only the resting selected face.
    local active = reaper.ImGui_IsItemActive ~= nil and reaper.ImGui_IsItemActive(ctx)
    local fill
    if active and hovered then
      fill = reaper.ImGui_GetStyleColor(ctx, reaper.ImGui_Col_HeaderActive())
    elseif hovered then
      fill = reaper.ImGui_GetStyleColor(ctx, reaper.ImGui_Col_HeaderHovered())
    elseif selected then
      fill = reaper.ImGui_GetStyleColor(ctx, reaper.ImGui_Col_Header())
    end
    if fill then reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, clip_x1, y0 + 2, fill) end
    if selected then
      -- From `x0` on purpose: the clip trims it to the same left edge the
      -- stripe below is trimmed to, so the two columns of blue line up.
      reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + M.SET_TAB_STRIPE_W, y0 + 2, T.ACCENT)
    end
    reaper.ImGui_DrawList_PopClipRect(dl)
  end

  -- Bold pushed around the measure AND the paint — DrawList text renders in
  -- whatever font is current, and a cut measured in one weight lies in the
  -- other. Falls back to the regular face (today's look) when no bold cut
  -- exists, the same graceful miss as every heading.
  --
  -- `SET_TAB_PAD`, not the sidebar's `SB_PAD`: with the stripe living in the
  -- row's left edge, the 6px inset put the name 4px off the accent bar
  -- (user-reported 2026-08-10). Every tab indents the same, lit or not.
  local bold = theme.push_bold_font(ctx)
  local text_x = x0 + M.SET_TAB_PAD
  local label = widgets.ellipsize(ctx, name:upper(), (x1 - M.SET_TAB_PAD) - text_x)
  local _, lh = reaper.ImGui_CalcTextSize(ctx, label)
  -- Snapped to a whole pixel: centring a body-size line in the row lands on a
  -- half pixel whenever the two have opposite parity, and ImGui renders a glyph
  -- run at a fractional origin visibly softer.
  reaper.ImGui_DrawList_AddText(dl,
    text_x, math.floor((y0 + y1) * 0.5 - lh * 0.5 + 0.5),
    selected and T.TEXT_PRIMARY or T.TEXT_SECONDARY, label)
  if bold then reaper.ImGui_PopFont(ctx) end

  return clicked
end

function settings.draw(ctx, state, res)
  local action
  if not ui.open then return nil end
  -- The Lucide font for the icon squares (see `row`). Per frame, not cached at
  -- load: resources belong to ui/app.lua and may not exist on old ReaImGui.
  icon_font = res and res.icon_font or nil

  -- A REAL WINDOW, not a modal (2026-08-08, user's call): everything behind it
  -- stays live and clickable, and it closes by its own title-bar ✕ — the same
  -- shape as the Loudness panel, and the reason the old footer Close bar is gone.
  --
  -- Fixed size every frame (Cond_Always) plus NoResize: the size is a decision,
  -- not a consequence of what happens to be inside. NoScrollbar because a
  -- scrollbar toggling on would steal width from the pane and change where every
  -- value is cut, frame to frame — the reservation below is exact, so there is
  -- nothing to scroll. Position is ImGui's own ini business after the first
  -- open, so a window dragged somewhere convenient stays there.
  local flags = reaper.ImGui_WindowFlags_NoResize()
    | reaper.ImGui_WindowFlags_NoCollapse()
    | reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  if reaper.ImGui_WindowFlags_NoDocking then
    flags = flags | reaper.ImGui_WindowFlags_NoDocking()
  end
  reaper.ImGui_SetNextWindowSize(ctx, M.SET_WIN_W, M.SET_WIN_H, reaper.ImGui_Cond_Always())
  if HAS_VIEWPORT then
    local cx, cy = reaper.ImGui_Viewport_GetCenter(reaper.ImGui_GetMainViewport(ctx))
    reaper.ImGui_SetNextWindowPos(ctx, cx, cy, reaper.ImGui_Cond_FirstUseEver(), 0.5, 0.5)
  end

  -- Zero window padding so the nav list bleeds to the window's own edges — the
  -- browser's rule, panels pad themselves. Popped the instant the window has
  -- taken it (ImGui reads WindowPadding once, at Begin); held across the contents
  -- it would also land on every tooltip and stacked popup inside.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  -- Centred title, like every other panel in the tool (user's call, 2026-08-08).
  local visible, still_open = theme.begin_window(ctx, "SETTINGS###yb_settings", true, flags, true)
  reaper.ImGui_PopStyleVar(ctx)
  if not still_open then
    ui.open = false
    -- The ✕ took the click; hand the keyboard back to REAPER rather than leaving
    -- focus on a window that's about to vanish (the browser's own ✕ path).
    focus.request()
  end
  -- No End on this path — ReaImGui's Begin already ended a not-visible window
  -- itself (see the matchwin note, verified 2026-08-09); End belongs to the
  -- visible path only.
  if not visible then
    return nil
  end

  -- The panes take the whole window now — the Close footer is gone with the
  -- modal, so there is nothing to reserve height for.
  local panes_h = select(2, reaper.ImGui_GetContentRegionAvail(ctx))

  -- Nav: full-bleed chrome, square corners (it meets the window edges), and ZERO
  -- padding on every side — a tab's fill runs the strip's full width and butts
  -- against its neighbours and the title bar. Any padding here becomes a gutter
  -- of bare chrome around the tabs, which is exactly what reads as "a list
  -- floating in a panel" rather than a tab strip (user's calls, 2026-08-08:
  -- first the gap above the top one, then the gaps either side). The names are
  -- inset inside the row instead — see nav_row.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), T.BG_CHROME)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local nav_flags = HAS_CHILD_PAD and reaper.ImGui_ChildFlags_AlwaysUseWindowPadding() or 0
  local nav_open = reaper.ImGui_BeginChild(ctx, "settingsnav", M.SET_NAV_W, panes_h, nav_flags)
  reaper.ImGui_PopStyleVar(ctx, 2)
  if nav_open then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), M.ITEM_SPACING_X, 0)
    for i, s in ipairs(SECTIONS) do
      -- `i == 1`: the top tab repaints its clipped first pixel — see nav_row.
      if nav_row(ctx, s.id, s.name, ui.section == s.id, i == 1) then ui.section = s.id end
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx)

  -- One hairline on the seam — the only separation the two surfaces need.
  local nx1, ny1 = reaper.ImGui_GetItemRectMax(ctx)
  local _, ny0 = reaper.ImGui_GetItemRectMin(ctx)
  reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
    nx1 + 0.5, ny0, nx1 + 0.5, ny1, T.STROKE_TERTIARY, 1)
  reaper.ImGui_SameLine(ctx, 0, 0)

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), M.WINDOW_PAD, M.WINDOW_PAD)
  local pane_flags = HAS_CHILD_PAD and reaper.ImGui_ChildFlags_AlwaysUseWindowPadding() or 0
  -- The pane never scrolls — the window's own rule, extended to the child that
  -- fills it (2026-08-09, user-reported: the Help composer's exact-fit stack
  -- could still wheel-scroll by a rounding hair). Every section reserves its
  -- height exactly; anything that scrolls does so in a child of its OWN (the
  -- release notes, the message box), never as "the page".
  local pane_win_flags = reaper.ImGui_WindowFlags_NoScrollbar()
    | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  local pane_open = reaper.ImGui_BeginChild(ctx, "settingspane", 0, panes_h,
    pane_flags, pane_win_flags)
  reaper.ImGui_PopStyleVar(ctx)
  -- The pane draws its section's rows and NOTHING ELSE — no heading, no rule.
  -- It used to repeat the section's name over a Separator, which the lit tab
  -- two inches to the left already says (flagged as redundant when it shipped,
  -- removed 2026-08-08 on the user's call). The section headings that DO earn
  -- their place are the ones in the Loudness panel, where several sections stack
  -- in one pane and the names are the only thing telling them apart.
  if pane_open then
    first_row = true -- the section's first row opens the pane, so it gets no rule
    for _, s in ipairs(SECTIONS) do
      if ui.section == s.id then
        local sec_action = s.draw(ctx, state)
        action = action or sec_action
      end
    end
    reaper.ImGui_EndChild(ctx)
  end

  -- Esc puts the window away while it has focus — the one popup habit kept now
  -- that outside clicks deliberately don't close it (the Loudness panel's rule).
  if HAS_ESCAPE and reaper.ImGui_IsWindowFocused(ctx)
    and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    ui.open = false
    focus.request()
  end

  reaper.ImGui_End(ctx)
  return action
end

return settings
