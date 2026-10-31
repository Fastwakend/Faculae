#!/usr/bin/env bash
set -euo pipefail

# Build the pinned, MIT-licensed asset catalog compiler on WSL's Linux disk.
# Rust and all build caches remain inside the WSL distribution on D:.
seek_accord_revision=98e463c15609b13c26ec8a2971c2248e7e1d544d
seek_accord_sha256=89559bf74963afbc13d1744eba4c69a66cffffde49efd3657822a8836a831662
seek_rust_version=1.92.0
seek_source="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
seek_downloads="${XDG_CACHE_HOME:-$HOME/.cache}/seekapi-downloads/accord"
seek_tools="$HOME/.local/share/seekapi-tools/accord-$seek_accord_revision"
mkdir -p "$seek_downloads" "$seek_tools" "$HOME/.local/bin"
export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v rustup >/dev/null; then
  curl -fL --retry 3 \
    https://static.rust-lang.org/rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init \
    -o "$seek_downloads/rustup-init"
  printf '%s  %s\n' 20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c \
    "$seek_downloads/rustup-init" | sha256sum --check
  chmod +x "$seek_downloads/rustup-init"
  "$seek_downloads/rustup-init" -y --profile minimal --default-toolchain "$seek_rust_version" --no-modify-path
else
  rustup toolchain install "$seek_rust_version" --profile minimal
fi

seek_archive="$seek_downloads/accord-$seek_accord_revision.tar.gz"
seek_local_archive="$seek_source/artifacts/build-tools/accord-$seek_accord_revision.tar.gz"
if [[ -f "$seek_local_archive" ]]; then
  cp "$seek_local_archive" "$seek_archive"
else
  curl -fL --retry 3 "https://codeload.github.com/MiloLug/dine-accord/tar.gz/$seek_accord_revision" -o "$seek_archive"
fi
printf '%s  %s\n' "$seek_accord_sha256" "$seek_archive" | sha256sum --check
tar -xzf "$seek_archive" --strip-components=1 -C "$seek_tools"
cargo "+$seek_rust_version" build --release --locked --jobs 2 --manifest-path "$seek_tools/Cargo.toml"
ln -sfn "$seek_tools/target/release/accord" "$HOME/.local/bin/accord"
printf 'accord revision: %s\n' "$seek_accord_revision"
printf 'Compiler: '
rustc "+$seek_rust_version" --version
echo "Installed: $HOME/.local/bin/accord"
