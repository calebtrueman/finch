/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ImageCaptureCore's string constants: every one Apple's exports, with the
 * values Apple's framework has on macOS 26 (read on the host with dlsym).
 * Some are not in the SDK's headers but are exported all the same.
 */
#import <ImageCaptureCore/ImageCaptureCore.h>

#pragma clang diagnostic ignored "-Wavailability"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

NSString *const ICADevicesFrameworkPath = @"/System/Library/Frameworks/ICADevices.framework";
NSString *const ICAuthorizationStatusAuthorized = @"ICAuthorizationStatusAuthorized";
NSString *const ICAuthorizationStatusDenied = @"ICAuthorizationStatusDenied";
NSString *const ICAuthorizationStatusNotDetermined = @"ICAuthorizationStatusNotDetermined";
NSString *const ICAuthorizationStatusRestricted = @"ICAuthorizationStatusRestricted";
NSString *const ICButtonTypeCopy = @"ICButtonTypeCopy";
NSString *const ICButtonTypeMail = @"ICButtonTypeMail";
NSString *const ICButtonTypePrint = @"ICButtonTypePrint";
NSString *const ICButtonTypeScan = @"ICButtonTypeScan";
NSString *const ICButtonTypeTransfer = @"ICButtonTypeTransfer";
NSString *const ICButtonTypeWeb = @"ICButtonTypeWeb";
NSString *const ICCameraDeviceCanAcceptPTPCommands = @"ICCameraDeviceCanAcceptPTPCommands";
NSString *const ICCameraDeviceCanDeleteAllFiles = @"ICCameraDeviceCanDeleteAllFiles";
NSString *const ICCameraDeviceCanDeleteOneFile = @"ICCameraDeviceCanDeleteOneFile";
NSString *const ICCameraDeviceCanReceiveFile = @"ICCameraDeviceCanReceiveFile";
NSString *const ICCameraDeviceCanSyncClock = @"ICCameraDeviceCanSyncClock";
NSString *const ICCameraDeviceCanTakePicture = @"ICCameraDeviceCanTakePicture";
NSString *const ICCameraDeviceCanTakePictureUsingShutterReleaseOnCamera = @"ICCameraDeviceCanTakePictureUsingShutterReleaseOnCamera";
NSString *const ICCameraDeviceSupportsApplePTP = @"ICCameraDeviceSupportsApplePTP";
NSString *const ICCameraDeviceSupportsHEIF = @"ICCameraDeviceSupportsHEIF";
NSString *const ICCameraDeviceSupportsPLRUUID = @"ICCameraDeviceSupportsPLRUUID";
NSString *const ICDeleteAfterSuccessfulDownload = @"ICDeleteAfterSuccessfulDownload";
NSString *const ICDeleteCanceled = @"ICDeleteCanceled";
NSString *const ICDeleteErrorCanceled = @"ICDeleteErrorCanceled";
NSString *const ICDeleteErrorDeviceMissing = @"ICDeleteErrorDeviceMissing";
NSString *const ICDeleteErrorFileMissing = @"ICDeleteErrorFileMissing";
NSString *const ICDeleteErrorReadOnly = @"ICDeleteErrorReadOnly";
NSString *const ICDeleteFailed = @"ICDeleteFailed";
NSString *const ICDeleteSuccessful = @"ICDeleteSuccessful";
NSString *const ICDeviceCanEjectOrDisconnect = @"ICDeviceCanEjectOrDisconnect";
NSString *const ICDeviceLocationDescriptionBluetooth = @"ICDeviceLocationDescriptionBluetooth";
NSString *const ICDeviceLocationDescriptionFireWire = @"ICDeviceLocationDescriptionFireWire";
NSString *const ICDeviceLocationDescriptionMassStorage = @"ICDeviceLocationDescriptionMassStorage";
NSString *const ICDeviceLocationDescriptionUSB = @"ICDeviceLocationDescriptionUSB";
NSString *const ICDownloadsDirectoryURL = @"ICDownloadsDirectoryURL";
NSString *const ICDownloadSidecarFiles = @"ICDownloadSidecarFiles";
NSString *const ICEnumerationChronologicalOrder = @"ICEnumerationChronologicalOrder";
NSString *const ICEnumerationPrioritizeSpeed = @"ICEnumerationPrioritizeSpeed";
NSString *const ICEnumerationPrioritizeTethering = @"ICEnumerationPrioritizeTethering";
NSString *const ICErrorDomain = @"com.apple.ImageCaptureCore";
NSString *const ICImageSourceShouldCache = @"kCGImageSourceShouldCache";
NSString *const ICImageSourceThumbnailMaxPixelSize = @"kCGImageSourceThumbnailMaxPixelSize";
NSString *const ICLocalizedStatusNotificationKey = @"ICLocalizedStatusNotificationKey";
NSString *const ICMetadataBrevity = @"kICMetadataBrevity";
NSString *const ICMetadataBrevityEssential = @"kICMetadataBrevityEssential";
NSString *const ICOverwrite = @"ICOverwrite";
NSString *const ICRawExtension = @"ica";
NSString *const ICRunLoopMode = @"com.apple.ImageCaptureCore";
NSString *const ICSaveAsFilename = @"ICSaveAsFilename";
NSString *const ICSavedAncillaryFiles = @"ICSavedAncillaryFiles";
NSString *const ICSavedFilename = @"ICSavedFilename";
NSString *const ICScannerStatusRequestsOverviewScan = @"ICScannerStatusRequestsOverviewScan";
NSString *const ICScannerStatusWarmingUp = @"ICScannerStatusWarmingUp";
NSString *const ICScannerStatusWarmUpDone = @"ICScannerStatusWarmUpDone";
NSString *const ICStatusCodeKey = @"ICStatusCodeKey";
NSString *const ICStatusNotificationKey = @"ICStatusNotificationKey";
NSString *const ICStatusSoftwareInstallation = @"ICStatusSoftwareInstallation";
NSString *const ICTransportTypeBluetooth = @"ICTransportTypeBluetooth";
NSString *const ICTransportTypeExFAT = @"ICTransportTypeExFAT";
NSString *const ICTransportTypeFireWire = @"ICTransportTypeFireWire";
NSString *const ICTransportTypeMassStorage = @"ICTransportTypeMassStorage";
NSString *const ICTransportTypeProximity = @"ICTransportTypeProximity";
NSString *const ICTransportTypeTCPIP = @"ICTransportTypeTCPIP";
NSString *const ICTransportTypeUSB = @"ICTransportTypeUSB";
NSString *const ICTruncateAfterSuccessfulDownload = @"ICTruncateAfterSuccessfulDownload";
NSString *const ICUTTypeRaw = @"com.apple.ica.raw";
