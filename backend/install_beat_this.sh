#!/bin/sh
# reawarp - installs the Beat This! beat detector in this folder.
# No Python installation is needed: uv downloads a private Python here.
# Copyright (C) 2026 Gabriel Schuck. GPL-3.0-or-later (see LICENSE).
cd "$(dirname "$0")" || exit 1
HERE=$(pwd)

finish() {
  echo
  printf 'Press Enter to close. '
  read -r _
  exit "$1"
}

echo "reawarp: installing the Beat This! beat detector."
echo "This downloads about 350 MB and needs about 1 GB of disk space."
echo "Everything goes inside this folder; no Python installation is needed."
echo

UV_VERSION=0.12.20
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) TARGET=aarch64-apple-darwin ;;
  Darwin-x86_64) TARGET=x86_64-apple-darwin ;;
  Linux-x86_64) TARGET=x86_64-unknown-linux-gnu ;;
  Linux-aarch64 | Linux-arm64) TARGET=aarch64-unknown-linux-gnu ;;
  *) echo "Unsupported system: $(uname -s) $(uname -m)"; finish 1 ;;
esac
# keep uv's Python, cache and tools inside this folder, and never use a system Python
export UV_PYTHON_INSTALL_DIR="$HERE/python"
export UV_CACHE_DIR="$HERE/uvcache"
export UV_PYTHON_PREFERENCE=only-managed
export UV_NO_CONFIG=1
UV="$HERE/uv/uv"

set -e
trap 'echo; echo "The installation failed. See the messages above."; echo "It needs an internet connection; you can run it again to retry."; finish 1' EXIT
if [ ! -x "$UV" ]; then
  echo "Downloading uv $UV_VERSION..."
  mkdir -p uv
  URL="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$TARGET.tar.gz"
  if command -v curl >/dev/null 2>&1; then curl -L --fail -o uv/uv.tar.gz "$URL"; else wget -O uv/uv.tar.gz "$URL"; fi
  tar -xzf uv/uv.tar.gz -C uv --strip-components=1
  rm uv/uv.tar.gz
fi
# --allow-existing keeps the installed packages and repairs an env whose folder was moved
echo "Installing Python..."
"$UV" venv env --python 3.12 --allow-existing
echo "Installing PyTorch..."
if [ "$(uname -s)" = "Darwin" ]; then
  "$UV" pip install --python env/bin/python torch torchaudio
else
  "$UV" pip install --python env/bin/python torch torchaudio --index-url https://download.pytorch.org/whl/cpu
fi
echo "Installing Beat This!..."
"$UV" pip install --python env/bin/python beat-this==1.1.0
echo "Downloading the model..."
env/bin/python reawarp_beat_this.py --download
rm -rf uvcache
trap - EXIT
echo
echo "Done. reawarp now uses Beat This! when analyzing."
finish 0
