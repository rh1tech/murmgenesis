#!/bin/bash
rm -rf ./build
mkdir build
cd build

# USB HID support is enabled by default. Set USB_HID_ENABLED=0 to disable.
CMAKE_OPTS="-DPICO_PLATFORM=rp2350 -DUSB_HID_ENABLED=1"
if [ "$USB_HID_ENABLED" = "0" ]; then
    CMAKE_OPTS="-DPICO_PLATFORM=rp2350"
    echo "Building WITHOUT USB HID Host support (USB for debug output)"
else
    echo "Building with USB HID Host support (UART for debug output)"
fi

# Optional tuning: run Z80 every N scanlines (more aggressive = larger N)
if [ -n "$Z80_SLICE_LINES" ]; then
    CMAKE_OPTS="$CMAKE_OPTS -DZ80_SLICE_LINES=$Z80_SLICE_LINES"
    echo "Z80_SLICE_LINES=$Z80_SLICE_LINES"
fi

cmake $CMAKE_OPTS ..
make -j4
