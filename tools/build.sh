#!/bin/sh
# Builds the Swift tools into build/tools.
. "$(dirname "$0")/lib.sh"
for t in wins sfcmd; do tool "$t" >/dev/null && echo "built: build/tools/$t"; done
