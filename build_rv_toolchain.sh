#!/bin/bash

# 1) Deps
sudo apt update
sudo apt install -y autoconf automake autotools-dev curl python3 python3-pip python3-tomli \
  libmpc-dev libmpfr-dev libgmp-dev gawk build-essential bison flex texinfo gperf libtool \
  patchutils bc zlib1g-dev libexpat-dev ninja-build git cmake libglib2.0-dev libslirp-dev


# 2) Sources
git clone https://github.com/riscv-collab/riscv-gnu-toolchain
cd riscv-gnu-toolchain


# 3) Build & install (multilib)
./configure --prefix=/opt/riscv --enable-multilib
make -j"$(nproc)"


# 4) PATH
echo 'export PATH=/opt/riscv/bin:$PATH' >> ~/.bashrc
source ~/.bashrc


