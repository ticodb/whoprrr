@import Foundation;
@import IOKit;
@import CoreGraphics;

#include "CDDC.h"
#include "upstream/ioregistry.h"
#include "upstream/i2c.h"

// -- Endpoint table: rebuilt on every cddc_list_displays, so handles never outlive a rescan.

typedef struct {
    char uuid[64];
    DDCTransport transport;
} Endpoint;

static Endpoint endpoints[CDDC_MAX_DISPLAYS];
static int endpointCount = 0;

static void releaseEndpoints(void) {
    for (int i = 0; i < endpointCount; i++) {
        if (endpoints[i].transport.service != NULL) {
            CFRelease(endpoints[i].transport.service);
        }
        endpoints[i].transport.service = NULL;
    }
    endpointCount = 0;
}

static void copyString(char *dst, size_t size, NSString *src) {
    dst[0] = '\0';
    if (src == nil) {
        return;
    }
    [src getCString:dst maxLength:size encoding:NSUTF8StringEncoding];
}

int cddc_list_displays(CDDCDisplay *out, int max) {
    releaseEndpoints();

    DisplayInfos infos[MAX_DISPLAYS];
    memset(infos, 0, sizeof(infos));
    int count = (int)getOnlineDisplayInfos(infos);

    int written = 0;
    for (int i = 0; i < count && written < max && written < CDDC_MAX_DISPLAYS; i++) {
        CDDCDisplay *d = out + written;
        memset(d, 0, sizeof(*d));
        d->displayID = infos[i].id;
        copyString(d->uuid, sizeof(d->uuid), infos[i].uuid);
        copyString(d->edidUUID, sizeof(d->edidUUID), infos[i].edid);
        copyString(d->productName, sizeof(d->productName), infos[i].productName);
        copyString(d->manufacturer, sizeof(d->manufacturer), infos[i].manufacturer);
        copyString(d->alphaSerial, sizeof(d->alphaSerial), infos[i].alphNumSerial);
        d->vendor = infos[i].vendor;
        d->model = infos[i].model;
        d->serial = infos[i].serial;
        d->isBuiltIn = CGDisplayIsBuiltin(infos[i].id) != 0;

        // Built-in panels never get a DDC endpoint: the bridge cannot be pointed at them.
        if (!d->isBuiltIn) {
            DDCTransport t = getDisplayDDCTransport(&infos[i]);
            if (t.service != NULL) {
                d->hasDDCEndpoint = true;
                Endpoint *e = &endpoints[endpointCount++];
                strlcpy(e->uuid, d->uuid, sizeof(e->uuid));
                e->transport = t;
            }
        }
        if (infos[i].adapter != MACH_PORT_NULL) {
            IOObjectRelease(infos[i].adapter);
        }
        written++;
    }
    return written;
}

static Endpoint *findEndpoint(const char *uuid) {
    for (int i = 0; i < endpointCount; i++) {
        if (strcmp(endpoints[i].uuid, uuid) == 0) {
            return &endpoints[i];
        }
    }
    return NULL;
}

CDDCStatus cddc_read(const char *uuid, uint8_t vcp, uint32_t readWaitMicros, int attempts,
                     uint16_t *current, uint16_t *maximum, int32_t *ioReturn) {
    if (ioReturn) { *ioReturn = 0; }
    Endpoint *e = findEndpoint(uuid);
    if (e == NULL) {
        return CDDC_NO_TRANSPORT;
    }
    if (attempts < 1) { attempts = 1; }
    if (readWaitMicros > 0) {
        ddcReadWait = readWaitMicros;
    }

    DDCPacket request = createDDCPacket(vcp);
    prepareDDCRead(&request);

    IOReturn err = kIOReturnSuccess;
    for (int attempt = 1; attempt <= attempts; attempt++) {
        if (attempt > 1) {
            usleep(DDC_RETRY_WAIT);
        }
        err = performDDCWriteAtChipAddress(e->transport.service, e->transport.chipAddress, &request);
        if (err) {
            continue;
        }
        DDCPacket reply = {};
        reply.inputAddr = request.inputAddr;
        err = performDDCReadAtChipAddress(e->transport.service, e->transport.chipAddress, &reply);
        if (err) {
            continue;
        }
        DDCReplyStatus status = checkDDCReply(reply.data, vcp);
        if (status == DDC_REPLY_OK) {
            DDCValue v = convertI2CtoDDC((char *)reply.data);
            *current = (uint16_t)v.curValue;
            *maximum = (uint16_t)v.maxValue;
            return CDDC_OK;
        }
        if (status == DDC_REPLY_UNSUPPORTED) {
            return CDDC_UNSUPPORTED;
        }
    }
    if (err) {
        if (ioReturn) { *ioReturn = (int32_t)err; }
        return CDDC_IO_ERROR;
    }
    return CDDC_NO_VALID_REPLY;
}

CDDCStatus cddc_write(const char *uuid, uint8_t vcp, uint16_t value, int32_t *ioReturn) {
    if (ioReturn) { *ioReturn = 0; }
    // Hard denylist: factory resets (0x04/05/06/08/0A), settings save, app-enable key, power,
    // identity/version codes. Policy for which other codes are writable lives in DisplayCore.
    switch (vcp) {
        case 0x02: case 0x04: case 0x05: case 0x06: case 0x08: case 0x0A:
        case 0xB0: case 0xC6: case 0xC8: case 0xC9: case 0xCA: case 0xD6: case 0xDF:
            return CDDC_REFUSED;
        default:
            break;
    }
    Endpoint *e = findEndpoint(uuid);
    if (e == NULL) {
        return CDDC_NO_TRANSPORT;
    }
    DDCPacket packet = createDDCPacket(vcp);
    prepareDDCWrite(&packet, value);
    IOReturn err = performDDCWriteAtChipAddress(e->transport.service, e->transport.chipAddress, &packet);
    if (err) {
        if (ioReturn) { *ioReturn = (int32_t)err; }
        return CDDC_IO_ERROR;
    }
    return CDDC_OK;
}
