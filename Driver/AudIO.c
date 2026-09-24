// AudIO virtual audio device – an AudioServerPlugIn (HAL) driver.
//
// Publishes one device, "AudIO" – a silent sink that exists to be selected:
//   • an output stream apps play into (it shows up in the Sound menu / settings),
//   • volume + mute controls. They are only published, not applied: the AudIO app
//     captures what apps play with a process tap and applies volume/mute itself,
//     after its alignment delay, so changes are heard immediately.
// There is deliberately no loopback input: reading any audio input lights the
// microphone indicator.
//
// Structure follows Apple's NullAudio sample: a static object tree
// (plug-in → device → stream/controls), property dispatch per object, and a
// host-clock driven zero timestamp. Output is discarded (no IO operations).

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

// MARK: - Constants

#define kDevice_Name        "AudIO"
#define kDevice_UID         "dev.enke.AudIO.Device"
#define kDevice_ModelUID    "dev.enke.AudIO.Model"
#define kPlugIn_BundleID    "dev.enke.AudIO.Driver"
#define kManufacturer       "enke.dev"
#define kChannels           2
#define kBytesPerFrame      (kChannels * sizeof(Float32))
#define kRingFrames         16384 // zero timestamp period
#define kVolumeMinDB        -64.0f
#define kVolumeMaxDB        0.0f
#define kDefaultVolume      0.75f
// Custom property ('Alat', CFNumber of frames): the app writes the real latency of its
// routing (outputs incl. Bluetooth, delay lines, buffers), reported as the device latency –
// so video players delay the picture accordingly, like they do for AirPods directly.
#define kAudIOPropertyLatency 'Alat'

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device        = 2,
    kObjectID_Stream_Output = 3,
    kObjectID_Volume        = 5,
    kObjectID_Mute          = 6,
};

static const Float64 kSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define kSampleRateCount ((UInt32)(sizeof(kSampleRates) / sizeof(kSampleRates[0])))

// MARK: - State

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gIOMutex = PTHREAD_MUTEX_INITIALIZER;
static os_log_t gLog;

static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;

static Float64 gSampleRate = 48000.0;
static Float64 gPendingSampleRate = 0.0;
static Float64 gHostClockFrequency = 0.0;
static Float64 gHostTicksPerFrame = 0.0;

static UInt32 gIORunning = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gTimestampCount = 0;

static Boolean gOutputStreamActive = true;

static _Atomic(float) gVolume = kDefaultVolume;   // scalar 0…1
static _Atomic(UInt32) gMute = 0;
static _Atomic(UInt32) gLatencyFrames = 0;

// MARK: - Helpers

static Boolean IsValidSampleRate(Float64 rate) {
    for (UInt32 i = 0; i < kSampleRateCount; i++) {
        if (kSampleRates[i] == rate) return true;
    }
    return false;
}

static AudioStreamBasicDescription MakeFormat(Float64 rate) {
    AudioStreamBasicDescription format = { 0 };
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = kBytesPerFrame;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = kBytesPerFrame;
    format.mChannelsPerFrame = kChannels;
    format.mBitsPerChannel = 32;
    return format;
}

// Volume curve: gain = scalar³ (≈ 60 dB range), matching the app's software faders.
static Float32 ScalarToDB(Float32 scalar) {
    if (scalar <= 0.0f) return kVolumeMinDB;
    Float32 db = 60.0f * log10f(scalar);
    return fmaxf(kVolumeMinDB, fminf(kVolumeMaxDB, db));
}

static Float32 DBToScalar(Float32 db) {
    if (db <= kVolumeMinDB) return 0.0f;
    return fminf(1.0f, powf(10.0f, fminf(db, kVolumeMaxDB) / 60.0f));
}

static void Notify(AudioObjectID object, AudioObjectPropertySelector first, AudioObjectPropertySelector second) {
    if (gHost == NULL) return;
    AudioObjectPropertyAddress addresses[2] = {
        { first, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { second, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    gHost->PropertiesChanged(gHost, object, second == 0 ? 1 : 2, addresses);
}

static void StoreVolume(void) {
    if (gHost == NULL) return;
    Float32 volume = atomic_load(&gVolume);
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberFloat32Type, &volume);
    if (number != NULL) {
        gHost->WriteToStorage(gHost, CFSTR("volume"), number);
        CFRelease(number);
    }
}

static void RestoreVolume(void) {
    CFPropertyListRef data = NULL;
    if (gHost->CopyFromStorage(gHost, CFSTR("volume"), &data) == 0 && data != NULL) {
        Float32 volume;
        if (CFGetTypeID(data) == CFNumberGetTypeID() &&
            CFNumberGetValue((CFNumberRef)data, kCFNumberFloat32Type, &volume)) {
            atomic_store(&gVolume, fmaxf(0.0f, fminf(1.0f, volume)));
        }
        CFRelease(data);
    }
}

static void UpdateTiming(void) {
    gHostTicksPerFrame = gHostClockFrequency / gSampleRate;
}

// Writes a fixed-size value; bails out of the calling property getter on a short buffer.
#define WRITE_VALUE(type, value)                                            \
    do {                                                                    \
        if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
        *((type*)outData) = (value);                                        \
        *outDataSize = sizeof(type);                                        \
        return 0;                                                           \
    } while (0)

static OSStatus WriteObjectIDs(const AudioObjectID* ids, UInt32 count, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    UInt32 fit = inDataSize / sizeof(AudioObjectID);
    UInt32 n = count < fit ? count : fit;
    if (n > 0) memcpy(outData, ids, n * sizeof(AudioObjectID));
    *outDataSize = n * sizeof(AudioObjectID);
    return 0;
}

// MARK: - Property getters per object

static OSStatus PlugIn_GetProperty(const AudioObjectPropertyAddress* address, UInt32 qualifierSize, const void* qualifier,
                                   UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    static const AudioObjectID devices[] = { kObjectID_Device };
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: WRITE_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: WRITE_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: WRITE_VALUE(CFStringRef, CFSTR(kManufacturer));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            return WriteObjectIDs(devices, 1, inDataSize, outDataSize, outData);
        case kAudioPlugInPropertyBoxList:
            *outDataSize = 0;
            return 0;
        case kAudioPlugInPropertyTranslateUIDToBox: WRITE_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID device = kAudioObjectUnknown;
            if (qualifierSize >= sizeof(CFStringRef) && qualifier != NULL) {
                CFStringRef uid = *(const CFStringRef*)qualifier;
                if (uid != NULL && CFStringCompare(uid, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo) {
                    device = kObjectID_Device;
                }
            }
            WRITE_VALUE(AudioObjectID, device);
        }
        case kAudioPlugInPropertyResourceBundle: WRITE_VALUE(CFStringRef, CFSTR(""));
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Device_GetProperty(const AudioObjectPropertyAddress* address,
                                   UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    const AudioObjectPropertyScope scope = address->mScope;
    const Boolean input = scope == kAudioObjectPropertyScopeInput;

    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: WRITE_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: WRITE_VALUE(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName: WRITE_VALUE(CFStringRef, CFSTR(kDevice_Name));
        case kAudioObjectPropertyManufacturer: WRITE_VALUE(CFStringRef, CFSTR(kManufacturer));
        case kAudioDevicePropertyDeviceUID: WRITE_VALUE(CFStringRef, CFSTR(kDevice_UID));
        case kAudioDevicePropertyModelUID: WRITE_VALUE(CFStringRef, CFSTR(kDevice_ModelUID));
        case kAudioDevicePropertyTransportType: WRITE_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain: WRITE_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: WRITE_VALUE(UInt32, 1);
        case kAudioDevicePropertyIsHidden: WRITE_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency: WRITE_VALUE(UInt32, input ? 0 : atomic_load(&gLatencyFrames));
        case kAudioDevicePropertySafetyOffset: WRITE_VALUE(UInt32, 0);

        case kAudioObjectPropertyCustomPropertyInfoList: {
            if (inDataSize < sizeof(AudioServerPlugInCustomPropertyInfo)) return kAudioHardwareBadPropertySizeError;
            AudioServerPlugInCustomPropertyInfo* info = (AudioServerPlugInCustomPropertyInfo*)outData;
            info->mSelector = kAudIOPropertyLatency;
            info->mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
            info->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
            *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
            return 0;
        }

        // Returned retained – the caller releases it.
        case kAudIOPropertyLatency: {
            if (inDataSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
            UInt32 frames = atomic_load(&gLatencyFrames);
            *(CFPropertyListRef*)outData = CFNumberCreate(NULL, kCFNumberSInt32Type, &frames);
            *outDataSize = sizeof(CFPropertyListRef);
            return 0;
        }
        case kAudioDevicePropertyZeroTimeStampPeriod: WRITE_VALUE(UInt32, kRingFrames);

        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIORunning > 0 ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            WRITE_VALUE(UInt32, running);
        }

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            WRITE_VALUE(UInt32, input ? 0 : 1);

        case kAudioDevicePropertyRelatedDevices: {
            static const AudioObjectID related[] = { kObjectID_Device };
            return WriteObjectIDs(related, 1, inDataSize, outDataSize, outData);
        }

        case kAudioObjectPropertyOwnedObjects: {
            static const AudioObjectID all[] = { kObjectID_Stream_Output, kObjectID_Volume, kObjectID_Mute };
            if (input) return WriteObjectIDs(NULL, 0, inDataSize, outDataSize, outData);
            return WriteObjectIDs(all, 3, inDataSize, outDataSize, outData);
        }

        case kAudioDevicePropertyStreams: {
            static const AudioObjectID outputs[] = { kObjectID_Stream_Output };
            if (input) return WriteObjectIDs(NULL, 0, inDataSize, outDataSize, outData);
            return WriteObjectIDs(outputs, 1, inDataSize, outDataSize, outData);
        }

        case kAudioObjectPropertyControlList: {
            static const AudioObjectID controls[] = { kObjectID_Volume, kObjectID_Mute };
            return WriteObjectIDs(controls, 2, inDataSize, outDataSize, outData);
        }

        case kAudioDevicePropertyNominalSampleRate: {
            pthread_mutex_lock(&gStateMutex);
            Float64 rate = gSampleRate;
            pthread_mutex_unlock(&gStateMutex);
            WRITE_VALUE(Float64, rate);
        }

        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 fit = inDataSize / sizeof(AudioValueRange);
            UInt32 n = kSampleRateCount < fit ? kSampleRateCount : fit;
            AudioValueRange* ranges = (AudioValueRange*)outData;
            for (UInt32 i = 0; i < n; i++) {
                ranges[i].mMinimum = kSampleRates[i];
                ranges[i].mMaximum = kSampleRates[i];
            }
            *outDataSize = n * sizeof(AudioValueRange);
            return 0;
        }

        // Shown next to the device in the Sound menu / settings. The caller releases it.
        case kAudioDevicePropertyIcon: {
            CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR(kPlugIn_BundleID));
            CFURLRef url = bundle ? CFBundleCopyResourceURL(bundle, CFSTR("Icon"), CFSTR("icns"), NULL) : NULL;
            if (url == NULL) return kAudioHardwareUnknownPropertyError;
            if (inDataSize < sizeof(CFURLRef)) {
                CFRelease(url);
                return kAudioHardwareBadPropertySizeError;
            }
            *(CFURLRef*)outData = url;
            *outDataSize = sizeof(CFURLRef);
            return 0;
        }

        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32*)outData)[0] = 1;
            ((UInt32*)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return 0;
        }

        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Stream_GetProperty(AudioObjectID stream, const AudioObjectPropertyAddress* address,
                                   UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    (void)stream;
    const Boolean isInput = false; // output-only device
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: WRITE_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: WRITE_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return 0;
        case kAudioStreamPropertyDirection: WRITE_VALUE(UInt32, isInput ? 1 : 0);
        case kAudioStreamPropertyTerminalType:
            WRITE_VALUE(UInt32, isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: WRITE_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: WRITE_VALUE(UInt32, 0);

        case kAudioStreamPropertyIsActive: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 active = gOutputStreamActive;
            pthread_mutex_unlock(&gStateMutex);
            WRITE_VALUE(UInt32, active);
        }

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            pthread_mutex_lock(&gStateMutex);
            Float64 rate = gSampleRate;
            pthread_mutex_unlock(&gStateMutex);
            WRITE_VALUE(AudioStreamBasicDescription, MakeFormat(rate));
        }

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 fit = inDataSize / sizeof(AudioStreamRangedDescription);
            UInt32 n = kSampleRateCount < fit ? kSampleRateCount : fit;
            AudioStreamRangedDescription* formats = (AudioStreamRangedDescription*)outData;
            for (UInt32 i = 0; i < n; i++) {
                formats[i].mFormat = MakeFormat(kSampleRates[i]);
                formats[i].mSampleRateRange.mMinimum = kSampleRates[i];
                formats[i].mSampleRateRange.mMaximum = kSampleRates[i];
            }
            *outDataSize = n * sizeof(AudioStreamRangedDescription);
            return 0;
        }

        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Volume_GetProperty(const AudioObjectPropertyAddress* address,
                                   UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE_VALUE(AudioClassID, kAudioLevelControlClassID);
        case kAudioObjectPropertyClass: WRITE_VALUE(AudioClassID, kAudioVolumeControlClassID);
        case kAudioObjectPropertyOwner: WRITE_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return 0;
        case kAudioControlPropertyScope: WRITE_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement: WRITE_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        case kAudioLevelControlPropertyScalarValue: WRITE_VALUE(Float32, atomic_load(&gVolume));
        case kAudioLevelControlPropertyDecibelValue: WRITE_VALUE(Float32, ScalarToDB(atomic_load(&gVolume)));
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange range = { kVolumeMinDB, kVolumeMaxDB };
            WRITE_VALUE(AudioValueRange, range);
        }
        // In/out conversions: the value to convert arrives in the data buffer.
        case kAudioLevelControlPropertyConvertScalarToDecibels: {
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 scalar = fmaxf(0.0f, fminf(1.0f, *(Float32*)outData));
            WRITE_VALUE(Float32, ScalarToDB(scalar));
        }
        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            WRITE_VALUE(Float32, DBToScalar(*(Float32*)outData));
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Mute_GetProperty(const AudioObjectPropertyAddress* address,
                                 UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE_VALUE(AudioClassID, kAudioBooleanControlClassID);
        case kAudioObjectPropertyClass: WRITE_VALUE(AudioClassID, kAudioMuteControlClassID);
        case kAudioObjectPropertyOwner: WRITE_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return 0;
        case kAudioControlPropertyScope: WRITE_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement: WRITE_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        case kAudioBooleanControlPropertyValue: WRITE_VALUE(UInt32, atomic_load(&gMute));
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetProperty(AudioObjectID object, const AudioObjectPropertyAddress* address,
                            UInt32 qualifierSize, const void* qualifier,
                            UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    switch (object) {
        case kObjectID_PlugIn:
            return PlugIn_GetProperty(address, qualifierSize, qualifier, inDataSize, outDataSize, outData);
        case kObjectID_Device:
            return Device_GetProperty(address, inDataSize, outDataSize, outData);
        case kObjectID_Stream_Output:
            return Stream_GetProperty(object, address, inDataSize, outDataSize, outData);
        case kObjectID_Volume:
            return Volume_GetProperty(address, inDataSize, outDataSize, outData);
        case kObjectID_Mute:
            return Mute_GetProperty(address, inDataSize, outDataSize, outData);
        default:
            return kAudioHardwareBadObjectError;
    }
}

// Scratch-buffer query: "has" and "size" are answered by running the getter.
// CFStrings handed out are CFSTR constants; the icon URL is a copy and released here.
static OSStatus QueryProperty(AudioObjectID object, const AudioObjectPropertyAddress* address,
                              UInt32 qualifierSize, const void* qualifier, UInt32* outDataSize) {
    UInt64 scratch[128] = { 0 };
    UInt32 size = 0;
    OSStatus status = GetProperty(object, address, qualifierSize, qualifier, sizeof(scratch), &size, scratch);
    if (status == 0 && object == kObjectID_Device &&
        (address->mSelector == kAudioDevicePropertyIcon || address->mSelector == kAudIOPropertyLatency)) {
        CFRelease(*(CFTypeRef*)scratch);
    }
    if (outDataSize != NULL) *outDataSize = size;
    return status;
}

// MARK: - Setters

static void RequestSampleRate(Float64 rate) {
    pthread_mutex_lock(&gStateMutex);
    Boolean changed = rate != gSampleRate;
    if (changed) gPendingSampleRate = rate;
    pthread_mutex_unlock(&gStateMutex);
    if (!changed) return;

    // Must not be requested synchronously from within a property call.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, 0, NULL);
    });
}

static OSStatus SetProperty(AudioObjectID object, const AudioObjectPropertyAddress* address,
                            UInt32 inDataSize, const void* inData) {
    switch (object) {
        case kObjectID_Device:
            if (address->mSelector == kAudioDevicePropertyNominalSampleRate) {
                if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
                Float64 rate = *(const Float64*)inData;
                if (!IsValidSampleRate(rate)) return kAudioHardwareIllegalOperationError;
                RequestSampleRate(rate);
                return 0;
            }
            if (address->mSelector == kAudIOPropertyLatency) {
                if (inDataSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
                CFPropertyListRef value = *(const CFPropertyListRef*)inData;
                SInt32 frames = 0;
                if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID() ||
                    !CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &frames)) {
                    return kAudioHardwareIllegalOperationError;
                }
                UInt32 latency = frames > 0 ? (UInt32)frames : 0;
                if (latency != atomic_exchange(&gLatencyFrames, latency) && gHost != NULL) {
                    AudioObjectPropertyAddress changed[3] = {
                        { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
                        { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                        { kAudIOPropertyLatency, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                    };
                    gHost->PropertiesChanged(gHost, kObjectID_Device, 3, changed);
                }
                return 0;
            }
            break;

        case kObjectID_Stream_Output:
            if (address->mSelector == kAudioStreamPropertyIsActive) {
                if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                Boolean active = *(const UInt32*)inData != 0;
                pthread_mutex_lock(&gStateMutex);
                gOutputStreamActive = active;
                pthread_mutex_unlock(&gStateMutex);
                Notify(object, kAudioStreamPropertyIsActive, 0);
                return 0;
            }
            if (address->mSelector == kAudioStreamPropertyVirtualFormat ||
                address->mSelector == kAudioStreamPropertyPhysicalFormat) {
                if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                const AudioStreamBasicDescription* format = (const AudioStreamBasicDescription*)inData;
                if (format->mFormatID != kAudioFormatLinearPCM ||
                    format->mChannelsPerFrame != kChannels ||
                    format->mBitsPerChannel != 32 ||
                    !IsValidSampleRate(format->mSampleRate)) {
                    return kAudioDeviceUnsupportedFormatError;
                }
                RequestSampleRate(format->mSampleRate);
                return 0;
            }
            break;

        case kObjectID_Volume:
            if (address->mSelector == kAudioLevelControlPropertyScalarValue ||
                address->mSelector == kAudioLevelControlPropertyDecibelValue) {
                if (inDataSize != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                Float32 value = *(const Float32*)inData;
                Float32 scalar = address->mSelector == kAudioLevelControlPropertyScalarValue
                    ? fmaxf(0.0f, fminf(1.0f, value))
                    : DBToScalar(value);
                if (scalar != atomic_load(&gVolume)) {
                    atomic_store(&gVolume, scalar);
                    Notify(kObjectID_Volume, kAudioLevelControlPropertyScalarValue, kAudioLevelControlPropertyDecibelValue);
                    StoreVolume();
                }
                return 0;
            }
            break;

        case kObjectID_Mute:
            if (address->mSelector == kAudioBooleanControlPropertyValue) {
                if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                UInt32 mute = *(const UInt32*)inData != 0;
                if (mute != atomic_load(&gMute)) {
                    atomic_store(&gMute, mute);
                    Notify(kObjectID_Mute, kAudioBooleanControlPropertyValue, 0);
                }
                return 0;
            }
            break;

        default:
            return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareUnknownPropertyError;
}

static Boolean IsSettable(AudioObjectID object, AudioObjectPropertySelector selector) {
    switch (object) {
        case kObjectID_Device:
            return selector == kAudioDevicePropertyNominalSampleRate || selector == kAudIOPropertyLatency;
        case kObjectID_Stream_Output:
            return selector == kAudioStreamPropertyIsActive ||
                   selector == kAudioStreamPropertyVirtualFormat ||
                   selector == kAudioStreamPropertyPhysicalFormat;
        case kObjectID_Volume:
            return selector == kAudioLevelControlPropertyScalarValue ||
                   selector == kAudioLevelControlPropertyDecibelValue;
        case kObjectID_Mute:
            return selector == kAudioBooleanControlPropertyValue;
        default:
            return false;
    }
}

// MARK: - Driver interface

static HRESULT AudIO_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG AudIO_AddRef(void* inDriver);
static ULONG AudIO_Release(void* inDriver);
static OSStatus AudIO_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus AudIO_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                   const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus AudIO_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus AudIO_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus AudIO_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                         const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus AudIO_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                       UInt64 inChangeAction, void* inChangeInfo);
static OSStatus AudIO_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction, void* inChangeInfo);
static Boolean AudIO_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                 const AudioObjectPropertyAddress* inAddress);
static OSStatus AudIO_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                         const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus AudIO_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                          const void* inQualifierData, UInt32* outDataSize);
static OSStatus AudIO_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                      const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus AudIO_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                      const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus AudIO_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus AudIO_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus AudIO_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                       Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus AudIO_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus AudIO_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                       UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus AudIO_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                    AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                    UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                    void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus AudIO_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    AudIO_QueryInterface,
    AudIO_AddRef,
    AudIO_Release,
    AudIO_Initialize,
    AudIO_CreateDevice,
    AudIO_DestroyDevice,
    AudIO_AddDeviceClient,
    AudIO_RemoveDeviceClient,
    AudIO_PerformDeviceConfigurationChange,
    AudIO_AbortDeviceConfigurationChange,
    AudIO_HasProperty,
    AudIO_IsPropertySettable,
    AudIO_GetPropertyDataSize,
    AudIO_GetPropertyData,
    AudIO_SetPropertyData,
    AudIO_StartIO,
    AudIO_StopIO,
    AudIO_GetZeroTimeStamp,
    AudIO_WillDoIOOperation,
    AudIO_BeginIOOperation,
    AudIO_DoIOOperation,
    AudIO_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// Factory named in Info.plist (CFPlugInFactories).
__attribute__((visibility("default")))
void* AudIO_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

static HRESULT AudIO_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;

    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AudIO_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG AudIO_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) --gRefCount;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static OSStatus AudIO_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    gLog = os_log_create("dev.enke.AudIO.Driver", "driver");

    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);
    gHostClockFrequency = (Float64)timebase.denom / (Float64)timebase.numer * 1000000000.0;
    UpdateTiming();

    RestoreVolume();
    os_log(gLog, "AudIO driver initialized (%.0f Hz)", gSampleRate);
    return 0;
}

static OSStatus AudIO_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                   const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AudIO_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AudIO_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus AudIO_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                         const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus AudIO_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                       UInt64 inChangeAction, void* inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gPendingSampleRate > 0) {
        gSampleRate = gPendingSampleRate;
        gPendingSampleRate = 0;
        UpdateTiming();
        os_log(gLog, "Sample rate changed to %.0f Hz", gSampleRate);
    }
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus AudIO_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction, void* inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    gPendingSampleRate = 0;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static Boolean AudIO_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                 const AudioObjectPropertyAddress* inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL) return false;
    return QueryProperty(inObjectID, inAddress, 0, NULL, NULL) == 0;
}

static OSStatus AudIO_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                         const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    OSStatus status = QueryProperty(inObjectID, inAddress, 0, NULL, NULL);
    if (status != 0) return status;
    *outIsSettable = IsSettable(inObjectID, inAddress->mSelector);
    return 0;
}

static OSStatus AudIO_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                          const void* inQualifierData, UInt32* outDataSize) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    return QueryProperty(inObjectID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
}

static OSStatus AudIO_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                      const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    return GetProperty(inObjectID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
}

static OSStatus AudIO_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                      const void* inQualifierData, UInt32 inDataSize, const void* inData) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    return SetProperty(inObjectID, inAddress, inDataSize, inData);
}

static OSStatus AudIO_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIORunning == 0) {
        pthread_mutex_lock(&gIOMutex);
        gAnchorHostTime = mach_absolute_time();
        gTimestampCount = 0;
        pthread_mutex_unlock(&gIOMutex);
    }
    // No "is running" notification here: like Apple's NullAudio, the host tracks IO state
    // itself (sending it produced "object is not valid" errors and a busy coreaudiod).
    ++gIORunning;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus AudIO_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIORunning > 0) --gIORunning;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus AudIO_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                       Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gIOMutex);
    const UInt64 now = mach_absolute_time();
    const Float64 ticksPerPeriod = gHostTicksPerFrame * kRingFrames;
    const UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gTimestampCount + 1) * ticksPerPeriod);
    if (next <= now) ++gTimestampCount;
    *outSampleTime = (Float64)(gTimestampCount * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gTimestampCount * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gIOMutex);
    return 0;
}

static OSStatus AudIO_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    // Like Apple's NullAudio: accept the mixed output, then discard it in DoIOOperation.
    if (outWillDo != NULL) *outWillDo = inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDoInPlace != NULL) *outWillDoInPlace = true;
    return 0;
}

static OSStatus AudIO_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                       UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus AudIO_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                    AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                    UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                    void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    (void)inStreamObjectID; (void)inOperationID; (void)inIOBufferFrameSize;
    (void)inIOCycleInfo; (void)ioMainBuffer;
    return 0;
}

static OSStatus AudIO_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}
