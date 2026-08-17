-- Walkthrough: the first-open guided tour's state machine. Six fixed stops
-- (data below) plus a welcome card, walked forward one action at a time.
-- Replayable from Settings, which is why the browser-open exception exists:
-- a replay can start with the Library already sitting open.
--
-- Pure Lua. The UI reads STOPS for titles/bodies and calls current()/is_frozen()
-- every frame; it never owns the position itself, so the tour can't drift out
-- of sync with what's actually on screen.

local walkthrough = {}

-- The six stops, in order. Fixed data, exported so the UI reads titles/bodies
-- from here rather than duplicating copy.
--
-- context: a second region the overlay keeps bright WITHOUT ringing it (the
-- sidebar stop keeps the sound list visible so clicking a category visibly
-- filters it).
-- demo: the FINALE only. Its panel is six numbers, and six dashes explain
-- nothing, so on a tour with an empty library core/demo.lua lends it a set
-- (never armed, never playable — see that file). The waveform deliberately gets
-- no stand-in: it is the one part of the tool you can click, seek and drag out
-- of, and a fake one would invite gestures that silently do nothing (user's
-- call, 2026-08-11, after seeing it live).
-- The entry script auto-closes the Library the moment the tour reaches a
-- main-window stop. The pin stop used to be exempt (its lesson was dragging out
-- of the Library's own list), but the user asked on 2026-08-10 for the Library
-- to close as soon as the categories stop is done — so the exception, and the
-- `keep_browser` flag that carried it, are gone. The pin stop's copy no longer
-- names the list as the drag's source.
-- button/act: EVERY stop carries a button (decided 2026-08-10,
-- `.brief/walkthrough-footer/`), and on a stop that waits for a real click it
-- PERFORMS that click's deed instead of skipping past it — so the button is
-- named after the deed ("Open") rather than "Next". Nobody can be stuck on a
-- stop, and pressing the button still shows what the stop teaches. The act is
-- carried out by the UI/entry script; the tour then advances on the resulting
-- real event, exactly as if the control were clicked.
walkthrough.STOPS = {
  { id = "library", window = "main",    button = "Open", act = "open_browser",
    title = "YOUR LIBRARY",
    body  = "All your sounds are stored in the Library. Click it to open." },
  { id = "drop",    window = "browser", button = "Next",
    title = "ADD SOUNDS",
    -- No mention of + Add sounds: the card can be standing over it (user, live,
    -- 2026-08-10), and a card pointing at something you can't see reads as broken.
    -- The library-is-global half of the tour's one abstract idea lands HERE, the
    -- first stop where the library is actually on screen (user's call); the
    -- per-project half rides the pin stop below.
    body  = "Drop audio files here to add them to your Library. Preview and inspect a sound here, then pin it to the project.",
    note  = "Your Library is saved to your computer and persists across all of your projects." },
  { id = "sidebar", window = "browser", button = "Next", context = "list",
    title = "CATEGORIES",
    -- Says what categories are FOR, not just that they exist (user, live
    -- 2026-08-10). The one-place rule is the fact people get wrong: there are
    -- no tags, so a sound is filed, not labelled.
    body  = "Organise your sounds with categories. Each sound lives in exactly one category." },
  { id = "pin",     window = "main",    button = "Next",
    title = "PIN A REFERENCE",
    -- The body carries the per-project half of the library/project split. It
    -- names no drag SOURCE any more: the Library is shut by the time this stop
    -- is reached, so a sound can come from the Library once reopened, from
    -- REAPER, or from a folder on the PC.
    body  = "Drag a sound from the Library or elsewhere onto this window to pin it to the project. Pinned references are saved with this project.",
    note  = "Anyone with this tool can open the project and will see the same references." },
  { id = "latch",   window = "main",    button = "Next",
    title = "REFERENCE MODE",
    -- "L" alone read as a KEYBOARD key (user, live 2026-08-10) — it is the
    -- ringed BUTTON, so both mentions name it as one.
    body  = "The Latch button turns on Reference mode and mutes your project, then pressing play in REAPER triggers your selected reference instead. Click the Latch button again to get your project back.",
    note  = "Reference mode is optional. You can also play a reference directly in yb-Reference." },
  -- The FINALE, and one stop where there were two (2026-08-10,
  -- `.brief/walkthrough-footer/`): a stop to open the panel plus a stop to
  -- describe it both ringed the ◎, so the second one stood beside a button the
  -- user had already pressed.
  --
  -- `auto` opens the panel the moment the stop is reached (user's ask, same
  -- day) and `panel` marks its window as a second highlighted region, so the
  -- card can talk about the panel with the panel actually on screen beside the
  -- ◎ that opens it. Nothing here waits on a click, so the button is a plain
  -- Done — and the panel opening can no longer be an advance event, or the tour
  -- would end the instant it arrived.
  { id = "match_open", window = "main", button = "Done",
    auto = "open_match", panel = "match", demo = true,
    -- The card's title is the panel's own (2026-08-11: "MATCH LOUDNESS" until
    -- the user renamed the panel to LOUDNESS). The stop's id and `auto`/`panel`
    -- keys stay `match*` — they name wiring, not anything on screen.
    title = "LOUDNESS",
    body  = "See the selected reference's loudness details here. Set a precise loudness target or choose a saved preset.",
    note  = "Replay the walkthrough anytime from the Settings \u{2192} Help." },
}
walkthrough.WELCOME = { title = "WELCOME",
  body = "Take a one-minute tour of the tool." }
-- The frozen card (a browser stop with the Library shut) borrows the same
-- shape: its button is the one that gets the tour moving again.
walkthrough.FROZEN_BODY = "Reopen the Library to continue."
walkthrough.FROZEN_BUTTON = "Open"
walkthrough.FROZEN_ACT = "open_browser"

-- A project that hasn't started (or has finished) the tour.
function walkthrough.new()
  return { active = false, pos = nil, browser_open = false }
end

-- The stop begin_welcome()/next()-from-welcome would land on, given whether
-- the browser is already open. Stop 1 teaches "click Library to open it" —
-- nonsense on a replay that starts with the Library already open.
local function first_stop(s)
  return s.browser_open and 2 or 1
end

function walkthrough.begin_welcome(s)
  s.active = true
  s.pos = 0
end

function walkthrough.begin_stops(s)
  s.active = true
  s.pos = first_stop(s)
end

-- Ends the tour. Used by the welcome card's "Not now" and every stop's "Skip"
-- — both are the same action, just reached differently.
function walkthrough.skip(s)
  s.active = false
  s.pos = nil
end

-- Advance one step. No-op when inactive, so a stray event after the user
-- skipped can't silently restart it.
function walkthrough.next(s)
  if not s.active then return end
  if s.pos == 0 then
    s.pos = first_stop(s)
  elseif s.pos >= #walkthrough.STOPS then
    walkthrough.skip(s)
  else
    s.pos = s.pos + 1
  end
end

-- Which event advances which stop, keyed by stop id rather than position —
-- reads cleaner than an if-chain and stays correct if stops are reordered.
local ADVANCE_EVENTS = {
  browser_opened = "library",
  files_added    = "drop",
  sound_pinned   = "pin",
}

-- The entry script fires these unconditionally as the app runs, so
-- browser_open must stay true even while inactive or on the welcome card —
-- a later replay needs the CURRENT truth, not a stale guess.
function walkthrough.event(s, name)
  if name == "browser_opened" then
    s.browser_open = true
  elseif name == "browser_closed" then
    s.browser_open = false
  end

  if not s.active or s.pos == 0 or s.pos == nil then return end

  local stop = walkthrough.STOPS[s.pos]
  if stop and ADVANCE_EVENTS[name] == stop.id then
    walkthrough.next(s)
  end
end

-- nil when inactive, "welcome" on the welcome card, else the stop table.
function walkthrough.current(s)
  if not s.active then return nil end
  if s.pos == 0 then return "welcome" end
  return walkthrough.STOPS[s.pos]
end

-- True only on a browser stop while the browser is shut — the UI then parks
-- the card on the main window with FROZEN_BODY instead of pointing at a
-- window that isn't there.
function walkthrough.is_frozen(s)
  if not s.active or not s.pos or s.pos < 1 then return false end
  local stop = walkthrough.STOPS[s.pos]
  return stop.window == "browser" and not s.browser_open
end

return walkthrough
