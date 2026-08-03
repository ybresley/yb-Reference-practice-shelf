#!/bin/sh
# gen_tool_index.sh <commit-hash> — build the two staged catalogs that serve the
# REAL yb_Reference from this harness shelf (the U12–U17 checklist needs a
# ReaPack-installed copy; dev copies keep the update feature dormant by design).
#
#   staging/index-tool-0.2.0.xml  ->  dummy v1.0–1.2  +  yb_Reference 0.2.0
#   staging/index-tool-0.2.1.xml  ->  same            +  0.2.1 on top (the update)
#
# The dummy's category is carried over verbatim from the live index.xml so the
# installed dummy never turns "obsolete" mid-run. Source URLs are pinned to the
# commit that holds the tool/ trees — run this AFTER committing those, from the
# repo root: scripts/gen_tool_index.sh <hash>
#
# File lists are read from the trees themselves (find), so the catalog can never
# drift from what is actually shipped. Multi-file packages install relative to
# the package's category folder — file="lib/…" lands beside the entry script,
# exactly like the tool's own @provides describes.

set -e
HASH="$1"
[ -n "$HASH" ] || { echo "usage: scripts/gen_tool_index.sh <commit-hash>"; exit 1; }
BASE="https://raw.githubusercontent.com/ybresley/yb-reapack-test/$HASH"

# The dummy's <category> block, verbatim (lines between <index…> and </index>).
DUMMY=$(sed -n '/<category name="Test">/,/<\/category>/p' index.xml)

emit_version() { # $1 = version, $2 = time attr
  echo "      <version name=\"$1\" author=\"ybresley\" time=\"$2\">"
  echo "        <changelog><![CDATA[v$1 - update-feature checklist stage]]></changelog>"
  echo "        <source main=\"main\">$BASE/tool/$1/yb_Reference.lua</source>"
  echo "        <source main=\"main\" file=\"yb_Reference_ToggleReferenceMode.lua\">$BASE/tool/$1/yb_Reference_ToggleReferenceMode.lua</source>"
  (cd "tool/$1" && find lib assets -type f | sort) | while read -r f; do
    echo "        <source file=\"$f\">$BASE/tool/$1/$f</source>"
  done
  echo "      </version>"
}

emit_index() { # $@ = versions to list (oldest first)
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<index version="1" name="yb_update_test">'
  echo "$DUMMY"
  echo '  <category name="Tools">'
  echo '    <reapack name="yb_Reference.lua" type="script" desc="yb_Reference">'
  emit_version "0.2.0" "2026-08-03T10:00:00Z"
  [ "$1" = "with-0.2.1" ] && emit_version "0.2.1" "2026-08-03T11:00:00Z"
  echo '    </reapack>'
  echo '  </category>'
  echo '</index>'
}

emit_index only-0.2.0  > staging/index-tool-0.2.0.xml
emit_index with-0.2.1  > staging/index-tool-0.2.1.xml
echo "wrote staging/index-tool-0.2.0.xml + staging/index-tool-0.2.1.xml (pinned to $HASH)"
