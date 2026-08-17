# Changelog

<!--
The single source of truth for release notes. Everything else is generated
from this file — the script header's @changelog block, the GitHub release
notes — and the tool reads it straight to draw the What's New card and the
Settings > Updates history. Never write release notes anywhere else.

THIS FILE STARTS EMPTY, ON PURPOSE (decided 2026-08-09). The beta ships with
no history: 0.1.0 and 0.2.0 were never published to anyone, so notes for them
would describe versions no tester ever had. The first entry below is written
for the first UPDATE after the beta opens, not for the beta itself.

While there are no releases here the tool simply shows nothing — no What's New
card, and no Release notes row in Settings > Updates. `scripts/gen_header.lua`
likewise leaves the script header with no @changelog tag, and adds one with the
first release.

The grammar is fixed, because lib/core/changelog.lua parses it:

  ## <version> — <YYYY-MM-DD>     one release
  ### New | Improved | Fixed      a group; those three names, in that order
  - **Area** — What changed.      one entry, area word from the fixed list
    An extra fact worth knowing.  optional dim second line, indented

The full house style and the fixed list of area words live in the
`changelog-release` skill. Curated highlights only: if a user would not
notice it, it does not belong here.
-->
