#!/bin/bash
# One-command install of the prebuilt lookin-swift binary from GitHub Releases.
# No Xcode / Swift toolchain needed.
#
#   curl -fsSL https://raw.githubusercontent.com/J-Jsen/Looin-swift-mcp/main/install-release.sh | bash
#
set -euo pipefail

REPO="J-Jsen/Looin-swift-mcp"
DEST="$HOME/.lookin-swift"
BIN="$DEST/lookin-swift"
URL="https://github.com/$REPO/releases/latest/download/lookin-swift"

mkdir -p "$DEST"
echo "Downloading lookin-swift (latest release)..."
curl -fsSL "$URL" -o "$BIN"
chmod +x "$BIN"
# Remove the Gatekeeper quarantine flag put on downloaded, unsigned binaries.
xattr -dr com.apple.quarantine "$BIN" 2>/dev/null || true

if "$BIN" --selftest >/dev/null 2>&1; then
  echo "Installed and self-test OK: $BIN"
else
  echo "Installed: $BIN (self-test did not pass; run '$BIN --selftest' to see why)"
fi

cat <<EOF

Add it to your MCP client with this command path:
  $BIN

Claude Code:
  claude mcp add --scope user lookin-swift "$BIN"

Then make sure your iOS app integrates the official LookinServer
(pod 'LookinServer', :configurations => ['Debug']) and is in the foreground.
EOF
