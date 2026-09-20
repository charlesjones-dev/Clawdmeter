#pragma once
#include <stdint.h>

// Side-button key bindings. Each of the two screen-independent buttons sends
// one HID key (+ modifier byte) while held. The mapping comes from the daemon
// (config keys button_left / button_right, payload "bl"/"br" = [key, mod]) and
// is persisted in NVS so it survives reboots and works while unpaired.
// Defaults match the original firmware: Space (push-to-talk) and Shift+Tab.
enum { KEYMAP_LEFT = 0, KEYMAP_RIGHT = 1 };

struct UsageData;

void keymap_init(void);                           // load the saved mapping (or defaults)
void keymap_apply(const UsageData* d);            // adopt a daemon-supplied mapping; saves on change
void keymap_get(int side, uint8_t* key, uint8_t* mod);
