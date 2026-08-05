-- yb_Reference — Toggle reference mode (companion action)
--
-- Bind this to a hotkey to turn reference mode on and off from anywhere in REAPER,
-- without clicking into the tool's window. It does one thing: leave a momentary note
-- that the open yb_Reference window picks up on its next frame and acts on.
--
-- Why a note instead of doing the work here: the latch mutes your project and writes
-- a crash-recovery file, and exactly one running script must own that. This action
-- stays a one-liner so there is no second place that can silence your project.
--
-- The note is deliberately NOT persisted — it's a momentary request, not saved state.
-- If the yb_Reference window isn't open, pressing this does nothing: the main script
-- clears any leftover note when it next starts, so a press made while the window was
-- closed can never silently mute your project later.
--
-- The section/key below are the contract with lib/reference.lua — change both together.

reaper.SetExtState("yb_Reference", "ref_toggle_request", "1", false)
