#pragma once
#include <Arduino.h>

struct UsageData {
    float session_pct;       // utilization 0-100 (5h window Pro/Max; spending % Enterprise)
    int session_reset_mins;  // minutes until reset
    float weekly_pct;        // 7-day utilization (Pro/Max only; 0 for Enterprise)
    int weekly_reset_mins;   // minutes until weekly reset (Pro/Max only)
    char status[16];         // "allowed", "limited", etc.
    bool chime;              // play the session-reset chime; false unless daemon opts in
    bool enterprise;         // true = Enterprise spending-limit account
    int time_pct;            // 0-100: fraction of billing period elapsed (Enterprise)
    int period_days;         // total billing period length in days (Enterprise)
    char reset_date[12];     // formatted reset date e.g. "Jul 1" (Enterprise)
    bool has_scoped;         // payload carried a model-scoped weekly window ("m") → third row
    float scoped_pct;        // model-scoped weekly utilization 0-100 (Fable today)
    int scoped_reset_mins;   // minutes until the model-scoped window resets
    char scoped_label[16];   // server-supplied row label, e.g. "Fable" (daemon clips to 15)
    bool has_keymap;         // payload carried "bl"/"br" side-button key bindings
    uint8_t key_left[2];     // [HID usage id, modifier bits] for the left button
    uint8_t key_right[2];    // same for the right button (boards without one ignore it)
    long clock_epoch;        // local wall-clock epoch (s) from daemon; 0 = not provided
    int  clock_fmt;          // 12 or 24 (hour format from daemon); defaults to 24
    bool ok;                 // data parse succeeded
    bool valid;              // false until first successful parse
};
