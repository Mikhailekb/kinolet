#!/bin/bash
# Inspect/render only the actual detached AppKit control; never touch a live player.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-motion-button.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Apps/Mac/UI/Localization.swift" "$ROOT/Apps/Mac/UI/PlayerUIModel.swift" \
  "$ROOT/Apps/Mac/UI/MotionButton.swift" "$ROOT/Scripts/tests/motion_button.swift" \
  -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks" "$@"
