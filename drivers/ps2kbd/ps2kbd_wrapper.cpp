// PS/2 Keyboard Wrapper for Genesis
// SPDX-License-Identifier: GPL-2.0-or-later

#include "../../src/board_config.h"
#include "ps2kbd_wrapper.h"
#include "ps2kbd_mrmltr.h"
#include <queue>

struct KeyEvent {
    int pressed;
    unsigned char key;
};

static std::queue<KeyEvent> event_queue;

// HID to Genesis key mapping (simplified)
// Returns 0 if no mapping
static unsigned char hid_to_genesis(uint8_t code) {
    // Arrow keys
    if (code == 0x52) return 0x01;  // Up
    if (code == 0x51) return 0x02;  // Down
    if (code == 0x50) return 0x03;  // Left
    if (code == 0x4F) return 0x04;  // Right
    // Genesis buttons
    if (code == 0x04) return 0x05;  // A = A button
    if (code == 0x16) return 0x06;  // S = B button
    if (code == 0x07) return 0x07;  // D = C button
    if (code == 0x28) return 0x08;  // Enter = Start
    return 0;
}

static void key_handler(hid_keyboard_report_t *curr, hid_keyboard_report_t *prev) {
    // Check keys - new key presses
    for (int i = 0; i < 6; i++) {
        if (curr->keycode[i] != 0) {
            bool found = false;
            for (int j = 0; j < 6; j++) {
                if (prev->keycode[j] == curr->keycode[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                unsigned char k = hid_to_genesis(curr->keycode[i]);
                if (k) event_queue.push({1, k});
            }
        }
    }

    // Check keys - key releases
    for (int i = 0; i < 6; i++) {
        if (prev->keycode[i] != 0) {
            bool found = false;
            for (int j = 0; j < 6; j++) {
                if (curr->keycode[j] == prev->keycode[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                unsigned char k = hid_to_genesis(prev->keycode[i]);
                if (k) event_queue.push({0, k});
            }
        }
    }
}

static Ps2Kbd_Mrmltr* kbd = nullptr;

extern "C" void ps2kbd_init(void) {
    kbd = new Ps2Kbd_Mrmltr(pio0, PS2_PIN_CLK, key_handler);
    kbd->init_gpio();
}

extern "C" void ps2kbd_tick(void) {
    if (kbd) kbd->tick();
}

extern "C" int ps2kbd_get_key(int* pressed, unsigned char* key) {
    if (event_queue.empty()) return 0;
    KeyEvent e = event_queue.front();
    event_queue.pop();
    *pressed = e.pressed;
    *key = e.key;
    return 1;
}

