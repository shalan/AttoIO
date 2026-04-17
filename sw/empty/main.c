/*
 * empty/main.c — the simplest possible AttoIO firmware.
 *
 * Purpose: validate the build + load + boot chain. Does nothing
 * productive. Loops forever with WFI so the core is idle.
 */

#include "../attoio.h"

int main(void) {
    while (1) {
        wfi();
    }
}
