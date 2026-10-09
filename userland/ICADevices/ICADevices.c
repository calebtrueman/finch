/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ICADevices: the library Image Capture device modules (camera and scanner
 * drivers) are built on. Finch has no device modules and no Image Capture
 * agent yet, so this is the public API (the SDK's headers) with nothing behind
 * it: connecting a device fails with kICADeviceNotFoundErr, talking to the
 * agent with kICACommunicationErr, and ICD_main/ICD_ScannerMain return 1. Apps
 * such as Image Capture link it without calling into it.
 */
#include <ICADevices/ICADevices.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

const CFStringRef kICUTTypeRaw = CFSTR("com.apple.ica.raw");

ICD_callback_functions gICDCallbackFunctions;
ICD_scanner_callback_functions gICDScannerCallbackFunctions;

/* Device modules */

int ICD_main(int argc, const char *argv[]) { return 1; }
int ICD_ScannerMain(int argc, const char *argv[]) { return 1; }

/* Objects and notifications go to the agent: there is none. */

ICAError ICDNewObject(ICD_NewObjectPB *pb, ICDCompletion completion) { return kICACommunicationErr; }
ICAError ICDDisposeObject(ICD_DisposeObjectPB *pb, ICDCompletion completion) { return kICACommunicationErr; }
ICAError ICDGetStandardPropertyData(const ObjectInfo *objectInfo, void *pb) { return kICAInvalidPropertyErr; }
ICAError ICDScannerGetStandardPropertyData(const ScannerObjectInfo *objectInfo, void *pb) { return kICAInvalidPropertyErr; }
ICAError ICDNewObjectInfoCreated(const ObjectInfo *parentInfo, UInt32 index, ICAObject *newICAObject) { return kICACommunicationErr; }
ICAError ICDScannerNewObjectInfoCreated(const ScannerObjectInfo *parentInfo, UInt32 index, ICAObject *newICAObject) { return kICACommunicationErr; }
ICAError ICDNewObjectCreated(const ObjectInfo *parentInfo, const ObjectInfo *objectInfo, ICDNewObjectCreatedCompletion completion) { return kICACommunicationErr; }
ICAError ICDSendNotification(ICASendNotificationPB *pb) { return kICACommunicationErr; }
ICAError ICDSendNotificationAndWaitForReply(ICASendNotificationPB *pb) { return kICACommunicationErr; }
ICAError ICDInitiateNotificationCallback(const void *pb) { return kICACommunicationErr; }
ICAError ICDScannerInitiateNotificationCallback(const void *pb) { return kICACommunicationErr; }
ICAError ICDCreateEventDataCookie(const ICAObject object, ICAEventDataCookie *cookie) { return kICAInvalidObjectErr; }
ICAError ICDScannerCreateEventDataCookie(const ICAObject object, ICAEventDataCookie *cookie) { return kICAInvalidObjectErr; }

static ICAError
no_info(CFDictionaryRef *theDict)
{
    if (theDict)
        *theDict = NULL;
    return kICADeviceNotFoundErr;
}

ICAError ICDCopyDeviceInfoDictionary(const char *deviceName, CFDictionaryRef *theDict) { return no_info(theDict); }
ICAError ICDScannerCopyDeviceInfoDictionary(const char *deviceName, CFDictionaryRef *theDict) { return no_info(theDict); }

ICAError ICDCreateICAThumbnailFromICNS(const char *fileName, void *thumbnail) { return kICAFileCorruptedErr; }
ICAError ICDScannerCreateICAThumbnailFromICNS(const char *fileName, void *thumbnail) { return kICAFileCorruptedErr; }
ICAError ICDCreateICAThumbnailFromIconRef(const IconRef iconRef, void *thumbnail) { return kICAFileCorruptedErr; }

/* Scanned image data and its colour space */

ICAError
ICDAddImageInfoToNotificationDictionary(CFMutableDictionaryRef dict, UInt32 width, UInt32 height, UInt32 bytesPerRow,
                                        UInt32 dataStartRow, UInt32 dataNumberOfRows, UInt32 dataSize, void *dataBuffer)
{
    return dict ? kICACommunicationErr : kICADeviceInvalidParamErr;
}

ICAError
ICDAddBandInfoToNotificationDictionary(CFMutableDictionaryRef dict, UInt32 width, UInt32 height, UInt32 bitsPerPixel,
                                       UInt32 bitsPerComponent, UInt32 numComponents, UInt32 endianness,
                                       UInt32 pixelDataType, UInt32 bytesPerRow, UInt32 dataStartRow,
                                       UInt32 dataNumberOfRows, UInt32 dataSize, void *dataBuffer)
{
    return dict ? kICACommunicationErr : kICADeviceInvalidParamErr;
}

CGColorSpaceRef
ICDCreateColorSpace(UInt32 bitsPerPixel, UInt32 samplesPerPixel, ICAObject icaObject, CFStringRef colorSyncMode,
                    CFDataRef abstractProfile, char *tmpProfilePath)
{
    if (samplesPerPixel == 1)
        return CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
    if (samplesPerPixel == 3 || samplesPerPixel == 4)
        return CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    return NULL;
}

/* Connecting devices: there are no device modules to take them. */

#define NOT_FOUND { return kICADeviceNotFoundErr; }
ICAError ICDConnectUSBDevice(UInt32 locationID) NOT_FOUND
ICAError ICDConnectUSBDeviceWithIORegPath(UInt32 locationID, io_string_t ioregPath) NOT_FOUND
ICAError ICDDisconnectUSBDevice(UInt32 locationID) NOT_FOUND
ICAError ICDDisconnectUSBDeviceWithIORegPath(UInt32 locationID, io_string_t ioregPath) NOT_FOUND
ICAError ICDConnectFWDevice(UInt64 guid) NOT_FOUND
ICAError ICDConnectFWDeviceWithIORegPath(UInt64 guid, io_string_t ioregPath) NOT_FOUND
ICAError ICDDisconnectFWDevice(UInt64 guid) NOT_FOUND
ICAError ICDDisconnectFWDeviceWithIORegPath(UInt64 guid, io_string_t ioregPath) NOT_FOUND
ICAError ICDConnectBluetoothDevice(CFDictionaryRef params) NOT_FOUND
ICAError ICDDisconnectBluetoothDevice(CFDictionaryRef params) NOT_FOUND
ICAError ICDConnectTCPIPDevice(CFDictionaryRef params) NOT_FOUND
ICAError ICDDisconnectTCPIPDevice(CFDictionaryRef params) NOT_FOUND
ICAError ICDScannerConnectUSBDevice(UInt32 locationID) NOT_FOUND
ICAError ICDScannerConnectUSBDeviceWithIORegPath(UInt32 locationID, io_string_t ioregPath) NOT_FOUND
ICAError ICDScannerDisconnectUSBDevice(UInt32 locationID) NOT_FOUND
ICAError ICDScannerDisconnectUSBDeviceWithIORegPath(UInt32 locationID, io_string_t ioregPath) NOT_FOUND
ICAError ICDScannerConnectFWDevice(UInt64 guid) NOT_FOUND
ICAError ICDScannerConnectFWDeviceWithIORegPath(UInt64 guid, io_string_t ioregPath) NOT_FOUND
ICAError ICDScannerDisconnectFWDevice(UInt64 guid) NOT_FOUND
ICAError ICDScannerDisconnectFWDeviceWithIORegPath(UInt64 guid, io_string_t ioregPath) NOT_FOUND
ICAError ICDScannerConnectBluetoothDevice(CFDictionaryRef params) NOT_FOUND
ICAError ICDScannerDisconnectBluetoothDevice(CFDictionaryRef params) NOT_FOUND
ICAError ICDScannerConnectTCPIPDevice(CFDictionaryRef params) NOT_FOUND
ICAError ICDScannerDisconnectTCPIPDevice(CFDictionaryRef params) NOT_FOUND
