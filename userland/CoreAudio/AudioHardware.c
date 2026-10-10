/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreAudio's object and property API (AudioHardware.h). Finch has no audio
 * hardware driver yet, so the system object (kAudioObjectSystemObject) is
 * the only object: it has no devices, its default devices are
 * kAudioObjectUnknown, and other objects are bad objects, as Apple's
 * CoreAudio answers on a Mac with no audio devices. Listeners are kept (and
 * never called: nothing changes).
 */
#include <CoreAudio/AudioHardware.h>
#include <dispatch/dispatch.h>
#include <string.h>

/* The system object's properties, and their sizes (0: a variable list, empty). */
static UInt32
system_property_size(AudioObjectPropertySelector s, Boolean *known)
{
    *known = true;
    switch (s) {
    case kAudioHardwarePropertyDevices:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioHardwarePropertyPlugInList:
    case kAudioHardwarePropertyBoxList:
    case kAudioHardwarePropertyClockDeviceList:
        return 0;
    case kAudioHardwarePropertyDefaultInputDevice:
    case kAudioHardwarePropertyDefaultOutputDevice:
    case kAudioHardwarePropertyDefaultSystemOutputDevice:
        return sizeof(AudioObjectID);
    case kAudioHardwarePropertyMixStereoToMono:
    case kAudioHardwarePropertyIsInitingOrExiting:
    case kAudioHardwarePropertySleepingIsAllowed:
    case kAudioHardwarePropertyUnloadingIsAllowed:
    case kAudioHardwarePropertyHogModeIsAllowed:
    case kAudioHardwarePropertyUserSessionIsActiveOrHeadless:
    case kAudioHardwarePropertyServiceRestarted:
    case kAudioHardwarePropertyPowerHint:
    case kAudioHardwarePropertyProcessIsMain:
        return sizeof(UInt32);
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyBaseClass:
        return sizeof(AudioClassID);
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
        return sizeof(CFStringRef);
    default:
        *known = false;
        return 0;
    }
}

Boolean
AudioObjectHasProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress)
{
    Boolean known = false;
    if (inObjectID == kAudioObjectSystemObject && inAddress)
        system_property_size(inAddress->mSelector, &known);
    return known;
}

OSStatus
AudioObjectIsPropertySettable(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable)
{
    if (inObjectID != kAudioObjectSystemObject)
        return kAudioHardwareBadObjectError;
    if (!AudioObjectHasProperty(inObjectID, inAddress))
        return kAudioHardwareUnknownPropertyError;
    if (outIsSettable)
        *outIsSettable = false;
    return kAudioHardwareNoError;
}

OSStatus
AudioObjectGetPropertyDataSize(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress,
                               UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize)
{
    Boolean known;
    if (inObjectID != kAudioObjectSystemObject)
        return kAudioHardwareBadObjectError;
    if (!inAddress || !outDataSize)
        return kAudioHardwareIllegalOperationError;
    UInt32 size = system_property_size(inAddress->mSelector, &known);
    if (!known)
        return kAudioHardwareUnknownPropertyError;
    *outDataSize = size;
    return kAudioHardwareNoError;
}

OSStatus
AudioObjectGetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                           const void *inQualifierData, UInt32 *ioDataSize, void *outData)
{
    Boolean known;
    if (inObjectID != kAudioObjectSystemObject)
        return kAudioHardwareBadObjectError;
    if (!inAddress || !ioDataSize)
        return kAudioHardwareIllegalOperationError;
    UInt32 size = system_property_size(inAddress->mSelector, &known);
    if (!known)
        return kAudioHardwareUnknownPropertyError;
    if (*ioDataSize < size || (size && !outData))
        return kAudioHardwareBadPropertySizeError;
    switch (inAddress->mSelector) {
    case kAudioHardwarePropertyDefaultInputDevice:
    case kAudioHardwarePropertyDefaultOutputDevice:
    case kAudioHardwarePropertyDefaultSystemOutputDevice:
        *(AudioObjectID *)outData = kAudioObjectUnknown;
        break;
    case kAudioObjectPropertyClass:
        *(AudioClassID *)outData = kAudioSystemObjectClassID;
        break;
    case kAudioObjectPropertyBaseClass:
        *(AudioClassID *)outData = kAudioObjectClassID;
        break;
    case kAudioObjectPropertyName:
        *(CFStringRef *)outData = CFSTR("The Audio System");
        break;
    case kAudioObjectPropertyManufacturer:
        *(CFStringRef *)outData = CFSTR("Finch");
        break;
    case kAudioHardwarePropertySleepingIsAllowed:
    case kAudioHardwarePropertyUnloadingIsAllowed:
    case kAudioHardwarePropertyHogModeIsAllowed:
    case kAudioHardwarePropertyUserSessionIsActiveOrHeadless:
    case kAudioHardwarePropertyProcessIsMain:
        *(UInt32 *)outData = 1;
        break;
    default:
        if (size)
            memset(outData, 0, size);
        break;
    }
    *ioDataSize = size;
    return kAudioHardwareNoError;
}

OSStatus
AudioObjectSetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                           const void *inQualifierData, UInt32 inDataSize, const void *inData)
{
    if (inObjectID != kAudioObjectSystemObject)
        return kAudioHardwareBadObjectError;
    if (!AudioObjectHasProperty(inObjectID, inAddress))
        return kAudioHardwareUnknownPropertyError;
    return kAudioHardwareIllegalOperationError;
}

OSStatus
AudioObjectAddPropertyListener(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress,
                               AudioObjectPropertyListenerProc inListener, void *inClientData)
{
    return inObjectID == kAudioObjectSystemObject ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

OSStatus
AudioObjectRemovePropertyListener(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress,
                                  AudioObjectPropertyListenerProc inListener, void *inClientData)
{
    return inObjectID == kAudioObjectSystemObject ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

OSStatus
AudioObjectAddPropertyListenerBlock(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress,
                                    dispatch_queue_t inDispatchQueue, AudioObjectPropertyListenerBlock inListener)
{
    return inObjectID == kAudioObjectSystemObject ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

OSStatus
AudioObjectRemovePropertyListenerBlock(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress,
                                       dispatch_queue_t inDispatchQueue, AudioObjectPropertyListenerBlock inListener)
{
    return inObjectID == kAudioObjectSystemObject ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

void AudioObjectShow(AudioObjectID inObjectID) {}
OSStatus AudioHardwareUnload(void) { return kAudioHardwareNoError; }
