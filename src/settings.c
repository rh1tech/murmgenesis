/*
 * Settings Menu Implementation
 * Uses the same 5x7 font as ROM selector for consistency
 */
#include "settings.h"
#include "ff.h"
#include "pico/stdlib.h"
#include "HDMI.h"
#include "board_config.h"
#include "hardware/clocks.h"
#include "hardware/watchdog.h"
#include "nespad/nespad.h"
#include "audio.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

// USB HID gamepad support
#ifdef USB_HID_ENABLED
#include "usbhid/usbhid.h"
#endif

// Screen dimensions
#define SCREEN_WIDTH 320
#define SCREEN_HEIGHT 240

// Font constants (same as ROM selector)
#define FONT_WIDTH 6    // 5px glyph + 1px spacing
#define FONT_HEIGHT 7
#define LINE_HEIGHT 12  // Slightly more spacing for settings

// UI layout
#define MENU_TITLE_Y 20
#define MENU_START_Y 50
#define MENU_X 40
#define VALUE_X 200  // X position for values

// Colors (8-bit 3-3-2 RGB palette)
#define COLOR_BLACK 1    // Near-black (not 0 for HDMI compatibility)
#define COLOR_WHITE 63   // Bright white
#define COLOR_YELLOW 48  // Yellow for highlight
#define COLOR_GRAY 42    // Medium gray
#define COLOR_RED 32     // Red

// Menu items
typedef enum {
    MENU_CPU_FREQ,
    MENU_PSRAM_FREQ,
    MENU_FM_SOUND,
    MENU_DAC_SOUND,
    MENU_CRT_EFFECT,
    MENU_CRT_DIM,
    MENU_SEPARATOR,  // Visual separator
    MENU_SAVE_RESTART,
    MENU_RESTART,
    MENU_CANCEL,
    MENU_ITEM_COUNT
} menu_item_t;

// Global settings instance
settings_t g_settings = {
    .cpu_freq = 504,
    .psram_freq = 166,
    .fm_sound = true,
    .dac_sound = true,
    .crt_effect = false,
    .crt_dim = 60
};

// Local copy for editing
static settings_t edit_settings;

// CRT dim values
static const uint8_t crt_dim_values[] = {10, 20, 30, 40, 50, 60, 70, 80, 90};
#define CRT_DIM_COUNT (sizeof(crt_dim_values) / sizeof(crt_dim_values[0]))

// 5x7 font glyphs (copied from rom_selector.c)
static const uint8_t *glyph_5x7(char ch) {
    static const uint8_t glyph_space[7] = {0, 0, 0, 0, 0, 0, 0};
    static const uint8_t glyph_dot[7] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C};
    static const uint8_t glyph_hyphen[7] = {0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00};
    static const uint8_t glyph_underscore[7] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F};
    static const uint8_t glyph_colon[7] = {0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00};
    static const uint8_t glyph_slash[7] = {0x01, 0x02, 0x04, 0x08, 0x10, 0x00, 0x00};
    static const uint8_t glyph_percent[7] = {0x11, 0x02, 0x04, 0x08, 0x11, 0x00, 0x00};
    static const uint8_t glyph_lparen[7] = {0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02};
    static const uint8_t glyph_rparen[7] = {0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08};
    static const uint8_t glyph_less[7] = {0x02, 0x04, 0x08, 0x10, 0x08, 0x04, 0x02};
    static const uint8_t glyph_greater[7] = {0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08};
    
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
    
    int c = (unsigned char)ch;
    if (c >= 'a' && c <= 'z') c = c - 'a' + 'A';
    
    switch (c) {
        case ' ': return glyph_space;
        case '.': return glyph_dot;
        case '-': return glyph_hyphen;
        case '_': return glyph_underscore;
        case ':': return glyph_colon;
        case '/': return glyph_slash;
        case '%': return glyph_percent;
        case '(': return glyph_lparen;
        case ')': return glyph_rparen;
        case '<': return glyph_less;
        case '>': return glyph_greater;
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
    
    if (color == 0) color = 1;  // Avoid index 0 for HDMI compatibility
    
    for (int yy = y; yy < y + h; ++yy) {
        memset(&screen[yy * SCREEN_WIDTH + x], color, (size_t)w);
    }
}

// Draw horizontal line
static void draw_hline(uint8_t *screen, int x, int y, int w, uint8_t color) {
    if (y < 0 || y >= SCREEN_HEIGHT) return;
    if (x < 0) { w += x; x = 0; }
    if (x + w > SCREEN_WIDTH) w = SCREEN_WIDTH - x;
    if (w <= 0) return;
    memset(&screen[y * SCREEN_WIDTH + x], color, (size_t)w);
}

// Get index of current CRT dim value
static int get_crt_dim_index(uint8_t dim) {
    for (int i = 0; i < (int)CRT_DIM_COUNT; i++) {
        if (crt_dim_values[i] == dim) return i;
    }
    return 5;  // Default to 60%
}

// Get menu item label
static const char* get_menu_label(menu_item_t item) {
    switch (item) {
        case MENU_CPU_FREQ:     return "RP2350 FREQ";
        case MENU_PSRAM_FREQ:   return "PSRAM FREQ";
        case MENU_FM_SOUND:     return "FM SOUND";
        case MENU_DAC_SOUND:    return "DAC SOUND";
        case MENU_CRT_EFFECT:   return "CRT EFFECT";
        case MENU_CRT_DIM:      return "CRT DIM";
        case MENU_SEPARATOR:    return "";
        case MENU_SAVE_RESTART: return "SAVE AND RESTART";
        case MENU_RESTART:      return "RESTART WITHOUT SAVING";
        case MENU_CANCEL:       return "CANCEL";
        default:                return "";
    }
}

// Get menu item value string
static void get_menu_value(menu_item_t item, char *buf, size_t size) {
    switch (item) {
        case MENU_CPU_FREQ:
            snprintf(buf, size, "< %d MHZ >", edit_settings.cpu_freq);
            break;
        case MENU_PSRAM_FREQ:
            snprintf(buf, size, "< %d MHZ >", edit_settings.psram_freq);
            break;
        case MENU_FM_SOUND:
            snprintf(buf, size, "< %s >", edit_settings.fm_sound ? "ON" : "OFF");
            break;
        case MENU_DAC_SOUND:
            snprintf(buf, size, "< %s >", edit_settings.dac_sound ? "ON" : "OFF");
            break;
        case MENU_CRT_EFFECT:
            snprintf(buf, size, "< %s >", edit_settings.crt_effect ? "ON" : "OFF");
            break;
        case MENU_CRT_DIM:
            if (edit_settings.crt_effect) {
                snprintf(buf, size, "< %d%% >", edit_settings.crt_dim);
            } else {
                snprintf(buf, size, "---");
            }
            break;
        default:
            buf[0] = '\0';
            break;
    }
}

// Change setting value (left/right)
static void change_setting(menu_item_t item, int direction) {
    switch (item) {
        case MENU_CPU_FREQ:
            if (direction < 0 && edit_settings.cpu_freq == 504) {
                edit_settings.cpu_freq = 378;
            } else if (direction > 0 && edit_settings.cpu_freq == 378) {
                edit_settings.cpu_freq = 504;
            }
            break;
            
        case MENU_PSRAM_FREQ:
            if (direction < 0 && edit_settings.psram_freq == 166) {
                edit_settings.psram_freq = 133;
            } else if (direction > 0 && edit_settings.psram_freq == 133) {
                edit_settings.psram_freq = 166;
            }
            break;
            
        case MENU_FM_SOUND:
            edit_settings.fm_sound = !edit_settings.fm_sound;
            break;
            
        case MENU_DAC_SOUND:
            edit_settings.dac_sound = !edit_settings.dac_sound;
            break;
            
        case MENU_CRT_EFFECT:
            edit_settings.crt_effect = !edit_settings.crt_effect;
            break;
            
        case MENU_CRT_DIM:
            if (edit_settings.crt_effect) {
                int idx = get_crt_dim_index(edit_settings.crt_dim);
                if (direction < 0 && idx > 0) {
                    edit_settings.crt_dim = crt_dim_values[idx - 1];
                } else if (direction > 0 && idx < (int)CRT_DIM_COUNT - 1) {
                    edit_settings.crt_dim = crt_dim_values[idx + 1];
                }
            }
            break;
            
        default:
            break;
    }
}

// Check if menu item is selectable
static bool is_selectable(menu_item_t item) {
    if (item == MENU_SEPARATOR) return false;
    if (item == MENU_CRT_DIM && !edit_settings.crt_effect) return false;
    return true;
}

// Get next selectable item
static int get_next_selectable(int current, int direction) {
    int next = current;
    do {
        next += direction;
        if (next < 0) next = MENU_ITEM_COUNT - 1;
        if (next >= MENU_ITEM_COUNT) next = 0;
    } while (!is_selectable((menu_item_t)next) && next != current);
    return next;
}

// Draw the entire settings menu
static void draw_settings_menu(uint8_t *screen, int selected) {
    // Clear screen
    fill_rect(screen, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, COLOR_BLACK);
    
    // Draw title
    const char *title = "SETTINGS";
    int title_width = (int)strlen(title) * FONT_WIDTH;
    int title_x = (SCREEN_WIDTH - title_width) / 2;
    draw_text(screen, title_x, MENU_TITLE_Y, title, COLOR_WHITE);
    
    // Draw separator under title
    draw_hline(screen, 40, MENU_TITLE_Y + FONT_HEIGHT + 4, SCREEN_WIDTH - 80, COLOR_GRAY);
    
    // Draw menu items
    int y = MENU_START_Y;
    char value_buf[32];
    
    for (int i = 0; i < MENU_ITEM_COUNT; i++) {
        menu_item_t item = (menu_item_t)i;
        
        if (item == MENU_SEPARATOR) {
            // Draw separator line
            draw_hline(screen, 40, y + LINE_HEIGHT / 2, SCREEN_WIDTH - 80, COLOR_GRAY);
            y += LINE_HEIGHT;
            continue;
        }
        
        bool is_selected = (i == selected);
        bool is_enabled = is_selectable(item);
        
        uint8_t label_color = is_selected ? COLOR_YELLOW : (is_enabled ? COLOR_WHITE : COLOR_GRAY);
        uint8_t value_color = is_selected ? COLOR_YELLOW : COLOR_WHITE;
        
        // Draw selection indicator
        if (is_selected) {
            draw_text(screen, MENU_X - 12, y, ">", COLOR_YELLOW);
        }
        
        // Draw label
        const char *label = get_menu_label(item);
        draw_text(screen, MENU_X, y, label, label_color);
        
        // Draw value (for settings items)
        get_menu_value(item, value_buf, sizeof(value_buf));
        if (value_buf[0]) {
            // Right-align value
            int value_width = (int)strlen(value_buf) * FONT_WIDTH;
            int value_x = SCREEN_WIDTH - MENU_X - value_width;
            
            // Dim the value for disabled items
            if (!is_enabled) value_color = COLOR_GRAY;
            draw_text(screen, value_x, y, value_buf, value_color);
        }
        
        y += LINE_HEIGHT;
    }
    
    // Draw help text at bottom
    const char *help = "UP/DOWN: SELECT   LEFT/RIGHT: CHANGE   A: CONFIRM";
    int help_width = (int)strlen(help) * FONT_WIDTH;
    int help_x = (SCREEN_WIDTH - help_width) / 2;
    draw_text(screen, help_x, SCREEN_HEIGHT - 20, help, COLOR_GRAY);
}

// Parse INI file line
static bool parse_ini_line(const char *line, const char *key, char *value, size_t value_size) {
    // Skip whitespace
    while (*line == ' ' || *line == '\t') line++;
    
    // Check if line starts with key
    size_t key_len = strlen(key);
    if (strncasecmp(line, key, key_len) != 0) return false;
    
    line += key_len;
    
    // Skip whitespace and equals sign
    while (*line == ' ' || *line == '\t') line++;
    if (*line != '=') return false;
    line++;
    while (*line == ' ' || *line == '\t') line++;
    
    // Copy value (strip trailing whitespace/newline)
    size_t i = 0;
    while (*line && *line != '\n' && *line != '\r' && i < value_size - 1) {
        value[i++] = *line++;
    }
    value[i] = '\0';
    
    // Strip trailing whitespace
    while (i > 0 && (value[i-1] == ' ' || value[i-1] == '\t')) {
        value[--i] = '\0';
    }
    
    return true;
}

void settings_load(void) {
    FIL file;
    char line[128];
    char value[64];
    
    // Set defaults first
    g_settings.cpu_freq = 504;
    g_settings.psram_freq = 166;
    g_settings.fm_sound = true;
    g_settings.dac_sound = true;
    g_settings.crt_effect = false;
    g_settings.crt_dim = 60;
    
    FRESULT res = f_open(&file, "/genesis/settings.ini", FA_READ);
    if (res != FR_OK) {
        // Try uppercase
        res = f_open(&file, "/GENESIS/settings.ini", FA_READ);
        if (res != FR_OK) {
            return;  // No settings file, use defaults
        }
    }
    
    // Read line by line
    while (f_gets(line, sizeof(line), &file)) {
        if (parse_ini_line(line, "cpu_freq", value, sizeof(value))) {
            int freq = atoi(value);
            if (freq == 378 || freq == 504) {
                g_settings.cpu_freq = (uint16_t)freq;
            }
        }
        else if (parse_ini_line(line, "psram_freq", value, sizeof(value))) {
            int freq = atoi(value);
            if (freq == 133 || freq == 166) {
                g_settings.psram_freq = (uint16_t)freq;
            }
        }
        else if (parse_ini_line(line, "fm_sound", value, sizeof(value))) {
            g_settings.fm_sound = (strcasecmp(value, "on") == 0 || strcmp(value, "1") == 0);
        }
        else if (parse_ini_line(line, "dac_sound", value, sizeof(value))) {
            g_settings.dac_sound = (strcasecmp(value, "on") == 0 || strcmp(value, "1") == 0);
        }
        else if (parse_ini_line(line, "crt_effect", value, sizeof(value))) {
            g_settings.crt_effect = (strcasecmp(value, "on") == 0 || strcmp(value, "1") == 0);
        }
        else if (parse_ini_line(line, "crt_dim", value, sizeof(value))) {
            int dim = atoi(value);
            if (dim >= 10 && dim <= 90) {
                g_settings.crt_dim = (uint8_t)dim;
            }
        }
    }
    
    f_close(&file);
}

bool settings_save(void) {
    FIL file;
    UINT bw;
    char buf[256];
    
    // Ensure genesis directory exists
    f_mkdir("/genesis");
    
    FRESULT res = f_open(&file, "/genesis/settings.ini", FA_WRITE | FA_CREATE_ALWAYS);
    if (res != FR_OK) {
        return false;
    }
    
    // Write settings in INI format
    snprintf(buf, sizeof(buf),
        "; MurmGenesis Settings\n"
        "; This file is auto-generated. Edit with care.\n"
        "\n"
        "cpu_freq = %d\n"
        "psram_freq = %d\n"
        "fm_sound = %s\n"
        "dac_sound = %s\n"
        "crt_effect = %s\n"
        "crt_dim = %d\n",
        g_settings.cpu_freq,
        g_settings.psram_freq,
        g_settings.fm_sound ? "on" : "off",
        g_settings.dac_sound ? "on" : "off",
        g_settings.crt_effect ? "on" : "off",
        g_settings.crt_dim);
    
    res = f_write(&file, buf, strlen(buf), &bw);
    f_close(&file);
    
    return (res == FR_OK && bw == strlen(buf));
}

// External audio control flags from main.c
extern bool sn76489_enabled;
extern bool ym2612_enabled;
extern bool ym2612_fm_enabled;
extern bool ym2612_dac_enabled;

// External CRT control from HDMI.c
extern void graphics_set_crt_effect(bool enabled, uint8_t dim_percent);

void settings_apply_runtime(void) {
    // Apply settings that can be changed without restart
    
    // Audio settings
    // FM SOUND controls FM channels 1-6 (when not in DAC mode)
    // DAC SOUND controls DAC samples (channel 6 in DAC mode) and PSG
    ym2612_enabled = g_settings.fm_sound || g_settings.dac_sound;  // Enable chip if either is on
    ym2612_fm_enabled = g_settings.fm_sound;   // FM channels mute control
    ym2612_dac_enabled = g_settings.dac_sound; // DAC mute control
    sn76489_enabled = g_settings.dac_sound;    // PSG follows DAC setting
    
    // CRT settings
    graphics_set_crt_effect(g_settings.crt_effect, g_settings.crt_dim);
}

settings_result_t settings_menu_show(uint8_t *screen_buffer) {
    return settings_menu_show_with_restore(screen_buffer, NULL);
}

settings_result_t settings_menu_show_with_restore(uint8_t *screen_buffer, uint8_t *saved_screen) {
    // Note: If saved_screen is provided, caller is responsible for saving screen content
    // before calling this function. We only use it for restore on cancel.
    
    // Save current audio state and mute while in settings menu
    bool saved_ym2612_enabled = ym2612_enabled;
    bool saved_ym2612_fm_enabled = ym2612_fm_enabled;
    bool saved_ym2612_dac_enabled = ym2612_dac_enabled;
    bool saved_sn76489_enabled = sn76489_enabled;
    
    // Disable audio output completely while in settings menu
    audio_set_enabled(false);
    
    // Also mute the emulated sound chips
    ym2612_enabled = false;
    ym2612_fm_enabled = false;
    ym2612_dac_enabled = false;
    sn76489_enabled = false;
    
    // Flush silence to DMA buffer to stop any repeating sound
    audio_flush_silence();
    
    // Copy current settings to edit buffer
    memcpy(&edit_settings, &g_settings, sizeof(settings_t));
    
    int selected = 0;
    uint32_t prev_buttons = 0;
    uint32_t hold_counter = 0;
    const uint32_t REPEAT_DELAY = 10;
    const uint32_t REPEAT_RATE = 3;
    
    // Clear screen and draw settings menu
    memset(screen_buffer, COLOR_BLACK, SCREEN_WIDTH * SCREEN_HEIGHT);
    draw_settings_menu(screen_buffer, selected);
    
    // Small delay to let display settle
    sleep_ms(100);
    
    while (true) {
        // Read gamepad
        nespad_read();
        uint32_t buttons = nespad_state;
        
#ifdef USB_HID_ENABLED
        // Poll USB and merge USB gamepad state
        usbhid_task();
        if (usbhid_gamepad_connected()) {
            usbhid_gamepad_state_t gp;
            usbhid_get_gamepad_state(&gp);
            
            if (gp.dpad & 0x01) buttons |= DPAD_UP;
            if (gp.dpad & 0x02) buttons |= DPAD_DOWN;
            if (gp.dpad & 0x04) buttons |= DPAD_LEFT;
            if (gp.dpad & 0x08) buttons |= DPAD_RIGHT;
            if (gp.buttons & 0x01) buttons |= DPAD_A;
            if (gp.buttons & 0x40) buttons |= DPAD_START;
        }
#endif
        
        // Detect button press
        uint32_t buttons_pressed = buttons & ~prev_buttons;
        
        // Key repeat for up/down/left/right
        bool up_repeat = false, down_repeat = false;
        bool left_repeat = false, right_repeat = false;
        
        if (buttons & (DPAD_UP | DPAD_DOWN | DPAD_LEFT | DPAD_RIGHT)) {
            hold_counter++;
            if (hold_counter > REPEAT_DELAY && ((hold_counter - REPEAT_DELAY) % REPEAT_RATE == 0)) {
                if (buttons & DPAD_UP) up_repeat = true;
                if (buttons & DPAD_DOWN) down_repeat = true;
                if (buttons & DPAD_LEFT) left_repeat = true;
                if (buttons & DPAD_RIGHT) right_repeat = true;
            }
        } else {
            hold_counter = 0;
        }
        prev_buttons = buttons;
        
        bool needs_redraw = false;
        
        // Navigate up
        if ((buttons_pressed & DPAD_UP) || up_repeat) {
            selected = get_next_selectable(selected, -1);
            needs_redraw = true;
        }
        
        // Navigate down
        if ((buttons_pressed & DPAD_DOWN) || down_repeat) {
            selected = get_next_selectable(selected, 1);
            needs_redraw = true;
        }
        
        // Change value left
        if ((buttons_pressed & DPAD_LEFT) || left_repeat) {
            if (selected < MENU_SEPARATOR) {
                change_setting((menu_item_t)selected, -1);
                needs_redraw = true;
            }
        }
        
        // Change value right
        if ((buttons_pressed & DPAD_RIGHT) || right_repeat) {
            if (selected < MENU_SEPARATOR) {
                change_setting((menu_item_t)selected, 1);
                needs_redraw = true;
            }
        }
        
        // Confirm selection
        if (buttons_pressed & (DPAD_A | DPAD_START)) {
            switch ((menu_item_t)selected) {
                case MENU_SAVE_RESTART:
                    // Copy edited settings to global
                    memcpy(&g_settings, &edit_settings, sizeof(settings_t));
                    return SETTINGS_RESULT_SAVE_RESTART;
                    
                case MENU_RESTART:
                    return SETTINGS_RESULT_RESTART;
                    
                case MENU_CANCEL: {
                    // Wait for all buttons to be released for multiple consecutive reads
                    int release_count = 0;
                    while (release_count < 5) {
                        sleep_ms(50);
                        nespad_read();
                        if (nespad_state & (DPAD_A | DPAD_B | DPAD_START | DPAD_SELECT)) {
                            release_count = 0;  // Reset if any button pressed
                        } else {
                            release_count++;  // Count consecutive releases
                        }
                    }
                    // Extra delay after confirmed release
                    sleep_ms(100);
                    // Restore audio state
                    ym2612_enabled = saved_ym2612_enabled;
                    ym2612_fm_enabled = saved_ym2612_fm_enabled;
                    ym2612_dac_enabled = saved_ym2612_dac_enabled;
                    sn76489_enabled = saved_sn76489_enabled;
                    audio_set_enabled(true);
                    return SETTINGS_RESULT_CANCEL;
                }
                    
                default:
                    // For settings items, toggle or change
                    change_setting((menu_item_t)selected, 1);
                    needs_redraw = true;
                    break;
            }
        }
        
        // B button or Select+Start = cancel
        if (buttons_pressed & DPAD_B) {
            // Wait for all buttons to be released for multiple consecutive reads
            int release_count = 0;
            while (release_count < 5) {
                sleep_ms(50);
                nespad_read();
                if (nespad_state & (DPAD_A | DPAD_B | DPAD_START | DPAD_SELECT)) {
                    release_count = 0;  // Reset if any button pressed
                } else {
                    release_count++;  // Count consecutive releases
                }
            }
            // Extra delay after confirmed release
            sleep_ms(100);
            // Restore audio state
            ym2612_enabled = saved_ym2612_enabled;
            ym2612_fm_enabled = saved_ym2612_fm_enabled;
            ym2612_dac_enabled = saved_ym2612_dac_enabled;
            sn76489_enabled = saved_sn76489_enabled;
            audio_set_enabled(true);
            return SETTINGS_RESULT_CANCEL;
        }
        
        if (needs_redraw) {
            draw_settings_menu(screen_buffer, selected);
        }
        
        sleep_ms(50);
    }
    
    // Shouldn't reach here, but just in case - caller will handle screen restore
    // Restore audio state
    ym2612_enabled = saved_ym2612_enabled;
    ym2612_fm_enabled = saved_ym2612_fm_enabled;
    ym2612_dac_enabled = saved_ym2612_dac_enabled;
    sn76489_enabled = saved_sn76489_enabled;
    audio_set_enabled(true);
    return SETTINGS_RESULT_CANCEL;
}

bool settings_check_hotkey(void) {
    // Check if Start+Select are both pressed
    nespad_read();
    
    bool start_select = (nespad_state & DPAD_SELECT) && (nespad_state & DPAD_START);
    
#ifdef USB_HID_ENABLED
    if (!start_select && usbhid_gamepad_connected()) {
        usbhid_gamepad_state_t gp;
        usbhid_get_gamepad_state(&gp);
        // Start=0x40, Select=0x80
        start_select = (gp.buttons & 0x40) && (gp.buttons & 0x80);
    }
#endif
    
    return start_select;
}
