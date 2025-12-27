#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include "inttypes.h"
#include "stdbool.h"

#include "hardware/pio.h"
#include "board_config.h"

// HDMI uses PIO0, Audio uses PIO1
#define PIO_VIDEO pio0
#define PIO_VIDEO_ADDR pio0
#define VIDEO_DMA_IRQ (DMA_IRQ_0)

// HDMI_BASE_PIN is already defined in board_config.h

#define HDMI_PIN_invert_diffpairs (1)
#define HDMI_PIN_RGB_notBGR (1)
#define beginHDMI_PIN_data (HDMI_BASE_PIN+2)
#define beginHDMI_PIN_clk (HDMI_BASE_PIN)

#define TEXTMODE_COLS 53
#define TEXTMODE_ROWS 30

#define RGB888(r, g, b) ((r<<16) | (g << 8 ) | b )

static const uint8_t textmode_palette[16] = {
    200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215
};

static void graphics_set_flashmode(bool flash_line, bool flash_frame) {
    // dummy
}

#ifdef __cplusplus
}
#endif
