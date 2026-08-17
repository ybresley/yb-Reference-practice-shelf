-- whatsnew: the card that shows what changed, once per version the user hasn't
-- read yet. Decided 2026-08-08 (`.brief/_done/changelog/`, 15 pages, every
-- answer the user's own).
--
-- Its own window rather than Settings opening itself, and PURE READING — no
-- buttons at all, closed by its title-bar ✕ or Esc, because a window that
-- already has a ✕ needs no second way out (the rule that removed the Settings
-- footer). Every missed version is stacked newest first; the window auto-sizes
-- to a short release and scrolls inside `WN_MAX_H` once the list outgrows it.
--
-- It fires after the RESTART, never before: an update swaps the files on disk
-- while REAPER carries on running the old script, so notes shown at install time
-- describe a version the user does not yet have. The tool restarts itself only
-- after ReaPack's report closes, and this card is the first thing the new code
-- draws. See the updater heartbeat in yb-Reference.lua.
--
-- The reading layout is shared with the Settings > Updates history
-- (`whatsnew.draw_release`), so the two surfaces cannot drift.
--
-- A ui/ module: reaper.ImGui_* only. The seen-version mark is written by the
-- entry script when the card is SHOWN, not on dismissal (audit fix, 2026-08-09):
-- dismissal-dependent marking relied on gestures the user could never perform —
-- Esc stays with REAPER until the card is clicked, and closing the whole tool
-- with the card open skipped the write, re-showing the same notes every launch.
-- Closing here is pure view cleanup, reported as an action out of habit only.

local theme = require("ui.theme")
local focus = require("ui.focus")
local T = theme.tokens
local M = theme.metrics

local whatsnew = {}

local HAS_WRAP_POS   = reaper.ImGui_PushTextWrapPos ~= nil and reaper.ImGui_PopTextWrapPos ~= nil
local HAS_ESCAPE     = reaper.ImGui_IsKeyPressed ~= nil and reaper.ImGui_Key_Escape ~= nil
local HAS_VIEWPORT   = reaper.ImGui_GetMainViewport ~= nil and reaper.ImGui_Viewport_GetCenter ~= nil
local HAS_CONSTRAIN  = reaper.ImGui_SetNextWindowSizeConstraints ~= nil

-- View state only. The post-update card is DRIVEN BY `state.whatsnew` — the
-- entry script decides there is something unread and puts { list, version } on
-- the state; `shown_for` remembers the version it already opened for, so a
-- dismissal isn't undone on the next frame.
--
-- `history` is the SAME window doing its second job (2026-08-09,
-- `.brief/changelog-reading/`): Settings' View button opens it over the WHOLE
-- parsed changelog — every release, one scroll, newest first — instead of the
-- missed slice. One window, one rendering, so the two can never drift; and the
-- post-update card became judgeable on demand, which the in-pane reading box
-- (retired the same day as "super cramped") never allowed.
local ui = { open = false, shown_for = nil, history = false }

function whatsnew.is_open() return ui.open end

-- Settings' View button. Reading the history never touches the seen-mark —
-- that belongs to the post-update flow alone.
function whatsnew.open_history()
  ui.open, ui.history = true, true
end

-- "2026-08-08" -> "8 Aug 2026". A changelog date is read, not sorted, and the
-- ISO form is for the file. Anything that isn't an ISO date comes back unchanged
-- rather than being guessed at.
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
function whatsnew.human_date(iso)
  local y, m, d = tostring(iso or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then return iso end
  local name = MONTHS[tonumber(m)]
  if not name then return iso end
  return string.format("%d %s %s", tonumber(d), name, y)
end

-- WRAP AT 0, NOT AT A WIDTH. PushTextWrapPos takes a POSITION in window-local
-- space, and 0 means "the end of this window or column" — which is the answer
-- here. Handing it a measured width instead (as this did first) wraps early by
-- however far the content region is inset, a bug that only shows on lines long
-- enough to wrap at all.
local WRAP_TO_EDGE = 0

-- One entry: a bullet hanging alone in the `WN_IND` gutter, the whole entry —
-- "Area — Sentence", every wrapped line of it, and the dim detail — on the
-- column at the gutter's edge (2026-08-09 round 2, `.brief/_done/
-- changelog-lines/`, the user's pick over flat lines; it REPLACES the same
-- day's area-word rail, turned down because a rail can cut a long area word).
--
-- THE SPLIT, and why it exists: the entry's first line is two colours (bright
-- area word, normal sentence), so it must be two text items — and ImGui
-- continues a wrapped item's later lines at the ITEM's own start x, which for
-- the sentence item is "after the area word": a different x on every entry,
-- the exact raggedness the user reported of the first build. So the first
-- line is measured ONCE per entry — the words of the sentence that fit beside
-- the area word — and the remainder is drawn as its own item at the column,
-- where ImGui's native wrapping continues it in exactly the right place.
--
-- The split is CACHED per entry (weak keys, so a swapped-out list is free to
-- be collected) and recut only when the text width changes (the scrollbar
-- appearing is the one real cause) — measuring word-by-word every frame would
-- be the repeated frame-loop work this project forbids.
local DASH = ": "
local split_cache = setmetatable({}, { __mode = "k" })

local function split_entry(ctx, e, text_w)
  local c = split_cache[e]
  if c and c.w == text_w then return c end
  local room = text_w - select(1, reaper.ImGui_CalcTextSize(ctx, e.area .. DASH))
  local head, rest_from = "", 1
  local words = {}
  for word in e.text:gmatch("%S+") do words[#words + 1] = word end
  for i = 1, #words do
    local try = i == 1 and words[1] or (head .. " " .. words[i])
    if select(1, reaper.ImGui_CalcTextSize(ctx, try)) > room and i > 1 then break end
    head, rest_from = try, i + 1
  end
  c = { w = text_w, head = DASH .. head, rest = table.concat(words, " ", rest_from) }
  split_cache[e] = c
  return c
end

local function entry_line(ctx, e, x0, text_w)
  local col = x0 + M.WN_IND
  reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "\u{2022}")
  reaper.ImGui_SameLine(ctx, col)

  if e.area then
    local s = split_entry(ctx, e, text_w)
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, e.area)
    reaper.ImGui_SameLine(ctx, 0, 0)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, s.head)
    if s.rest ~= "" then
      -- Spacing y pushed to 0 so the remainder sits at the natural line
      -- advance — with the theme's 6px it would read as a gap mid-paragraph.
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), M.ITEM_SPACING_X, 0)
      reaper.ImGui_SetCursorPosX(ctx, col)
      if HAS_WRAP_POS then reaper.ImGui_PushTextWrapPos(ctx, WRAP_TO_EDGE) end
      reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, s.rest)
      if HAS_WRAP_POS then reaper.ImGui_PopTextWrapPos(ctx) end
      reaper.ImGui_PopStyleVar(ctx)
    end
  else
    -- No area word (parser-legal, style-illegal): one colour means one item,
    -- so no split is needed — native wrapping at the column is already right.
    if HAS_WRAP_POS then reaper.ImGui_PushTextWrapPos(ctx, WRAP_TO_EDGE) end
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, e.text)
    if HAS_WRAP_POS then reaper.ImGui_PopTextWrapPos(ctx) end
  end

  -- The detail line: AT THE BODY SIZE, dim — not smaller (11px for a sentence
  -- somebody has to read has drawn the user's complaint three times now), on
  -- the same column, with NO bullet of its own — the bullet marks where an
  -- entry begins, and a detail is not a new entry. Dim-where-earned is the
  -- brief's own pick (page 6); the indent is what makes the dimness read as
  -- "belongs to the line above" instead of a second voice interrupting.
  if e.detail then
    reaper.ImGui_SetCursorPosX(ctx, col)
    if HAS_WRAP_POS then reaper.ImGui_PushTextWrapPos(ctx, WRAP_TO_EDGE) end
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, e.detail)
    if HAS_WRAP_POS then reaper.ImGui_PopTextWrapPos(ctx) end
  end
end

-- One release, headed by its version and date. Shared with Settings' history
-- pane so the two readings of the same file cannot look like different things.
-- `opts.head` draws the version line (the card wants it, a pane that already
-- names the version in its picker does not).
function whatsnew.draw_release(ctx, release, opts)
  opts = opts or {}
  -- The column's anchor and the sentence width, captured once so every entry
  -- agrees — and so the split cache is keyed on one number per frame.
  local x0 = reaper.ImGui_GetCursorPosX(ctx)
  local text_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx)) - M.WN_IND

  if opts.head ~= false then
    -- The version wears the app ACCENT (2026-08-09, user's ask — "the colour of
    -- the pin icons", which IS the accent) and the BOLD cut at the body size
    -- (same day): the one landmark you scan a long history by, in the colour
    -- the tool already uses for marks worth finding.
    local bold = theme.push_bold_font(ctx)
    reaper.ImGui_TextColored(ctx, T.ACCENT, "v" .. (release.version or "?"))
    if bold then reaper.ImGui_PopFont(ctx) end
    if release.date then
      reaper.ImGui_SameLine(ctx)
      local small = theme.push_small_font(ctx)
      reaper.ImGui_TextColored(ctx, T.TEXT_QUATERNARY, whatsnew.human_date(release.date))
      if small then reaper.ImGui_PopFont(ctx) end
    end
  end

  for gi, g in ipairs(release.groups or {}) do
    -- A group heading is a LABEL, not a sentence — BOLD small caps, the exact
    -- grammar the Loudness panel's section headings use. Weight is what makes it
    -- lead, so it stays TEXT_PRIMARY like the lines under it rather than
    -- reaching for a size or colour step.
    if gi > 1 or opts.head ~= false then reaper.ImGui_Dummy(ctx, 0, 2) end
    local small = theme.push_heading_font(ctx)
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, tostring(g.name):upper())
    if small then reaper.ImGui_PopFont(ctx) end
    for _, e in ipairs(g.entries or {}) do
      entry_line(ctx, e, x0, text_w)
    end
  end
end

function whatsnew.draw(ctx, state)
  local pending = state.whatsnew
  -- Open once per unread version. Keyed on the version rather than a plain flag
  -- so dismissing it doesn't reopen on the very next frame, and so a second
  -- update in one session (which cannot happen today — an update restarts the
  -- tool — but might once that changes) would still get its own card.
  if pending and ui.shown_for ~= pending.version then
    ui.open, ui.shown_for = true, pending.version
  end

  -- History mode wins while both apply — the full file is a superset of the
  -- missed slice, so nothing the card had to say is lost by the takeover.
  local list, title
  if ui.history then
    list = state.changelog
    title = "RELEASE NOTES###yb_whatsnew"
  elseif pending then
    list = pending.list
    -- Titled by the version the user has ARRIVED at, so the window says what
    -- happened rather than naming a feature.
    title = "UPDATED TO V" .. (pending.version or "?") .. "###yb_whatsnew"
  end
  if not ui.open or not list or #list == 0 then return nil end
  local action

  -- Auto-sizing UP TO a ceiling: a one-line patch release gets a small card, a
  -- big one (or several missed versions) stops at WN_MAX_H and scrolls inside.
  -- The width is fixed at both ends of the constraint so it never varies with
  -- content — the one thing that would make the same notes look different on
  -- two machines.
  if HAS_CONSTRAIN then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, M.WN_WIN_W, 0, M.WN_WIN_W, M.WN_MAX_H)
  else
    reaper.ImGui_SetNextWindowSize(ctx, M.WN_WIN_W, M.WN_MAX_H, reaper.ImGui_Cond_Appearing())
  end
  if HAS_VIEWPORT then
    local cx, cy = reaper.ImGui_Viewport_GetCenter(reaper.ImGui_GetMainViewport(ctx))
    reaper.ImGui_SetNextWindowPos(ctx, cx, cy, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  end

  local flags = reaper.ImGui_WindowFlags_NoCollapse()
    | reaper.ImGui_WindowFlags_NoSavedSettings()
  if HAS_CONSTRAIN then flags = flags | reaper.ImGui_WindowFlags_AlwaysAutoResize() end
  if reaper.ImGui_WindowFlags_NoDocking then
    flags = flags | reaper.ImGui_WindowFlags_NoDocking()
  end

  local visible, still_open = theme.begin_window(ctx, title, true, flags, true)
  if not still_open then
    ui.open, ui.history = false, false
    focus.request()
    action = { type = "whatsnew_closed" }
  end
  -- No End on this path — ReaImGui's Begin already ended a not-visible window
  -- itself (see the matchwin note, verified 2026-08-09); End belongs to the
  -- visible path only.
  if not visible then
    return action
  end

  for i, r in ipairs(list) do
    -- A rule BETWEEN releases only — never above the first or under the last,
    -- the settings rows' own separator rule.
    if i > 1 then
      reaper.ImGui_Dummy(ctx, 0, 4)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), T.STROKE_SECONDARY)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_PopStyleColor(ctx)
      reaper.ImGui_Dummy(ctx, 0, 4)
    end
    whatsnew.draw_release(ctx, r)
  end

  if HAS_ESCAPE and reaper.ImGui_IsWindowFocused(ctx)
    and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    ui.open, ui.history = false, false
    focus.request()
    action = action or { type = "whatsnew_closed" }
  end

  reaper.ImGui_End(ctx)
  return action
end

return whatsnew
