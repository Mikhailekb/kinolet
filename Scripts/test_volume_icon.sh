#!/bin/bash
# Draw only owned native image/button fixtures; no live player or screen access.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-volume-icon.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Apps/Mac/UI/Localization.swift" "$ROOT/Apps/Mac/UI/VolumeIcon.swift" \
  "$ROOT/Apps/Mac/UI/VolumeFeedbackView.swift" "$ROOT/Apps/Mac/UI/FloatingVideoController.swift" \
  "$ROOT/Scripts/tests/volume_icon.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks" "$@"
