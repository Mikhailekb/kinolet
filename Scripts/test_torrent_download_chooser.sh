#!/bin/bash
# Actual native menu/actions and owned metadata; no external app launch or HID.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-download-chooser.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete \
  -warnings-as-errors -parse-as-library "$ROOT/Apps/Mac/UI/TorrentModels.swift" \
  "$ROOT/Apps/Mac/UI/TorrentDownloadChooser.swift" \
  "$ROOT/Scripts/tests/torrent_download_chooser.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks" "$@"
