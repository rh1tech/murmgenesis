/*
 * ROM Selector Implementation
 * Adapted from murmdoom start screen
 */
#include "rom_selector.h"
#include "ff.h"
#include "pico/stdlib.h"
#include "HDMI.h"
#include "nespad/nespad.h"
#include <string.h>
#include <stdio.h>

// USB HID gamepad support
#ifdef USB_HID_ENABLED
#include "usbhid/usbhid.h"
#endif

// Screen dimensions
#define SCREEN_WIDTH 320
#define SCREEN_HEIGHT 240

// ROM list management
#define MAX_ROMS 256
typedef struct {
    char filename[64];
    char display_name[64];
} rom_entry_t;

static rom_entry_t rom_list[MAX_ROMS];
static int rom_count = 0;

// Font and UI constants
#define FONT_WIDTH 6    // 5px glyph + 1px spacing
#define FONT_HEIGHT 7
#define LINE_HEIGHT 10
#define VISIBLE_LINES 16  // Number of ROM entries visible at once
#define MENU_X 24
#define MENU_Y 80
#define MENU_WIDTH (SCREEN_WIDTH - 48)
#define SCROLLBAR_WIDTH 4
#define SCROLLBAR_X (SCREEN_WIDTH - 32)
#define SCROLLBAR_Y MENU_Y
#define SCROLLBAR_HEIGHT (VISIBLE_LINES * LINE_HEIGHT)

// 5x7 font glyphs (from murmdoom)
static const uint8_t *glyph_5x7(char ch) {
    static const uint8_t glyph_space[7] = {0, 0, 0, 0, 0, 0, 0};
    static const uint8_t glyph_dot[7] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C};
    static const uint8_t glyph_hyphen[7] = {0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00};
    static const uint8_t glyph_underscore[7] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F};
    static const uint8_t glyph_colon[7] = {0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00};
    
    static const uint8_t glyph_0[7] = {0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E};
    static const uint8_t glyph_1[7] = {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E};
    static const uint8_t glyph_2[7] = {0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F};
    static const uint8_t glyph_3[7] = {0x1E, 0x01, 0x01, 0x0E, 0x01, 0x01, 0x1E};
    static const uint8_t glyph_4[7] = {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02};
    static const uint8_t glyph_5[7] = {0x1F, 0x10, 0x10, 0x1E, 0x01, 0x01, 0x1E};
    static const uint8_t glyph_6[7] = {0x0E, 0x10, 0x10, 0x1E, 0x11, 0x11, 0x0E};
    static const uint8_t glyph_7[7] = {0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08};
    static const uint8_t glyph_8[7] = {0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E};
    static const uint8_t glyph_9[7] = {0x0E, 0x11, 0x11, 0x0F, 0x01, 0x01, 0x0E};
    
    static const uint8_t glyph_A[7] = {0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11};
    static const uint8_t glyph_B[7] = {0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E};
    static const uint8_t glyph_C[7] = {0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E};
    static const uint8_t glyph_D[7] = {0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E};
    static const uint8_t glyph_E[7] = {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F};
    static const uint8_t glyph_F[7] = {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10};
    static const uint8_t glyph_G[7] = {0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E};
    static const uint8_t glyph_H[7] = {0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11};
    static const uint8_t glyph_I[7] = {0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x1F};
    static const uint8_t glyph_J[7] = {0x07, 0x02, 0x02, 0x02, 0x12, 0x12, 0x0C};
    static const uint8_t glyph_K[7] = {0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11};
    static const uint8_t glyph_L[7] = {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F};
    static const uint8_t glyph_M[7] = {0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11};
    static const uint8_t glyph_N[7] = {0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11};
    static const uint8_t glyph_O[7] = {0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E};
    static const uint8_t glyph_P[7] = {0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10};
    static const uint8_t glyph_Q[7] = {0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D};
    static const uint8_t glyph_R[7] = {0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11};
    static const uint8_t glyph_S[7] = {0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E};
    static const uint8_t glyph_T[7] = {0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04};
    static const uint8_t glyph_U[7] = {0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E};
    static const uint8_t glyph_V[7] = {0x11, 0x11, 0x11, 0x11, 0x0A, 0x0A, 0x04};
    static const uint8_t glyph_W[7] = {0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A};
    static const uint8_t glyph_X[7] = {0x11, 0x0A, 0x04, 0x04, 0x04, 0x0A, 0x11};
    static const uint8_t glyph_Y[7] = {0x11, 0x0A, 0x04, 0x04, 0x04, 0x04, 0x04};
    static const uint8_t glyph_Z[7] = {0x1F, 0x02, 0x04, 0x08, 0x10, 0x10, 0x1F};
    
    // Lowercase (simpler, same as uppercase for readability)
    int c = (unsigned char)ch;
    if (c >= 'a' && c <= 'z') c = c - 'a' + 'A';
    
    switch (c) {
        case ' ': return glyph_space;
        case '.': return glyph_dot;
        case '-': return glyph_hyphen;
        case '_': return glyph_underscore;
        case ':': return glyph_colon;
        case '0': return glyph_0;
        case '1': return glyph_1;
        case '2': return glyph_2;
        case '3': return glyph_3;
        case '4': return glyph_4;
        case '5': return glyph_5;
        case '6': return glyph_6;
        case '7': return glyph_7;
        case '8': return glyph_8;
        case '9': return glyph_9;
        case 'A': return glyph_A;
        case 'B': return glyph_B;
        case 'C': return glyph_C;
        case 'D': return glyph_D;
        case 'E': return glyph_E;
        case 'F': return glyph_F;
        case 'G': return glyph_G;
        case 'H': return glyph_H;
        case 'I': return glyph_I;
        case 'J': return glyph_J;
        case 'K': return glyph_K;
        case 'L': return glyph_L;
        case 'M': return glyph_M;
        case 'N': return glyph_N;
        case 'O': return glyph_O;
        case 'P': return glyph_P;
        case 'Q': return glyph_Q;
        case 'R': return glyph_R;
        case 'S': return glyph_S;
        case 'T': return glyph_T;
        case 'U': return glyph_U;
        case 'V': return glyph_V;
        case 'W': return glyph_W;
        case 'X': return glyph_X;
        case 'Y': return glyph_Y;
        case 'Z': return glyph_Z;
        default: return glyph_space;
    }
}

// Draw a single character
static void draw_char(uint8_t *screen, int x, int y, char ch, uint8_t color) {
    const uint8_t *rows = glyph_5x7(ch);
    for (int row = 0; row < FONT_HEIGHT; ++row) {
        int yy = y + row;
        if (yy < 0 || yy >= SCREEN_HEIGHT) continue;
        uint8_t bits = rows[row];
        for (int col = 0; col < 5; ++col) {
            int xx = x + col;
            if (xx < 0 || xx >= SCREEN_WIDTH) continue;
            if (bits & (1u << (4 - col))) {
                screen[yy * SCREEN_WIDTH + xx] = color;
            }
        }
    }
}

// Draw text string
static void draw_text(uint8_t *screen, int x, int y, const char *text, uint8_t color) {
    for (const char *p = text; *p; ++p) {
        draw_char(screen, x, y, *p, color);
        x += FONT_WIDTH;
    }
}

// Fill rectangle
static void fill_rect(uint8_t *screen, int x, int y, int w, int h, uint8_t color) {
    if (w <= 0 || h <= 0) return;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > SCREEN_WIDTH) w = SCREEN_WIDTH - x;
    if (y + h > SCREEN_HEIGHT) h = SCREEN_HEIGHT - y;
    if (w <= 0 || h <= 0) return;
    
    for (int yy = y; yy < y + h; ++yy) {
        memset(&screen[yy * SCREEN_WIDTH + x], color, (size_t)w);
    }
}

// Scan /genesis directory for ROM files
static void scan_roms(void) {
    DIR dir;
    FILINFO fno;
    rom_count = 0;
    
    FRESULT res = f_opendir(&dir, "/genesis");
    if (res != FR_OK) {
        // Try uppercase
        res = f_opendir(&dir, "/GENESIS");
        if (res != FR_OK) {
            return;
        }
    }
    
    while (rom_count < MAX_ROMS) {
        res = f_readdir(&dir, &fno);
        if (res != FR_OK || fno.fname[0] == 0) break;
        
        // Skip directories and hidden files
        if (fno.fattrib & AM_DIR || fno.fname[0] == '.') continue;
        
        // Check for supported extensions
        const char *ext = strrchr(fno.fname, '.');
        if (ext && (strcasecmp(ext, ".md") == 0 || 
                    strcasecmp(ext, ".bin") == 0 ||
                    strcasecmp(ext, ".gen") == 0 ||
                    strcasecmp(ext, ".smd") == 0)) {
            
            strncpy(rom_list[rom_count].filename, fno.fname, sizeof(rom_list[rom_count].filename) - 1);
            rom_list[rom_count].filename[sizeof(rom_list[rom_count].filename) - 1] = '\0';
            
            // Create display name (remove extension, uppercase)
            strncpy(rom_list[rom_count].display_name, fno.fname, sizeof(rom_list[rom_count].display_name) - 1);
            rom_list[rom_count].display_name[sizeof(rom_list[rom_count].display_name) - 1] = '\0';
            
            // Remove extension for display
            char *dot = strrchr(rom_list[rom_count].display_name, '.');
            if (dot) *dot = '\0';
            
            // Convert to uppercase for display
            for (char *p = rom_list[rom_count].display_name; *p; p++) {
                if (*p >= 'a' && *p <= 'z') *p = *p - 'a' + 'A';
            }
            
            rom_count++;
        }
    }
    
    f_closedir(&dir);
}

// Draw scrollbar
static void draw_scrollbar(uint8_t *screen, int scroll_offset) {
    if (rom_count <= VISIBLE_LINES) return;  // No scrollbar needed
    
    // Clear scrollbar area
    fill_rect(screen, SCROLLBAR_X, SCROLLBAR_Y, SCROLLBAR_WIDTH, SCROLLBAR_HEIGHT, 0);
    
    // Calculate scrollbar thumb position and size
    int thumb_height = (SCROLLBAR_HEIGHT * VISIBLE_LINES) / rom_count;
    if (thumb_height < 10) thumb_height = 10;  // Minimum thumb size
    
    int thumb_max_y = SCROLLBAR_HEIGHT - thumb_height;
    int thumb_y = (thumb_max_y * scroll_offset) / (rom_count - VISIBLE_LINES);
    
    // Draw scrollbar background (dark)
    fill_rect(screen, SCROLLBAR_X, SCROLLBAR_Y, SCROLLBAR_WIDTH, SCROLLBAR_HEIGHT, 16);
    
    // Draw scrollbar thumb (bright)
    fill_rect(screen, SCROLLBAR_X, SCROLLBAR_Y + thumb_y, SCROLLBAR_WIDTH, thumb_height, 63);
}

// Render ROM menu with scrolling
static void render_rom_menu(uint8_t *screen, int selected, int scroll_offset) {
    // Clear menu area (including space for highlight border on left)
    fill_rect(screen, MENU_X - 2, MENU_Y - 2, MENU_WIDTH + 4, (VISIBLE_LINES * LINE_HEIGHT) + 4, 0);
    
    if (rom_count == 0) {
        draw_text(screen, MENU_X, MENU_Y, "NO ROMS FOUND", 63);
        return;
    }
    
    // Draw visible ROM entries
    for (int i = 0; i < VISIBLE_LINES && (scroll_offset + i) < rom_count; i++) {
        int rom_idx = scroll_offset + i;
        int y = MENU_Y + i * LINE_HEIGHT;
        
        if (rom_idx == selected) {
            // Highlight selected ROM (white on black becomes black on white)
            fill_rect(screen, MENU_X - 2, y - 1, MENU_WIDTH, LINE_HEIGHT - 1, 63);
            draw_text(screen, MENU_X, y, rom_list[rom_idx].display_name, 0);
        } else {
            draw_text(screen, MENU_X, y, rom_list[rom_idx].display_name, 63);
        }
    }
    
    // Draw scrollbar
    draw_scrollbar(screen, scroll_offset);
}

bool rom_selector_show(char *selected_rom_path, size_t buffer_size, uint8_t *screen_buffer) {
    printf("ROM Selector: Starting...\n");
    
    // Clear screen to a test pattern first to verify display is working
    printf("ROM Selector: Drawing test pattern...\n");
    for (int i = 0; i < SCREEN_WIDTH * SCREEN_HEIGHT; i++) {
        screen_buffer[i] = (i / SCREEN_WIDTH) % 2 ? 63 : 0;  // Alternating white/black lines (use palette 0-63)
    }
    sleep_ms(1000);  // Show test pattern for 1 second
    
    // Clear screen
    printf("ROM Selector: Clearing screen...\n");
    memset(screen_buffer, 0, SCREEN_WIDTH * SCREEN_HEIGHT);
    
    // Scan for ROMs
    scan_roms();
    
    printf("ROM Selector: Found %d ROMs\n", rom_count);
    for (int i = 0; i < rom_count && i < 10; i++) {
        printf("  %d: %s\n", i, rom_list[i].display_name);
    }
    
    int selected = 0;
    int scroll_offset = 0;
    
    // Draw title
    const char *title = "MURMGENESIS - SELECT ROM";
    int title_x = (SCREEN_WIDTH - (strlen(title) * FONT_WIDTH)) / 2;
    printf("ROM Selector: Drawing title at %d,%d\n", title_x, 20);
    fill_rect(screen_buffer, title_x - 4, 20, strlen(title) * FONT_WIDTH + 8, FONT_HEIGHT + 4, 32);
    draw_text(screen_buffer, title_x, 22, title, 0);
    
    // Draw instructions
    draw_text(screen_buffer, MENU_X, MENU_Y - 24, "UP/DOWN: SELECT", 63);
    draw_text(screen_buffer, MENU_X, MENU_Y - 14, "A/START: CONFIRM", 63);
    
    // Initial render
    render_rom_menu(screen_buffer, selected, scroll_offset);
    
    printf("ROM Selector: Menu rendered, waiting for input...\n");
    
    // If no ROMs found, wait a bit and return false
    if (rom_count == 0) {
        printf("ROM Selector: No ROMs found!\n");
        sleep_ms(3000);
        return false;
    }
    
    // Wait for input
    int prev_selected = -1;
    int prev_scroll = -1;
    uint16_t prev_buttons = 0;  // Track previous button state
    
    // Wait a moment for display to settle
    sleep_ms(100);
    
    while (true) {
        // Only redraw if selection changed
        if (selected != prev_selected || scroll_offset != prev_scroll) {
            render_rom_menu(screen_buffer, selected, scroll_offset);
            prev_selected = selected;
            prev_scroll = scroll_offset;
        }
        
        // Read gamepad
        nespad_read();
        uint16_t buttons = nespad_state;
        
#ifdef USB_HID_ENABLED
        // Poll USB and merge USB gamepad state
        usbhid_task();
        if (usbhid_gamepad_connected()) {
            usbhid_gamepad_state_t gp;
            usbhid_get_gamepad_state(&gp);
            
            // Merge USB gamepad D-pad with nespad buttons
            if (gp.dpad & 0x01) buttons |= DPAD_UP;
            if (gp.dpad & 0x02) buttons |= DPAD_DOWN;
            if (gp.dpad & 0x04) buttons |= DPAD_LEFT;
            if (gp.dpad & 0x08) buttons |= DPAD_RIGHT;
            // Merge USB gamepad buttons (A=confirm, Start=confirm)
            if (gp.buttons & 0x01) buttons |= DPAD_A;     // A button
            if (gp.buttons & 0x02) buttons |= DPAD_B;     // B button
            if (gp.buttons & 0x40) buttons |= DPAD_START; // Start button
        } else {
            static int not_conn = 0;
            if ((not_conn++ % 100) == 0) {
                printf("USB gamepad not connected\n");
            }
        }
#endif
        
        // Detect button press (transition from not pressed to pressed)
        uint16_t buttons_pressed = buttons & ~prev_buttons;
        prev_buttons = buttons;
        
        // Handle input (only on button press, not hold)
        if (buttons_pressed & DPAD_UP) {
            selected--;
            if (selected < 0) {
                selected = rom_count - 1;  // Wrap to last
                scroll_offset = (rom_count > VISIBLE_LINES) ? (rom_count - VISIBLE_LINES) : 0;
            } else if (selected < scroll_offset) {
                scroll_offset = selected;
            }
        }
        
        if (buttons_pressed & DPAD_DOWN) {
            selected++;
            if (selected >= rom_count) {
                selected = 0;  // Wrap to first
                scroll_offset = 0;
            } else if (selected >= scroll_offset + VISIBLE_LINES) {
                scroll_offset = selected - VISIBLE_LINES + 1;
            }
        }
        
        if (buttons_pressed & (DPAD_A | DPAD_START)) {
            if (rom_count > 0) {
                // Build full path
                snprintf(selected_rom_path, buffer_size, "/genesis/%s", rom_list[selected].filename);
                return true;
            }
        }
        
        sleep_ms(50);  // Update rate
    }
    
    return false;
}
