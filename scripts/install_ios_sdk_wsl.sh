#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 || ! -f "$1" ]]; then
  echo "Usage: bash scripts/install_ios_sdk_wsl.sh /mnt/d/path/to/Xcode.xip" >&2
  exit 1
fi
if [[ -f "$HOME/.local/share/swiftly/env.sh" ]]; then
  . "$HOME/.local/share/swiftly/env.sh"
fi
export PATH="$HOME/.local/bin:$PATH"
seek_source="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
seek_downloads="$seek_source/artifacts/toolchain-downloads"
if [[ -f "$seek_downloads/OpenAppleMacrosServer-x86_64-1.4.1.tar.gz" && -f "$seek_downloads/toolset-x86_64-1.1.0.tar.gz" ]]; then
  seek_cache="${XDG_CACHE_HOME:-$HOME/.cache}/seekapi-downloads/sdk-xtool-1.24.0"
  mkdir -p "$seek_cache"
  cp "$seek_downloads/OpenAppleMacrosServer-x86_64-1.4.1.tar.gz" "$seek_downloads/toolset-x86_64-1.1.0.tar.gz" "$seek_cache/"
  export XTL_OAM_TARBALL="$seek_cache/OpenAppleMacrosServer-x86_64-1.4.1.tar.gz"
  export XTL_TOOLSET_TARBALL="$seek_cache/toolset-x86_64-1.1.0.tar.gz"
  printf '%s  %s\n' \
    2d80c922d0873dd8b0a85e19d10bd7f42a1aea3db3a85f7b6edf56fe9b687a21 "$XTL_OAM_TARBALL" \
    a5166f2d56ac45707e5ef2f3c20a41a94af8ef0c0456354224dd08656e874188 "$XTL_TOOLSET_TARBALL" | sha256sum --check
fi
mkdir -p "$seek_source/artifacts"
xtool sdk install "$1" --slim 2>&1 | tr '\r' '\n' | \
  awk 'NF && $0 != last { print; fflush(); last = $0 }' | tee "$seek_source/artifacts/sdk-install-wsl.log"
xtool sdk status
swift sdk list
