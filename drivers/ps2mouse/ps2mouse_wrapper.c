// PS/2 Mouse Wrapper for Genesis (stub)
// SPDX-License-Identifier: GPL-2.0-or-later

#include "ps2mouse_wrapper.h"
#include "ps2mouse.h"
#include <stdint.h>

void ps2mouse_wrapper_init(void) {
    ps2mouse_init();
}

void ps2mouse_wrapper_tick(void) {
    // Consume any mouse events (not used in Genesis emulator yet)
    int16_t dx, dy;
    int8_t wheel;
    uint8_t buttons;
    ps2mouse_get_state(&dx, &dy, &wheel, &buttons);
}
