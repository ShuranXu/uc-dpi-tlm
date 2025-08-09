#!/bin/bash

sudo apt update
sudo apt install -y git cmake build-essential pkg-config

git clone --recursive https://github.com/unicorn-engine/unicorn.git
cd unicorn && mkdir build && cd build
# build **RISC-V only**
cmake .. -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_INSTALL_PREFIX=/usr/local/unicorn \
         -DUNICORN_ARCHS="riscv"

cmake --build . -j"$(nproc)"
sudo cmake --install .

echo "Verify it's 64-bit and present"
file /usr/local/unicorn/lib/libunicorn.so.2