#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo "This setup is for Ubuntu 24.04 x86_64, including WSL2."
  exit 1
fi
. /etc/os-release
if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != 24.04 ]]; then
  echo "Expected Ubuntu 24.04; detected ${PRETTY_NAME:-unknown}."
  exit 1
fi

seek_sudo=()
if [[ "$(id -u)" != 0 ]]; then seek_sudo=(sudo); fi
"${seek_sudo[@]}" apt-get -o Acquire::Retries=3 update
"${seek_sudo[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl git gnupg2 binutils build-essential pkg-config \
  libc6-dev libcurl4-openssl-dev libedit2 libncurses-dev libpython3-dev \
  libsqlite3-0 libstdc++-13-dev libxml2-dev libz3-dev zlib1g-dev \
  unzip zip rsync python3-venv usbmuxd libimobiledevice-utils

echo "Ubuntu Swift / xtool prerequisites installed."
