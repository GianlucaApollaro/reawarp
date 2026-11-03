@echo off
rem reawarp - installs the Beat This! beat detector in this folder.
rem No Python installation is needed: uv downloads a private Python here.
rem Copyright (C) 2026 Gabriel Schuck. GPL-3.0-or-later (see LICENSE).
rem Argument: gpu (PyTorch for NVIDIA graphics cards, about 2.5 GB) or cpu (about
rem 300 MB). Without one it keeps the kind already installed (cpu on a new install).
setlocal
set "KIND=%~1"
cd /d "%~dp0"
echo reawarp: installing the Beat This! beat detector.
echo This downloads about 350 MB and needs about 1 GB of disk space
echo (the version for NVIDIA graphics cards: about 2.5 GB, and 3 GB of disk).
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
rem the PyTorch build installed now: cpu, a CUDA version, or none
set "CUR="
for /f "delims=" %%v in ('env\Scripts\python.exe -c "import torch; print(torch.version.cuda or 0)" 2^>nul') do set "CUR=%%v"
if "%CUR%"=="0" set "CUR=cpu"
if not defined KIND (
  set "KIND=cpu"
  if defined CUR if /i not "%CUR%"=="cpu" set "KIND=keep"
)
set "INDEX=cpu"
if /i "%KIND%"=="gpu" call :cuda_index
set "REINSTALL="
if /i "%KIND%"=="keep" goto torch_install
if /i "%INDEX%"=="cpu" (
  if defined CUR if /i not "%CUR%"=="cpu" set "REINSTALL=--reinstall-package torch --reinstall-package torchaudio"
) else (
  if /i "%CUR%"=="cpu" set "REINSTALL=--reinstall-package torch --reinstall-package torchaudio"
)
:torch_install
if /i "%KIND%"=="keep" (
  echo PyTorch for the GPU is already installed.
) else (
  if /i "%INDEX%"=="cpu" (echo Installing PyTorch for the CPU...) else (echo Installing PyTorch for the NVIDIA GPU [%INDEX%], about 2.5 GB...)
  "%UV%" pip install --python "env\Scripts\python.exe" torch torchaudio --index-url https://download.pytorch.org/whl/%INDEX% %REINSTALL% || goto fail
)
echo Installing Beat This!...
"%UV%" pip install --python "env\Scripts\python.exe" beat-this==1.1.0 || goto fail
echo Downloading the model...
"env\Scripts\python.exe" reawarp_beat_this.py --download || goto fail
for /f "delims=" %%d in ('env\Scripts\python.exe reawarp_beat_this.py --device 2^>nul') do echo Beat This! will run on: %%d
if exist uvcache rmdir /s /q uvcache
echo.
echo Done. reawarp now uses Beat This! when analyzing.
goto end

:cuda_index
rem the newest CUDA build that the NVIDIA driver supports
set "DRV="
for /f "tokens=1 delims=." %%a in ('nvidia-smi --query-gpu^=driver_version --format^=csv^,noheader 2^>nul') do if not defined DRV set "DRV=%%a"
if not defined DRV (
  echo No NVIDIA graphics card found: installing the CPU version.
  goto :eof
)
if %DRV% GEQ 580 (set "INDEX=cu130" & goto :eof)
if %DRV% GEQ 570 (set "INDEX=cu128" & goto :eof)
if %DRV% GEQ 560 (set "INDEX=cu126" & goto :eof)
echo The NVIDIA driver is too old for the GPU version (update it to use the GPU): installing the CPU version.
goto :eof

:fail
echo.
echo The installation failed. See the messages above.
echo It needs an internet connection; you can run it again to retry.

:end
echo.
pause
