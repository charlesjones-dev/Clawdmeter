#include "keymap.h"
#include "data.h"
#include <Preferences.h>
#include <Arduino.h>

// bindings[side][0] = HID usage id, [side][1] = modifier bits. Key 0 + mod 0 = disabled.
static uint8_t bindings[2][2] = {
    {0x2C, 0x00},   // left: Space
    {0x2B, 0x02},   // right: Tab + LEFT_SHIFT
};
static const char* const NVS_KEYS[2][2] = {{"kl_k", "kl_m"}, {"kr_k", "kr_m"}};

static void log_map(const char* why) {
    Serial.printf("Keymap %s: left=0x%02X/0x%02X right=0x%02X/0x%02X\n", why,
                  bindings[0][0], bindings[0][1], bindings[1][0], bindings[1][1]);
}

void keymap_init(void) {
    Preferences prefs;
    prefs.begin("clawdmeter", true);
    // Only adopt a saved mapping if both halves of a side are present (0xFF = never saved).
    for (int s = 0; s < 2; s++) {
        uint8_t k = prefs.getUChar(NVS_KEYS[s][0], 0xFF);
        uint8_t m = prefs.getUChar(NVS_KEYS[s][1], 0xFF);
        if (k != 0xFF && m != 0xFF) { bindings[s][0] = k; bindings[s][1] = m; }
    }
    prefs.end();
    log_map("init");
}

void keymap_apply(const UsageData* d) {
    if (!d || !d->has_keymap) return;
    const uint8_t want[2][2] = {{d->key_left[0], d->key_left[1]}, {d->key_right[0], d->key_right[1]}};
    bool changed = false;
    for (int s = 0; s < 2; s++)
        if (want[s][0] != bindings[s][0] || want[s][1] != bindings[s][1]) changed = true;
    if (!changed) return;

    Preferences prefs;
    prefs.begin("clawdmeter", false);
    for (int s = 0; s < 2; s++) {
        bindings[s][0] = want[s][0];
        bindings[s][1] = want[s][1];
        prefs.putUChar(NVS_KEYS[s][0], bindings[s][0]);
        prefs.putUChar(NVS_KEYS[s][1], bindings[s][1]);
    }
    prefs.end();
    log_map("updated from daemon");
}

void keymap_get(int side, uint8_t* key, uint8_t* mod) {
    if (side < 0 || side > 1) side = 0;
    if (key) *key = bindings[side][0];
    if (mod) *mod = bindings[side][1];
}
