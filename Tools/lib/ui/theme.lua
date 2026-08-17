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
  -- Text. The whole ladder was lifted on 2026-08-07 (user: this grey "is
  -- generally quite hard to read"). TERTIARY was the complaint, but raising it
  -- alone would have landed it on top of SECONDARY and flattened the three
  -- tiers into one, so all three moved together and kept their spacing. Only
  -- QUATERNARY is allowed to whisper, and nothing the user must read uses it.
  TEXT_PRIMARY    = 0xE4E4E4EB, -- headings, selected, active values
  TEXT_SECONDARY  = 0xE4E4E4B8, -- default row text, labels, buttons
  TEXT_TERTIARY   = 0xE4E4E485, -- metadata values, inactive icons
  TEXT_QUATERNARY = 0xE4E4E45C, -- durations, counts, placeholders, disabled
  TEXT_ON_ACCENT  = 0x191C22FF, -- text on accent-filled surfaces
  -- Accent & state
  ACCENT       = 0x599CE7FF, -- play, selection edge, active sort, drop highlight
  ACCENT_HOVER = 0x6AABE9FF,
  ACCENT_WASH  = 0x599CE714, -- drop-target fill while a file drag hovers it
  -- Red is no longer RESERVED (2026-08-06, user's call). It used to mean "and
  -- nothing else in the UI may be red", which forced the whole window outline
  -- and the picker slot red while reference mode was latched, and pushed every
  -- other red decision through a documented exception. Both of those are gone:
  -- the LATCH BUTTON is the only thing that reddens for reference mode now, and
  -- red is free to mean "destructive" elsewhere.
  REF_RED      = 0xFC6B83FF, -- the latch button's fill while reference mode is on
  TEXT_ON_REF  = 0x1A1414FF, -- the "R" on that red fill
  -- A destructive control's GLYPH while the cursor is on it (today only the
  -- picker's unpin cross). Same hue as REF_RED on purpose: two nearly-identical
  -- reds would be harder to tell apart than one red doing two jobs, and the two
  -- can't be confused anyway — the latch is a filled square that persists while
  -- your project is muted, this is a glyph that reddens only under the cursor.
  DANGER_RED   = 0xFC6B83FF, -- = REF_RED
  -- The title bar's ✕ under the cursor. The same red, THINNED over the dark
  -- title bar rather than laid on at full strength: at full strength the cross
  -- on top of it all but disappeared (user-reported 2026-08-08). What these two
  -- read as is a muted brick red with a clearly legible near-white cross, one
  -- step stronger while the button is held.
  CLOSE_HOVER  = 0xFC6B8399,
  CLOSE_HELD   = 0xFC6B83CC,
  -- Waveform (aliases of the above, named for their role so the drawing code
  -- reads by intent, not by borrowing an unrelated token).
  WAVE_BG       = 0xE4E4E40A, -- = FILL_QUATERNARY: panel background
  -- Held at the OLD tertiary alpha when the text ladder was lifted (2026-08-07):
  -- the complaint was about reading words, and these are bars in a picture —
  -- brightening them would flatten the waveform against its played half.
  WAVE_BARS     = 0xE4E4E45E, -- unplayed part of the waveform
  WAVE_PLAYED   = 0x599CE7FF, -- = ACCENT: part left of the playhead while playing
  WAVE_PLAYHEAD = 0xE4E4E4EB, -- = TEXT_PRIMARY: the playhead line
  -- Outside the start/end span the picture DIMS (loudness tools, 2026-08-06):
  -- a window-coloured wash, dark enough that the framed stretch clearly reads
  -- as "what plays", light enough that the excluded picture is still there.
  SPAN_DIM      = 0x181818A6,
  -- The REF_TAB_* pair retired with the reference row itself (2026-08-06, the
  -- reference-picker redesign): the pins are no longer tabs, so red's third
  -- home moved to the picker slot in the control bar, where it is REF_RED +
  -- TEXT_ON_REF directly rather than an alias of its own.
  -- Faders (aliases, same intent-naming as the waveform group). The track uses the
  -- strongest white fill because a 4px bar needs more contrast than a full-height
  -- frame to stay visible on the window background.
  FADER_TRACK = 0xE4E4E430, -- = FILL_PRIMARY: unfilled part of the track
  FADER_FILL  = 0x599CE7FF, -- = ACCENT: filled part (ACCENT_HOVER while hovered)
  FADER_KNOB  = 0xE4E4E4EB, -- = TEXT_PRIMARY: the pill grab knob
  FADER_TICK  = 0xE4E4E433, -- = STROKE_PRIMARY: the 0 dB detent mark on trim
  -- The slim scrollbar thumb (widgets.scrollbar — the browser table's rail and
  -- the sidebar's, brief `table-scrollbar` 2026-08-09). It replaced ImGui's own
  -- bar there: that one carved its width out of the columns and ran up into the
  -- frozen header. No track colour on purpose — the empty strip IS the track.
  SCROLL_THUMB     = 0xE4E4E430, -- = FILL_PRIMARY: resting (a 4px pill needs the contrast)
  SCROLL_THUMB_HOT = 0xE4E4E45C, -- hovered or dragged (= TEXT_QUATERNARY's alpha)
  -- The walkthrough's spotlight wash (2026-08-10, `.brief/_done/walkthrough/`):
  -- chrome-dark over everything but the ringed target. 0xAD on the first live
  -- look was too heavy ("less greyed out", round 2) — 0x78 keeps the dimmed
  -- controls readable while the ringed target still clearly leads.
  WALK_DIM = 0x14141478,
  -- Its footer's progress dots (2026-08-10, `.brief/walkthrough-footer/`): the
  -- stop you are on wears ACCENT, the rest this dim white. Same value as
  -- FILL_PRIMARY, named for its role like the waveform's aliases — a 5px disc
  -- is a mark, not a control fill.
  WALK_DOT = 0xE4E4E430,
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

-- DrawList colours ignore the style Alpha that BeginDisabled lowers — anything
-- hand-painted onto a draw list (widgets.lua's faders/scrollbar, icons.lua's
-- glyphs) must fade itself or it stays at full brightness while disabled.
-- Shared here so every custom-drawn control agrees on the same arithmetic.
function theme.fade(col, alpha)
  if alpha >= 1 then return col end
  local a = math.floor((col & 0xFF) * alpha + 0.5)
  return (col & ~0xFF) | a
end

-- Layout sizes, mirrored from tokens.md "Sizing". Kept out of the colour table so
-- a size never gets used where a colour is expected.
--
-- These are the AUTHORING values — every one of them at scale 1.0. The live table
-- the UI reads is `theme.metrics`, which `theme.set_scale` fills by multiplying
-- these (see below). Change a size HERE, never in theme.metrics.
local BASE = {
  -- ONE body text size for the whole app (2026-07-29 redesign review): the old
  -- split — 13px working view vs 16px browser — was exactly the inconsistency
  -- the user flagged ("two size worlds"). theme.apply pushes this over ReaImGui's
  -- built-in 13px default once per frame, so both windows, every popup and every
  -- tooltip read the same. Control height follows automatically (13 + 2×4 = 21).
  --
  -- 15 until 2026-08-07, when the whole UI was tightened to REAPER's own density
  -- (user: "space is precious in REAPER" — the tool lives docked beside a project,
  -- and every pixel the chrome takes is a pixel the waveform doesn't get).
  BASE_FS = 13,
  -- The framed-control geometry, in one place because every square button, the
  -- bar's height and the whole collapse order derive from it. FramePadding.y is
  -- what actually sets control height: BASE_FS + 2×FRAME_PAD_Y.
  FRAME_PAD_X = 6, -- was 8
  FRAME_PAD_Y = 4, -- was 6 -> control height 27; now 21
  ITEM_SPACING_X = 6, -- was 8
  ITEM_SPACING_Y = 6, -- was 8
  WINDOW_PAD     = 8, -- was 12
  -- Icon glyph sizes. Lucide glyphs are drawn at an explicit size rather than the
  -- current font's, so they need their own token or they'd stay big while
  -- everything around them shrank (ui/icons.lua).
  ICON_FS    = 14, -- a square button's glyph (was a hardcoded 16)
  ICON_SM_FS = 12, -- a glyph painted inside something else: the picker's chevron, the search magnifier (was 14)
  ICON_PIN_FS = 11, -- the sound table's pushpin, header and rows alike (was 12/13 — two sizes for one glyph)
  -- Default sidebar width; user-resizable by dragging its edge (ChildFlags_ResizeX,
  -- persisted by ImGui's own ini). 185 before the density pass, briefly 160 —
  -- but 160 assumed the rows had shrunk with everything else, and they went back
  -- to the body size the same day (they were unreadable at 11px). The row text is
  -- therefore the SAME 13px it always was, so a much narrower sidebar would clip
  -- category names sooner than before the pass; the tighter padding pays for most
  -- of the difference.
  SIDEBAR_W = 176,
  -- How narrow the drag may take it. Without a floor the edge could be pulled in
  -- until a category row was a couple of letters and an ellipsis — technically
  -- still drawn, useless to read (user's ask, 2026-08-07). Sized to hold a short
  -- caps name plus its count with room to spare, so hitting the floor still
  -- leaves a working sidebar rather than a stub.
  SIDEBAR_MIN_W = 120,
  -- The count's right margin, and the reserved air between the name and the
  -- count beside it.
  --
  -- The margin clears the slim scrollbar's THUMB (2026-08-11): every sidebar row
  -- now runs the panel's full width — the category list gave up its reserved
  -- rail, which was what left the category counts a strip short of the two
  -- pinned views' counts above them — so the thumb, when the list overflows,
  -- floats over the rows' right end. At 10 the digits stop just left of it; at
  -- the old 6 the thumb crossed the last one.
  --
  -- The GAP is deliberately small because it is only half of what you see. A cut
  -- name ends at the last WHOLE character that fits, so there is always up to
  -- one character of leftover slack between the ellipsis and the reserved edge
  -- on top of this — unavoidable, since the count is right-aligned to the row
  -- and cutting mid-character is worse. At 8 the two together read as a hole
  -- (user-reported 2026-08-07); at 4 the reserved air still keeps a FULL name
  -- off the number, and a cut one lands where the eye expects.
  SB_COUNT_PAD = 10,
  SB_COUNT_GAP = 4,
  SB_PAD    = 6,   -- sidebar inner padding (spacing scale)
  -- Sidebar rows sit tight (2026-07-29, user: "we don't need an empty row
  -- between subcategories") — the global ItemSpacing.y of 8 read as blank rows
  -- between 13px caps lines. Only the deliberate view/category separators
  -- (Dummy 8) remain as gaps.
  SB_ROW_GAP = 2,
  INDENT    = 10,  -- sub-category indent
  -- List row height is NOT read by any draw call — ImGui's ListClipper is given
  -- no items_height (see draw_sound_list's ListClipper_Begin), so it auto-measures
  -- from the row actually submitted and can never desync from the real font size.
  -- Kept here as a rough reference only.
  ROW_H     = 17,  -- list row height (informational; text line height + table CellPadding — tightened 2026-08-05 from control height, which read as too spaced out)
  -- Waveform panel height is not fixed: it fills whatever space is left once
  -- the control bar has taken its own. No floor any more (2026-07-30) — a floor
  -- is what pushed the controls off the bottom of a short window and summoned a
  -- scrollbar. WAVE_MIN_H survives only as the fallback height for a caller that
  -- passes none (see ui/waveform.lua).
  WAVE_MIN_H = 60,
  -- Below this there is no useful waveform left, so it isn't drawn at all
  -- rather than shown as a sliver. Vertical priority is absolute: the control
  -- bar first, the ruler next, the waveform last.
  WAVE_HIDE_H = 24,
  -- The working view's time ruler (waveform ruler brief, 2026-08-05): a fixed
  -- strip carved OUT of the waveform's own height budget, never added on top —
  -- reserved whether or not a sound is currently armed, so it never changes
  -- size with state (ui/waveform.lua, ui/window.lua). The browser's strip
  -- carries the same ruler since 2026-08-06, but ADDS it beneath instead.
  --
  -- DELIBERATELY NOT SHRUNK in the 2026-08-07 density pass (user's call): the
  -- tightening comes out of the controls, never out of the picture. The ruler's
  -- labels got smaller with everything else, so it simply reads as roomier now.
  RULER_H = 22,
  RULER_TICK_MAJOR = 6, -- major tick length, px, pointing up from the strip's top edge
  RULER_TICK_MINOR = 4, -- minor tick length, px
  -- The reference picker (2026-08-06 redesign — it replaced the reference-tab
  -- row, and with it the whole side-column arrangement and its two switch
  -- thresholds: the working view is ONE control bar under the waveform now, so
  -- there is no arrangement left to choose between).
  PICK_MIN_W    = 80,  -- the name slot's smallest width before the bar wraps its cluster
  -- ...and its LARGEST. The slot is the bar's flexible element — it absorbs
  -- every spare pixel — so on a wide window it stretched into a very long box
  -- holding one short name (user-reported 2026-08-06). Past this the surplus
  -- stays as a gap between the count and the trim fader instead: the left group
  -- is still pinned left and the right group still pinned right, so nothing
  -- moves that the collapse order doesn't already move.
  -- 260 since 2026-08-07 (horizontal-layout brief: 360 still read as "stretching
  -- all the way", and the freed width is what seats the tech-facts text). A
  -- PROVISIONAL number — the brief's own decision is that the final cap gets
  -- picked by eye in REAPER with the user; this is the starting point.
  PICK_MAX_W    = 260,
  PICK_LIST_W   = 280, -- the list popup's width FLOOR (it widens to the slot's width)
  -- ...and its CEILING. The slot is the bar's flexible element, so a wide
  -- window grew it without limit and the list followed it into a very long,
  -- very empty box (user-reported 2026-08-06).
  PICK_LIST_MAX_W = 460,
  -- EVERY row is this tall (2026-08-06, second pass — user-reported). A labeled
  -- pin still gets two lines and an unlabeled one a single centred line, but
  -- they no longer have DIFFERENT heights: the old 40-vs-26 pair is where all
  -- the per-row centring arithmetic came from, and 26 was shorter than a
  -- control (27), so edit mode's buttons bulged past their own row. One height
  -- makes the list a multiplication instead of a running total.
  -- 40 until the 2026-08-07 density pass: two lines of 13 + 11 leave the same
  -- proportion of air at 34 that 15 + 13 had at 40, and it stays well clear of
  -- the control height (21) the rule below demands.
  PICK_ROW_H    = 34,
  PICK_LIST_ROWS = 8,  -- rows shown before the list starts scrolling
  PICK_TOOL_GAP  = 4,  -- between edit mode's two buttons
  PICK_TOOL_LEAD = 10, -- from the row's name to whatever ends the row
  -- Edit mode's buttons are NARROWER than a control. They carry no frame, so a
  -- full 27px square left the glyph floating well inside the row's right edge
  -- while the duration it replaces sat flush against it (user-reported
  -- 2026-08-06). Height stays a full control for the hit area.
  PICK_TOOL_W    = 18,
  -- Between the two step arrows. They were welded together (gap 0) so they'd
  -- read as ONE TARGET rather than two things to aim between; at zero they read
  -- as one BUTTON instead (user-reported 2026-08-06). A hairline of air tells
  -- them apart without breaking the pair.
  PICK_ARROW_GAP = 4,
  -- The count's own breathing room, EITHER SIDE — wider than ItemSpacing (8) on
  -- purpose. At 8 it read as squeezed between the arrows and the trim fader
  -- (user-reported 2026-08-06): a small dim number between two much heavier
  -- controls needs more air than two controls need from each other.
  PICK_COUNT_PAD = 12,
  -- The match window (the target button's popup, 2026-08-06 loudness tools).
  -- Fixed width: its rows are short ("−16.0 LUFS-M" + a trim), and a popup that
  -- resized with its content would shift on every preset edit. 320 originally;
  -- narrowed once the readout went two-columns-of-three (user's call — the
  -- three-wide grid was what forced the width, and the spare middle read as
  -- empty space on every preset row).
  MATCH_WIN_W    = 248,
  -- The custom row's unit dropdown and typed-number field. 90/70 originally;
  -- the dropdown clipped "LUFS-M" (user-reported 2026-08-06), so it took the
  -- width the number box didn't need — the total is unchanged.
  MATCH_UNIT_W   = 100,
  MATCH_VAL_W    = 50,
  -- (The preset list's size bound is core/match.lua's PRESET_MAX — a data
  -- policy, not a pixel.)
  -- The browser popup's compact audition strip (Phase 5.7 Stage 3). The
  -- DEFAULT height since 2026-08-06: the seam above the strip is a drag handle
  -- (ui/browser.lua), the chosen height is remembered in ExtState, and this is
  -- what unset/reset falls back to. Roughly doubled 2026-07-28 (was 48) — the
  -- user reported it too short to read comfortably. Left alone by the 2026-08-07
  -- density pass for the same reason RULER_H was: the shrink comes out of the
  -- controls, not the picture (and this one is the user's own dragged height
  -- most of the time anyway).
  BROWSER_WAVE_H = 96,
  -- The strip's resize floor: below ~half the default the bars are a sliver,
  -- not a picture, and the strip must stay a usable click-to-audition target.
  BROWSER_WAVE_MIN_H = 48,
  -- The resize ceiling is window-relative, not a number: however tall the
  -- strip is dragged, the sound table above keeps its header plus this many
  -- rows visible — the strip is for checking a sound, the list is the
  -- browser's actual job. A bigger window therefore allows a bigger strip.
  BROWSER_LIST_MIN_ROWS = 2,
  -- Breathing room between a channel lane's loudest possible bar and the lane edge,
  -- so stereo lanes don't touch across their hairline. A fixed inset, NOT a fraction
  -- of the lane (which was the original 0.85 factor): a proportional gap grew with
  -- the window and read as dead space in a tall panel (2026-07-30).
  WAVE_LANE_PAD = 2,
  -- Half-width of the start/end handles' grab zone (loudness tools,
  -- 2026-08-06): the mouse counts as "on a handle" within this many px of its
  -- line, resolved inside the waveform's one hit item — never a second widget
  -- fighting the seek click.
  SPAN_GRAB = 6,
  -- REF_W is retired (2026-07-30): the latch is a square like every other
  -- transport control now, faced "L", so it sizes from GetFrameHeight like the
  -- rest and needs no width of its own.
  -- Trim / master volume fader TOTAL width (track + gap + readout). 140 until
  -- the 2026-08-07 density pass, and the 8px it lost came entirely off the
  -- READOUT, not the track: the tapered trim fader's feel was measured on a
  -- 70px track the day before (0.69 dB/px on the boost), and a shorter track
  -- would silently coarsen every fader move. 132 = 70 track + 8 gap + 54 number.
  SLIDER_W  = 132,
  -- Fader anatomy (all inside SLIDER_W, so the row layout never changes):
  FADER_VAL_W   = 54, -- fixed readout zone right of the track ("+24.0 dB" at BASE_FS 13; was 62 at 15px)
  -- Gap between the end of the track and the first digit. Widened from 6 to 8
  -- (2026-08-01): the knob is a pill that overhangs the track's end, so a
  -- fader parked at its maximum left barely 4px of clear air before the number.
  FADER_VAL_GAP = 8,
  FADER_TRACK_H = 4,  -- track bar thickness (spacing scale)
  FADER_KNOB_W  = 4,  -- slim pill knob: width …
  FADER_KNOB_H  = 12, -- … and height (taller than the track so it reads at the ends)
  FADER_TICK_H  = 8,  -- 0 dB detent mark height (overhangs the track 2px each side)
  -- TRIM_MIN_TAIL retired 2026-08-06: the bar's collapse order is now a plain
  -- list of arrangements tried richest-first (ui/transport.lua), so "how much
  -- tail must be left over" has nothing to guard.
  FIELD_W   = 176, -- standard text-input width (popup name fields)
  SEARCH_W  = 176, -- the search box (fits "Search name of sounds" + the embedded magnifier at BASE_FS 13)
  SEARCH_ICON_PAD = 24, -- left FramePadding.x for the search field, clearing the drawn magnifier glyph
  POPUP_BTN_W = 72, -- popup action buttons (OK / Cancel / Delete / Close)
  -- The walkthrough card (2026-08-10, `.brief/_done/walkthrough/`): a titled
  -- card beside the ringed target. Width fixed — a card that resized to each
  -- stop's sentence would read as six different cards; height auto-sizes.
  -- 230 on the first live look ran the footer's three residents into each
  -- other ("1 of 6" under "Skip walkthrough"); 260 seats them with air.
  WALK_CARD_W   = 260,
  WALK_CARD_PAD = 12, -- its inner padding (spacing scale)
  WALK_RING_PAD = 4,  -- accent ring's inflation around the target (spacing scale)
  -- The footer's progress dots. A RADIUS, so it stays whole through set_scale's
  -- rounding — 3 draws the 6px disc that reads cleanly beside 13px text.
  WALK_DOT_R    = 3,
  WALK_DOT_GAP  = 4,  -- gap between two dots (spacing scale)
  -- The Settings modal (`.brief/settings-layout`, 2026-08-08, every answer the
  -- user's own): a FIXED window with a section list down the left, one section's
  -- rows in the pane beside it. Fixed, not auto-sizing, because the nav list
  -- would otherwise stretch and shrink on every section click; 620 is the width
  -- at which a real library path is still recognisable before it needs cutting.
  -- Draggable-and-remembered was offered and rejected — that would have cost
  -- Settings its modal behaviour.
  -- The What's New card (2026-08-08, `.brief/_done/changelog/`). Its own window,
  -- not the Settings one opening itself: a 620-wide panel landing on you at
  -- startup is heavier than a card, and this one is pure reading — no buttons,
  -- closed by its ✕ or Esc. Width is a READING measure, narrower than Settings:
  -- a changelog line is a sentence, and 620 would run it too wide to scan.
  -- Height is a CEILING, not a size — the window auto-sizes to a short release
  -- and scrolls inside this once a big one (or several missed ones) passes it.
  WN_WIN_W    = 440,
  WN_MAX_H    = 420,
  -- A remembered library that disappears opens a compact recovery surface.
  -- One reserved status line keeps the actions still when a message appears
  -- without leaving the old three-line blank block during the normal state.
  RECOVERY_WIN_W    = 420,
  RECOVERY_WIN_H    = 150,
  RECOVERY_STATUS_H = 24,
  RECOVERY_ACTION_W = 120,
  -- The bullet indent (2026-08-09 round 2, `.brief/_done/changelog-lines/` —
  -- REPLACES the area-word rail of the same day, which the user turned down:
  -- a rail can cut or bend a long area word). A bullet hangs alone in this
  -- gutter; the entry — and every wrapped line of it, and its detail line —
  -- sits on the column at its right edge. A COLUMN width, not a spacing
  -- token, which is why it may sit off the spacing scale.
  WN_IND      = 14,
  SET_WIN_W   = 620,
  -- 380 until 2026-08-08: that number was picked before there was any content to
  -- size it against, and left Library's rows ending ~200px short of the bottom
  -- ("lots of empty space"). 320 fits the richest section known — Help, with four
  -- add-on rows plus walkthrough and feedback — without a scrollbar. The height
  -- must fit the TALLEST section, not the one on screen: they share one window.
  SET_WIN_H   = 320,
  SET_NAV_W   = 140, -- the section list (narrower than SIDEBAR_W: five short words, no counts)
  -- A nav row's height. Deliberately taller than a control (21) and than the
  -- sidebar's text rows: these read as TABS, and they sit flush (no row gap, no
  -- padding above the first one) so the strip is continuous from the title bar
  -- down (2026-08-08, user's call on the first live look).
  -- 28 until 2026-08-10 (user: more air above/below the tab text — provisional,
  -- picked by eye against the running build).
  SET_NAV_ROW_H = 34,
  -- The lit tab's ACCENT edge (2026-08-10, `.brief/_done/settings-tabs/` — the
  -- user's pick, cost stated: accent's one "where you are" job, settings nav
  -- only; selection everywhere else stays fill-only).
  SET_TAB_STRIPE_W = 2,
  -- The tab NAME's inset from the strip's left edge. Its own number rather than
  -- `SB_PAD` (6): with the stripe in the edge, SB_PAD left the text 4px off the
  -- accent bar — "not much space... feels a little off" (user, 2026-08-10).
  -- Every tab indents the same, lit or not, so the text never shifts on click.
  SET_TAB_PAD = 12,
  -- (SET_LABEL_W, the setting-name column, retired 2026-08-10: a fixed 96px
  -- measured nothing and "Project References" overprinted its own path. A
  -- setting's name owns its own LINE now, value beneath — see the row grammar
  -- in settings.lua and `.brief/_done/settings-row-shape/`.)
  -- ONE width for every labelled action button in Settings (2026-08-08 — sized
  -- by its own text, no two matched: "…" 26px beside "Update now" 98px, and
  -- nothing could align). A button with a WORD on it is this wide, always; a
  -- bare "…" is a control-height square instead — the same two classes the
  -- browser toolbar already runs ("+ Add sounds" plus its square icon buttons).
  SET_ACTION_W = 96,
  -- (SET_INPUT_W, the fixed email-field width, retired 2026-08-10: it cut off
  -- its own hint text — the field is now sized to the hint it holds, measured
  -- in settings.lua's draw_help, so a token can't drift out of step with it.)
  -- Sound table's fixed columns (Name stretches to fill what's left).
  --
  -- Each is sized by its HEADER plus the sort arrow, never by the numbers under
  -- it (2026-08-11, user's ask to shorten Ch and Loudness): the values are short
  -- — one digit of channels, "-14.3" of loudness — but a clipped "LUFS-M" would
  -- name the wrong measurement, so the word is the floor. The arrow's width is
  -- reserved whether or not the column is the one sorting, so nothing shifts
  -- when the sort moves.
  COL_DUR_W  = 56, -- Dur column
  COL_CH_W   = 38, -- Ch column ("Ch" + arrow; the value is a single digit) — was 64
  COL_LOUD_W = 66, -- Loudness column ("LUFS-M", the widest header, + arrow) — was 84
  -- The sort arrow the sound table draws for ITSELF (2026-08-11). ImGui puts its
  -- own at the cell's right EDGE, which on a stretched Name column sat a long
  -- way from the word it belongs to ("far away from the text"); ours is painted
  -- immediately after the label. Height is 0.6 of the width — a wide shallow
  -- triangle reads as a direction rather than a spike.
  SORT_ARROW_W   = 7,
  SORT_ARROW_GAP = 5,
  -- The pin column: a pushpin glyph, header included. Widened from 24 on
  -- 2026-08-01, when the column became sortable — ImGui draws the sort arrow
  -- inside the header cell, and at 24 the arrow sat on top of the pushpin.
  PIN_COL_W  = 34,
  -- The slim scrollbar (brief `table-scrollbar`, 2026-08-09): the rail is the
  -- strip RESERVED beside a scrolling list — always, so the content never moves
  -- when scrolling starts — and the thumb is the pill drawn in it. The rail is
  -- deliberately wider than the thumb: the whole strip is the drag target.
  SCROLL_RAIL_W     = 12,
  SCROLL_THUMB_W    = 4,
  SCROLL_THUMB_MIN_H = 24, -- a huge list must still leave something to grab
  -- Group rows (browser categories, views) — the "this is a grouping, not a
  -- sound" treatment: small-caps name at a smaller size, coloured by meaning,
  -- vs sounds' mixed case (sidebar redesign, 2026-07-27 — swatches removed;
  -- colour lives in the name itself). Also the size for the browser's small
  -- text: sidebar counts, the info row's tech details, the PREVIEW fader label.
  -- 11 until 2026-08-08. THE TOOL HAS EXACTLY TWO TEXT SIZES — this and BASE_FS
  -- — and 11 had drawn the same complaint four times (sidebar category rows,
  -- Settings' explanation lines, Settings' facts line, then the Loudness panel's
  -- readout labels). The first three were each answered by moving that one
  -- element up to BASE_FS, which is how the smallest size ends up meaning
  -- "unreadable" rather than "subordinate". Raising the size itself fixes every
  -- remaining user of it at once, with no per-element exception.
  GROUP_FS  = 12,  -- small text size (caps rows keep reading smaller than the body)
  -- Floating-window floor: below this the layout is unusable, and a size saved
  -- while squashed used to come back just as squashed on every reopen. Docked
  -- windows are sized by their dock node, so this only governs floating.
  -- Must stay ABOVE the bar's full two-line width (~300 at scale 1.0): the
  -- user made that form the minimum (2026-08-08) — a floating window must
  -- never be able to clip it. Only a dock can go narrower, and there the bar
  -- clips rather than shedding controls.
  MIN_WIN_W = 340,
  MIN_WIN_H = 210,
  -- The Library popup's OWN width floor (2026-08-12). MIN_WIN_W above is sized
  -- for the WORKING VIEW's transport bar; the browser just reused it, which was
  -- already tight with two toggles on the info row and went stale the moment
  -- play/pause and stop landed beside them (four squares now — see the info
  -- row's own comment in ui/browser.lua). Applied at the browser's own
  -- SetNextWindowSizeConstraints call IN PLACE OF MIN_WIN_W (mirrors how
  -- MIN_WIN_H already gets RULER_H added for that same call — width needs a
  -- full replacement rather than an addition, since the row's shape has
  -- nothing in common with the working view's bar).
  --
  -- Derived from what the row needs, worst case for room: the sidebar dragged
  -- to ITS OWN floor (SIDEBAR_MIN_W, 120 — the pane-splitter can't go narrower
  -- than that regardless of the window, so it can't violate this number).
  -- Left to right: SIDEBAR_MIN_W (120) + the main pane's own WINDOW_PAD on
  -- both sides (16) + a readable slice of the tech line (80 — enough to read
  -- the sample rate and bit depth before the rest clips, not the whole line;
  -- the one judgement call here, tune by eye) + the row's own 8px text-to-
  -- controls gap (browser.lua) + four control-height squares with their
  -- trailing gaps — play/pause, stop, loop, auto-audition: 4×(BASE_FS +
  -- FRAME_PAD_Y×2) + 4×ITEM_SPACING_X = 108 + the "Preview" fader caption
  -- (~46 at GROUP_FS — CalcTextSize only knows the real width at runtime, so
  -- this is a hand measurement, the same way SEARCH_W's text allowance was)
  -- + its 6px gap to the track (transport.lua's own `spacing`) + the whole
  -- master fader (SLIDER_W, 132, already track + gap + FADER_VAL_W). Total:
  -- 120+16+80+8+108+46+6+132 = 516.
  BROWSER_MIN_W = 516,
  -- The update notice: an ACCENT dot drawn over the gear button's top-right
  -- corner while a newer version is published (DESIGN "Distribution, updates &
  -- versioning" — the gear is the notice's ONLY home; nothing moves or resizes).
  UPDATE_DOT_R = 3,
}

-- ---- UI scale ---------------------------------------------------------------
--
-- One number multiplies every size above. Today it is fixed at 1.0 and the base
-- values ARE the shipped sizes; it exists so the planned "UI size" setting is a
-- call to set_scale rather than a second re-tuning of forty hand-measured
-- numbers (2026-08-07).
--
-- `theme.metrics` is filled IN PLACE and never replaced — every UI module holds
-- `local M = theme.metrics` from require time, so a new table would leave them
-- all pointing at the old sizes.

-- Counts, not pixels: scaling these would show fewer rows on a bigger UI, which
-- is the opposite of what a size setting means.
local UNSCALED = {
  PICK_LIST_ROWS = true,
  BROWSER_LIST_MIN_ROWS = true,
}

theme.metrics = {}
theme.scale = 1.0

function theme.set_scale(s)
  if not (s and s > 0) then s = 1.0 end
  theme.scale = s
  for k, v in pairs(BASE) do
    if UNSCALED[k] then
      theme.metrics[k] = v
    else
      local scaled = math.floor(v * s + 0.5)
      theme.metrics[k] = scaled < 1 and 1 or scaled
    end
  end
  -- The ImGui style vars are built from these same numbers, so they have to be
  -- rebuilt too (see `resolve` below). Harmless before the first frame.
  theme.invalidate_style()
end

-- The control bar's own widths are NOT metrics: every square is one frame
-- height, and the picker's name slot takes whatever is left over, so they all
-- derive from the live frame height (see ui/transport.lua's `geometry`).

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

-- ImGui style var -> value(s). The padding and spacing values come from the
-- scaled metrics, so a change of UI size moves them with everything else; the
-- corner radii and border widths are deliberately fixed (a 1px border scaled to
-- 0.8 renders as a smudge, and 4px corners look right at any control height).
local function build_vars()
  local M = theme.metrics
  return {
    { "WindowRounding",   { 8 } },
    { "WindowBorderSize", { 1 } },
    { "WindowPadding",    { M.WINDOW_PAD, M.WINDOW_PAD } },
    { "ChildRounding",    { 4 } },
    { "FrameRounding",    { 4 } },
    { "FrameBorderSize",  { 1 } },
    { "PopupRounding",    { 8 } },
    { "ItemSpacing",      { M.ITEM_SPACING_X, M.ITEM_SPACING_Y } },
    -- Sets every framed control (buttons, inputs, sliders) to the same height:
    -- BASE_FS + 2×FRAME_PAD_Y = 21px. Left unset, ImGui's own default would
    -- decide it, and the whole control bar's collapse order is measured from it.
    { "FramePadding",     { M.FRAME_PAD_X, M.FRAME_PAD_Y } },
    { "GrabRounding",     { 4 } }, -- slider grabs share the control radius (tokens.md)
  }
end

-- The slot lookups above resolved ONCE, on the first frame. The slot functions
-- return constants, so re-deriving each name string and doing the table lookup
-- every frame was ~32 throwaway strings a frame — small, but repeated frame-loop
-- allocations are exactly what the frame rules forbid. A slot an older ReaImGui
-- doesn't define is skipped here, so the push and pop counts still match.
local resolved_colors, resolved_vars

-- Drop the cached style vars so the next frame rebuilds them from the current
-- metrics. Called by set_scale; a no-op before the first frame has resolved.
function theme.invalidate_style()
  resolved_vars = nil
end

local function resolve()
  resolved_colors = {}
  for _, c in ipairs(COLORS) do
    local fn = reaper["ImGui_Col_" .. c[1]]
    if fn then resolved_colors[#resolved_colors + 1] = { fn(), T[c[2]] } end
  end
  resolved_vars = {}
  for _, v in ipairs(build_vars()) do
    local fn = reaper["ImGui_StyleVar_" .. v[1]]
    if fn then resolved_vars[#resolved_vars + 1] = { fn(), v[2] } end
  end
end

-- Whether this ReaImGui supports PushFont(ctx, nil, size) — the resize form that
-- carries the app-wide BASE_FS. Probed ONCE with a pcall on the first frame (the
-- same idiom browser.lua used for its old per-window push); on an older build the
-- whole app simply stays at the built-in 13px, consistently.
local base_font_ok

-- The BOLD cut of the UI font, handed over once by app.create_context. May stay
-- nil (older ReaImGui, or no bold cut available) — push_heading_font falls back
-- to the regular small font then.
--
-- There is no regular-weight counterpart on purpose: ReaImGui's context already
-- defaults to the system sans-serif face, so every push below passes nil, which
-- PushFont reads as "keep the current font, only change the size". See
-- app.create_context.
local ui_font_bold
function theme.set_heading_font(bold)
  ui_font_bold = bold
end

-- Small-text push (GROUP_FS): caps rows, sidebar counts, the info row's tech
-- details, the PREVIEW fader label. One probed implementation shared by every
-- caller (browser, transport) so the fallback behaviour can't diverge. Returns
-- whether a font was pushed — the caller pops only if it was.
--
-- Passes nil deliberately: the base font is already current, so this only needs
-- to change the size, and asking for the same font again would be a second way
-- to say the same thing.
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

-- A SECTION HEADING: the bold cut at GROUP_FS (decided 2026-08-09,
-- `.brief/font-and-hierarchy`). Weight is what makes a heading lead, so a
-- heading needs no size step and no colour step — it stays TEXT_PRIMARY, the
-- same white as the values it heads, and still reads as the loudest thing on
-- its line. Callers pair it with ALL CAPS (see the Headings rule in the UI
-- skill).
--
-- Falls back to the small REGULAR font when no bold cut exists, so the heading
-- is merely un-emphasised rather than missing.
local heading_font_ok
function theme.push_heading_font(ctx)
  if not ui_font_bold then return theme.push_small_font(ctx) end
  if heading_font_ok == nil then
    heading_font_ok = pcall(reaper.ImGui_PushFont, ctx, ui_font_bold, theme.metrics.GROUP_FS)
    if heading_font_ok then return true end
    return theme.push_small_font(ctx)
  end
  if heading_font_ok then
    reaper.ImGui_PushFont(ctx, ui_font_bold, theme.metrics.GROUP_FS)
    return true
  end
  return theme.push_small_font(ctx)
end

-- BOLD at the BODY size — the heading font's weight without its smallness.
-- Today: the What's New card's version numbers (2026-08-09, user's ask). Same
-- probe-and-fallback shape as push_heading_font; when no bold cut exists the
-- text simply stays regular, which is un-emphasised rather than wrong.
local bold_font_ok
function theme.push_bold_font(ctx)
  if not ui_font_bold then return false end
  if bold_font_ok == nil then
    bold_font_ok = pcall(reaper.ImGui_PushFont, ctx, ui_font_bold, theme.metrics.BASE_FS)
    return bold_font_ok
  end
  if bold_font_ok then
    reaper.ImGui_PushFont(ctx, ui_font_bold, theme.metrics.BASE_FS)
    return true
  end
  return false
end

-- Push the whole theme. Returns how many colours, vars and fonts were pushed so
-- the caller pops exactly that many (mismatched counts make ImGui raise).
function theme.apply(ctx)
  if not (resolved_colors and resolved_vars) then resolve() end
  for _, c in ipairs(resolved_colors) do
    reaper.ImGui_PushStyleColor(ctx, c[1], c[2])
  end
  for _, v in ipairs(resolved_vars) do
    reaper.ImGui_PushStyleVar(ctx, v[1], table.unpack(v[2]))
  end
  -- nil = "keep the current font, only change the size". The current font is
  -- ReaImGui's own default, which is already the system sans-serif face — so
  -- this sets the app-wide SIZE and nothing else.
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

------------------------------------------------------- the title bar's ✕
--
-- Drawn BY HAND for every floating window (2026-08-08). ImGui's own close
-- button gives almost nothing to style: a 12-sided disc barely wider than the
-- glyph, filled with whatever Col_ButtonHovered holds, and the cross itself
-- locked to Col_Text — the slot the window TITLE also reads, so the cross can
-- never be coloured apart from the title. Full-strength red in the only
-- reachable slot was what made the hovered button loud and the cross unreadable
-- (user-reported 2026-08-08). Painting the button ourselves costs about as many
-- lines as the old two pushes and answers all three complaints at once: a chip
-- the height of the title bar instead of a blob, a softened red, and a cross
-- that stays legible on it.
--
-- Two behaviours are deliberately carried over from the widened close zone this
-- replaces (which used to live in ui/app.lua, for the working view only — every
-- window gets it now):
--   * the HIT AREA is the whole title-bar-height square at the window's right
--     end, not the glyph alone (the glyph is a small target, 2026-07-30);
--   * a press there that drags the window away before the release does NOT
--     close it.
-- While DOCKED nothing is drawn or hit-tested: a docked window has no title bar
-- and REAPER's docker tab carries the close box. That path runs through ImGui's
-- own `p_open`, so `p_open` is handed to Begin for docked windows and only then.
local HAS_DOCKED     = reaper.ImGui_IsWindowDocked ~= nil
local HAS_CLIP       = reaper.ImGui_DrawList_PushClipRect ~= nil
local HAS_HOVER_HELD = reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem ~= nil

-- Which window's ✕ took the press. One name rather than a table: there is only
-- one mouse button, so only one ✕ can be part-way through a click.
local close_armed = nil
-- Was each window docked at its last draw? Read one frame later, when deciding
-- whether Begin gets a p_open (see above) — the dock state can only be asked
-- for INSIDE the window, which is after that decision has to be made.
local docked_last = {}

-- Draws the ✕ for the window that has just begun, and reports a completed click.
local function close_button(ctx, name)
  local docked = HAS_DOCKED and reaper.ImGui_IsWindowDocked(ctx) or false
  docked_last[name] = docked
  if docked then return false end

  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww     = reaper.ImGui_GetWindowWidth(ctx)
  -- A title bar is exactly GetFrameHeight tall (both are font size + 2×
  -- FramePadding.y) — the same fact the title-bar right-click menu hit-tests on.
  local tbh    = reaper.ImGui_GetFrameHeight(ctx)
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  -- AllowWhenBlockedByActiveItem: pressing a title bar makes ImGui start moving
  -- the window, which counts as an active item — without the flag the button
  -- would go dark the instant it was pressed.
  local over = mx >= wx + ww - tbh and mx < wx + ww and my >= wy and my < wy + tbh
    and reaper.ImGui_IsWindowHovered(ctx,
      HAS_HOVER_HELD and reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem() or 0)

  -- Press then release, both on this window's ✕. The arming is cleared by ANY
  -- release, wherever it landed, so a press here followed by a release outside
  -- can neither close this window now nor leave a stale arm to close it later.
  local closed = false
  if over and reaper.ImGui_IsMouseClicked(ctx, 0) then close_armed = name end
  local held = close_armed == name
  if held and reaper.ImGui_IsMouseReleased(ctx, 0) then
    close_armed = nil
    closed = over
  end

  -- The chip is the hit square itself, inset 2px on every side: centred on what
  -- it closes, and far enough in that the window's 8px rounded top-right corner
  -- never cuts it. 17px at scale 1, against a 21px title bar. Snapped to whole
  -- pixels — a fill on a half pixel renders with a soft edge.
  local right = math.floor(wx + ww)
  local side  = math.floor(tbh) - 4
  local x2, y1 = right - 2, math.floor(wy) + 2
  local x1, y2 = x2 - side, y1 + side

  -- The title bar sits OUTSIDE the clip rect ImGui pushes for a window's
  -- contents, so these calls would be thrown away unclipped. Widening the clip
  -- to the chip keeps the drawing in this window's own layer, where another
  -- window overlapping it covers it properly; the foreground list (the fallback
  -- for an older ReaImGui without the clip calls) would paint over that window.
  local dl
  if HAS_CLIP then
    dl = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_PushClipRect(dl, x1, y1, x2, y2, false)
  else
    dl = reaper.ImGui_GetForegroundDrawList(ctx)
  end
  if over then
    reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2,
      held and T.CLOSE_HELD or T.CLOSE_HOVER, 4)
  end
  -- The cross sits QUIET until the cursor is on it (user's call, 2026-08-08 —
  -- the first cut was too big and too bright to be chrome): a small, thin,
  -- TEXT_TERTIARY mark that brightens to TEXT_PRIMARY on the chip. Its size
  -- never changes — only its colour, like every other glyph in the tool.
  local cx, cy = (x1 + x2) * 0.5, (y1 + y2) * 0.5
  local arm = side * 0.21 -- ~7px across, well inside the 17px chip
  local col = over and T.TEXT_PRIMARY or T.TEXT_TERTIARY
  reaper.ImGui_DrawList_AddLine(dl, cx - arm, cy - arm, cx + arm, cy + arm, col, 1.2)
  reaper.ImGui_DrawList_AddLine(dl, cx - arm, cy + arm, cx + arm, cy - arm, col, 1.2)
  if HAS_CLIP then reaper.ImGui_DrawList_PopClipRect(dl) end

  return closed
end

-- Centre a title on the FULL width of its bar, for the length of one Begin.
-- Shared because the delete-confirm modal begins itself (BeginPopupModal) and
-- would otherwise be the one panel wearing its name on the left. Returns
-- whether it pushed, which is what has to be handed back to pop_title_center.
--
-- WHY THE ✕ IS NOT IN THE SUM: ImGui only makes room in the title bar for a
-- close button it drew ITSELF, which happens when `p_open` is passed to Begin.
-- Floating windows here are given no `p_open` — the ✕ is ours, drawn after the
-- fact by close_button — so ImGui pads both ends of the bar equally and the
-- title lands on the bar's true middle, exactly as the user asked (2026-08-08).
-- **Never "tidy" this by handing Begin a p_open while floating**: that would
-- both double the ✕ and shove the title left off centre.
function theme.push_title_center(ctx)
  if reaper.ImGui_StyleVar_WindowTitleAlign == nil then return false end
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowTitleAlign(), 0.5, 0.5)
  return true
end

function theme.pop_title_center(ctx, pushed)
  if pushed then reaper.ImGui_PopStyleVar(ctx, 1) end
end

-- Begin a window wearing that ✕. `open` says the window HAS a close button (all
-- of ours do); the returned `still_open` is false on the frame it is clicked.
--
-- `center_title` centres the title text for the length of the same call.
function theme.begin_window(ctx, name, open, flags, center_title)
  -- Docked only: REAPER's docker tab carries the close box, so ImGui's own
  -- p_open path is used there and no ✕ of ours is drawn. A docked window has no
  -- title bar at all, so this can never affect the centring above.
  local p_open = docked_last[name] and open or nil
  local centred = center_title and theme.push_title_center(ctx)
  local visible, still_open = reaper.ImGui_Begin(ctx, name, p_open, flags)
  theme.pop_title_center(ctx, centred)
  -- Floating: ImGui was given no p_open to report on, so the answer is ours.
  if p_open == nil then still_open = open end
  -- Only while the window actually drew — the ✕ is drawn into it, and asking a
  -- skipped window for its geometry is asking about a window that isn't there.
  if visible and open and close_button(ctx, name) then still_open = false end
  return visible, still_open
end

function theme.unapply(ctx, nc, nv, nf)
  -- "Any release disarms the ✕" must survive the armed window NOT drawing this
  -- frame (closed by an action or Esc while the button was held) — close_button
  -- can only clear the arm while its window draws, so a release that lands in
  -- that gap used to leave a stale arm, and the next release over the ✕ zone
  -- would close a window nobody pressed (2026-08-09 Fable review). End of frame
  -- on purpose: every window that DID draw has already consumed this release
  -- as a legitimate click by now.
  if close_armed and reaper.ImGui_IsMouseReleased(ctx, 0) then close_armed = nil end
  if nf and nf > 0 then reaper.ImGui_PopFont(ctx) end
  if nv and nv > 0 then reaper.ImGui_PopStyleVar(ctx, nv) end
  if nc and nc > 0 then reaper.ImGui_PopStyleColor(ctx, nc) end
end

-- Fill theme.metrics before anything requires this module. The settings-driven
-- size option will call set_scale again with the user's own number.
theme.set_scale(1.0)

return theme
