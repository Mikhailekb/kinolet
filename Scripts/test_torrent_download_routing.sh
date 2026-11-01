#!/bin/bash
# Execute the controller's real save-routing methods against owned chooser,
# panel and security-scope boundaries. No player, worker or networking is used.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-download-routing.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import hashlib, json, os, sys
root, scratch = map(Path, sys.argv[1:])
source = (root/'Apps/Mac/UI/PlayerViewController.swift').read_text()
playlist = (root/'Apps/Mac/UI/Playlist.swift').read_text()
(scratch/'playlist-models.swift').write_text(playlist[:playlist.index('private final class SPPlaylistCancellation:')])
def member(signature):
    assert source.count(signature) == 1, signature
    begin = source.index(signature)
    brace = source.index('{', begin)
    depth, end = 1, brace + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[begin:end]
signatures = [
    '    @objc func saveTorrentFileAction(_ sender: Any?)',
    '    private func saveTorrentPlaylistEntry(_ identity: URL)',
    '    private func presentTorrentFileSave(_ file: SPTorrentFile, descriptor: SPTorrentDescriptor)',
    '    private func presentBuiltInTorrentFileSave(_ file: SPTorrentFile, descriptor: SPTorrentDescriptor)',
]
original = '\n\n'.join(member(signature) for signature in signatures)
substitutions = {
    '    private func ': '    func ',
    'let panel = NSSavePanel()': 'let panel = RoutingSavePanel()',
    'destination.startAccessingSecurityScopedResource()': 'RoutingGrants.start(destination)',
    'destination.stopAccessingSecurityScopedResource()': 'RoutingGrants.stop(destination)',
}
projected = original
for before, after in substitutions.items():
    assert before in projected, before
    projected = projected.replace(before, after)
restored = projected
for before, after in reversed(list(substitutions.items())):
    restored = restored.replace(after, before)
assert restored == original, 'Only declared UI/access boundaries may change'
# Optional adversarial copies prove that runtime checks reject wrong-file
# routing or removal of the controller callback's stale-state guard.
mutation = os.environ.get('TORRENT_DOWNLOAD_ROUTING_MUTATION')
if mutation == 'playlist-current-file':
    before = 'presentTorrentFileSave(file, descriptor: context.descriptor)'
    assert projected.count(before) == 1
    projected = projected.replace(before, '_ = file\n        presentTorrentFileSave(context.file, descriptor: context.descriptor)')
elif mutation == 'unguarded-built-in':
    before = 'builtIn: { [weak self] in\n                guard isCurrent() else { return }'
    assert projected.count(before) == 1
    projected = projected.replace(before, 'builtIn: { [weak self] in')
elif mutation:
    raise AssertionError('Unknown routing mutation: ' + mutation)
fixture = (root/'Scripts/tests/torrent_download_routing.swift').read_text()
marker = '    // INSERT_PRODUCTION_ROUTING_METHODS'
assert fixture.count(marker) == 1
(scratch/'checks.swift').write_text(fixture.replace(marker, projected))
(scratch/'source-evidence.json').write_text(json.dumps({
    'controllerSHA256': hashlib.sha256(source.encode()).hexdigest(),
    'extractedOriginalSHA256': hashlib.sha256(original.encode()).hexdigest(),
    'fixtureSHA256': hashlib.sha256(fixture.encode()).hexdigest(),
    'signatures': signatures,
    'boundarySubstitutions': substitutions,
    'roundTripExact': restored == original,
    'mutation': mutation,
}, indent=2) + '\n')
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Apps/Mac/UI/Localization.swift" \
  "$CHECK_DIR/playlist-models.swift" \
  "$ROOT/Apps/Mac/UI/TorrentModels.swift" \
  "$ROOT/Apps/Mac/UI/TorrentPlayback.swift" \
  "$ROOT/Apps/Mac/UI/TorrentPreferences.swift" \
  "$ROOT/Apps/Mac/UI/TorrentServer.swift" \
  "$ROOT/Apps/Mac/UI/TorrentFileSaves.swift" \
  "$CHECK_DIR/checks.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks" "$CHECK_DIR" "${1:-}"
if [[ -n "${1:-}" ]]; then
  mkdir -p "$1"
  cp "$CHECK_DIR/source-evidence.json" "$1/source-evidence.json"
fi
