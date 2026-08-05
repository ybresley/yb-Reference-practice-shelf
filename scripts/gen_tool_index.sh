#!/bin/sh
# gen_tool_index.sh <commit-hash> <out-file> <version...> — build a catalog
# serving the REAL yb_Reference from this harness shelf, listing the given
# versions (oldest first). The package installs as yb_Reference_TEST.lua
# (2026-08-05): the plain name was indistinguishable from the dev copies in
# REAPER's action list, and a shelf-side rename is the ONLY safe way to change
# it — ReaPack owns installed files by path. The real release shelf will use
# the clean name. The prototype dummy was dropped the same day (U0–U9 long
# done); with it out of the index, an uninstalled dummy can never auto-return.
#
# Source URLs are pinned to the commit that holds the tool/ trees — run this
# AFTER committing those, from the repo root:
#   scripts/gen_tool_index.sh <hash> staging/index-tool-0.2.2.xml 0.2.0 0.2.1 0.2.2
#
# File lists are read from the trees themselves (find), so the catalog can never
# drift from what is actually shipped. Multi-file packages install relative to
# the package's category folder — file="lib/…" lands beside the entry script,
# exactly like the tool's own @provides describes.

set -e
HASH="$1"; OUT="$2"
[ -n "$HASH" ] && [ -n "$OUT" ] && [ -n "$3" ] || {
  echo "usage: scripts/gen_tool_index.sh <commit-hash> <out-file> <version...>"; exit 1; }
shift 2
BASE="https://raw.githubusercontent.com/ybresley/yb-reapack-test/$HASH"

emit_version() { # $1 = version, $2 = hour for the time attr
  echo "      <version name=\"$1\" author=\"ybresley\" time=\"2026-08-05T$2:00:00Z\">"
  echo "        <changelog><![CDATA[v$1 - update-feature checklist stage]]></changelog>"
  echo "        <source main=\"main\">$BASE/tool/$1/yb_Reference.lua</source>"
  echo "        <source main=\"main\" file=\"yb_Reference_TEST_ToggleReferenceMode.lua\">$BASE/tool/$1/yb_Reference_ToggleReferenceMode.lua</source>"
  (cd "tool/$1" && find lib assets -type f | sort) | while read -r f; do
    echo "        <source file=\"$f\">$BASE/tool/$1/$f</source>"
  done
  echo "      </version>"
}

{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<index version="1" name="yb_update_test">'
  echo '  <category name="Tools">'
  echo '    <reapack name="yb_Reference_TEST.lua" type="script" desc="yb_Reference TEST">'
  hour=10
  for v in "$@"; do
    emit_version "$v" "$hour"
    hour=$((hour + 1))
  done
  echo '    </reapack>'
  echo '  </category>'
  echo '</index>'
} > "$OUT"
echo "wrote $OUT ($* @ $HASH)"
