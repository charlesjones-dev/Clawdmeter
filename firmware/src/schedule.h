#pragma once
#include "data.h"

// Work-hours schedule. Two features hang off it:
//   - Off-hours screensaver: outside work hours, switch the usage view to the
//     splash (Clawd animations) after a stretch with no touch or button press.
//     A splash it put up itself is dismissed when work hours begin.
//   - Brightness: jump to one level when work hours begin and another when
//     they end. A PWR-button choice in between holds until the next change.
// The settings and the local wall-clock time arrive from the daemon ("sch" +
// "lt"); the clock then runs on millis(), so the schedule keeps working
// overnight with the host asleep.

// Adopt the payload's schedule and local time. Absent keys (older daemon,
// {"ok":false} beat) keep the previous values.
void schedule_apply(const UsageData* data);

// A touch or button press: restarts the screensaver's inactivity timer.
void schedule_note_input(void);

// Called every loop(): shows / dismisses the splash and sets brightness when due.
void schedule_tick(void);
