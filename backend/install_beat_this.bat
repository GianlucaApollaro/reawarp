@echo off
rem reawarp - installs the Beat This! beat detector in this folder.
rem No Python installation is needed: uv downloads a private Python here.
rem Copyright (C) 2026 Gabriel Schuck. GPL-3.0-or-later (see LICENSE).
setlocal
cd /d "%~dp0"
echo reawarp: installing the Beat This! beat detector.
echo This downloads about 350 MB and needs about 1 GB of disk space.
echo Everything goes inside this folder; no Python installation is needed.
echo.

set "UV_VERSION=0.12.20"
set "UV_TARGET=x86_64-pc-windows-msvc"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "UV_TARGET=aarch64-pc-windows-msvc"
set "UV=%CD%\uv\uv.exe"
rem keep uv's Python, cache and tools inside this folder, and never use a system Python
set "UV_PYTHON_INSTALL_DIR=%CD%\python"
set "UV_CACHE_DIR=%CD%\uvcache"
set "UV_PYTHON_PREFERENCE=only-managed"
set "UV_NO_CONFIG=1"
rem Windows' own tar (it opens .zip files; another tar on the PATH may not)
set "TAR=tar"
if exist "%SystemRoot%\System32\tar.exe" set "TAR=%SystemRoot%\System32\tar.exe"

if not exist "%UV%" (
  echo Downloading uv %UV_VERSION%...
  if not exist uv mkdir uv
  curl -L --fail -o "uv\uv.zip" "https://github.com/astral-sh/uv/releases/download/%UV_VERSION%/uv-%UV_TARGET%.zip" || goto fail
  "%TAR%" -xf "uv\uv.zip" -C uv || goto fail
  del "uv\uv.zip"
)
if not exist "%UV%" goto fail

rem --allow-existing keeps the installed packages and repairs an env whose folder was moved
echo Installing Python...
"%UV%" venv env --python 3.12 --allow-existing || goto fail
echo Installing PyTorch (CPU)...
"%UV%" pip install --python "env\Scripts\python.exe" torch torchaudio --index-url https://download.pytorch.org/whl/cpu || goto fail
echo Installing Beat This!...
"%UV%" pip install --python "env\Scripts\python.exe" beat-this==1.1.0 || goto fail
echo Downloading the model...
"env\Scripts\python.exe" reawarp_beat_this.py --download || goto fail
if exist uvcache rmdir /s /q uvcache
echo.
echo Done. reawarp now uses Beat This! when analyzing.
goto end

:fail
echo.
echo The installation failed. See the messages above.
echo It needs an internet connection; you can run it again to retry.

:end
echo.
pause
