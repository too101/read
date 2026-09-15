#!/bin/sh
# Build read on Linux with GCC + libX11 + libXext (MIT-SHM) dev headers.
# Debian/Ubuntu: sudo apt install build-essential libx11-dev libxext-dev
# Fedora:        sudo dnf install gcc libX11-devel libXext-devel
# Arch:          sudo pacman -S base-devel libx11 libxext

set -e
gcc -O2 -Wall -Wextra -o read src/read_linux.c -lX11 -lXext
echo "Built ./read"
