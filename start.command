#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-}" in
  --help|-h)
    echo "Usage: ./start.command [--build]"
    echo "Build if missing, then open CodexIsland. --build rebuilds first."
    exit 0 ;;
  ""|--build) ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "This build requires an Apple Silicon Mac running macOS 13 or later." >&2
  exit 1
fi
if [[ "${1:-}" == --build || ! -x build/CodexIsland.app/Contents/MacOS/CodexIsland ]]; then
  xcrun --find swiftc >/dev/null
  ./build.sh
fi
open "$PWD/build/CodexIsland.app"
echo "Opened CodexIsland. Look for the island near the notch; there is no Dock icon."
