// PS/2 Mouse Wrapper for DOOM
// Interfaces ps2mouse driver with DOOM's event system
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef PS2MOUSE_WRAPPER_H
#define PS2MOUSE_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

// Initialize PS/2 mouse for DOOM
void ps2mouse_wrapper_init(void);

// Poll mouse and post events to DOOM
// Call this from the main game loop
void ps2mouse_wrapper_tick(void);

#ifdef __cplusplus
}
#endif

#endif // PS2MOUSE_WRAPPER_H
