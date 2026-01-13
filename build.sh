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

# Optional Z80 core selection: OLD (original) or GPX (Genesis-Plus-GX)
if [ -n "$Z80_CORE" ]; then
    CMAKE_OPTS="$CMAKE_OPTS -DZ80_CORE=$Z80_CORE"
    echo "Z80_CORE=$Z80_CORE"
fi

# Line interlacing: render every other line (halves VDP time, some quality loss)
# Set LINE_INTERLACE=1 to enable
if [ "$LINE_INTERLACE" = "1" ]; then
    CMAKE_OPTS="$CMAKE_OPTS -DLINE_INTERLACE=1"
    echo "LINE_INTERLACE=1 (rendering every other line)"
fi

# Frame skip level: 0=60fps, 1=50fps (default), 2=40fps, 3=30fps, 4=20fps
# Set FRAMESKIP_LEVEL=N to change
if [ -n "$FRAMESKIP_LEVEL" ]; then
    CMAKE_OPTS="$CMAKE_OPTS -DFRAMESKIP_LEVEL=$FRAMESKIP_LEVEL"
    echo "FRAMESKIP_LEVEL=$FRAMESKIP_LEVEL"
fi

cmake $CMAKE_OPTS ..
make -j4
