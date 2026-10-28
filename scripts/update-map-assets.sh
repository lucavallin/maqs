#!/usr/bin/env bash
# Regenerates Sources/MaqsUI/MapAssets (glyphs, sprite and the two default styles) from pinned
# VersaTiles releases. Downloads into a temporary directory, verifies each archive's SHA-256, only
# extracts (nothing from an archive is ever executed) and copies the files the package bundles.
# LICENSES.md in the output folder is written by hand and is kept. Run from anywhere.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
assets="$root/Sources/MaqsUI/MapAssets"

fonts_release="https://github.com/versatiles-org/versatiles-fonts/releases/download/v3.0.0"
style_release="https://github.com/versatiles-org/versatiles-style/releases/download/v7.0.1"

stacks=(noto_sans_regular noto_sans_bold)
ranges=(0-255 256-511 512-767 768-1023 8192-8447)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch() { # name url sha256
  curl -fsSL --retry 3 -o "$work/$1" "$2"
  echo "$3  $work/$1" | shasum -a 256 -c -
  mkdir "$work/${1%.tar.gz}"
  tar -xzf "$work/$1" -C "$work/${1%.tar.gz}"
}

fetch noto_sans.tar.gz "$fonts_release/noto_sans.tar.gz" \
  f58be6be2eb3d127b6ff1c90d828b69ff4807d1d88cd13a43930943fda0e334e
fetch styles.tar.gz "$style_release/styles.tar.gz" \
  088bbfb96b0807c1d90e2e1a464f680c458e9ba23341547d37ad6e12c14d6e41
fetch sprites.tar.gz "$style_release/sprites.tar.gz" \
  3dfed482a0c48caa2762ae08badcd1c4b5d4a3901c1508ecc30b73a992f10b65

# Old output goes first so a removed file cannot linger; the licence file is source, not output.
rm -rf "$assets/glyphs" "$assets/sprite" "$assets/styles"
mkdir -p "$assets/sprite"

for stack in "${stacks[@]}"; do
  mkdir -p "$assets/glyphs/$stack"
  for range in "${ranges[@]}"; do
    cp "$work/noto_sans/$stack/$range.pbf" "$assets/glyphs/$stack/$range.pbf"
  done
done

for file in base.json base.png base@2x.json base@2x.png; do
  cp "$work/sprites/$file" "$assets/sprite/$file"
done

(
  cd "$root/pipeline"
  uv run python -m maqs.map_style "$work/styles" "$assets/styles"
)

echo "MapAssets: $(find "$assets" -type f -exec stat -f %z {} + | awk '{s += $1} END {print s}') bytes"
