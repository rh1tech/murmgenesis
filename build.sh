#!/bin/bash
rm -rf ./build
mkdir build
cd build
cmake -DPICO_PLATFORM=rp2350 -DUSB_HID_ENABLED=0 ..
make -j4
