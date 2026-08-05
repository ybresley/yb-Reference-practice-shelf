#!/bin/sh
# gen_tool_index.sh <commit-hash> <out-file> <version...> — build a catalog
# serving the REAL yb_Reference from this harness shelf, listing the given
# versions (oldest first). The dummy's category is carried over verbatim from
# the live index.xml so the installed dummy never turns "obsolete" mid-run.
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

# The dummy's <category> block, verbatim.
DUMMY=$(sed -n '/<category name="Test">/,/<\/category>/p' index.xml)

emit_version() { # $1 = version, $2 = hour for the time attr
  echo "      <version name=\"$1\" author=\"ybresley\" time=\"2026-08-05T$2:00:00Z\">"
  echo "        <changelog><![CDATA[v$1 - update-feature checklist stage]]></changelog>"
  echo "        <source main=\"main\">$BASE/tool/$1/yb_Reference.lua</source>"
  echo "        <source main=\"main\" file=\"yb_Reference_ToggleReferenceMode.lua\">$BASE/tool/$1/yb_Reference_ToggleReferenceMode.lua</source>"
  (cd "tool/$1" && find lib assets -type f | sort) | while read -r f; do
    echo "        <source file=\"$f\">$BASE/tool/$1/$f</source>"
  done
  echo "      </version>"
}

{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<index version="1" name="yb_update_test">'
  echo "$DUMMY"
  echo '  <category name="Tools">'
  echo '    <reapack name="yb_Reference.lua" type="script" desc="yb_Reference">'
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
