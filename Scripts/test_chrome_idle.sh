#!/bin/bash
# Exercise actual chrome routing and controller idle timers in an owned window.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-chrome-idle.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
import os
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
controller = Path(os.environ.get('CHROME_IDLE_CONTROLLER_SOURCE', str(root / 'Apps/Mac/UI/PlayerViewController.swift'))).read_text()
chrome = (root / 'Apps/Mac/UI/SPChrome.swift').read_text()
def function(source, signature):
    assert source.count(signature) == 1, signature
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[start:end]
methods = '\n'.join(function(controller, signature) for signature in [
    '    private func showControlsTemporarily()',
    '    private func armHideTimer(after t: TimeInterval)',
    '    private func hideControls()',
    '    override func mouseMoved(with event: NSEvent)'])
start, end = '    func videoGestureExclusionRect(in targetView: NSView)', '    func layoutChrome(in parentBounds: NSRect)'
assert chrome.count(start) == 1 and chrome.count(end) == 1
chrome_methods = start + chrome.split(start, 1)[1].split(end, 1)[0]
fixture = (root / 'Scripts/tests/chrome_idle.swift').read_text()
assert fixture.count('    // INSERT_CONTROLLER_METHODS') == 1
assert fixture.count('    // INSERT_CHROME_METHODS') == 1
(scratch / 'checks.swift').write_text(fixture.replace('    // INSERT_CONTROLLER_METHODS', methods)
    .replace('    // INSERT_CHROME_METHODS', chrome_methods))
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$CHECK_DIR/checks.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"
