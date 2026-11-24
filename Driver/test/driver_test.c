// Loads WhopperMic.driver like coreaudiod would (CFPlugIn), with a fake host, and checks its behaviour.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <unistd.h>

static int failures = 0;
#define CHECK(c, msg) do { if (c) printf("PASS %s\n", msg); else { printf("FAIL %s\n", msg); failures++; } } while (0)

static AudioServerPlugInDriverRef drv;
static AudioServerPlugInDriverInterface* I;
static AudioServerPlugInHostRef hostRef;
static UInt64 lastChangeAction = 0; static int changeRequests = 0;

static OSStatus H_PropertiesChanged(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress* a) { (void)h; (void)o; (void)n; (void)a; return 0; }
static OSStatus H_CopyFromStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef* d) { (void)h; (void)k; *d = NULL; return 0; }
static OSStatus H_WriteToStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d) { (void)h; (void)k; (void)d; return 0; }
static OSStatus H_DeleteFromStorage(AudioServerPlugInHostRef h, CFStringRef k) { (void)h; (void)k; return 0; }
static OSStatus H_RequestChange(AudioServerPlugInHostRef h, AudioObjectID o, UInt64 a, void* i) {
    (void)h; lastChangeAction = a; changeRequests++; return I->PerformDeviceConfigurationChange(drv, o, a, i);
}
static AudioServerPlugInHostInterface hostIface = { H_PropertiesChanged, H_CopyFromStorage, H_WriteToStorage, H_DeleteFromStorage, H_RequestChange };

static OSStatus get(AudioObjectID o, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, UInt32 qs, const void* q, void* out, UInt32 cap, UInt32* got) {
    AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    OSStatus st = I->GetPropertyDataSize(drv, o, 0, &a, qs, q, &size);
    if (st) return st;
    if (size > cap) return kAudioHardwareBadPropertySizeError;
    st = I->GetPropertyData(drv, o, 0, &a, qs, q, cap, &size, out);
    if (got) *got = size;
    return st;
}

static int cfEq(CFStringRef s, const char* c) { CFStringRef t = CFStringCreateWithCString(NULL, c, kCFStringEncodingUTF8); int r = CFEqual(s, t); CFRelease(t); return r; }

int main(int argc, char** argv) {
    if (argc < 2) { printf("usage: driver_test <path to .driver>\n"); return 2; }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)argv[1], strlen(argv[1]), true);
    CFPlugInRef plugin = CFPlugInCreate(NULL, url);
    CHECK(plugin != NULL, "bundle loads as a CFPlugIn");
    if (!plugin) return 1;
    CFArrayRef fac = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kAudioServerPlugInTypeUUID, plugin);
    CHECK(fac && CFArrayGetCount(fac) == 1, "declares one AudioServerPlugIn factory");
    drv = (AudioServerPlugInDriverRef)CFPlugInInstanceCreate(NULL, CFArrayGetValueAtIndex(fac, 0), kAudioServerPlugInTypeUUID);
    CHECK(drv != NULL, "factory returns the driver");
    I = *drv;
    hostRef = &hostIface;
    CHECK(I->Initialize(drv, hostRef) == 0, "Initialize");

    AudioObjectID ids[4]; UInt32 n = 0; OSStatus st;
    st = get(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, 0, NULL, ids, sizeof ids, &n);
    CHECK(st == 0 && n == sizeof(AudioObjectID), "plug-in lists exactly one device");
    AudioObjectID dev = ids[0];

    CFStringRef uid = CFSTR("WhopperMicDevice_UID"); AudioObjectID found = 0;
    st = get(kAudioObjectPlugInObject, kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, sizeof(uid), &uid, &found, sizeof found, NULL);
    CHECK(st == 0 && found == dev, "UID translates to the device");

    CFStringRef s = NULL;
    st = get(dev, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, 0, NULL, &s, sizeof s, NULL);
    CHECK(st == 0 && s && cfEq(s, "Whoprrr Mic"), "device is named Whoprrr Mic");
    st = get(dev, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, 0, NULL, &s, sizeof s, NULL);
    CHECK(st == 0 && s && cfEq(s, "WhopperMicDevice_UID"), "device UID is stable");
    UInt32 v = 0;
    get(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0, NULL, &v, sizeof v, NULL);
    CHECK(v == kAudioDeviceTransportTypeVirtual, "transport type is virtual");

    get(dev, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput, 0, NULL, &v, sizeof v, NULL);
    CHECK(v == 1, "can be the default input");
    get(dev, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput, 0, NULL, &v, sizeof v, NULL);
    CHECK(v == 0, "is never offered as the default output");

    AudioObjectID in[2] = {0}, out[2] = {0};
    get(dev, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, 0, NULL, in, sizeof in, &n);
    CHECK(n == sizeof(AudioObjectID), "one input stream");
    get(dev, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, 0, NULL, out, sizeof out, &n);
    CHECK(n == sizeof(AudioObjectID), "one output stream");

    AudioStreamBasicDescription f;
    st = get(in[0], kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, 0, NULL, &f, sizeof f, NULL);
    CHECK(st == 0 && f.mChannelsPerFrame == 2 && f.mSampleRate == 48000.0 && (f.mFormatFlags & kAudioFormatFlagIsFloat), "input format: 48 kHz stereo float");
    UInt32 dir = 9;
    get(in[0], kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal, 0, NULL, &dir, sizeof dir, NULL);
    CHECK(dir == 1, "input stream direction is input");

    AudioValueRange rates[8];
    get(dev, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, 0, NULL, rates, sizeof rates, &n);
    CHECK(n / sizeof(AudioValueRange) == 4 && rates[1].mMinimum == 48000.0, "offers 44.1/48/88.2/96 kHz");

    // Unknown property is refused, not crashed on.
    st = get(dev, 'nope', kAudioObjectPropertyScopeGlobal, 0, NULL, &v, sizeof v, NULL);
    CHECK(st == kAudioHardwareUnknownPropertyError, "unknown property is an error");

    // Loopback through the ring.
    CHECK(I->StartIO(drv, dev, 1) == 0, "StartIO");
    Float64 t0 = 0; UInt64 h0 = 0, seed = 0, h1 = 0, seed1 = 0; Float64 t1 = 0;
    I->GetZeroTimeStamp(drv, dev, 1, &t0, &h0, &seed);
    usleep(500000);
    I->GetZeroTimeStamp(drv, dev, 1, &t1, &h1, &seed1);
    CHECK(t1 >= t0 && h1 >= h0 && seed == seed1, "zero timestamps advance monotonically");

    Boolean will = false, inplace = false;
    I->WillDoIOOperation(drv, dev, 1, kAudioServerPlugInIOOperationWriteMix, &will, &inplace);
    CHECK(will, "does WriteMix");
    I->WillDoIOOperation(drv, dev, 1, kAudioServerPlugInIOOperationReadInput, &will, &inplace);
    CHECK(will, "does ReadInput");
    I->WillDoIOOperation(drv, dev, 1, kAudioServerPlugInIOOperationProcessOutput, &will, &inplace);
    CHECK(!will, "ignores other operations");

    enum { N = 512 };
    Float32 outBuf[N * 2], inBuf[N * 2];
    for (int i = 0; i < N; i++) { outBuf[i * 2] = sinf(0.05f * i); outBuf[i * 2 + 1] = -sinf(0.05f * i); }
    AudioServerPlugInIOCycleInfo info; memset(&info, 0, sizeof info);
    info.mOutputTime.mSampleTime = 100000; info.mInputTime.mSampleTime = 100000;      // same timeline position
    I->DoIOOperation(drv, dev, out[0], 1, kAudioServerPlugInIOOperationWriteMix, N, &info, outBuf, NULL);
    I->DoIOOperation(drv, dev, in[0], 1, kAudioServerPlugInIOOperationReadInput, N, &info, inBuf, NULL);
    CHECK(memcmp(outBuf, inBuf, sizeof outBuf) == 0, "samples written to the output come out of the input, bit-exact");

    I->DoIOOperation(drv, dev, in[0], 1, kAudioServerPlugInIOOperationReadInput, N, &info, inBuf, NULL);
    int allZero = 1; for (int i = 0; i < N * 2; i++) if (inBuf[i] != 0) allZero = 0;
    CHECK(allZero, "audio is consumed once: a stalled writer gives silence, not a replay");

    info.mOutputTime.mSampleTime = 16384 - 100; info.mInputTime.mSampleTime = 16384 - 100;     // straddles the ring wrap
    I->DoIOOperation(drv, dev, out[0], 1, kAudioServerPlugInIOOperationWriteMix, N, &info, outBuf, NULL);
    I->DoIOOperation(drv, dev, in[0], 1, kAudioServerPlugInIOOperationReadInput, N, &info, inBuf, NULL);
    CHECK(memcmp(outBuf, inBuf, sizeof outBuf) == 0, "loopback survives the ring wrap-around");

    // Sample rate change.
    Float64 want = 96000.0;
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    st = I->SetPropertyData(drv, dev, 0, &ra, 0, NULL, sizeof want, &want);
    Float64 now = 0; get(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0, NULL, &now, sizeof now, NULL);
    CHECK(st == 0 && changeRequests == 1 && now == 96000.0, "sample rate change goes through the host and applies");
    want = 12345.0;
    st = I->SetPropertyData(drv, dev, 0, &ra, 0, NULL, sizeof want, &want);
    CHECK(st != 0, "unsupported rate is rejected");

    CHECK(I->StopIO(drv, dev, 1) == 0, "StopIO");
    printf(failures ? "\nFAILED (%d)\n" : "\nALL PASS\n", failures);
    return failures ? 1 : 0;
}
