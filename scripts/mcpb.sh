#!/usr/bin/env bash
# Packs ramback-mcp.mcpb for a GitHub release and points manifest.json and server.json at it.
#
#   scripts/mcpb.sh <version> [binary]
#
# binary defaults to the CLI inside Ramback.app, which is universal, signed and notarized; a plain
# `swift build` binary isn't, and Gatekeeper blocks it once it's downloaded. Needs npx (Node).
set -euo pipefail
cd "$(dirname "$0")/.."
version="$1"
bin="${2:-/Applications/Ramback.app/Contents/Helpers/ramback}"
mkdir -p mcpb/server
cp "$bin" mcpb/server/ramback
sed -i '' -E "s/\"version\": \"[^\"]*\"/\"version\": \"$version\"/" mcpb/manifest.json server.json
sed -i '' -E "s|/download/v[^/]*/|/download/v$version/|" server.json
npx -y @anthropic-ai/mcpb pack mcpb ramback-mcp.mcpb
sha=$(shasum -a 256 ramback-mcp.mcpb | cut -d' ' -f1)
sed -i '' -E "s/\"fileSha256\": \"[^\"]*\"/\"fileSha256\": \"$sha\"/" server.json
echo "ramback-mcp.mcpb $sha"
