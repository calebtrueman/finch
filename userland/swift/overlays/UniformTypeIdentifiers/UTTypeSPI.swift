// SPDX-License-Identifier: MIT OR Apache-2.0
// Apple's UniformTypeIdentifiers overlay also exports private (SPI) type
// constants, which some of Apple's apps use (Wallet passes, app categories,
// device types). Finch provides them by identifier; the identifiers are those
// of Apple's framework's private constants (read on macOS 26.4).

extension UTType {
  public static var _appCategory: UTType { UTType(importedAs: "public.app-category") }
  public static var _appCategoryActionGames: UTType { UTType(importedAs: "public.app-category.action-games") }
  public static var _appCategoryAdventureGames: UTType { UTType(importedAs: "public.app-category.adventure-games") }
  public static var _appCategoryArcadeGames: UTType { UTType(importedAs: "public.app-category.arcade-games") }
  public static var _appCategoryBoardGames: UTType { UTType(importedAs: "public.app-category.board-games") }
  public static var _appCategoryBookmarks: UTType { UTType(importedAs: "public.app-category.bookmarks") }
  public static var _appCategoryBooks: UTType { UTType(importedAs: "public.app-category.books") }
  public static var _appCategoryBusiness: UTType { UTType(importedAs: "public.app-category.business") }
  public static var _appCategoryCardGames: UTType { UTType(importedAs: "public.app-category.card-games") }
  public static var _appCategoryCasinoGames: UTType { UTType(importedAs: "public.app-category.casino-games") }
  public static var _appCategoryDeveloperTools: UTType { UTType(importedAs: "public.app-category.developer-tools") }
  public static var _appCategoryDiceGames: UTType { UTType(importedAs: "public.app-category.dice-games") }
  public static var _appCategoryEducation: UTType { UTType(importedAs: "public.app-category.education") }
  public static var _appCategoryEducationalGames: UTType { UTType(importedAs: "public.app-category.educational-games") }
  public static var _appCategoryEntertainment: UTType { UTType(importedAs: "public.app-category.entertainment") }
  public static var _appCategoryFamilyGames: UTType { UTType(importedAs: "public.app-category.family-games") }
  public static var _appCategoryFinance: UTType { UTType(importedAs: "public.app-category.finance") }
  public static var _appCategoryFoodAndDrink: UTType { UTType(importedAs: "public.app-category.food-and-drink") }
  public static var _appCategoryGames: UTType { UTType(importedAs: "public.app-category.games") }
  public static var _appCategoryGraphicsDesign: UTType { UTType(importedAs: "public.app-category.graphics-design") }
  public static var _appCategoryHealthcareFitness: UTType { UTType(importedAs: "public.app-category.healthcare-fitness") }
  public static var _appCategoryKidsGames: UTType { UTType(importedAs: "public.app-category.kids-games") }
  public static var _appCategoryLifestyle: UTType { UTType(importedAs: "public.app-category.lifestyle") }
  public static var _appCategoryMagazinesAndNewspapers: UTType { UTType(importedAs: "public.app-category.magazines-and-newspapers") }
  public static var _appCategoryMedical: UTType { UTType(importedAs: "public.app-category.medical") }
  public static var _appCategoryMusic: UTType { UTType(importedAs: "public.app-category.music") }
  public static var _appCategoryMusicGames: UTType { UTType(importedAs: "public.app-category.music-games") }
  public static var _appCategoryNavigation: UTType { UTType(importedAs: "public.app-category.navigation") }
  public static var _appCategoryNews: UTType { UTType(importedAs: "public.app-category.news") }
  public static var _appCategoryPhotoAndVideo: UTType { UTType(importedAs: "public.app-category.photography-and-video") }
  public static var _appCategoryPhotography: UTType { UTType(importedAs: "public.app-category.photography") }
  public static var _appCategoryProductivity: UTType { UTType(importedAs: "public.app-category.productivity") }
  public static var _appCategoryPuzzleGames: UTType { UTType(importedAs: "public.app-category.puzzle-games") }
  public static var _appCategoryRacingGames: UTType { UTType(importedAs: "public.app-category.racing-games") }
  public static var _appCategoryReference: UTType { UTType(importedAs: "public.app-category.reference") }
  public static var _appCategoryRolePlayingGames: UTType { UTType(importedAs: "public.app-category.role-playing-games") }
  public static var _appCategoryShopping: UTType { UTType(importedAs: "public.app-category.shopping") }
  public static var _appCategorySimulationGames: UTType { UTType(importedAs: "public.app-category.simulation-games") }
  public static var _appCategorySocialNetworking: UTType { UTType(importedAs: "public.app-category.social-networking") }
  public static var _appCategorySports: UTType { UTType(importedAs: "public.app-category.sports") }
  public static var _appCategorySportsGames: UTType { UTType(importedAs: "public.app-category.sports-games") }
  public static var _appCategoryStrategyGames: UTType { UTType(importedAs: "public.app-category.strategy-games") }
  public static var _appCategoryTravel: UTType { UTType(importedAs: "public.app-category.travel") }
  public static var _appCategoryTriviaGames: UTType { UTType(importedAs: "public.app-category.trivia-games") }
  public static var _appCategoryUtilities: UTType { UTType(importedAs: "public.app-category.utilities") }
  public static var _appCategoryVideo: UTType { UTType(importedAs: "public.app-category.video") }
  public static var _appCategoryWeather: UTType { UTType(importedAs: "public.app-category.weather") }
  public static var _appCategoryWordGames: UTType { UTType(importedAs: "public.app-category.word-games") }
  public static var _appleDevice: UTType { UTType(importedAs: "com.apple.device") }
  public static var _appleEncryptedArchive: UTType { UTType(importedAs: "com.apple.encrypted-archive") }
  public static var _appleTV: UTType { UTType(importedAs: "com.apple.apple-tv") }
  public static var _appleVisionPro: UTType { UTType(importedAs: "com.apple.visionpro") }
  public static var _appleWatch: UTType { UTType(importedAs: "com.apple.watch") }
  public static var _applicationsFolder: UTType { UTType(importedAs: "com.apple.applications-folder") }
  public static var _blockSpecial: UTType { UTType(importedAs: "public.block-special") }
  public static var _characterSpecial: UTType { UTType(importedAs: "public.character-special") }
  public static var _computer: UTType { UTType(importedAs: "public.computer") }
  public static var _dataContainer: UTType { UTType(importedAs: "com.apple.data-container") }
  public static var _device: UTType { UTType(importedAs: "public.device") }
  public static var _display: UTType { UTType(importedAs: "public.display") }
  public static var _dropFolder: UTType { UTType(importedAs: "com.apple.drop-folder") }
  public static var _genericPC: UTType { UTType(importedAs: "public.generic-pc") }
  public static var _heifStandard: UTType { UTType(importedAs: "public.heif-standard") }
  public static var _homePod: UTType { UTType(importedAs: "com.apple.homepod") }
  public static var _libraryFolder: UTType { UTType(importedAs: "com.apple.library-folder") }
  public static var _mac: UTType { UTType(importedAs: "com.apple.mac") }
  public static var _macBook: UTType { UTType(importedAs: "com.apple.macbook") }
  public static var _macBookAir: UTType { UTType(importedAs: "com.apple.macbookair") }
  public static var _macBookPro: UTType { UTType(importedAs: "com.apple.macbookpro") }
  public static var _macLaptop: UTType { UTType(importedAs: "com.apple.mac.laptop") }
  public static var _macMini: UTType { UTType(importedAs: "com.apple.macmini") }
  public static var _macPro: UTType { UTType(importedAs: "com.apple.macpro") }
  public static var _mxiFile: UTType { UTType(importedAs: "com.apple.mxi.file") }
  public static var _namedPipeOrFIFO: UTType { UTType(importedAs: "public.named-pipe") }
  public static var _networkNeighborhood: UTType { UTType(importedAs: "com.apple.network-neighborhood") }
  public static var _passBundle: UTType { UTType(importedAs: "com.apple.pkpass") }
  public static var _passData: UTType { UTType(importedAs: "com.apple.pkpass-data") }
  public static var _passesData: UTType { UTType(importedAs: "com.apple.pkpasses-data") }
  public static var _remoteApplicationPlaceholder: UTType { UTType(importedAs: "com.apple.remote-application-placeholder") }
  public static var _serversFolder: UTType { UTType(importedAs: "com.apple.servers-folder") }
  public static var _socket: UTType { UTType(importedAs: "public.socket") }
  public static var _speaker: UTType { UTType(importedAs: "public.speaker") }
  public static var _iMac: UTType { UTType(importedAs: "com.apple.imac") }
  public static var _iOSDevice: UTType { UTType(importedAs: "com.apple.ios-device") }
  public static var _iOSSimulator: UTType { UTType(importedAs: "com.apple.ios-simulator") }
  public static var _iPad: UTType { UTType(importedAs: "com.apple.ipad") }
  public static var _iPhone: UTType { UTType(importedAs: "com.apple.iphone") }
  public static var _iPodTouch: UTType { UTType(importedAs: "com.apple.ipod") }
  /// The type of the machine running the code (Apple's names the model and
  /// colour); Finch answers with the generic Mac type.
  public static var _currentDevice: UTType { UTType(importedAs: "com.apple.mac") }
}

extension UTTagClass {
  public static var _pasteboardType: UTTagClass { UTTagClass(rawValue: "com.apple.nspboard-type") }
  public static var _hfsTypeCode: UTTagClass { UTTagClass(rawValue: "com.apple.ostype") }
  public static var _deviceModelCode: UTTagClass { UTTagClass(rawValue: "com.apple.device-model-code") }
}

/// A device enclosure colour (SPI of Apple's overlay, for device types).
public enum UTHardwareColor: Hashable, Codable {
  case rgb(UInt8, UInt8, UInt8)
  case indexed(Int32)

  /// Finch doesn't know the machine's colour.
  public static var currentEnclosureColor: UTHardwareColor? { nil }
}

extension UTType {
  // Tag classes Apple's framework keeps private.
  private static let hfsTagClass = UTTagClass(rawValue: "com.apple.ostype")
  private static let deviceModelTagClass = UTTagClass(rawValue: "com.apple.device-model-code")

  public init?(_identifier identifier: String, allowUndeclared: Bool) {
    if let type = UTType(identifier) {
      self = type
    } else if allowUndeclared {
      self.init(importedAs: identifier)
    } else {
      return nil
    }
  }

  public init(_exportedAs identifier: String, from bundle: Bundle, conformingTo parentType: UTType?) {
    self.init(exportedAs: identifier, conformingTo: parentType)
  }

  public init(_importedAs identifier: String, from bundle: Bundle, conformingTo parentType: UTType?) {
    self.init(importedAs: identifier, conformingTo: parentType)
  }

  public init?(_hfsTypeCode code: UInt32, conformingTo supertype: UTType) {
    let tag = String(decoding: withUnsafeBytes(of: code.bigEndian) { Array($0) }, as: UTF8.self)
    self.init(tag: tag, tagClass: UTType.hfsTagClass, conformingTo: supertype)
  }

  public var _hfsTypeCodes: [UInt32] {
    return (tags[UTType.hfsTagClass] ?? []).compactMap { tag in
      let bytes = Array(tag.utf8)
      guard bytes.count == 4 else { return nil }
      return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
  }

  public var _preferredHFSTypeCode: UInt32? { _hfsTypeCodes.first }

  public init?(_deviceModelCode code: String, enclosureColor: UTHardwareColor?) {
    self.init(tag: code, tagClass: UTType.deviceModelTagClass, conformingTo: nil)
  }

  public init?(_rawBluetoothProductID productID: UInt32, rawVendorID vendorID: UInt16) {
    return nil
  }

  public init(_forPromiseFileAt url: URL) throws {
    self = UTType(filenameExtension: url.pathExtension) ?? .data
  }

  public init(_ofItemAt url: URL) throws {
    if let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType {
      self = type
    } else {
      self = UTType(filenameExtension: url.pathExtension) ?? .data
    }
  }

  public var _isCoreType: Bool { UTType._namedConstants_UTCoreTypes.contains(self) }
  public var _isExported: Bool { false }
  public var _isImported: Bool { false }
  public var _isWildcard: Bool { false }
  public var _parentTypes: [UTType] { Array(supertypes.subtracting([self])) }
  public var _childTypes: Set<UTType> { [] }
  public var _subtypes: Set<UTType> { [] }
  public var _kindString: String? { localizedDescription }
  public func _kindString(using preferredLocalizations: [String]) -> String? { localizedDescription }
  public func _localizedDescription(using preferredLocalizations: [String]) -> String? {
    localizedDescription
  }
  public var _kindStringDictionary: [String: String] { [:] }
  public var _localizedDescriptionDictionary: [String: String] { [:] }
  public var _enclosureColor: UTHardwareColor? { nil }
  public var _enclosureColors: [UTHardwareColor] { [] }
  public var _preferredEnclosureColor: UTHardwareColor? { nil }
  public var referenceAccessoryURL: URL? { nil }

  public static var _namedConstants_UTCoreTypes: [UTType] {
    [.item, .content, .compositeContent, .diskImage, .data, .directory, .resolvable, .symbolicLink, .executable, .mountPoint, .aliasFile, .urlBookmarkData, .url, .fileURL, .text, .plainText, .utf8PlainText, .utf16ExternalPlainText, .utf16PlainText, .delimitedText, .commaSeparatedText, .tabSeparatedText, .utf8TabSeparatedText, .rtf, .html, .xml, .yaml, .css, .sourceCode, .assemblyLanguageSource, .cSource, .objectiveCSource, .swiftSource, .cPlusPlusSource, .objectiveCPlusPlusSource, .cHeader, .cPlusPlusHeader, .script, .appleScript, .osaScript, .osaScriptBundle, .javaScript, .shellScript, .perlScript, .pythonScript, .rubyScript, .phpScript, .makefile, .json, .propertyList, .xmlPropertyList, .binaryPropertyList, .pdf, .rtfd, .flatRTFD, .webArchive, .image, .jpeg, .tiff, .gif, .png, .icns, .bmp, .ico, .rawImage, .svg, .livePhoto, .heif, .heic, .heics, .webP, .exr, .dng, .jpegxl, .threeDContent, .usd, .usdz, .realityFile, .sceneKitScene, .arReferenceObject, .audiovisualContent, .movie, .video, .audio, .quickTimeMovie, .mpeg, .mpeg2Video, .mpeg2TransportStream, .mp3, .mpeg4Movie, .mpeg4Audio, .appleProtectedMPEG4Audio, .appleProtectedMPEG4Video, .avi, .aiff, .wav, .midi, .playlist, .m3uPlaylist, .folder, .volume, .package, .bundle, .pluginBundle, .spotlightImporter, .quickLookGenerator, .xpcService, .framework, .application, .applicationBundle, .applicationExtension, .unixExecutable, .exe, .systemPreferencesPane, .archive, .gzip, .bz2, .zip, .appleArchive, .tarArchive, .spreadsheet, .presentation, .database, .message, .contact, .vCard, .toDoItem, .calendarEvent, .emailMessage, .internetLocation, .internetShortcut, .font, .bookmark, .pkcs12, .x509Certificate, .epub, .log, .ahap, .geoJSON, .linkPresentationMetadata]
  }

  public static var _namedConstants_UTCoreTypesPriv: [UTType] {
    [._appCategory, ._appCategoryActionGames, ._appCategoryAdventureGames, ._appCategoryArcadeGames, ._appCategoryBoardGames, ._appCategoryBookmarks, ._appCategoryBooks, ._appCategoryBusiness, ._appCategoryCardGames, ._appCategoryCasinoGames, ._appCategoryDeveloperTools, ._appCategoryDiceGames, ._appCategoryEducation, ._appCategoryEducationalGames, ._appCategoryEntertainment, ._appCategoryFamilyGames, ._appCategoryFinance, ._appCategoryFoodAndDrink, ._appCategoryGames, ._appCategoryGraphicsDesign, ._appCategoryHealthcareFitness, ._appCategoryKidsGames, ._appCategoryLifestyle, ._appCategoryMagazinesAndNewspapers, ._appCategoryMedical, ._appCategoryMusic, ._appCategoryMusicGames, ._appCategoryNavigation, ._appCategoryNews, ._appCategoryPhotoAndVideo, ._appCategoryPhotography, ._appCategoryProductivity, ._appCategoryPuzzleGames, ._appCategoryRacingGames, ._appCategoryReference, ._appCategoryRolePlayingGames, ._appCategoryShopping, ._appCategorySimulationGames, ._appCategorySocialNetworking, ._appCategorySports, ._appCategorySportsGames, ._appCategoryStrategyGames, ._appCategoryTravel, ._appCategoryTriviaGames, ._appCategoryUtilities, ._appCategoryVideo, ._appCategoryWeather, ._appCategoryWordGames, ._appleDevice, ._appleEncryptedArchive, ._appleTV, ._appleVisionPro, ._appleWatch, ._applicationsFolder, ._blockSpecial, ._characterSpecial, ._computer, ._dataContainer, ._device, ._display, ._dropFolder, ._genericPC, ._heifStandard, ._homePod, ._libraryFolder, ._mac, ._macBook, ._macBookAir, ._macBookPro, ._macLaptop, ._macMini, ._macPro, ._mxiFile, ._namedPipeOrFIFO, ._networkNeighborhood, ._passBundle, ._passData, ._passesData, ._remoteApplicationPlaceholder, ._serversFolder, ._socket, ._speaker, ._iMac, ._iOSDevice, ._iOSSimulator, ._iPad, ._iPhone, ._iPodTouch]
  }

  public static func _types(identifiers: Set<String>) -> [String: UTType] {
    var result: [String: UTType] = [:]
    for identifier in identifiers {
      if let type = UTType(identifier) { result[identifier] = type }
    }
    return result
  }

  /// Finch enumerates the types it names as constants.
  public static func _enumerateAllDeclaredTypes(using body: (UTType, inout Bool) throws -> Void) throws {
    var stop = false
    for type in _namedConstants_UTCoreTypes + _namedConstants_UTCoreTypesPriv {
      try body(type, &stop)
      if stop { return }
    }
  }

  public static func _enumerateAllDeclaredTypes(using body: (UTType, inout Bool) -> Void) {
    var stop = false
    for type in _namedConstants_UTCoreTypes + _namedConstants_UTCoreTypesPriv {
      body(type, &stop)
      if stop { return }
    }
  }
}
