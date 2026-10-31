#!/usr/bin/env bash
set -euo pipefail

seek_version=1.24.0
seek_hash=dbfd9d7216f077c84c171b688c4173c37c23ca76bf7fd185d1a9ae8a53dab59f
seek_cache="${XDG_CACHE_HOME:-$HOME/.cache}/seekapi-downloads/xtool-$seek_version"
seek_install="${XDG_DATA_HOME:-$HOME/.local/share}/seekapi-tools/xtool-$seek_version"
mkdir -p "$seek_cache" "$HOME/.local/bin"
if [[ ! -f "$seek_cache/xtool.AppImage" ]]; then
  curl --fail --location --retry 3 \
    "https://github.com/xtool-org/xtool/releases/download/$seek_version/xtool-x86_64.AppImage" \
    --output "$seek_cache/xtool.AppImage.download"
  mv "$seek_cache/xtool.AppImage.download" "$seek_cache/xtool.AppImage"
fi
printf '%s  %s\n' "$seek_hash" "$seek_cache/xtool.AppImage" | sha256sum --check
if [[ ! -x "$seek_install/squashfs-root/AppRun" ]]; then
  mkdir -p "$seek_install"
  chmod +x "$seek_cache/xtool.AppImage"
  (cd "$seek_install"; "$seek_cache/xtool.AppImage" --appimage-extract > "$seek_cache/extraction.log")
fi
if [[ -e "$HOME/.local/bin/xtool" && ! -L "$HOME/.local/bin/xtool" ]]; then
  echo "An existing non-symlink xtool is present; leaving it unchanged." >&2
  exit 1
fi
ln -sfn "$seek_install/squashfs-root/AppRun" "$HOME/.local/bin/xtool"
"$HOME/.local/bin/xtool" --version
