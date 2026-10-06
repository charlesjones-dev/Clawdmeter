#pragma once
#include <stdint.h>

// User-controlled display brightness, persisted to NVS. The middle (PWR)
// button short-press cycles through the levels via brightness_cycle(); the
// work-hours schedule (schedule.cpp) jumps levels via brightness_set_level().
// idle owns the actual panel brightness, so this routes the chosen level
// through idle_set_awake_brightness().
void    brightness_init(void);    // load saved level from NVS and apply
void    brightness_cycle(void);   // advance to next level, save, apply
void    brightness_set_level(uint8_t idx);   // jump to a level (0 = dimmest, clamped), save, apply
uint8_t brightness_get(void);     // current PWM level (0..255)
