# Controller Button Mapping

## NES Controller (3-button mode)

| NES Button | Genesis Button | Notes |
|------------|---------------|-------|
| D-pad | D-pad | Direct mapping |
| A | A | |
| B | B | |
| A + B | A | Jump combo for easier platforming |
| Start | Start | |
| Select + A | C | Button combo required |
| Select + B | C | Button combo required |
| Select + Start | Reset | Return to ROM selector |

## SNES Controller (6-button mode)

The emulator automatically detects SNES controllers and provides full 6-button support.

| SNES Button | Genesis Button | Action (typical) | Physical Position |
|-------------|---------------|------------------|-------------------|
| D-pad | D-pad | Movement | D-pad |
| B (bottom) | A | Jump | Bottom face button |
| A (right) | B | Primary action (shoot/attack) | Right face button |
| Y (left) | C | Secondary action (special) | Left face button |
| X (top) | C | Secondary action (alternate) | Top face button |
| L (shoulder) | A | Jump (alternate) | Left shoulder |
| R (shoulder) | B | Primary action (alternate) | Right shoulder |
| Start | Start | Pause/Menu | |
| Select + Start | Reset | Return to ROM selector | |

**Note:** The shoulder buttons (L/R) provide duplicate access to jump and primary action for comfortable one-handed gameplay or alternate control schemes.

## Genesis Controller Reference

For reference, the Genesis/Mega Drive controller has:
- **3-button:** D-pad, A, B, C, Start
- **6-button:** D-pad, A, B, C, X, Y, Z, Start, Mode

Current implementation maps SNES buttons primarily to the 3-button layout with shoulder buttons as alternates.

## Technical Details

- Controller detection is automatic based on button state
- SNES controllers are identified by the presence of extended buttons (X, Y, L, R)
- Both NES and SNES controllers can be used simultaneously on ports 1 and 2
- Button states are read at ~60Hz for responsive input
