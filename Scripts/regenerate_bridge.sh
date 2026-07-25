#!/bin/bash
#
# Regenerates the ScriptingBridge interface to Music.app.
#
# `Music.h` is produced from Apple's own scripting definition, so it is
# generated locally rather than committed. Re-run this if Music.app's
# dictionary changes in a future macOS release — `Scripts/build_app.sh` also
# calls it automatically whenever the header is missing.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Sources/MusicBridge/include"
MUSIC="/System/Applications/Music.app"

if [ ! -d "$MUSIC" ]; then
    echo "error: $MUSIC not found" >&2
    exit 1
fi

mkdir -p "$OUT"
sdef "$MUSIC" | sdp -fh --basename Music -o "$OUT"
echo "wrote $OUT/Music.h"
