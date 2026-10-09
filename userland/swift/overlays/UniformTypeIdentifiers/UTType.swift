// SPDX-License-Identifier: MIT OR Apache-2.0
// The UniformTypeIdentifiers overlay: UTType, the Swift value type over the
// framework's Objective-C UTType class (UTTypeReference in Swift), and
// UTTagClass, with the declarations of Apple's overlay (macOS 26.4 SDK).
// Finch's code, over Finch's UniformTypeIdentifiers.framework.

@_exported import UniformTypeIdentifiers
import Foundation

public struct UTType: Sendable {
  internal let _reference: UTTypeReference

  internal init(_ reference: UTTypeReference) {
    _reference = reference
  }
}

extension UTType {
  public init?(_ identifier: String) {
    guard let reference = UTTypeReference(identifier) else { return nil }
    self.init(reference)
  }

  public init?(filenameExtension: String, conformingTo supertype: UTType = .data) {
    guard let reference = UTTypeReference(filenameExtension: filenameExtension,
                                                 conformingTo: supertype)
    else { return nil }
    self.init(reference)
  }

  public init?(mimeType: String, conformingTo supertype: UTType = .data) {
    guard let reference = UTTypeReference(mimeType: mimeType,
                                                 conformingTo: supertype)
    else { return nil }
    self.init(reference)
  }

  public var identifier: String { _reference.identifier }
  public var preferredFilenameExtension: String? { _reference.preferredFilenameExtension }
  public var preferredMIMEType: String? { _reference.preferredMIMEType }
  public var localizedDescription: String? { _reference.localizedDescription }
  public var version: Int? { _reference.version?.intValue }
  public var referenceURL: URL? { _reference.referenceURL }
  public var isDynamic: Bool { _reference.isDynamic }
  public var isDeclared: Bool { _reference.isDeclared }
  public var isPublic: Bool { _reference.isPublic }
}

extension UTType {
  public func conforms(to type: UTType) -> Bool {
    return _reference.conforms(to: type)
  }

  public func isSupertype(of type: UTType) -> Bool {
    return _reference.isSupertype(of: type)
  }

  public func isSubtype(of type: UTType) -> Bool {
    return _reference.isSubtype(of: type)
  }

  public var supertypes: Set<UTType> { _reference.supertypes }
}

extension UTType {
  public init?(tag: String, tagClass: UTTagClass, conformingTo supertype: UTType?) {
    guard let reference = UTTypeReference(tag: tag, tagClass: tagClass.rawValue,
                                                 conformingTo: supertype)
    else { return nil }
    self.init(reference)
  }

  public static func types(tag: String, tagClass: UTTagClass, conformingTo supertype: UTType?)
    -> [UTType]
  {
    return UTTypeReference.types(tag: tag, tagClass: tagClass.rawValue,
                                 conformingTo: supertype)
  }

  public var tags: [UTTagClass: [String]] {
    var result: [UTTagClass: [String]] = [:]
    for (tagClass, values) in _reference.tags {
      result[UTTagClass(rawValue: tagClass)] = values
    }
    return result
  }
}

extension UTType {
  public init(exportedAs identifier: String, conformingTo parentType: UTType? = nil) {
    if let parentType {
      self.init(UTTypeReference(exportedAs: identifier, conformingTo: parentType))
    } else {
      self.init(UTTypeReference(exportedAs: identifier))
    }
  }

  public init(importedAs identifier: String, conformingTo parentType: UTType? = nil) {
    if let parentType {
      self.init(UTTypeReference(importedAs: identifier, conformingTo: parentType))
    } else {
      self.init(UTTypeReference(importedAs: identifier))
    }
  }
}

extension UTType: Equatable, Hashable {
  public static func == (lhs: UTType, rhs: UTType) -> Bool {
    return lhs._reference.isEqual(rhs._reference)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(_reference.hash)
  }
}

extension UTType: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { identifier }
  public var debugDescription: String { _reference.debugDescription }
}

extension UTType: ReferenceConvertible {
  public typealias ReferenceType = UTTypeReference

  public func _bridgeToObjectiveC() -> UTTypeReference {
    return _reference
  }

  public static func _forceBridgeFromObjectiveC(_ source: UTTypeReference, result: inout UTType?) {
    result = UTType(source)
  }

  public static func _conditionallyBridgeFromObjectiveC(
    _ source: UTTypeReference, result: inout UTType?
  ) -> Bool {
    result = UTType(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: UTTypeReference?) -> UTType {
    return UTType(source!)
  }
}

extension UTType: Codable {
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(identifier)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let identifier = try container.decode(String.self)
    guard let type = UTType(identifier) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "unknown type identifier \(identifier)")
    }
    self = type
  }
}

extension UTType {
  public static var item: UTType { UTType(__UTTypeItem) }
  public static var content: UTType { UTType(__UTTypeContent) }
  public static var compositeContent: UTType { UTType(__UTTypeCompositeContent) }
  public static var diskImage: UTType { UTType(__UTTypeDiskImage) }
  public static var data: UTType { UTType(__UTTypeData) }
  public static var directory: UTType { UTType(__UTTypeDirectory) }
  public static var resolvable: UTType { UTType(__UTTypeResolvable) }
  public static var symbolicLink: UTType { UTType(__UTTypeSymbolicLink) }
  public static var executable: UTType { UTType(__UTTypeExecutable) }
  public static var mountPoint: UTType { UTType(__UTTypeMountPoint) }
  public static var aliasFile: UTType { UTType(__UTTypeAliasFile) }
  public static var urlBookmarkData: UTType { UTType(__UTTypeURLBookmarkData) }
  public static var url: UTType { UTType(__UTTypeURL) }
  public static var fileURL: UTType { UTType(__UTTypeFileURL) }
  public static var text: UTType { UTType(__UTTypeText) }
  public static var plainText: UTType { UTType(__UTTypePlainText) }
  public static var utf8PlainText: UTType { UTType(__UTTypeUTF8PlainText) }
  public static var utf16ExternalPlainText: UTType { UTType(__UTTypeUTF16ExternalPlainText) }
  public static var utf16PlainText: UTType { UTType(__UTTypeUTF16PlainText) }
  public static var delimitedText: UTType { UTType(__UTTypeDelimitedText) }
  public static var commaSeparatedText: UTType { UTType(__UTTypeCommaSeparatedText) }
  public static var tabSeparatedText: UTType { UTType(__UTTypeTabSeparatedText) }
  public static var utf8TabSeparatedText: UTType { UTType(__UTTypeUTF8TabSeparatedText) }
  public static var rtf: UTType { UTType(__UTTypeRTF) }
  public static var html: UTType { UTType(__UTTypeHTML) }
  public static var xml: UTType { UTType(__UTTypeXML) }
  public static var yaml: UTType { UTType(__UTTypeYAML) }
  public static var css: UTType { UTType(__UTTypeCSS) }
  public static var sourceCode: UTType { UTType(__UTTypeSourceCode) }
  public static var assemblyLanguageSource: UTType { UTType(__UTTypeAssemblyLanguageSource) }
  public static var cSource: UTType { UTType(__UTTypeCSource) }
  public static var objectiveCSource: UTType { UTType(__UTTypeObjectiveCSource) }
  public static var swiftSource: UTType { UTType(__UTTypeSwiftSource) }
  public static var cPlusPlusSource: UTType { UTType(__UTTypeCPlusPlusSource) }
  public static var objectiveCPlusPlusSource: UTType { UTType(__UTTypeObjectiveCPlusPlusSource) }
  public static var cHeader: UTType { UTType(__UTTypeCHeader) }
  public static var cPlusPlusHeader: UTType { UTType(__UTTypeCPlusPlusHeader) }
  public static var script: UTType { UTType(__UTTypeScript) }
  public static var appleScript: UTType { UTType(__UTTypeAppleScript) }
  public static var osaScript: UTType { UTType(__UTTypeOSAScript) }
  public static var osaScriptBundle: UTType { UTType(__UTTypeOSAScriptBundle) }
  public static var javaScript: UTType { UTType(__UTTypeJavaScript) }
  public static var shellScript: UTType { UTType(__UTTypeShellScript) }
  public static var perlScript: UTType { UTType(__UTTypePerlScript) }
  public static var pythonScript: UTType { UTType(__UTTypePythonScript) }
  public static var rubyScript: UTType { UTType(__UTTypeRubyScript) }
  public static var phpScript: UTType { UTType(__UTTypePHPScript) }
  public static var makefile: UTType { UTType(__UTTypeMakefile) }
  public static var json: UTType { UTType(__UTTypeJSON) }
  public static var propertyList: UTType { UTType(__UTTypePropertyList) }
  public static var xmlPropertyList: UTType { UTType(__UTTypeXMLPropertyList) }
  public static var binaryPropertyList: UTType { UTType(__UTTypeBinaryPropertyList) }
  public static var pdf: UTType { UTType(__UTTypePDF) }
  public static var rtfd: UTType { UTType(__UTTypeRTFD) }
  public static var flatRTFD: UTType { UTType(__UTTypeFlatRTFD) }
  public static var webArchive: UTType { UTType(__UTTypeWebArchive) }
  public static var image: UTType { UTType(__UTTypeImage) }
  public static var jpeg: UTType { UTType(__UTTypeJPEG) }
  public static var tiff: UTType { UTType(__UTTypeTIFF) }
  public static var gif: UTType { UTType(__UTTypeGIF) }
  public static var png: UTType { UTType(__UTTypePNG) }
  public static var icns: UTType { UTType(__UTTypeICNS) }
  public static var bmp: UTType { UTType(__UTTypeBMP) }
  public static var ico: UTType { UTType(__UTTypeICO) }
  public static var rawImage: UTType { UTType(__UTTypeRAWImage) }
  public static var svg: UTType { UTType(__UTTypeSVG) }
  public static var livePhoto: UTType { UTType(__UTTypeLivePhoto) }
  public static var heif: UTType { UTType(__UTTypeHEIF) }
  public static var heic: UTType { UTType(__UTTypeHEIC) }
  public static var heics: UTType { UTType(__UTTypeHEICS) }
  public static var webP: UTType { UTType(__UTTypeWebP) }
  public static var exr: UTType { UTType(__UTTypeEXR) }
  public static var dng: UTType { UTType(__UTTypeDNG) }
  public static var jpegxl: UTType { UTType(__UTTypeJPEGXL) }
  public static var threeDContent: UTType { UTType(__UTType3DContent) }
  public static var usd: UTType { UTType(__UTTypeUSD) }
  public static var usdz: UTType { UTType(__UTTypeUSDZ) }
  public static var realityFile: UTType { UTType(__UTTypeRealityFile) }
  public static var sceneKitScene: UTType { UTType(__UTTypeSceneKitScene) }
  public static var arReferenceObject: UTType { UTType(__UTTypeARReferenceObject) }
  public static var audiovisualContent: UTType { UTType(__UTTypeAudiovisualContent) }
  public static var movie: UTType { UTType(__UTTypeMovie) }
  public static var video: UTType { UTType(__UTTypeVideo) }
  public static var audio: UTType { UTType(__UTTypeAudio) }
  public static var quickTimeMovie: UTType { UTType(__UTTypeQuickTimeMovie) }
  public static var mpeg: UTType { UTType(__UTTypeMPEG) }
  public static var mpeg2Video: UTType { UTType(__UTTypeMPEG2Video) }
  public static var mpeg2TransportStream: UTType { UTType(__UTTypeMPEG2TransportStream) }
  public static var mp3: UTType { UTType(__UTTypeMP3) }
  public static var mpeg4Movie: UTType { UTType(__UTTypeMPEG4Movie) }
  public static var mpeg4Audio: UTType { UTType(__UTTypeMPEG4Audio) }
  public static var appleProtectedMPEG4Audio: UTType { UTType(__UTTypeAppleProtectedMPEG4Audio) }
  public static var appleProtectedMPEG4Video: UTType { UTType(__UTTypeAppleProtectedMPEG4Video) }
  public static var avi: UTType { UTType(__UTTypeAVI) }
  public static var aiff: UTType { UTType(__UTTypeAIFF) }
  public static var wav: UTType { UTType(__UTTypeWAV) }
  public static var midi: UTType { UTType(__UTTypeMIDI) }
  public static var playlist: UTType { UTType(__UTTypePlaylist) }
  public static var m3uPlaylist: UTType { UTType(__UTTypeM3UPlaylist) }
  public static var folder: UTType { UTType(__UTTypeFolder) }
  public static var volume: UTType { UTType(__UTTypeVolume) }
  public static var package: UTType { UTType(__UTTypePackage) }
  public static var bundle: UTType { UTType(__UTTypeBundle) }
  public static var pluginBundle: UTType { UTType(__UTTypePluginBundle) }
  public static var spotlightImporter: UTType { UTType(__UTTypeSpotlightImporter) }
  public static var quickLookGenerator: UTType { UTType(__UTTypeQuickLookGenerator) }
  public static var xpcService: UTType { UTType(__UTTypeXPCService) }
  public static var framework: UTType { UTType(__UTTypeFramework) }
  public static var application: UTType { UTType(__UTTypeApplication) }
  public static var applicationBundle: UTType { UTType(__UTTypeApplicationBundle) }
  public static var applicationExtension: UTType { UTType(__UTTypeApplicationExtension) }
  public static var unixExecutable: UTType { UTType(__UTTypeUnixExecutable) }
  public static var exe: UTType { UTType(__UTTypeEXE) }
  public static var systemPreferencesPane: UTType { UTType(__UTTypeSystemPreferencesPane) }
  public static var archive: UTType { UTType(__UTTypeArchive) }
  public static var gzip: UTType { UTType(__UTTypeGZIP) }
  public static var bz2: UTType { UTType(__UTTypeBZ2) }
  public static var zip: UTType { UTType(__UTTypeZIP) }
  public static var appleArchive: UTType { UTType(__UTTypeAppleArchive) }
  public static var tarArchive: UTType { UTType(__UTTypeTarArchive) }
  public static var spreadsheet: UTType { UTType(__UTTypeSpreadsheet) }
  public static var presentation: UTType { UTType(__UTTypePresentation) }
  public static var database: UTType { UTType(__UTTypeDatabase) }
  public static var message: UTType { UTType(__UTTypeMessage) }
  public static var contact: UTType { UTType(__UTTypeContact) }
  public static var vCard: UTType { UTType(__UTTypeVCard) }
  public static var toDoItem: UTType { UTType(__UTTypeToDoItem) }
  public static var calendarEvent: UTType { UTType(__UTTypeCalendarEvent) }
  public static var emailMessage: UTType { UTType(__UTTypeEmailMessage) }
  public static var internetLocation: UTType { UTType(__UTTypeInternetLocation) }
  public static var internetShortcut: UTType { UTType(__UTTypeInternetShortcut) }
  public static var font: UTType { UTType(__UTTypeFont) }
  public static var bookmark: UTType { UTType(__UTTypeBookmark) }
  public static var pkcs12: UTType { UTType(__UTTypePKCS12) }
  public static var x509Certificate: UTType { UTType(__UTTypeX509Certificate) }
  public static var epub: UTType { UTType(__UTTypeEPUB) }
  public static var log: UTType { UTType(__UTTypeLog) }
  public static var ahap: UTType { UTType(__UTTypeAHAP) }
  public static var geoJSON: UTType { UTType(__UTTypeGeoJSON) }
  public static var linkPresentationMetadata: UTType { UTType(__UTTypeLinkPresentationMetadata) }
}

public struct UTTagClass: RawRepresentable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

extension UTTagClass {
  public static var filenameExtension: UTTagClass { UTTagClass(rawValue: __UTTagClassFilenameExtension) }
  public static var mimeType: UTTagClass { UTTagClass(rawValue: __UTTagClassMIMEType) }
}

extension UTTagClass: Equatable, Hashable {
  public static func == (lhs: UTTagClass, rhs: UTTagClass) -> Bool {
    return lhs.rawValue == rhs.rawValue
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(rawValue)
  }
}

extension UTTagClass: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { rawValue }
  public var debugDescription: String { rawValue }
}

extension UTTagClass: Codable {
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    rawValue = try container.decode(String.self)
  }
}

extension URLResourceValues {
  public var contentType: UTType? {
    return allValues[.contentTypeKey] as? UTType
  }
}

extension URL {
  public func appendingPathComponent(_ partialName: String, conformingTo contentType: UTType) -> URL {
    return (self as NSURL).appendingPathComponent(partialName, conformingTo: contentType)
  }

  public mutating func appendPathComponent(_ partialName: String, conformingTo contentType: UTType) {
    self = appendingPathComponent(partialName, conformingTo: contentType)
  }

  public func appendingPathExtension(for contentType: UTType) -> URL {
    return (self as NSURL).appendingPathExtension(for: contentType)
  }

  public mutating func appendPathExtension(for contentType: UTType) {
    self = appendingPathExtension(for: contentType)
  }
}

extension String {
  @available(*, unavailable, message: "Use NSString's method or URL's.")
  public func appendingPathExtension(for contentType: UTType) -> Never {
    fatalError("unavailable")
  }

  @available(*, unavailable, message: "Use NSString's method or URL's.")
  public func appendingPathComponent(_ partialName: String, conformingTo contentType: UTType) -> Never {
    fatalError("unavailable")
  }
}

extension NSItemProvider {
  public convenience init(
    contentsOf fileURL: URL, contentType: UTType?, openInPlace: Bool = false,
    coordinated: Bool = false, visibility: NSItemProviderRepresentationVisibility = .all
  ) {
    self.init(__contentsOf: fileURL, contentType: contentType, openInPlace: openInPlace,
              coordinated: coordinated, visibility: visibility)
  }

  public func registerDataRepresentation(
    for contentType: UTType, visibility: NSItemProviderRepresentationVisibility = .all,
    loadHandler: @escaping @Sendable (@escaping (Data?, Error?) -> Void) -> Progress?
  ) {
    __registerDataRepresentation(forContentType: contentType, visibility: visibility, loadHandler: loadHandler)
  }

  public func registerFileRepresentation(
    for contentType: UTType, visibility: NSItemProviderRepresentationVisibility = .all,
    openInPlace: Bool = false,
    loadHandler: @escaping @Sendable (@escaping (URL?, Bool, Error?) -> Void) -> Progress?
  ) {
    __registerFileRepresentation(forContentType: contentType, visibility: visibility,
                                 openInPlace: openInPlace, loadHandler: loadHandler)
  }

  public func loadDataRepresentation(
    for contentType: UTType,
    completionHandler: @escaping @Sendable (Data?, Error?) -> Void
  ) -> Progress {
    return __loadDataRepresentation(forContentType: contentType, completionHandler: completionHandler)
  }

  public func loadFileRepresentation(
    for contentType: UTType, openInPlace: Bool = false,
    completionHandler: @escaping @Sendable (URL?, Bool, Error?) -> Void
  ) -> Progress {
    return __loadFileRepresentation(forContentType: contentType, openInPlace: openInPlace,
                                    completionHandler: completionHandler)
  }
}
