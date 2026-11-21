#!/usr/bin/env bash
# Install a local LiveKit server binary without Docker.
# Downloads an official Go toolchain (darwin-arm64) into .tools/go and builds
# livekit-server from the pinned release tag into .tools/bin/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
GO_DIR="$TOOLS/go"
BIN_DIR="$TOOLS/bin"
LIVEKIT_VERSION="${LIVEKIT_VERSION:-v1.13.11}"
GO_VERSION="${GO_VERSION:-}"

mkdir -p "$TOOLS" "$BIN_DIR"

if [[ -x "$BIN_DIR/livekit-server" ]]; then
  echo "livekit-server already installed at $BIN_DIR/livekit-server"
  exit 0
fi

# Pick a Go version: env override, else the latest stable from go.dev
if [[ -z "$GO_VERSION" ]]; then
  GO_VERSION="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=stable' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["version"])')"
fi
echo "Using Go toolchain $GO_VERSION"

if [[ ! -x "$GO_DIR/bin/go" ]]; then
  TMP_TGZ="$TOOLS/go.tgz"
  echo "Downloading https://go.dev/dl/${GO_VERSION}.darwin-arm64.tar.gz"
  curl -fSL -o "$TMP_TGZ" "https://go.dev/dl/${GO_VERSION}.darwin-arm64.tar.gz"
  rm -rf "$GO_DIR"
  tar -C "$TOOLS" -xzf "$TMP_TGZ"
  rm "$TMP_TGZ"
fi

export GOROOT="$GO_DIR"
export GOPATH="$TOOLS/gopath"
export GOCACHE="$TOOLS/gocache"
export PATH="$GO_DIR/bin:$PATH"

echo "Building livekit-server $LIVEKIT_VERSION"
SRC_DIR="$TOOLS/livekit-src"
rm -rf "$SRC_DIR"
git clone --depth 1 --branch "$LIVEKIT_VERSION" \
  https://github.com/livekit/livekit-server.git "$SRC_DIR"
# The newest CLT SDKs (MacOSX27+) ship .tbd files with arch entries the
# toolchain's tapi can't parse ("arm64e.x1"), breaking cgo linking. Pick the
# newest SDK that parses cleanly.
SDK=""
for cand in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
  if ! grep -q "arm64e\.x1" "$cand/usr/lib/libSystem.tbd" 2>/dev/null; then
    SDK="$cand"
  fi
done
if [[ -n "$SDK" ]]; then
  export SDKROOT="$SDK"
  export CGO_CFLAGS="-isysroot $SDK"
  export CGO_LDFLAGS="-isysroot $SDK"
  echo "Using SDK: $SDK"
fi

(cd "$SRC_DIR" && go build -o "$BIN_DIR/livekit-server" ./cmd/server)

"$BIN_DIR/livekit-server" --version
echo "Installed: $BIN_DIR/livekit-server"
