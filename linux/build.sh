#!/bin/sh
# Build read on Linux with GCC + libX11 dev headers.
# Debian/Ubuntu: sudo apt install build-essential libx11-dev
# Fedora:        sudo dnf install gcc libX11-devel
# Arch:          sudo pacman -S base-devel libx11

set -e
gcc -O2 -Wall -Wextra -o read src/read_linux.c -lX11
echo "Built ./read"
