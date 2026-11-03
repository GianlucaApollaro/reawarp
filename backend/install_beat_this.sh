#!/bin/sh
# reawarp - installs the Beat This! beat detector in this folder.
# No Python installation is needed: uv downloads a private Python here.
# Copyright (C) 2026 Gabriel Schuck. GPL-3.0-or-later (see LICENSE).
cd "$(dirname "$0")" || exit 1
HERE=$(pwd)

finish() {
  # nothing here writable by everyone (folders synced to the cloud, as with
  # MEGA, refuse 777): 775 for folders, 664 for files
  chmod -R o-w "$HERE" 2>/dev/null
  echo
  printf 'Press Enter to close. '
  read -r _
  exit "$1"
}

echo "reawarp: installing the Beat This! beat detector."
echo "This downloads about 350 MB and needs about 1 GB of disk space"
echo "(the version for NVIDIA graphics cards: about 2.5 GB, and 3 GB of disk)."
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
if [ "$(uname -s)" = "Darwin" ]; then
  # the standard build also uses the GPU of Apple silicon (MPS)
  echo "Installing PyTorch..."
  "$UV" pip install --python env/bin/python torch torchaudio
else
  # gpu: PyTorch for NVIDIA graphics cards (about 2.5 GB); cpu: about 300 MB.
  # Without an argument it keeps the kind already installed (cpu on a new install).
  KIND="${1:-}"
  CUR=$(env/bin/python -c "import torch; print(torch.version.cuda or 'cpu')" 2>/dev/null || true)
  if [ -z "$KIND" ]; then
    if [ -n "$CUR" ] && [ "$CUR" != cpu ]; then KIND=keep; else KIND=cpu; fi
  fi
  INDEX=cpu
  if [ "$KIND" = gpu ]; then
    # the newest CUDA build that the NVIDIA driver supports
    DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 | cut -d. -f1 || true)
    case "$DRV" in
      '' | *[!0-9]*) echo "No NVIDIA graphics card found: installing the CPU version." ;;
      *) if [ "$DRV" -ge 580 ]; then INDEX=cu130
         elif [ "$DRV" -ge 570 ]; then INDEX=cu128
         elif [ "$DRV" -ge 560 ]; then INDEX=cu126
         else echo "The NVIDIA driver is too old for the GPU version (update it to use the GPU): installing the CPU version."
         fi ;;
    esac
  fi
  if [ "$KIND" = keep ]; then
    echo "PyTorch for the GPU is already installed."
  else
    REINSTALL=""
    if [ "$INDEX" = cpu ] && [ -n "$CUR" ] && [ "$CUR" != cpu ]; then REINSTALL="--reinstall-package torch --reinstall-package torchaudio"; fi
    if [ "$INDEX" != cpu ] && [ "$CUR" = cpu ]; then REINSTALL="--reinstall-package torch --reinstall-package torchaudio"; fi
    if [ "$INDEX" = cpu ]; then echo "Installing PyTorch for the CPU..."; else echo "Installing PyTorch for the NVIDIA GPU ($INDEX), about 2.5 GB..."; fi
    # shellcheck disable=SC2086
    "$UV" pip install --python env/bin/python torch torchaudio --index-url "https://download.pytorch.org/whl/$INDEX" $REINSTALL
  fi
fi
echo "Installing Beat This!..."
"$UV" pip install --python env/bin/python beat-this==1.1.0
echo "Downloading the model..."
env/bin/python reawarp_beat_this.py --download
echo "Beat This! will run on: $(env/bin/python reawarp_beat_this.py --device 2>/dev/null || echo cpu)"
rm -rf uvcache
trap - EXIT
echo
echo "Done. reawarp now uses Beat This! when analyzing."
finish 0
