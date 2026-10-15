#!/bin/sh
# Installs the pinned external CLIs the maqs pipeline uses, on macOS (Homebrew) and
# Ubuntu 24.04 (release binaries or source builds). `--check` only verifies versions.
# Pins here must match maqs/tools.py PINS; `maqs check-tools` is the authority.
set -eu

VERSATILES_VERSION="5.0.0"
PMTILES_VERSION="1.31.2"
OSMIUM_VERSION="1.19.1"
LIBOSMIUM_VERSION="2.23.1"
TIPPECANOE_VERSION="2.79.0"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

os="$(uname -s)"
arch="$(uname -m)"

have() { command -v "$1" >/dev/null 2>&1; }

version_of() {
  case "$1" in
    versatiles) versatiles --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 ;;
    pmtiles)    pmtiles version 2>/dev/null | head -1 | sed -E 's/^pmtiles ([^,]+),.*/\1/' ;;
    osmium)     osmium --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 ;;
    tippecanoe) tippecanoe --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 ;;
  esac
}

report() {
  status=0
  for tool in versatiles pmtiles osmium tippecanoe; do
    if have "$tool"; then
      printf '%-11s %s\n' "$tool" "$(version_of "$tool")"
    else
      printf '%-11s missing\n' "$tool"; status=1
    fi
  done
  return $status
}

if [ "$CHECK_ONLY" = 1 ]; then report; exit $?; fi

install_macos() {
  have brew || { echo "Homebrew is required on macOS" >&2; exit 1; }
  brew tap versatiles-org/versatiles >/dev/null
  brew install versatiles pmtiles osmium-tool tippecanoe
}

install_ubuntu() {
  sudo apt-get update -q
  sudo apt-get install -y -q curl ca-certificates build-essential cmake git \
    libboost-program-options-dev libbz2-dev zlib1g-dev libexpat1-dev liblz4-dev \
    nlohmann-json3-dev libprotozero-dev libsqlite3-dev

  case "$arch" in
    x86_64) vt_arch="x86_64"; pm_arch="x86_64" ;;
    aarch64|arm64) vt_arch="aarch64"; pm_arch="arm64" ;;
    *) echo "unsupported arch $arch" >&2; exit 1 ;;
  esac

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  if [ "$(version_of versatiles)" != "$VERSATILES_VERSION" ]; then
    curl -fsSL -o "$tmp/versatiles.deb" \
      "https://github.com/versatiles-org/versatiles-rs/releases/download/v${VERSATILES_VERSION}/versatiles-linux-gnu-${vt_arch}.deb"
    sudo dpkg -i "$tmp/versatiles.deb"
  fi
  # The deb installs to /usr/bin; CI caches and looks in /usr/local/bin. Put a real copy
  # there, not a link: the cache restores a link as a link, and its target is not cached.
  # Replace a link, a missing or stale binary; keep a regular one at the pinned version.
  if [ -x /usr/bin/versatiles ]; then
    local_vt=/usr/local/bin/versatiles
    if [ -L "$local_vt" ] || [ ! -x "$local_vt" ] \
      || [ "$("$local_vt" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" != "$VERSATILES_VERSION" ]; then
      sudo install -m 0755 /usr/bin/versatiles "$local_vt"
    fi
  fi
  if [ "$(version_of pmtiles)" != "$PMTILES_VERSION" ]; then
    curl -fsSL -o "$tmp/pmtiles.tgz" \
      "https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/go-pmtiles_${PMTILES_VERSION}_Linux_${pm_arch}.tar.gz"
    tar -xzf "$tmp/pmtiles.tgz" -C "$tmp" pmtiles
    sudo install -m 0755 "$tmp/pmtiles" /usr/local/bin/pmtiles
  fi
  if [ "$(version_of osmium)" != "$OSMIUM_VERSION" ]; then
    git clone -q --depth 1 -b "v${LIBOSMIUM_VERSION}" https://github.com/osmcode/libosmium "$tmp/libosmium"
    git clone -q --depth 1 -b "v${OSMIUM_VERSION}" https://github.com/osmcode/osmium-tool "$tmp/osmium-tool"
    cmake -S "$tmp/osmium-tool" -B "$tmp/osmium-build" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
      -DOSMIUM_INCLUDE_DIR="$tmp/libosmium/include" >/dev/null
    cmake --build "$tmp/osmium-build" -j "$(nproc)" >/dev/null
    sudo install -m 0755 "$tmp/osmium-build/src/osmium" /usr/local/bin/osmium
  fi
  if [ "$(version_of tippecanoe)" != "$TIPPECANOE_VERSION" ]; then
    git clone -q --depth 1 -b "${TIPPECANOE_VERSION}" https://github.com/felt/tippecanoe "$tmp/tippecanoe"
    make -C "$tmp/tippecanoe" -j "$(nproc)" >/dev/null
    sudo make -C "$tmp/tippecanoe" install >/dev/null
  fi
}

case "$os" in
  Darwin) install_macos ;;
  Linux)  install_ubuntu ;;
  *) echo "unsupported OS $os" >&2; exit 1 ;;
esac

report
