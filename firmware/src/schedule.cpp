#include <Arduino.h>
#include <time.h>
#include "schedule.h"
#include "brightness.h"
#include "ui.h"

static uint16_t work_start = 0;      // minutes since local midnight
static uint16_t work_end   = 0;      // may be 1440 (midnight); start == end = no work hours
static uint8_t  work_days  = 0x7F;   // bit 0 = Sunday … bit 6 = Saturday (tm_wday)
static uint32_t saver_ms   = 0;      // inactivity before the splash; 0 = off
static uint8_t  bright_work = 0;     // brightness level 1..N in work hours; 0 = leave alone
static uint8_t  bright_off  = 0;     // same, off-hours
static long     base_epoch = 0;      // local wall-clock epoch from "lt"; 0 = time unknown
static uint32_t base_ms    = 0;      // millis() when base_epoch landed
static uint32_t last_input_ms = 0;
static uint32_t last_eval_ms  = 0;
static int8_t   applied_period = -1; // brightness last set for: 1 work, 0 off-hours, -1 not yet
static bool     auto_shown = false;  // the splash is up because we put it there

void schedule_apply(const UsageData* data) {
    if (data->local_epoch > 0) {
        base_epoch = data->local_epoch;
        base_ms = millis();
    }
    if (!data->has_schedule) return;
    const uint16_t start = data->work_start < 1440 ? data->work_start : 0;
    const uint16_t end   = data->work_end <= 1440 ? data->work_end : 0;
    const uint8_t  days  = data->work_days & 0x7F;
    // New hours or levels take effect now rather than at the next change.
    if (start != work_start || end != work_end || days != work_days ||
        data->bright_work != bright_work || data->bright_off != bright_off) {
        applied_period = -1;
    }
    work_start  = start;
    work_end    = end;
    work_days   = days;
    saver_ms    = data->saver_after_s * 1000UL;
    bright_work = data->bright_work;
    bright_off  = data->bright_off;
}

void schedule_note_input(void) {
    last_input_ms = millis();
}

// The epoch is already local wall-clock, so gmtime() yields local fields.
static bool in_work_hours(time_t local) {
    if (work_start == work_end) return false;   // no work hours → always off-hours
    struct tm t;
    gmtime_r(&local, &t);
    const int m = t.tm_hour * 60 + t.tm_min;
    int day = t.tm_wday;
    if (work_start < work_end) {
        if (m < work_start || m >= work_end) return false;
    } else {                                    // overnight, e.g. 22:00-06:00
        if (m >= work_end && m < work_start) return false;
        if (m < work_end) day = (day + 6) % 7;  // past midnight: the shift began yesterday
    }
    return work_days & (1 << day);
}

void schedule_tick(void) {
    const screen_t cur = ui_get_current_screen();
    if (auto_shown && cur != SCREEN_SPLASH) auto_shown = false;   // user tapped back
    if (base_epoch == 0) return;                                  // no local time yet

    const uint32_t now = millis();
    if (now - last_eval_ms < 1000) return;      // minute-resolution schedule; check 1/s
    last_eval_ms = now;

    const time_t local = (time_t)(base_epoch + (now - base_ms) / 1000);
    const bool work = in_work_hours(local);

    if ((int8_t)work != applied_period) {
        applied_period = work;
        const uint8_t level = work ? bright_work : bright_off;
        if (level) brightness_set_level(level - 1);
    }

    if (work) {
        if (auto_shown) {
            ui_show_screen(SCREEN_USAGE);
            auto_shown = false;
        }
    } else if (saver_ms && cur == SCREEN_USAGE && now - last_input_ms >= saver_ms) {
        ui_show_screen(SCREEN_SPLASH);
        auto_shown = true;
    }
}
