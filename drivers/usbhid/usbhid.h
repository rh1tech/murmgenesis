/*
 * USB HID Host Driver Header
 * Provides keyboard and mouse input via USB Host
 * 
 * SPDX-License-Identifier: MIT
 */

#ifndef USBHID_H
#define USBHID_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

//--------------------------------------------------------------------
// USB HID State
//--------------------------------------------------------------------

// USB keyboard state accessible from wrapper
typedef struct {
    uint8_t keycode[6];     // Currently pressed keys (HID keycodes)
    uint8_t modifier;       // Modifier keys (shift, ctrl, alt, etc.)
    int has_key;            // Non-zero if a key event is pending
} usbhid_keyboard_state_t;

// USB mouse state
typedef struct {
    int16_t dx;             // Accumulated X movement
    int16_t dy;             // Accumulated Y movement
    int8_t wheel;           // Wheel movement
    uint8_t buttons;        // Button state (bit 0=left, 1=right, 2=middle)
    int has_motion;         // Non-zero if motion/button change occurred
} usbhid_mouse_state_t;

// USB gamepad state (normalized to Genesis-style mapping)
typedef struct {
    int8_t axis_x;          // Left stick X: -127 to 127
    int8_t axis_y;          // Left stick Y: -127 to 127
    uint8_t dpad;           // D-pad: bit 0=up, 1=down, 2=left, 3=right
    uint16_t buttons;       // Buttons: bit 0=A, 1=B, 2=C, 3=X, 4=Y, 5=Z, 6=Start, 7=Select/Mode
    int connected;          // Non-zero if gamepad is connected
} usbhid_gamepad_state_t;

//--------------------------------------------------------------------
// API Functions
//--------------------------------------------------------------------

/**
 * Initialize USB Host HID driver
 * Call this during system initialization
 */
void usbhid_init(void);

/**
 * Poll USB Host for events
 * Must be called periodically (e.g., every frame)
 */
void usbhid_task(void);

/**
 * Check if a USB keyboard is connected
 * @return Non-zero if keyboard connected
 */
int usbhid_keyboard_connected(void);

/**
 * Check if a USB mouse is connected
 * @return Non-zero if mouse connected
 */
int usbhid_mouse_connected(void);

/**
 * Get current keyboard state
 * @param state Pointer to state structure to fill
 */
void usbhid_get_keyboard_state(usbhid_keyboard_state_t *state);

/**
 * Get current mouse state and reset deltas
 * @param state Pointer to state structure to fill
 */
void usbhid_get_mouse_state(usbhid_mouse_state_t *state);

/**
 * Get pending key action (for wrapper compatibility)
 * @param keycode HID keycode of the key
 * @param down Non-zero if key pressed, 0 if released
 * @return Non-zero if action available
 */
int usbhid_get_key_action(uint8_t *keycode, int *down);

/**
 * Check if a USB gamepad is connected
 * @return Non-zero if gamepad connected
 */
int usbhid_gamepad_connected(void);

/**
 * Get current gamepad state
 * @param state Pointer to state structure to fill
 */
void usbhid_get_gamepad_state(usbhid_gamepad_state_t *state);

#ifdef __cplusplus
}
#endif

#endif /* USBHID_H */
