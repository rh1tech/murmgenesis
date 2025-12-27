#!/bin/bash
rm -rf ./build
mkdir build
cd build
cmake -DPICO_PLATFORM=rp2350 ..
make -j4
