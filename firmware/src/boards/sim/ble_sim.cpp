// BLE stub with two data sources. Implements ble.h without any transport,
// delivering payloads through the same ble_has_data()/ble_get_data() path
// main.cpp uses on hardware — so JSON parsing, usage-rate tracking, and the
// chime trigger all run for real.
//
//   scenario (default) — plays sim/scenario.jsonl in a loop (UI iteration, CI).
//   live (SIM_MODE=live) — follows the daemon's latest.json mirror
//     (~/.config/claude-usage-monitor/latest.json, or SIM_LIVE_FILE), so the
//     window shows the same numbers the board does. Playback keys are inert;
//     `d` still toggles the link for testing the pairing screen.
#include "../../ble.h"
#include "sim_platform.h"
#include <Arduino.h>
#include <ArduinoJson.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>

#define MAX_STATES 64
#define MAX_LINE   512

struct SimState {
    char json[MAX_LINE];
    char name[32];
    uint32_t hold_ms;
};

static SimState states[MAX_STATES];
static int      n_states = 0;
static int      cur = 0;
static bool     playing = true;
static bool     connected = true;
static bool     pending = false;      // a state is queued for main's next poll
static uint32_t delivered_ms = 0;

// ---- Live mode ----
static bool     live = false;
static char     live_path[512];
static time_t   live_mtime = 0;       // mtime of the last delivered file
static uint32_t live_check_ms = 0;
static char     live_json[MAX_LINE];
static char     live_stamp[16];       // "HH:MM:SS" of the last delivery, for the title
#define LIVE_POLL_MS   1000
#define LIVE_STALE_S   180            // ignore a mirror older than this at startup

static const char* FALLBACK[] = {
    "{\"name\":\"fresh\",\"s\":3.0,\"sr\":295,\"w\":12.0,\"wr\":9000,\"st\":\"allowed\",\"ok\":true}",
    "{\"name\":\"mid\",\"s\":48.0,\"sr\":150,\"w\":35.0,\"wr\":7200,\"st\":\"allowed\",\"ok\":true}",
    "{\"name\":\"high\",\"s\":92.0,\"sr\":30,\"w\":71.0,\"wr\":4600,\"st\":\"allowed\",\"ok\":true}",
    "{\"name\":\"reset+chime\",\"hold_ms\":4000,\"s\":2.0,\"sr\":298,\"w\":72.0,\"wr\":4500,\"st\":\"allowed\",\"c\":true,\"ok\":true}",
};

static void add_state(const char* line) {
    if (n_states >= MAX_STATES) return;
    size_t len = strlen(line);
    while (len && (line[len - 1] == '\n' || line[len - 1] == '\r')) len--;
    if (!len || line[0] == '#') return;   // blank lines / comments
    SimState* s = &states[n_states];
    if (len >= MAX_LINE) len = MAX_LINE - 1;
    memcpy(s->json, line, len);
    s->json[len] = 0;
    s->hold_ms = 3000;
    snprintf(s->name, sizeof(s->name), "state %d", n_states + 1);
    // "name" and "hold_ms" ride along in the payload; main's parse_json
    // ignores unknown keys so the line is delivered as-is.
    JsonDocument doc;
    if (deserializeJson(doc, s->json) == DeserializationError::Ok) {
        s->hold_ms = doc["hold_ms"] | 3000;
        const char* nm = doc["name"] | (const char*)NULL;
        if (nm) snprintf(s->name, sizeof(s->name), "%s", nm);
    }
    n_states++;
}

static void load_scenario(void) {
    const char* tries[] = { getenv("SIM_SCENARIO"), "sim/scenario.jsonl",
                            "firmware/sim/scenario.jsonl", "../sim/scenario.jsonl" };
    FILE* f = NULL;
    for (const char* t : tries) {
        if (!t) continue;
        f = fopen(t, "r");
        if (f) { printf("[sim] scenario: %s\n", t); break; }
    }
    if (f) {
        char line[MAX_LINE];
        while (fgets(line, sizeof(line), f)) add_state(line);
        fclose(f);
    }
    if (!n_states) {
        printf("[sim] no scenario file found — using built-in states\n");
        for (const char* l : FALLBACK) add_state(l);
    }
}

static void refresh_title(void) {
    char t[128];
    if (live) {
        snprintf(t, sizeof(t), "Clawdmeter — live%s%s%s",
                 connected ? "" : " (link off)",
                 live_stamp[0] ? " · updated " : " · waiting for daemon",
                 live_stamp);
    } else {
        snprintf(t, sizeof(t), "Clawdmeter sim — %s[%d/%d] %s %s",
                 connected ? "" : "(disconnected) ",
                 cur + 1, n_states, states[cur].name,
                 playing ? "\xE2\x96\xB6" : "\xE2\x8F\xB8");
    }
    sim_display_set_title(t);
}

// Read the mirror file into live_json when its mtime moves. At startup a stale
// mirror (daemon not running for a while) is skipped so hours-old numbers are
// never rendered as live; the firmware's own idle logic then shows "No data".
static void live_poll(void) {
    struct stat st;
    if (stat(live_path, &st) != 0) return;
    if (st.st_mtime == live_mtime) return;
    if (live_mtime == 0 && time(NULL) - st.st_mtime > LIVE_STALE_S) {
        live_mtime = st.st_mtime;   // remember it, but don't deliver
        printf("[sim] live: %s is %lds old — waiting for a fresh write\n",
               live_path, (long)(time(NULL) - st.st_mtime));
        return;
    }
    FILE* f = fopen(live_path, "r");
    if (!f) return;
    size_t n = fread(live_json, 1, sizeof(live_json) - 1, f);
    fclose(f);
    live_json[n] = 0;
    while (n && (live_json[n - 1] == '\n' || live_json[n - 1] == '\r')) live_json[--n] = 0;
    if (!n) return;
    live_mtime = st.st_mtime;
    struct tm tmv; time_t now = time(NULL); localtime_r(&now, &tmv);
    strftime(live_stamp, sizeof(live_stamp), "%H:%M:%S", &tmv);
    pending = true;
    refresh_title();
}

void ble_init(void) {
    const char* mode = getenv("SIM_MODE");
    live = mode && strcmp(mode, "live") == 0;
    if (live) {
        const char* f = getenv("SIM_LIVE_FILE");
        if (f && *f) snprintf(live_path, sizeof(live_path), "%s", f);
        else {
            const char* home = getenv("HOME");
            snprintf(live_path, sizeof(live_path), "%s/.config/claude-usage-monitor/latest.json",
                     home ? home : ".");
        }
        live_stamp[0] = 0;
        printf("[sim] live mode: following %s\n", live_path);
        refresh_title();
        return;
    }
    load_scenario();
    pending = true;
    refresh_title();
}

void ble_tick(void) {
    if (live) {
        if (connected && !pending && millis() - live_check_ms >= LIVE_POLL_MS) {
            live_check_ms = millis();
            live_poll();
        }
        return;
    }
    if (!connected || pending || !playing || n_states == 0) return;
    if (millis() - delivered_ms >= states[cur].hold_ms) {
        cur = (cur + 1) % n_states;
        pending = true;
        refresh_title();
    }
}

ble_state_t ble_get_state(void) {
    return connected ? BLE_STATE_CONNECTED : BLE_STATE_DISCONNECTED;
}
const char* ble_get_device_name(void) { return "Clawdmeter (sim)"; }
const char* ble_get_mac_address(void) { return "00:51:4D:00:00:01"; }

void ble_clear_bonds(void) { printf("[sim] pair gesture completed — bonds cleared\n"); }
bool ble_has_bonds(void)   { return true; }

bool ble_has_data(void) { return connected && pending; }
const char* ble_get_data(void) {
    pending = false;
    delivered_ms = millis();
    return live ? live_json : states[cur].json;
}
void ble_send_ack(void)  {}
void ble_send_nack(void) { printf("[sim] payload NACKed — check the scenario JSON\n"); }
void ble_request_refresh(void) {}
void ble_set_battery_level(int pct) { (void)pct; }

void ble_keyboard_press(uint8_t key, uint8_t modifier) {
    printf("[sim] HID press key=0x%02X mod=0x%02X\n", key, modifier);
}
void ble_keyboard_release(void) { printf("[sim] HID release\n"); }

// ---- Playback controls (called from the sim_platform event pump) ----
void sim_playback_toggle(void) {
    if (live) return;   // nothing to play in live mode
    playing = !playing;
    delivered_ms = millis();   // restart the hold timer on resume
    refresh_title();
}
void sim_playback_step(int dir) {
    if (live || !n_states) return;
    playing = false;
    cur = (cur + dir + n_states) % n_states;
    pending = true;
    refresh_title();
}
void sim_playback_jump(int idx) {
    if (live || idx < 0 || idx >= n_states) return;
    playing = false;
    cur = idx;
    pending = true;
    refresh_title();
}
void sim_playback_toggle_link(void) {
    connected = !connected;
    refresh_title();
}
