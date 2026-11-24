// Whoprrr Mic: a virtual microphone for macOS (AudioServerPlugIn).
//
// A loopback device with one output stream and one input stream. The Whoprrr app writes processed microphone
// audio to the output stream; every app that records from "Whoprrr Mic" reads it from the input stream. All the
// audio work happens in the app; this driver only moves samples through a ring buffer and keeps time.
//
// Written from the AudioServerPlugIn contract (CoreAudio/AudioServerPlugIn.h). MIT-style: no third-party code.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

#define kWhopperDeviceUID   "WhopperMicDevice_UID"
#define kWhopperModelUID    "WhopperMicModel_UID"
#define kWhopperDeviceName  "Whoprrr Mic"
#define kWhopperManufacturer "Whoprrr"

enum {
    kObjectID_PlugIn       = kAudioObjectPlugInObject,
    kObjectID_Device       = 2,
    kObjectID_Stream_Input = 3,
    kObjectID_Stream_Output = 4,
};

#define kChannels      2
#define kRingFrames    16384            // power of two
#define kZeroTSPeriod  kRingFrames
static const Float64 kSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define kNumRates (sizeof(kSampleRates) / sizeof(kSampleRates[0]))

static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;
static Float64 gSampleRate = 48000.0;
static UInt64 gIOClients = 0;
static UInt64 gAnchorHostTime = 0;
static Float64 gTicksPerFrame = 0;
static UInt64 gTimestampSeed = 1;
static Float32 gRing[kRingFrames * kChannels];

static void UpdateTicksPerFrame(void) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    Float64 ticksPerSecond = 1.0e9 * (Float64)tb.denom / (Float64)tb.numer;
    gTicksPerFrame = ticksPerSecond / gSampleRate;
}

static AudioStreamBasicDescription CurrentFormat(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = gSampleRate; f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kChannels * 4; f.mFramesPerPacket = 1; f.mBytesPerFrame = kChannels * 4;
    f.mChannelsPerFrame = kChannels; f.mBitsPerChannel = 32;
    return f;
}

// MARK: - Interface forward declarations

static HRESULT   Q_QueryInterface(void*, REFIID, LPVOID*);
static ULONG     Q_AddRef(void*);
static ULONG     Q_Release(void*);
static OSStatus  Q_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus  Q_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus  Q_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus  Q_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus  Q_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus  Q_PerformConfigChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus  Q_AbortConfigChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean   Q_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus  Q_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus  Q_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus  Q_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus  Q_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus  Q_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus  Q_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus  Q_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus  Q_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus  Q_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus  Q_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus  Q_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Q_QueryInterface, Q_AddRef, Q_Release,
    Q_Initialize, Q_CreateDevice, Q_DestroyDevice, Q_AddDeviceClient, Q_RemoveDeviceClient,
    Q_PerformConfigChange, Q_AbortConfigChange,
    Q_HasProperty, Q_IsPropertySettable, Q_GetPropertyDataSize, Q_GetPropertyData, Q_SetPropertyData,
    Q_StartIO, Q_StopIO, Q_GetZeroTimeStamp, Q_WillDoIOOperation, Q_BeginIOOperation, Q_DoIOOperation, Q_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - Factory

void* WhopperMic_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}

// MARK: - IUnknown

static HRESULT Q_QueryInterface(void* d, REFIID uuid, LPVOID* out) {
    if (d != gDriverRef || out == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gMutex); gRefCount++; pthread_mutex_unlock(&gMutex);
        *out = gDriverRef; result = S_OK;
    } else { *out = NULL; }
    CFRelease(req);
    return result;
}
static ULONG Q_AddRef(void* d) { if (d != gDriverRef) return 0; pthread_mutex_lock(&gMutex); ULONG r = ++gRefCount; pthread_mutex_unlock(&gMutex); return r; }
static ULONG Q_Release(void* d) { if (d != gDriverRef) return 0; pthread_mutex_lock(&gMutex); if (gRefCount > 0) gRefCount--; ULONG r = gRefCount; pthread_mutex_unlock(&gMutex); return r; }

// MARK: - Lifecycle

static OSStatus Q_Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = host; UpdateTicksPerFrame();
    return kAudioHardwareNoError;
}
static OSStatus Q_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* o) {
    (void)d; (void)desc; (void)c; (void)o; return kAudioHardwareUnsupportedOperationError;
}
static OSStatus Q_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o) { (void)d; (void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus Q_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo* c) { (void)d; (void)o; (void)c; return kAudioHardwareNoError; }
static OSStatus Q_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo* c) { (void)d; (void)o; (void)c; return kAudioHardwareNoError; }

static OSStatus Q_PerformConfigChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 action, void* info) {
    (void)d; (void)info;
    if (o != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    gSampleRate = (Float64)action;            // the requested rate travels in `action`
    UpdateTicksPerFrame();
    memset(gRing, 0, sizeof(gRing));
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}
static OSStatus Q_AbortConfigChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void* i) { (void)d; (void)o; (void)a; (void)i; return kAudioHardwareNoError; }

// MARK: - Property helpers

#define IS(sel, scope_) (a->mSelector == (sel))
static Boolean RateIsSupported(Float64 r) { for (size_t i = 0; i < kNumRates; i++) if (kSampleRates[i] == r) return true; return false; }

// Common to every object.
static Boolean HasCommon(const AudioObjectPropertyAddress* a) {
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects: return true;
        default: return false;
    }
}

static Boolean HasProp(AudioObjectID obj, const AudioObjectPropertyAddress* a) {
    switch (obj) {
    case kObjectID_PlugIn:
        if (HasCommon(a)) return true;
        switch (a->mSelector) {
            case kAudioObjectPropertyManufacturer: case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyResourceBundle: return true;
        }
        return false;
    case kObjectID_Device:
        if (HasCommon(a)) return true;
        switch (a->mSelector) {
            case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: case kAudioDevicePropertyLatency: case kAudioDevicePropertyStreams:
            case kAudioObjectPropertyControlList: case kAudioDevicePropertySafetyOffset: case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates: case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyPreferredChannelsForStereo: case kAudioDevicePropertyZeroTimeStampPeriod: return true;
        }
        return false;
    case kObjectID_Stream_Input: case kObjectID_Stream_Output:
        if (HasCommon(a)) return true;
        switch (a->mSelector) {
            case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection: case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency: case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: return true;
        }
        return false;
    }
    return false;
}

static Boolean Q_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress* a) {
    (void)pid; return d == gDriverRef && a != NULL && HasProp(o, a);
}

static OSStatus Q_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* out) {
    (void)pid;
    if (d != gDriverRef || a == NULL || out == NULL) return kAudioHardwareBadObjectError;
    if (!HasProp(o, a)) return kAudioHardwareUnknownPropertyError;
    *out = false;
    if (o == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) *out = true;
    if ((o == kObjectID_Stream_Input || o == kObjectID_Stream_Output) &&
        (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) *out = true;
    return kAudioHardwareNoError;
}

// Sizes (and the data itself) come from one function so the two can never disagree.
static OSStatus Property(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32 qualSize, const void* qual,
                         UInt32 inSize, UInt32* outSize, void* out, Boolean wantData) {
    #define PUT(type, value, count_) do { UInt32 need = (UInt32)(sizeof(type) * (count_)); \
        if (wantData) { if (inSize < need) return kAudioHardwareBadPropertySizeError; *(type*)out = (value); } *outSize = need; return kAudioHardwareNoError; } while (0)
    #define PUT_CF(str) do { if (wantData) { if (inSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError; \
        *(CFStringRef*)out = CFSTR(str); } *outSize = sizeof(CFStringRef); return kAudioHardwareNoError; } while (0)
    #define PUT_IDS(ids, n) do { UInt32 need = (UInt32)(sizeof(AudioObjectID) * (n)); UInt32 give = wantData ? (inSize < need ? inSize / sizeof(AudioObjectID) : (n)) : (n); \
        if (wantData) memcpy(out, ids, give * sizeof(AudioObjectID)); *outSize = (UInt32)(give * sizeof(AudioObjectID)); return kAudioHardwareNoError; } while (0)

    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
        if (obj == kObjectID_PlugIn) PUT(AudioClassID, kAudioObjectClassID, 1);
        if (obj == kObjectID_Device) PUT(AudioClassID, kAudioObjectClassID, 1);
        PUT(AudioClassID, kAudioObjectClassID, 1);
    case kAudioObjectPropertyClass:
        if (obj == kObjectID_PlugIn) PUT(AudioClassID, kAudioPlugInClassID, 1);
        if (obj == kObjectID_Device) PUT(AudioClassID, kAudioDeviceClassID, 1);
        PUT(AudioClassID, kAudioStreamClassID, 1);
    case kAudioObjectPropertyOwner:
        if (obj == kObjectID_PlugIn) PUT(AudioObjectID, kAudioObjectUnknown, 1);
        if (obj == kObjectID_Device) PUT(AudioObjectID, kObjectID_PlugIn, 1);
        PUT(AudioObjectID, kObjectID_Device, 1);
    case kAudioObjectPropertyManufacturer: PUT_CF(kWhopperManufacturer);
    case kAudioObjectPropertyName:
        if (obj == kObjectID_Device) PUT_CF(kWhopperDeviceName);
        if (obj == kObjectID_Stream_Input) PUT_CF("Whoprrr Mic Input");
        PUT_CF("Whopper Mic Output");
    case kAudioObjectPropertyOwnedObjects:
        if (obj == kObjectID_PlugIn) { AudioObjectID ids[] = { kObjectID_Device }; PUT_IDS(ids, 1); }
        if (obj == kObjectID_Device) { AudioObjectID ids[] = { kObjectID_Stream_Input, kObjectID_Stream_Output }; PUT_IDS(ids, 2); }
        *outSize = 0; return kAudioHardwareNoError;
    case kAudioPlugInPropertyDeviceList: { AudioObjectID ids[] = { kObjectID_Device }; PUT_IDS(ids, 1); }
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        if (qualSize != sizeof(CFStringRef) || qual == NULL) return kAudioHardwareBadPropertySizeError;
        AudioObjectID r = CFEqual(*(CFStringRef*)qual, CFSTR(kWhopperDeviceUID)) ? kObjectID_Device : kAudioObjectUnknown;
        PUT(AudioObjectID, r, 1);
    }
    case kAudioPlugInPropertyResourceBundle: PUT_CF("");

    // Device
    case kAudioDevicePropertyDeviceUID: PUT_CF(kWhopperDeviceUID);
    case kAudioDevicePropertyModelUID: PUT_CF(kWhopperModelUID);
    case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual, 1);
    case kAudioDevicePropertyRelatedDevices: { AudioObjectID ids[] = { kObjectID_Device }; PUT_IDS(ids, 1); }
    case kAudioDevicePropertyClockDomain: PUT(UInt32, 0, 1);
    case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1, 1);
    case kAudioDevicePropertyDeviceIsRunning: { pthread_mutex_lock(&gMutex); UInt32 v = gIOClients > 0; pthread_mutex_unlock(&gMutex); PUT(UInt32, v, 1); }
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        PUT(UInt32, a->mScope == kAudioObjectPropertyScopeInput ? 1 : 0, 1);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, 0, 1);
    case kAudioDevicePropertyLatency: PUT(UInt32, 0, 1);
    case kAudioDevicePropertyStreams: {
        if (a->mScope == kAudioObjectPropertyScopeInput) { AudioObjectID ids[] = { kObjectID_Stream_Input }; PUT_IDS(ids, 1); }
        if (a->mScope == kAudioObjectPropertyScopeOutput) { AudioObjectID ids[] = { kObjectID_Stream_Output }; PUT_IDS(ids, 1); }
        AudioObjectID ids[] = { kObjectID_Stream_Input, kObjectID_Stream_Output }; PUT_IDS(ids, 2);
    }
    case kAudioObjectPropertyControlList: *outSize = 0; return kAudioHardwareNoError;
    case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0, 1);
    case kAudioDevicePropertyNominalSampleRate: { pthread_mutex_lock(&gMutex); Float64 r = gSampleRate; pthread_mutex_unlock(&gMutex); PUT(Float64, r, 1); }
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        UInt32 need = (UInt32)(sizeof(AudioValueRange) * kNumRates);
        if (wantData) {
            UInt32 n = inSize / sizeof(AudioValueRange); if (n > kNumRates) n = (UInt32)kNumRates;
            AudioValueRange* r = (AudioValueRange*)out;
            for (UInt32 i = 0; i < n; i++) { r[i].mMinimum = kSampleRates[i]; r[i].mMaximum = kSampleRates[i]; }
            *outSize = (UInt32)(n * sizeof(AudioValueRange));
        } else *outSize = need;
        return kAudioHardwareNoError;
    }
    case kAudioDevicePropertyIsHidden: PUT(UInt32, 0, 1);
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        UInt32 need = 2 * sizeof(UInt32);
        if (wantData) { if (inSize < need) return kAudioHardwareBadPropertySizeError; ((UInt32*)out)[0] = 1; ((UInt32*)out)[1] = 2; }
        *outSize = need; return kAudioHardwareNoError;
    }
    case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kZeroTSPeriod, 1);

    // Streams
    case kAudioStreamPropertyIsActive: PUT(UInt32, 1, 1);
    case kAudioStreamPropertyDirection: PUT(UInt32, obj == kObjectID_Stream_Input ? 1 : 0, 1);
    case kAudioStreamPropertyTerminalType:
        PUT(UInt32, obj == kObjectID_Stream_Input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker, 1);
    case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1, 1);
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: {
        pthread_mutex_lock(&gMutex); AudioStreamBasicDescription f = CurrentFormat(); pthread_mutex_unlock(&gMutex);
        PUT(AudioStreamBasicDescription, f, 1);
    }
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
        UInt32 need = (UInt32)(sizeof(AudioStreamRangedDescription) * kNumRates);
        if (wantData) {
            UInt32 n = inSize / sizeof(AudioStreamRangedDescription); if (n > kNumRates) n = (UInt32)kNumRates;
            AudioStreamRangedDescription* r = (AudioStreamRangedDescription*)out;
            for (UInt32 i = 0; i < n; i++) {
                pthread_mutex_lock(&gMutex); Float64 keep = gSampleRate; gSampleRate = kSampleRates[i];
                r[i].mFormat = CurrentFormat(); gSampleRate = keep; pthread_mutex_unlock(&gMutex);
                r[i].mSampleRateRange.mMinimum = kSampleRates[i]; r[i].mSampleRateRange.mMaximum = kSampleRates[i];
            }
            *outSize = (UInt32)(n * sizeof(AudioStreamRangedDescription));
        } else *outSize = need;
        return kAudioHardwareNoError;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Q_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress* a,
                                      UInt32 qs, const void* q, UInt32* outSize) {
    (void)pid;
    if (d != gDriverRef || a == NULL || outSize == NULL) return kAudioHardwareBadObjectError;
    if (!HasProp(o, a)) return kAudioHardwareUnknownPropertyError;
    return Property(o, a, qs, q, 0, outSize, NULL, false);
}

static OSStatus Q_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress* a,
                                  UInt32 qs, const void* q, UInt32 inSize, UInt32* outSize, void* out) {
    (void)pid;
    if (d != gDriverRef || a == NULL || outSize == NULL || out == NULL) return kAudioHardwareBadObjectError;
    if (!HasProp(o, a)) return kAudioHardwareUnknownPropertyError;
    return Property(o, a, qs, q, inSize, outSize, out, true);
}

static OSStatus Q_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress* a,
                                  UInt32 qs, const void* q, UInt32 size, const void* data) {
    (void)pid; (void)qs; (void)q;
    if (d != gDriverRef || a == NULL || data == NULL) return kAudioHardwareBadObjectError;
    Float64 want = 0;
    if (o == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        want = *(const Float64*)data;
    } else if ((o == kObjectID_Stream_Input || o == kObjectID_Stream_Output) &&
               (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (size != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)data;
        if (f->mFormatID != kAudioFormatLinearPCM || f->mChannelsPerFrame != kChannels || f->mBitsPerChannel != 32 ||
            !(f->mFormatFlags & kAudioFormatFlagIsFloat)) return kAudioDeviceUnsupportedFormatError;
        want = f->mSampleRate;
    } else return kAudioHardwareUnknownPropertyError;
    if (!RateIsSupported(want)) return kAudioDeviceUnsupportedFormatError;
    if (gHost) gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)want, NULL);
    return kAudioHardwareNoError;
}

// MARK: - IO

static OSStatus Q_StartIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client) {
    (void)client;
    if (d != gDriverRef || o != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIOClients == 0) { gAnchorHostTime = mach_absolute_time(); memset(gRing, 0, sizeof(gRing)); gTimestampSeed++; }
    gIOClients++;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus Q_StopIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client) {
    (void)client;
    if (d != gDriverRef || o != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex); if (gIOClients > 0) gIOClients--; pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus Q_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)client;
    if (d != gDriverRef || o != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    Float64 ticksPerPeriod = gTicksPerFrame * (Float64)kZeroTSPeriod;
    UInt64 now = mach_absolute_time();
    UInt64 periods = (UInt64)((Float64)(now - gAnchorHostTime) / ticksPerPeriod);
    *outSampleTime = (Float64)(periods * kZeroTSPeriod);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)periods * ticksPerPeriod);
    *outSeed = gTimestampSeed;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus Q_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client, UInt32 op, Boolean* willDo, Boolean* inPlace) {
    (void)client;
    if (d != gDriverRef || o != kObjectID_Device) return kAudioHardwareBadObjectError;
    *willDo = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix);
    *inPlace = true;
    return kAudioHardwareNoError;
}
static OSStatus Q_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo* i) {
    (void)d; (void)o; (void)c; (void)op; (void)n; (void)i; return kAudioHardwareNoError;
}
static OSStatus Q_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo* i) {
    (void)d; (void)o; (void)c; (void)op; (void)n; (void)i; return kAudioHardwareNoError;
}

static OSStatus Q_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames,
                                const AudioServerPlugInIOCycleInfo* info, void* mainBuf, void* secondaryBuf) {
    (void)stream; (void)client; (void)secondaryBuf;
    if (d != gDriverRef || o != kObjectID_Device) return kAudioHardwareBadObjectError;
    Float32* buf = (Float32*)mainBuf;
    if (op == kAudioServerPlugInIOOperationWriteMix) {
        UInt64 t = (UInt64)info->mOutputTime.mSampleTime;
        for (UInt32 i = 0; i < frames; i++) {
            UInt32 slot = (UInt32)((t + i) & (kRingFrames - 1));
            gRing[slot * 2] = buf[i * 2]; gRing[slot * 2 + 1] = buf[i * 2 + 1];
        }
    } else if (op == kAudioServerPlugInIOOperationReadInput) {
        UInt64 t = (UInt64)info->mInputTime.mSampleTime;
        for (UInt32 i = 0; i < frames; i++) {
            UInt32 slot = (UInt32)((t + i) & (kRingFrames - 1));
            buf[i * 2] = gRing[slot * 2]; buf[i * 2 + 1] = gRing[slot * 2 + 1];
            gRing[slot * 2] = 0; gRing[slot * 2 + 1] = 0;       // consume: never replay stale audio if the app stops writing
        }
    }
    return kAudioHardwareNoError;
}
