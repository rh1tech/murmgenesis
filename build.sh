#!/bin/bash
rm -rf ./build
mkdir build
cd build

# Build with optional USB HID support: USB_HID_ENABLED=1 ./build.sh
CMAKE_OPTS="-DPICO_PLATFORM=rp2350"
if [ "$USB_HID_ENABLED" = "1" ]; then
    CMAKE_OPTS="$CMAKE_OPTS -DUSB_HID_ENABLED=1"
    echo "Building with USB HID Host support (UART for debug output)"
fi

cmake $CMAKE_OPTS ..
make -j4
