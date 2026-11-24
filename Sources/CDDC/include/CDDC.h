// CDDC: the smallest C surface over the vendored m1ddc transport (see upstream/PROVENANCE.md).
// Everything private to macOS stays behind this header. Not thread-safe by itself: callers
// (DisplayCore.DisplayController) serialize every call on one worker.
#ifndef CDDC_H
#define CDDC_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CDDC_MAX_DISPLAYS 8

typedef struct {
    uint32_t displayID;        // CGDirectDisplayID: a session handle only
    char uuid[64];             // macOS system UUID of the display
    char edidUUID[64];         // may be empty
    char productName[64];
    char manufacturer[32];
    char alphaSerial[32];      // may be empty
    uint32_t vendor;
    uint32_t model;
    uint32_t serial;
    bool isBuiltIn;
    bool hasDDCEndpoint;       // an external IOAVService was resolved for this display
} CDDCDisplay;

typedef enum {
    CDDC_OK = 0,
    CDDC_NO_DISPLAY = 1,       // uuid not in the table from the last list call
    CDDC_NO_TRANSPORT = 2,     // display known, but no DDC endpoint (built-in, or not resolvable)
    CDDC_UNSUPPORTED = 3,      // display answered "unsupported VCP code"
    CDDC_NO_VALID_REPLY = 4,   // all attempts returned an empty, echoed or corrupt reply
    CDDC_IO_ERROR = 5,         // IOKit returned an error (see ioReturn)
    CDDC_REFUSED = 6           // the bridge refuses this VCP code (write allowlist)
} CDDCStatus;

// Rescans macOS displays, rebuilds the endpoint table (releases the previous one) and returns the
// count written to `out` (at most `max`).
int cddc_list_displays(CDDCDisplay *out, int max);

// Reads a VCP feature. Up to `attempts` tries with `readWaitMicros` before each reply read.
CDDCStatus cddc_read(const char *uuid, uint8_t vcp, uint32_t readWaitMicros, int attempts,
                     uint16_t *current, uint16_t *maximum, int32_t *ioReturn);

// Writes a VCP feature. A hard denylist (factory resets, power, settings save, identity codes) is
// refused with CDDC_REFUSED; which other codes may be written is decided in DisplayCore.
CDDCStatus cddc_write(const char *uuid, uint8_t vcp, uint16_t value, int32_t *ioReturn);

#ifdef __cplusplus
}
#endif

#endif
