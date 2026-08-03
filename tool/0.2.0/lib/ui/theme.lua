-- theme: the one fixed dark theme (Cursor-IDE look), as a token table plus a
-- push/pop pair applied once per frame. Nothing in the UI hard-codes a colour or
-- size — it comes from here. Mirror of skills/reaimgui-ui/tokens.md; if a token is
-- missing, add it here first.
--
-- Colours are 0xRRGGBBAA (the alpha is part of the token — keep it).

local theme = {}

local T = {
  -- Backgrounds (darkest -> lightest)
  BG_CHROME       = 0x141414FF, -- title bar, sidebar, docked chrome
  BG_WINDOW       = 0x181818FF, -- main content background
  BG_POPUP        = 0x1F1F1FFF, -- popups, menus, tooltips
  -- Fills (white overlays for hover/selection/inputs)
  FILL_PRIMARY    = 0xE4E4E430, -- active/pressed
  FILL_SECONDARY  = 0xE4E4E41E, -- selected rows, button hover (active toggles use ACCENT faces)
  FILL_TERTIARY   = 0xE4E4E411, -- default control background
  FILL_QUATERNARY = 0xE4E4E40A, -- input fields, waveform background
  -- Strokes / borders
  STROKE_PRIMARY   = 0xE4E4E433, -- focused element borders
  STROKE_SECONDARY = 0xE4E4E41F, -- default control borders
  STROKE_TERTIARY  = 0xE4E4E414, -- hairlines, dividers
  -- Text
  TEXT_PRIMARY    = 0xE4E4E4EB, -- headings, selected, active values
  TEXT_SECONDARY  = 0xE4E4E48D, -- default row text, labels, buttons
  TEXT_TERTIARY   = 0xE4E4E45E, -- metadata values, inactive icons
  TEXT_QUATERNARY = 0xE4E4E442, -- durations, counts, placeholders, disabled
  TEXT_ON_ACCENT  = 0x191C22FF, -- text on accent-filled surfaces
  -- Accent & state
  ACCENT       = 0x599CE7FF, -- play, selection edge, active sort, drop highlight
  ACCENT_HOVER = 0x6AABE9FF,
  ACCENT_WASH  = 0x599CE714, -- drop-target fill while a file drag hovers it
  REF_RED      = 0xFC6B83FF, -- reference mode ONLY (nothing else may be red)
  TEXT_ON_REF  = 0x1A1414FF,
  -- Waveform (aliases of the above, named for their role so the drawing code
  -- reads by intent, not by borrowing an unrelated token).
  WAVE_BG       = 0xE4E4E40A, -- = FILL_QUATERNARY: panel background
  WAVE_BARS     = 0xE4E4E45E, -- = TEXT_TERTIARY: unplayed part of the waveform
  WAVE_PLAYED   = 0x599CE7FF, -- = ACCENT: part left of the playhead while playing
  WAVE_PLAYHEAD = 0xE4E4E4EB, -- = TEXT_PRIMARY: the playhead line
  -- Reference tabs (aliases, same intent-naming as the waveform block): the
  -- working view's reference row draws each pin as a compact tab (Phase 5.7
  -- Stage 2, 2026-07-28 — replaces the retired Context-row treatment above).
  -- Selected re-uses the same fill every Selectable/Header already uses;
  -- armed re-uses REF_RED, red's third home after the window border and the
  -- REF button itself (tokens.md "reference-row grammar").
  REF_TAB_SELECTED = 0xE4E4E41E, -- = FILL_SECONDARY
  REF_TAB_ARMED    = 0xFC6B83FF, -- = REF_RED
  -- Faders (aliases, same intent-naming as the waveform group). The track uses the
  -- strongest white fill because a 4px bar needs more contrast than a full-height
  -- frame to stay visible on the window background.
  FADER_TRACK = 0xE4E4E430, -- = FILL_PRIMARY: unfilled part of the track
  FADER_FILL  = 0x599CE7FF, -- = ACCENT: filled part (ACCENT_HOVER while hovered)
  FADER_KNOB  = 0xE4E4E4EB, -- = TEXT_PRIMARY: the pill grab knob
  FADER_TICK  = 0xE4E4E433, -- = STROKE_PRIMARY: the 0 dB detent mark on trim
}
theme.tokens = T

-- A sub-category's name is written in a dimmer shade of its parent's colour —
-- the family reads at a glance while the parent stays strongest (S2, decided
-- 2026-07-27). One factor, applied to the colour's alpha byte only.
local SUB_DIM = 0.62
function theme.dim(color)
  local a = color & 0xFF
  return (color & ~0xFF) | math.floor(a * SUB_DIM + 0.5)
end

-- Layout sizes (pre-DPI-scale), mirrored from tokens.md "Sizing". Kept out of the
-- colour table so a size never gets used where a colour is expected. A global DPI
-- pass multiplies these later (structure now, polish last).
theme.metrics = {
  -- ONE body text size for the whole app (2026-07-29 redesign review): the old
  -- split — 13px working view vs 16px browser — was exactly the inconsistency
  -- the user flagged ("two size worlds"). theme.apply pushes this over ReaImGui's
  -- built-in 13px default once per frame, so both windows, every popup and every
  -- tooltip read the same. Control height follows automatically (15 + 2×6 = 27).
  BASE_FS = 15,
  SIDEBAR_W = 185, -- default sidebar width; user-resizable by dragging its edge (ChildFlags_ResizeX, persisted by ImGui's own ini)
  SB_PAD    = 8,   -- sidebar inner padding (spacing scale)
  -- Sidebar rows sit tight (2026-07-29, user: "we don't need an empty row
  -- between subcategories") — the global ItemSpacing.y of 8 read as blank rows
  -- between 13px caps lines. Only the deliberate view/category separators
  -- (Dummy 8) remain as gaps.
  SB_ROW_GAP = 2,
  INDENT    = 12,  -- sub-category indent (spacing scale)
  -- List row height is NOT read by any draw call — ImGui's ListClipper is given
  -- no items_height (see draw_sound_list's ListClipper_Begin), so it auto-measures
  -- from the row actually submitted and can never desync from the real font size.
  -- Kept here as a rough reference only; bumped to reflect BROWSER_FS.
  ROW_H     = 27,  -- list row height (informational; tracks BASE_FS 15 + FramePadding)
  -- Waveform panel height is not fixed: it fills whatever space is left after
  -- the transport row and the reference row have taken theirs. No floor any
  -- more (2026-07-30) — a floor is what pushed the transport off the bottom of
  -- a short window and summoned a scrollbar. WAVE_MIN_H survives only as the
  -- fallback height for a caller that passes none (see ui/waveform.lua).
  WAVE_MIN_H = 60,
  -- Below this there is no useful waveform left, so it isn't drawn at all
  -- rather than shown as a sliver. Vertical priority is absolute: transport
  -- first, reference row second, waveform last.
  WAVE_HIDE_H = 24,
  -- The side-column arrangement (decided 2026-07-30). A short window packs the
  -- controls into a column so the waveform gets the height instead of a thin
  -- band; a taller one keeps them stacked. Which one is in use is chosen from
  -- the room actually measured, never from the window's shape — a 900×450 and a
  -- 400×200 panel share an aspect ratio and need opposite treatment.
  --
  -- The two thresholds differ on purpose: switching arrangement changes how
  -- much room there is, which would re-trigger a single-threshold test and
  -- oscillate while the user drags the dock edge. The gap between them is the
  -- dead band that breaks that loop.
  LAYOUT_SWITCH_LO = 120, -- stacked -> column, once stacked's waveform would be shorter than this
  LAYOUT_SWITCH_HI = 160, -- column -> stacked, only once it would be taller than this
  WAVE_MIN_W = 260,       -- the column arrangement needs at least this much left for the waveform
  -- The browser popup's compact audition strip (Phase 5.7 Stage 3): fixed,
  -- unlike the working view's waveform, because the popup also needs room for
  -- its own status/search row and the sortable table below. Roughly doubled
  -- 2026-07-28 (was 48) — the user reported it too short to read comfortably.
  BROWSER_WAVE_H = 96,
  -- Breathing room between a channel lane's loudest possible bar and the lane edge,
  -- so stereo lanes don't touch across their hairline. A fixed inset, NOT a fraction
  -- of the lane (which was the original 0.85 factor): a proportional gap grew with
  -- the window and read as dead space in a tall panel (2026-07-30).
  WAVE_LANE_PAD = 2,
  -- REF_W is retired (2026-07-30): the latch is a square like every other
  -- transport control now, faced "R", so it sizes from GetFrameHeight like the
  -- rest and needs no width of its own.
  SLIDER_W  = 140, -- trim / master volume fader TOTAL width (track + gap + readout)
  -- Fader anatomy (all inside SLIDER_W, so the row layout never changes):
  FADER_VAL_W   = 62, -- fixed readout zone right of the track ("+24.0 dB" at BASE_FS 15; was 54 at 13px)
  -- Gap between the end of the track and the first digit. Widened from 6 to 8
  -- (2026-08-01): the knob is a pill that overhangs the track's end, so a
  -- fader parked at its maximum left barely 4px of clear air before the number.
  FADER_VAL_GAP = 8,
  FADER_TRACK_H = 4,  -- track bar thickness (spacing scale)
  FADER_KNOB_W  = 4,  -- slim pill knob: width …
  FADER_KNOB_H  = 12, -- … and height (taller than the track so it reads at the ends)
  FADER_TICK_H  = 8,  -- 0 dB detent mark height (overhangs the track 2px each side)
  -- Responsive collapse for the working view's transport row (tokens.md
  -- "working view — responsive collapse order", Phase 5.7 Stage 2): the trim
  -- fader hides once less than SLIDER_W plus this much room is left for the
  -- readout tail, rather than crushing both illegibly. Window-size driven only.
  TRIM_MIN_TAIL = 60,
  FIELD_W   = 200, -- standard text-input width (popup name fields)
  SEARCH_W  = 200, -- the search box (fits "Search name or note" + the embedded magnifier at BASE_FS 15)
  SEARCH_ICON_PAD = 28, -- left FramePadding.x for the search field, clearing the drawn magnifier glyph
  POPUP_BTN_W = 80, -- popup action buttons (OK / Cancel / Delete / Close)
  -- Sound table's fixed columns (Name stretches to fill what's left). Widened
  -- 2026-07-28 alongside BROWSER_FS so the bigger digits/header text don't clip
  -- (was 56/64/84 at the old 13px body text).
  COL_DUR_W  = 64, -- Dur column
  COL_CH_W   = 70, -- Ch column
  COL_LOUD_W = 96, -- Loudness column (LUFS-I / LUFS-M / dBTP header)
  -- The pin column: a pushpin glyph, header included. Widened from 24 on
  -- 2026-08-01, when the column became sortable — ImGui draws the sort arrow
  -- inside the header cell, and at 24 the arrow sat on top of the pushpin.
  PIN_COL_W  = 40,
  -- Group rows (browser categories, views) — the "this is a grouping, not a
  -- sound" treatment: small-caps name at a smaller size, coloured by meaning,
  -- vs sounds' mixed case (sidebar redesign, 2026-07-27 — swatches removed;
  -- colour lives in the name itself). Also the size for the browser's small
  -- text: sidebar counts, the info row's tech details, the PREVIEW fader label.
  GROUP_FS  = 13,  -- small text size (caps rows keep reading smaller than the 15px body)
  -- Floating-window floor: below this the layout is unusable, and a size saved
  -- while squashed used to come back just as squashed on every reopen. Docked
  -- windows are sized by their dock node, so this only governs floating.
  MIN_WIN_W = 380,
  MIN_WIN_H = 240,
  -- The update notice: an ACCENT dot drawn over the gear button's top-right
  -- corner while a newer version is published (DESIGN "Distribution, updates &
  -- versioning" — the gear is the notice's ONLY home; nothing moves or resizes).
  UPDATE_DOT_R = 3,
}

-- The control column's width is NOT a metric: it's two square controls plus one
-- gap, so it derives from the live frame height (see transport.column_width).
-- It used to be pinned to SLIDER_W, which made the fader set the column's width
-- and left dead space beside every button row.

-- ImGui colour slot -> token. Guarded at apply time, so a slot that a slightly
-- older ReaImGui doesn't define is simply skipped (the pop count still matches).
local COLORS = {
  { "WindowBg",         "BG_WINDOW" },
  { "ChildBg",          "BG_WINDOW" },
  { "PopupBg",          "BG_POPUP" },
  { "Border",           "STROKE_SECONDARY" },
  { "FrameBg",          "FILL_QUATERNARY" },
  { "FrameBgHovered",   "FILL_TERTIARY" },
  { "FrameBgActive",    "FILL_SECONDARY" },
  { "TitleBg",          "BG_CHROME" },
  { "TitleBgActive",    "BG_CHROME" },
  { "TitleBgCollapsed", "BG_CHROME" },
  { "MenuBarBg",        "BG_CHROME" },
  { "ScrollbarBg",      "BG_CHROME" },
  { "Text",             "TEXT_SECONDARY" },
  { "TextDisabled",     "TEXT_QUATERNARY" },
  { "Button",           "FILL_TERTIARY" },
  { "ButtonHovered",    "FILL_SECONDARY" },
  { "ButtonActive",     "FILL_PRIMARY" },
  { "Header",           "FILL_SECONDARY" },
  { "HeaderHovered",    "FILL_TERTIARY" },
  { "HeaderActive",     "FILL_PRIMARY" },
  { "Separator",        "STROKE_TERTIARY" },
  { "CheckMark",        "ACCENT" },
  { "SliderGrab",       "ACCENT" },
  { "SliderGrabActive", "ACCENT_HOVER" },
}

-- ImGui style var -> value(s). Sizes are pre-DPI; a global DPI-scale pass lands
-- with the real layout work (kept simple for the skeleton). Radius/spacing values
-- come from the token scale in tokens.md.
local VARS = {
  { "WindowRounding",   { 8 } },
  { "WindowBorderSize", { 1 } },
  { "WindowPadding",    { 12, 12 } },
  { "ChildRounding",    { 4 } },
  { "FrameRounding",    { 4 } },
  { "FrameBorderSize",  { 1 } },
  { "PopupRounding",    { 8 } },
  { "ItemSpacing",      { 8, 8 } },
  -- Sets every framed control (buttons, inputs, sliders) to the same comfortable
  -- height: base font 13 + 2×6 = 25px. Left unset, ImGui's default (4,3) made
  -- them a cramped 19px — well under the 25 the design calls for.
  { "FramePadding",     { 8, 6 } },
  { "GrabRounding",     { 4 } }, -- slider grabs share the control radius (tokens.md)
}

-- The slot lookups above resolved ONCE, on the first frame. The slot functions
-- return constants, so re-deriving each name string and doing the table lookup
-- every frame was ~32 throwaway strings a frame — small, but repeated frame-loop
-- allocations are exactly what the frame rules forbid. A slot an older ReaImGui
-- doesn't define is skipped here, so the push and pop counts still match.
local resolved_colors, resolved_vars

local function resolve()
  resolved_colors = {}
  for _, c in ipairs(COLORS) do
    local fn = reaper["ImGui_Col_" .. c[1]]
    if fn then resolved_colors[#resolved_colors + 1] = { fn(), T[c[2]] } end
  end
  resolved_vars = {}
  for _, v in ipairs(VARS) do
    local fn = reaper["ImGui_StyleVar_" .. v[1]]
    if fn then resolved_vars[#resolved_vars + 1] = { fn(), v[2] } end
  end
end

-- Whether this ReaImGui supports PushFont(ctx, nil, size) — the resize form that
-- carries the app-wide BASE_FS. Probed ONCE with a pcall on the first frame (the
-- same idiom browser.lua used for its old per-window push); on an older build the
-- whole app simply stays at the built-in 13px, consistently.
local base_font_ok

-- Small-text push (GROUP_FS): caps rows, sidebar counts, the info row's tech
-- details, the PREVIEW fader label. One probed implementation shared by every
-- caller (browser, transport) so the fallback behaviour can't diverge. Returns
-- whether a font was pushed — the caller pops only if it was.
local small_font_ok
function theme.push_small_font(ctx)
  if small_font_ok == nil then
    small_font_ok = pcall(reaper.ImGui_PushFont, ctx, nil, theme.metrics.GROUP_FS)
    return small_font_ok
  end
  if small_font_ok then
    reaper.ImGui_PushFont(ctx, nil, theme.metrics.GROUP_FS)
    return true
  end
  return false
end

-- Push the whole theme. Returns how many colours, vars and fonts were pushed so
-- the caller pops exactly that many (mismatched counts make ImGui raise).
function theme.apply(ctx)
  if not resolved_colors then resolve() end
  for _, c in ipairs(resolved_colors) do
    reaper.ImGui_PushStyleColor(ctx, c[1], c[2])
  end
  for _, v in ipairs(resolved_vars) do
    reaper.ImGui_PushStyleVar(ctx, v[1], table.unpack(v[2]))
  end
  local nf = 0
  if base_font_ok == nil then
    base_font_ok = pcall(reaper.ImGui_PushFont, ctx, nil, theme.metrics.BASE_FS)
    nf = base_font_ok and 1 or 0
  elseif base_font_ok then
    reaper.ImGui_PushFont(ctx, nil, theme.metrics.BASE_FS)
    nf = 1
  end
  return #resolved_colors, #resolved_vars, nf
end

function theme.unapply(ctx, nc, nv, nf)
  if nf and nf > 0 then reaper.ImGui_PopFont(ctx) end
  if nv and nv > 0 then reaper.ImGui_PopStyleVar(ctx, nv) end
  if nc and nc > 0 then reaper.ImGui_PopStyleColor(ctx, nc) end
end

return theme
