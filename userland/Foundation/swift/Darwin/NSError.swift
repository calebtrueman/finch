//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
// SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
// Finch: from Swift's historical overlay stdlib/public/Darwin/Foundation/NSError.swift
// (swift-5.4-RELEASE), less what swift-foundation now carries; edits are
// marked "Finch:" or noted in docs/design/FOUNDATION.md.

@_exported import Foundation // Clang module
import CoreFoundation
import Darwin
@_implementationOnly import _SwiftFoundationOverlayShims

//===----------------------------------------------------------------------===//
// NSError (as an out parameter).
//===----------------------------------------------------------------------===//

public typealias NSErrorPointer = AutoreleasingUnsafeMutablePointer<NSError?>?

// Note: NSErrorPointer becomes ErrorPointer in Swift 3.
public typealias ErrorPointer = NSErrorPointer

// An error value to use when an Objective-C API indicates error
// but produces a nil error object.
// This is 'internal' rather than 'private' for no other reason but to make the
// type print more nicely. It's not part of the ABI, so if type printing of
// private things improves we can change it.
internal enum _GenericObjCError : Error {
  case nilError
}
// A cached instance of the above in order to save on the conversion to Error.
private let _nilObjCError: Error = _GenericObjCError.nilError

public // COMPILER_INTRINSIC
func _convertNSErrorToError(_ error: NSError?) -> Error {
  if let error = error {
    return error
  }
  return _nilObjCError
}

public // COMPILER_INTRINSIC
func _convertErrorToNSError(_ error: Error) -> NSError {
  return unsafeDowncast(_bridgeErrorToNSError(error), to: NSError.self)
}

// was renamed. The old name must not be used in the new runtime.
class __NSErrorRecoveryAttempter {
  @objc(attemptRecoveryFromError:optionIndex:delegate:didRecoverSelector:contextInfo:)
  func attemptRecovery(fromError nsError: NSError,
                       optionIndex recoveryOptionIndex: Int,
                       delegate: AnyObject?,
                       didRecoverSelector: Selector,
                       contextInfo: UnsafeMutableRawPointer?) {
    let error = nsError as Error as! RecoverableError
    error.attemptRecovery(optionIndex: recoveryOptionIndex) { success in
      __NSErrorPerformRecoverySelector(delegate, didRecoverSelector, success, contextInfo)
    }
  }

  @objc(attemptRecoveryFromError:optionIndex:)
  func attemptRecovery(fromError nsError: NSError,
                       optionIndex recoveryOptionIndex: Int) -> Bool {
    let error = nsError as Error as! RecoverableError
    return error.attemptRecovery(optionIndex: recoveryOptionIndex)
  }
}

/// Describes an error that may be recoverable by presenting several
/// potential recovery options to the user.
public protocol RecoverableError : Error {
  /// Provides a set of possible recovery options to present to the user.
  var recoveryOptions: [String] { get }

  /// Attempt to recover from this error when the user selected the
  /// option at the given index. This routine must call handler and
  /// indicate whether recovery was successful (or not).
  ///
  /// This entry point is used for recovery of errors handled at a
  /// "document" granularity, that do not affect the entire
  /// application.
  func attemptRecovery(optionIndex recoveryOptionIndex: Int,
                       resultHandler handler: @escaping (_ recovered: Bool) -> Void)

  /// Attempt to recover from this error when the user selected the
  /// option at the given index. Returns true to indicate
  /// successful recovery, and false otherwise.
  ///
  /// This entry point is used for recovery of errors handled at
  /// the "application" granularity, where nothing else in the
  /// application can proceed until the attempted error recovery
  /// completes.
  func attemptRecovery(optionIndex recoveryOptionIndex: Int) -> Bool
}

public extension RecoverableError {
  /// Default implementation that uses the application-model recovery
  /// mechanism (``attemptRecovery(optionIndex:)``) to implement
  /// document-modal recovery.
  func attemptRecovery(optionIndex recoveryOptionIndex: Int,
                       resultHandler handler: @escaping (_ recovered: Bool) -> Void) {
    handler(attemptRecovery(optionIndex: recoveryOptionIndex))
  }
}

/// expressible.
func unsafeBinaryIntegerToInt<T: BinaryInteger>(_ value: T) -> Int {
    if T.isSigned {
        return numericCast(value)
    }

    let uintValue: UInt = numericCast(value)
    return Int(bitPattern: uintValue)
}

/// Convert from an Int to an arbitrary binary integer, reinterpreting signed ->
/// unsigned if needed but trapping if the result is otherwise not expressible.
func unsafeBinaryIntegerFromInt<T: BinaryInteger>(_ value: Int) -> T {
  if T.isSigned {
    return numericCast(value)
  }

  let uintValue = UInt(bitPattern: value)
  return numericCast(uintValue)
}

extension CustomNSError
    where Self: RawRepresentable, Self.RawValue: FixedWidthInteger {
  // The error code of Error with integral raw values is the raw value.
  public var errorCode: Int {
    return unsafeBinaryIntegerToInt(self.rawValue)
  }
}

internal let _errorDomainUserInfoProviderQueue = DispatchQueue(
  label: "SwiftFoundation._errorDomainUserInfoProviderQueue")

/// Retrieve the default userInfo dictionary for a given error.
public func _getErrorDefaultUserInfo<T: Error>(_ error: T)
  -> AnyObject? {
  let hasUserInfoValueProvider: Bool

  // If the OS supports user info value providers, use those
  // to lazily populate the user-info dictionary for this domain.
  if #available(macOS 10.11, iOS 9.0, tvOS 9.0, watchOS 2.0, *) {
    // Note: the Cocoa error domain specifically excluded from
    // user-info value providers.
    let domain = error._domain
    if domain != NSCocoaErrorDomain {
      _errorDomainUserInfoProviderQueue.sync {
        if NSError.userInfoValueProvider(forDomain: domain) != nil { return }
        NSError.setUserInfoValueProvider(forDomain: domain) { (error, key) in

          switch key {
          case NSLocalizedDescriptionKey:
            return (error as? LocalizedError)?.errorDescription

          case NSLocalizedFailureReasonErrorKey:
            return (error as? LocalizedError)?.failureReason

          case NSLocalizedRecoverySuggestionErrorKey:
            return (error as? LocalizedError)?.recoverySuggestion

          case NSHelpAnchorErrorKey:
            return (error as? LocalizedError)?.helpAnchor

          case NSLocalizedRecoveryOptionsErrorKey:
            return (error as? RecoverableError)?.recoveryOptions

          case NSRecoveryAttempterErrorKey:
            if error is RecoverableError {
              return __NSErrorRecoveryAttempter()
            }
            return nil

          default:
            return nil
          }
        }
      }
      assert(NSError.userInfoValueProvider(forDomain: domain) != nil)

      hasUserInfoValueProvider = true
    } else {
      hasUserInfoValueProvider = false
    }
  } else {
    hasUserInfoValueProvider = false
  }

  // Populate the user-info dictionary 
  var result: [String : Any]

  // Initialize with custom user-info.
  if let customNSError = error as? CustomNSError {
    result = customNSError.errorUserInfo
  } else {
    result = [:]
  }

  // Handle localized errors. If we registered a user-info value
  // provider, these will computed lazily.
  if !hasUserInfoValueProvider,
     let localizedError = error as? LocalizedError {
    if let description = localizedError.errorDescription {
      result[NSLocalizedDescriptionKey] = description
    }
    
    if let reason = localizedError.failureReason {
      result[NSLocalizedFailureReasonErrorKey] = reason
    }
    
    if let suggestion = localizedError.recoverySuggestion {   
      result[NSLocalizedRecoverySuggestionErrorKey] = suggestion
    }
    
    if let helpAnchor = localizedError.helpAnchor {   
      result[NSHelpAnchorErrorKey] = helpAnchor
    }
  }

  // Handle recoverable errors. If we registered a user-info value
  // provider, these will computed lazily.
  if !hasUserInfoValueProvider,
     let recoverableError = error as? RecoverableError {
    result[NSLocalizedRecoveryOptionsErrorKey] =
      recoverableError.recoveryOptions
    result[NSRecoveryAttempterErrorKey] = __NSErrorRecoveryAttempter()
  }

  return result as AnyObject
}

// NSError and CFError conform to the standard Error protocol. Compiler
// magic allows this to be done as a "toll-free" conversion when an NSError
// or CFError is used as an Error existential.

extension NSError : Error {
  @nonobjc
  public var _domain: String { return domain }

  @nonobjc
  public var _code: Int { return code }

  @nonobjc
  public var _userInfo: AnyObject? { return userInfo as NSDictionary }

  /// The "embedded" NSError is itself.
  @nonobjc
  public func _getEmbeddedNSError() -> AnyObject? {
    return self
  }
}

extension CFError : Error {
  public var _domain: String {
    return CFErrorGetDomain(self) as String
  }

  public var _code: Int {
    return CFErrorGetCode(self)
  }

  public var _userInfo: AnyObject? {
    return CFErrorCopyUserInfo(self) as AnyObject
  }

  /// The "embedded" NSError is itself.
  public func _getEmbeddedNSError() -> AnyObject? {
    return self
  }
}

/// An internal protocol to represent Swift error enums that map to standard
/// Cocoa NSError domains.
public protocol _ObjectiveCBridgeableError : Error {
  /// Produce a value of the error type corresponding to the given NSError,
  /// or return nil if it cannot be bridged.
  init?(_bridgedNSError: __shared NSError)
}

/// A hook for the runtime to use _ObjectiveCBridgeableError in order to
/// attempt an "errorTypeValue as? SomeError" cast.
///
/// If the bridge succeeds, the bridged value is written to the uninitialized
/// memory pointed to by 'out', and true is returned. Otherwise, 'out' is
/// left uninitialized, and false is returned.
public func _bridgeNSErrorToError<
  T : _ObjectiveCBridgeableError
>(_ error: NSError, out: UnsafeMutablePointer<T>) -> Bool {
  if let bridged = T(_bridgedNSError: error) {
    out.initialize(to: bridged)
    return true
  } else {
    return false
  }
}

/// Describes a raw representable type that is bridged to a particular
/// NSError domain.
///
/// This protocol is used primarily to generate the conformance to
/// _ObjectiveCBridgeableError for such an enum defined in Swift.
public protocol _BridgedNSError :
    _ObjectiveCBridgeableError, RawRepresentable, Hashable
    where Self.RawValue: FixedWidthInteger {
  /// The NSError domain to which this type is bridged.
  static var _nsErrorDomain: String { get }
}

extension _BridgedNSError {
  public var _domain: String { return Self._nsErrorDomain }
}

extension _BridgedNSError where Self.RawValue: FixedWidthInteger {
  public var _code: Int { return Int(rawValue) }

  public init?(_bridgedNSError: __shared NSError) {
    if _bridgedNSError.domain != Self._nsErrorDomain {
      return nil
    }

    self.init(rawValue: RawValue(_bridgedNSError.code))
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(_code)
  }
}

/// Describes a bridged error that stores the underlying NSError, so
/// it can be queried.
public protocol _BridgedStoredNSError :
     _ObjectiveCBridgeableError, CustomNSError, Hashable {
  /// The type of an error code.
  associatedtype Code: _ErrorCodeProtocol, RawRepresentable
  where Code.RawValue: FixedWidthInteger

  //// Retrieves the embedded NSError.
  var _nsError: NSError { get }

  /// Create a new instance of the error type with the given embedded
  /// NSError.
  ///
  /// The \c error must have the appropriate domain for this error
  /// type.
  init(_nsError error: NSError)
}

/// Various helper implementations for _BridgedStoredNSError
extension _BridgedStoredNSError {
  public var code: Code {
    return Code(rawValue: unsafeBinaryIntegerFromInt(_nsError.code))!
  }

  /// Initialize an error within this domain with the given ``code``
  /// and ``userInfo``.
  public init(_ code: Code, userInfo: [String : Any] = [:]) {
    self.init(_nsError: NSError(domain: Self.errorDomain,
                                code: unsafeBinaryIntegerToInt(code.rawValue),
                                userInfo: userInfo))
  }

  /// The user-info dictionary for an error that was bridged from
  /// NSError.
  public var userInfo: [String : Any] { return errorUserInfo }
}

/// Implementation of _ObjectiveCBridgeableError for all _BridgedStoredNSErrors.
extension _BridgedStoredNSError {
  /// Default implementation of ``init(_bridgedNSError:)`` to provide
  /// bridging from NSError.
  public init?(_bridgedNSError error: NSError) {
    if error.domain != Self.errorDomain {
      return nil
    }

    self.init(_nsError: error)
  }
}

/// Implementation of CustomNSError for all _BridgedStoredNSErrors.
public extension _BridgedStoredNSError {
  // FIXME: Would prefer to have a clear "extract an NSError
  // directly" operation.

  // Synthesized by the compiler.
  // static var errorDomain: String

  var errorCode: Int { return _nsError.code }

  var errorUserInfo: [String : Any] {
    var result: [String : Any] = [:]
    for (key, value) in _nsError.userInfo {
      result[key] = value
    }
    return result
  }
}

/// Implementation of Hashable for all _BridgedStoredNSErrors.
extension _BridgedStoredNSError {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(_nsError)
  }

  @_alwaysEmitIntoClient public var hashValue: Int {
    return _nsError.hashValue
  }
}

extension _BridgedStoredNSError {
  /// Retrieve the embedded NSError from a bridged, stored NSError.
  public func _getEmbeddedNSError() -> AnyObject? {
    return _nsError
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    return lhs._nsError.isEqual(rhs._nsError)
  }
}

extension _SwiftNewtypeWrapper where Self.RawValue == Error {
  @inlinable // FIXME(sil-serialize-all)
  public func _bridgeToObjectiveC() -> NSError {
    return rawValue as NSError
  }

  @inlinable // FIXME(sil-serialize-all)
  public static func _forceBridgeFromObjectiveC(
    _ source: NSError,
    result: inout Self?
  ) {
    result = Self(rawValue: source)
  }

  @inlinable // FIXME(sil-serialize-all)
  public static func _conditionallyBridgeFromObjectiveC(
    _ source: NSError,
    result: inout Self?
  ) -> Bool {
    result = Self(rawValue: source)
    return result != nil
  }

  @inlinable // FIXME(sil-serialize-all)
  @_effects(readonly)
  public static func _unconditionallyBridgeFromObjectiveC(
    _ source: NSError?
  ) -> Self {
    return Self(rawValue: _convertNSErrorToError(source))!
  }
}


/// Describes errors in the URL error domain.
public struct URLError : _BridgedStoredNSError {
  public let _nsError: NSError

  public init(_nsError error: NSError) {
    precondition(error.domain == NSURLErrorDomain)
    self._nsError = error
  }

  public static var errorDomain: String { return NSURLErrorDomain }

  public var hashValue: Int {
    return _nsError.hashValue
  }

  /// The error code itself.
  public struct Code : RawRepresentable, Hashable, _ErrorCodeProtocol {
    public typealias _ErrorType = URLError

    public let rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }
  }
}

extension URLError.Code {
  public static var unknown: URLError.Code {
    return URLError.Code(rawValue: -1)
  }
  public static var cancelled: URLError.Code {
    return URLError.Code(rawValue: -999)
  }
  public static var badURL: URLError.Code {
    return URLError.Code(rawValue: -1000)
  }
  public static var timedOut: URLError.Code {
    return URLError.Code(rawValue: -1001)
  }
  public static var unsupportedURL: URLError.Code {
    return URLError.Code(rawValue: -1002)
  }
  public static var cannotFindHost: URLError.Code {
    return URLError.Code(rawValue: -1003)
  }
  public static var cannotConnectToHost: URLError.Code {
    return URLError.Code(rawValue: -1004)
  }
  public static var networkConnectionLost: URLError.Code {
    return URLError.Code(rawValue: -1005)
  }
  public static var dnsLookupFailed: URLError.Code {
    return URLError.Code(rawValue: -1006)
  }
  public static var httpTooManyRedirects: URLError.Code {
    return URLError.Code(rawValue: -1007)
  }
  public static var resourceUnavailable: URLError.Code {
    return URLError.Code(rawValue: -1008)
  }
  public static var notConnectedToInternet: URLError.Code {
    return URLError.Code(rawValue: -1009)
  }
  public static var redirectToNonExistentLocation: URLError.Code {
    return URLError.Code(rawValue: -1010)
  }
  public static var badServerResponse: URLError.Code {
    return URLError.Code(rawValue: -1011)
  }
  public static var userCancelledAuthentication: URLError.Code {
    return URLError.Code(rawValue: -1012)
  }
  public static var userAuthenticationRequired: URLError.Code {
    return URLError.Code(rawValue: -1013)
  }
  public static var zeroByteResource: URLError.Code {
    return URLError.Code(rawValue: -1014)
  }
  public static var cannotDecodeRawData: URLError.Code {
    return URLError.Code(rawValue: -1015)
  }
  public static var cannotDecodeContentData: URLError.Code {
    return URLError.Code(rawValue: -1016)
  }
  public static var cannotParseResponse: URLError.Code {
    return URLError.Code(rawValue: -1017)
  }
  @available(macOS, introduced: 10.11) @available(iOS, introduced: 9.0)
  public static var appTransportSecurityRequiresSecureConnection: URLError.Code {
    return URLError.Code(rawValue: -1022)
  }
  public static var fileDoesNotExist: URLError.Code {
    return URLError.Code(rawValue: -1100)
  }
  public static var fileIsDirectory: URLError.Code {
    return URLError.Code(rawValue: -1101)
  }
  public static var noPermissionsToReadFile: URLError.Code {
    return URLError.Code(rawValue: -1102)
  }
  @available(macOS, introduced: 10.5) @available(iOS, introduced: 2.0)
  public static var dataLengthExceedsMaximum: URLError.Code {
    return URLError.Code(rawValue: -1103)
  }
  public static var secureConnectionFailed: URLError.Code {
    return URLError.Code(rawValue: -1200)
  }
  public static var serverCertificateHasBadDate: URLError.Code {
    return URLError.Code(rawValue: -1201)
  }
  public static var serverCertificateUntrusted: URLError.Code {
    return URLError.Code(rawValue: -1202)
  }
  public static var serverCertificateHasUnknownRoot: URLError.Code {
    return URLError.Code(rawValue: -1203)
  }
  public static var serverCertificateNotYetValid: URLError.Code {
    return URLError.Code(rawValue: -1204)
  }
  public static var clientCertificateRejected: URLError.Code {
    return URLError.Code(rawValue: -1205)
  }
  public static var clientCertificateRequired: URLError.Code {
    return URLError.Code(rawValue: -1206)
  }
  public static var cannotLoadFromNetwork: URLError.Code {
    return URLError.Code(rawValue: -2000)
  }
  public static var cannotCreateFile: URLError.Code {
    return URLError.Code(rawValue: -3000)
  }
  public static var cannotOpenFile: URLError.Code {
    return URLError.Code(rawValue: -3001)
  }
  public static var cannotCloseFile: URLError.Code {
    return URLError.Code(rawValue: -3002)
  }
  public static var cannotWriteToFile: URLError.Code {
    return URLError.Code(rawValue: -3003)
  }
  public static var cannotRemoveFile: URLError.Code {
    return URLError.Code(rawValue: -3004)
  }
  public static var cannotMoveFile: URLError.Code {
    return URLError.Code(rawValue: -3005)
  }
  public static var downloadDecodingFailedMidStream: URLError.Code {
    return URLError.Code(rawValue: -3006)
  }
  public static var downloadDecodingFailedToComplete: URLError.Code {
    return URLError.Code(rawValue: -3007)
  }

  @available(macOS, introduced: 10.7) @available(iOS, introduced: 3.0)
  public static var internationalRoamingOff: URLError.Code {
    return URLError.Code(rawValue: -1018)
  }

  @available(macOS, introduced: 10.7) @available(iOS, introduced: 3.0)
  public static var callIsActive: URLError.Code {
    return URLError.Code(rawValue: -1019)
  }

  @available(macOS, introduced: 10.7) @available(iOS, introduced: 3.0)
  public static var dataNotAllowed: URLError.Code {
    return URLError.Code(rawValue: -1020)
  }

  @available(macOS, introduced: 10.7) @available(iOS, introduced: 3.0)
  public static var requestBodyStreamExhausted: URLError.Code {
    return URLError.Code(rawValue: -1021)
  }

  @available(macOS, introduced: 10.10) @available(iOS, introduced: 8.0)
  public static var backgroundSessionRequiresSharedContainer: URLError.Code {
    return URLError.Code(rawValue: -995)
  }

  @available(macOS, introduced: 10.10) @available(iOS, introduced: 8.0)
  public static var backgroundSessionInUseByAnotherProcess: URLError.Code {
    return URLError.Code(rawValue: -996)
  }

  @available(macOS, introduced: 10.10) @available(iOS, introduced: 8.0)
  public static var backgroundSessionWasDisconnected: URLError.Code {
    return URLError.Code(rawValue: -997)
  }
}

extension URLError {
  /// Reasons used by URLError to indicate why a background URLSessionTask was cancelled.
  @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
  public enum BackgroundTaskCancelledReason : Int {
    case userForceQuitApplication
    case backgroundUpdatesDisabled
    case insufficientSystemResources
  }
}

extension URLError {
  /// Reasons used by URLError to indicate that a URLSessionTask failed because of unsatisfiable network constraints.
  @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
  public enum NetworkUnavailableReason : Int {
    case cellular
    case expensive
    case constrained
  }
}

extension URLError {
  private var _nsUserInfo: [AnyHashable : Any] {
    return (self as NSError).userInfo
  }

  /// The URL which caused a load to fail.
  public var failingURL: URL? {
    return _nsUserInfo[NSURLErrorFailingURLErrorKey as NSString] as? URL
  }

  /// The string for the URL which caused a load to fail. 
  public var failureURLString: String? {
    return _nsUserInfo[NSURLErrorFailingURLStringErrorKey as NSString] as? String
  }

  /// The state of a failed SSL handshake.
  public var failureURLPeerTrust: SecTrust? {
    if let secTrust = _nsUserInfo[NSURLErrorFailingURLPeerTrustErrorKey as NSString] {
      return (secTrust as! SecTrust)
    }

    return nil
  }

  /// The reason why a background URLSessionTask was cancelled.
  @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
  public var backgroundTaskCancelledReason: BackgroundTaskCancelledReason? {
    return (_nsUserInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int).flatMap(BackgroundTaskCancelledReason.init(rawValue:))
  }

  /// The reason why the network is unavailable when the task failed due to unsatisfiable network constraints.
  @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
  public var networkUnavailableReason: NetworkUnavailableReason? {
    return (_nsUserInfo[NSURLErrorNetworkUnavailableReasonKey] as? Int).flatMap(NetworkUnavailableReason.init(rawValue:))
  }

  /// An opaque data blob to resume a failed download task.
  @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
  public var downloadTaskResumeData: Data? {
    return _nsUserInfo["NSURLSessionDownloadTaskResumeData"] as? Data  // Finch: CFNetwork's key, without linking CFNetwork
  }
}

extension URLError {
  public static var unknown: URLError.Code {
    return .unknown
  }

  public static var cancelled: URLError.Code {
    return .cancelled
  }

  public static var badURL: URLError.Code {
    return .badURL
  }

  public static var timedOut: URLError.Code {
    return .timedOut
  }

  public static var unsupportedURL: URLError.Code {
    return .unsupportedURL
  }

  public static var cannotFindHost: URLError.Code {
    return .cannotFindHost
  }

  public static var cannotConnectToHost: URLError.Code {
    return .cannotConnectToHost
  }

  public static var networkConnectionLost: URLError.Code {
    return .networkConnectionLost
  }

  public static var dnsLookupFailed: URLError.Code {
    return .dnsLookupFailed
  }

  public static var httpTooManyRedirects: URLError.Code {
    return .httpTooManyRedirects
  }

  public static var resourceUnavailable: URLError.Code {
    return .resourceUnavailable
  }

  public static var notConnectedToInternet: URLError.Code {
    return .notConnectedToInternet
  }

  public static var redirectToNonExistentLocation: URLError.Code {
    return .redirectToNonExistentLocation
  }

  public static var badServerResponse: URLError.Code {
    return .badServerResponse
  }

  public static var userCancelledAuthentication: URLError.Code {
    return .userCancelledAuthentication
  }

  public static var userAuthenticationRequired: URLError.Code {
    return .userAuthenticationRequired
  }

  public static var zeroByteResource: URLError.Code {
    return .zeroByteResource
  }

  public static var cannotDecodeRawData: URLError.Code {
    return .cannotDecodeRawData
  }

  public static var cannotDecodeContentData: URLError.Code {
    return .cannotDecodeContentData
  }

  public static var cannotParseResponse: URLError.Code {
    return .cannotParseResponse
  }

  @available(macOS, introduced: 10.11) @available(iOS, introduced: 9.0)
  public static var appTransportSecurityRequiresSecureConnection: URLError.Code {
    return .appTransportSecurityRequiresSecureConnection
  }

  public static var fileDoesNotExist: URLError.Code {
    return .fileDoesNotExist
  }

  public static var fileIsDirectory: URLError.Code {
    return .fileIsDirectory
  }

  public static var noPermissionsToReadFile: URLError.Code {
    return .noPermissionsToReadFile
  }

  @available(macOS, introduced: 10.5) @available(iOS, introduced: 2.0)
  public static var dataLengthExceedsMaximum: URLError.Code {
    return .dataLengthExceedsMaximum
  }

  public static var secureConnectionFailed: URLError.Code {
    return .secureConnectionFailed
  }

  public static var serverCertificateHasBadDate: URLError.Code {
    return .serverCertificateHasBadDate
  }

  public static var serverCertificateUntrusted: URLError.Code {
    return .serverCertificateUntrusted
  }

  public static var serverCertificateHasUnknownRoot: URLError.Code {
    return .serverCertificateHasUnknownRoot
  }

  public static var serverCertificateNotYetValid: URLError.Code {
    return .serverCertificateNotYetValid
  }

  public static var clientCertificateRejected: URLError.Code {
    return .clientCertificateRejected
  }

  public static var clientCertificateRequired: URLError.Code {
    return .clientCertificateRequired
  }

  public static var cannotLoadFromNetwork: URLError.Code {
    return .cannotLoadFromNetwork
  }

  public static var cannotCreateFile: URLError.Code {
    return .cannotCreateFile
  }

  public static var cannotOpenFile: URLError.Code {
    return .cannotOpenFile
  }

  public static var cannotCloseFile: URLError.Code {
    return .cannotCloseFile
  }

  public static var cannotWriteToFile: URLError.Code {
    return .cannotWriteToFile
  }

  public static var cannotRemoveFile: URLError.Code {
    return .cannotRemoveFile
  }

  public static var cannotMoveFile: URLError.Code {
    return .cannotMoveFile
  }

  public static var downloadDecodingFailedMidStream: URLError.Code {
    return .downloadDecodingFailedMidStream
  }

  public static var downloadDecodingFailedToComplete: URLError.Code {
    return .downloadDecodingFailedToComplete
  }

  @available(macOS, introduced: 10.7) @available(iOS, introduced: 3.0)
  public static var internationalRoamingOff: URLError.Code {
    return .internationalRoamingOff
  }

  @available(macOS, introduced: 10.7) @available(iOS, introduced: 3.0)
  public static var callIsActive: URLError.Code {
    return .callIsActive
  }

  @available(macOS, introduced: 10.7) @available(iOS, introduced: 3.0)
  public static var dataNotAllowed: URLError.Code {
    return .dataNotAllowed
  }

  @available(macOS, introduced: 10.7) @available(iOS, introduced: 3.0)
  public static var requestBodyStreamExhausted: URLError.Code {
    return .requestBodyStreamExhausted
  }

  @available(macOS, introduced: 10.10) @available(iOS, introduced: 8.0)
  public static var backgroundSessionRequiresSharedContainer: Code {
    return .backgroundSessionRequiresSharedContainer
  }

  @available(macOS, introduced: 10.10) @available(iOS, introduced: 8.0)
  public static var backgroundSessionInUseByAnotherProcess: Code {
    return .backgroundSessionInUseByAnotherProcess
  }

  @available(macOS, introduced: 10.10) @available(iOS, introduced: 8.0)
  public static var backgroundSessionWasDisconnected: Code {
    return .backgroundSessionWasDisconnected
  }
}

extension URLError {
  @available(*, unavailable, renamed: "unknown")
  public static var Unknown: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "cancelled")
  public static var Cancelled: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "badURL")
  public static var BadURL: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "timedOut")
  public static var TimedOut: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "unsupportedURL")
  public static var UnsupportedURL: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "cannotFindHost")
  public static var CannotFindHost: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "cannotConnectToHost")
  public static var CannotConnectToHost: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "networkConnectionLost")
  public static var NetworkConnectionLost: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "dnsLookupFailed")
  public static var DNSLookupFailed: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "httpTooManyRedirects")
  public static var HTTPTooManyRedirects: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "resourceUnavailable")
  public static var ResourceUnavailable: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "notConnectedToInternet")
  public static var NotConnectedToInternet: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "redirectToNonExistentLocation")
  public static var RedirectToNonExistentLocation: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "badServerResponse")
  public static var BadServerResponse: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "userCancelledAuthentication")
  public static var UserCancelledAuthentication: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "userAuthenticationRequired")
  public static var UserAuthenticationRequired: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "zeroByteResource")
  public static var ZeroByteResource: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "cannotDecodeRawData")
  public static var CannotDecodeRawData: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "cannotDecodeContentData")
  public static var CannotDecodeContentData: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "cannotParseResponse")
  public static var CannotParseResponse: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "appTransportSecurityRequiresSecureConnection")
  public static var AppTransportSecurityRequiresSecureConnection: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "fileDoesNotExist")
  public static var FileDoesNotExist: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "fileIsDirectory")
  public static var FileIsDirectory: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "noPermissionsToReadFile")
  public static var NoPermissionsToReadFile: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "dataLengthExceedsMaximum")
  public static var DataLengthExceedsMaximum: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "secureConnectionFailed")
  public static var SecureConnectionFailed: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "serverCertificateHasBadDate")
  public static var ServerCertificateHasBadDate: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "serverCertificateUntrusted")
  public static var ServerCertificateUntrusted: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "serverCertificateHasUnknownRoot")
  public static var ServerCertificateHasUnknownRoot: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "serverCertificateNotYetValid")
  public static var ServerCertificateNotYetValid: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "clientCertificateRejected")
  public static var ClientCertificateRejected: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "clientCertificateRequired")
  public static var ClientCertificateRequired: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "cannotLoadFromNetwork")
  public static var CannotLoadFromNetwork: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "cannotCreateFile")
  public static var CannotCreateFile: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "cannotOpenFile")
  public static var CannotOpenFile: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "cannotCloseFile")
  public static var CannotCloseFile: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "cannotWriteToFile")
  public static var CannotWriteToFile: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "cannotRemoveFile")
  public static var CannotRemoveFile: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "cannotMoveFile")
  public static var CannotMoveFile: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "downloadDecodingFailedMidStream")
  public static var DownloadDecodingFailedMidStream: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "downloadDecodingFailedToComplete")
  public static var DownloadDecodingFailedToComplete: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "internationalRoamingOff")
  public static var InternationalRoamingOff: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "callIsActive")
  public static var CallIsActive: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "dataNotAllowed")
  public static var DataNotAllowed: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "requestBodyStreamExhausted")
  public static var RequestBodyStreamExhausted: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "backgroundSessionRequiresSharedContainer")
  public static var BackgroundSessionRequiresSharedContainer: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "backgroundSessionInUseByAnotherProcess")
  public static var BackgroundSessionInUseByAnotherProcess: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }

  @available(*, unavailable, renamed: "backgroundSessionWasDisconnected")
  public static var BackgroundSessionWasDisconnected: URLError.Code {
    fatalError("unavailable accessor can't be called")
  }
}

/// Describes an error in the Mach error domain.
public struct MachError : _BridgedStoredNSError {
  public let _nsError: NSError

  public init(_nsError error: NSError) {
    precondition(error.domain == NSMachErrorDomain)
    self._nsError = error
  }

  public static var errorDomain: String { return NSMachErrorDomain }

  public var hashValue: Int {
    return _nsError.hashValue
  }

  public typealias Code = MachErrorCode
}

extension MachErrorCode : _ErrorCodeProtocol {
  public typealias _ErrorType = MachError
}

extension MachError {
  public static var success: MachError.Code {
    return .success
  }

  /// Specified address is not currently valid.
  public static var invalidAddress: MachError.Code {
    return .invalidAddress
  }

  /// Specified memory is valid, but does not permit the required
  /// forms of access.
  public static var protectionFailure: MachError.Code {
    return .protectionFailure
  }

  /// The address range specified is already in use, or no address
  /// range of the size specified could be found.  
  public static var noSpace: MachError.Code {
    return .noSpace
  }

  /// The function requested was not applicable to this type of
  /// argument, or an argument is invalid.
  public static var invalidArgument: MachError.Code {
    return .invalidArgument
  }

  /// The function could not be performed.  A catch-all.
  public static var failure: MachError.Code {
    return .failure
  }

  /// A system resource could not be allocated to fulfill this
  /// request.  This failure may not be permanent.
  public static var resourceShortage: MachError.Code {
    return .resourceShortage
  }

  /// The task in question does not hold receive rights for the port
  /// argument.
  public static var notReceiver: MachError.Code {
    return .notReceiver
  }

  /// Bogus access restriction.
  public static var noAccess: MachError.Code {
    return .noAccess
  }

  /// During a page fault, the target address refers to a memory
  /// object that has been destroyed.  This failure is permanent.
  public static var memoryFailure: MachError.Code {
    return .memoryFailure
  }

  /// During a page fault, the memory object indicated that the data
  /// could not be returned.  This failure may be temporary; future
  /// attempts to access this same data may succeed, as defined by the
  /// memory object.
  public static var memoryError: MachError.Code {
    return .memoryError
  }

  /// The receive right is already a member of the portset.
  public static var alreadyInSet: MachError.Code {
    return .alreadyInSet
  }

  /// The receive right is not a member of a port set.
  public static var notInSet: MachError.Code {
    return .notInSet
  }

  /// The name already denotes a right in the task.
  public static var nameExists: MachError.Code {
    return .nameExists
  }

  /// The operation was aborted.  Ipc code will catch this and reflect
  /// it as a message error.
  public static var aborted: MachError.Code {
    return .aborted
  }

  /// The name doesn't denote a right in the task.
  public static var invalidName: MachError.Code {
    return .invalidName
  }

  /// Target task isn't an active task.
  public static var invalidTask: MachError.Code {
    return .invalidTask
  }

  /// The name denotes a right, but not an appropriate right.
  public static var invalidRight: MachError.Code {
    return .invalidRight
  }

  /// A blatant range error.
  public static var invalidValue: MachError.Code {
    return .invalidValue
  }

  /// Operation would overflow limit on user-references.
  public static var userReferencesOverflow: MachError.Code {
    return .userReferencesOverflow
  }

  /// The supplied (port) capability is improper.
  public static var invalidCapability: MachError.Code {
    return .invalidCapability
  }

  /// The task already has send or receive rights for the port under
  /// another name.
  public static var rightExists: MachError.Code {
    return .rightExists
  }

  /// Target host isn't actually a host.
  public static var invalidHost: MachError.Code {
    return .invalidHost
  }

  /// An attempt was made to supply "precious" data for memory that is
  /// already present in a memory object.
  public static var memoryPresent: MachError.Code {
    return .memoryPresent
  }

  /// A page was requested of a memory manager via
  /// memory_object_data_request for an object using a
  /// MEMORY_OBJECT_COPY_CALL strategy, with the VM_PROT_WANTS_COPY
  /// flag being used to specify that the page desired is for a copy
  /// of the object, and the memory manager has detected the page was
  /// pushed into a copy of the object while the kernel was walking
  /// the shadow chain from the copy to the object. This error code is
  /// delivered via memory_object_data_error and is handled by the
  /// kernel (it forces the kernel to restart the fault). It will not
  /// be seen by users.
  public static var memoryDataMoved: MachError.Code {
    return .memoryDataMoved
  }

  /// A strategic copy was attempted of an object upon which a quicker
  /// copy is now possible.  The caller should retry the copy using
  /// vm_object_copy_quickly. This error code is seen only by the
  /// kernel.
  public static var memoryRestartCopy: MachError.Code {
    return .memoryRestartCopy
  }

  /// An argument applied to assert processor set privilege was not a
  /// processor set control port.
  public static var invalidProcessorSet: MachError.Code {
    return .invalidProcessorSet
  }

  /// The specified scheduling attributes exceed the thread's limits.
  public static var policyLimit: MachError.Code {
    return .policyLimit
  }

  /// The specified scheduling policy is not currently enabled for the
  /// processor set.
  public static var invalidPolicy: MachError.Code {
    return .invalidPolicy
  }

  /// The external memory manager failed to initialize the memory object.
  public static var invalidObject: MachError.Code {
    return .invalidObject
  }

  /// A thread is attempting to wait for an event for which there is
  /// already a waiting thread.
  public static var alreadyWaiting: MachError.Code {
    return .alreadyWaiting
  }

  /// An attempt was made to destroy the default processor set.
  public static var defaultSet: MachError.Code {
    return .defaultSet
  }

  /// An attempt was made to fetch an exception port that is
  /// protected, or to abort a thread while processing a protected
  /// exception.
  public static var exceptionProtected: MachError.Code {
    return .exceptionProtected
  }

  /// A ledger was required but not supplied.
  public static var invalidLedger: MachError.Code {
    return .invalidLedger
  }

  /// The port was not a memory cache control port.
  public static var invalidMemoryControl: MachError.Code {
    return .invalidMemoryControl
  }

  /// An argument supplied to assert security privilege was not a host
  /// security port.
  public static var invalidSecurity: MachError.Code {
    return .invalidSecurity
  }

  /// thread_depress_abort was called on a thread which was not
  /// currently depressed.
  public static var notDepressed: MachError.Code {
    return .notDepressed
  }

  /// Object has been terminated and is no longer available.
  public static var terminated: MachError.Code {
    return .terminated
  }

  /// Lock set has been destroyed and is no longer available.
  public static var lockSetDestroyed: MachError.Code {
    return .lockSetDestroyed
  }

  /// The thread holding the lock terminated before releasing the lock.
  public static var lockUnstable: MachError.Code {
    return .lockUnstable
  }

  /// The lock is already owned by another thread.
  public static var lockOwned: MachError.Code {
    return .lockOwned
  }

  /// The lock is already owned by the calling thread.
  public static var lockOwnedSelf: MachError.Code {
    return .lockOwnedSelf
  }

  /// Semaphore has been destroyed and is no longer available.
  public static var semaphoreDestroyed: MachError.Code {
    return .semaphoreDestroyed
  }

  /// Return from RPC indicating the target server was terminated
  /// before it successfully replied.
  public static var rpcServerTerminated: MachError.Code {
    return .rpcServerTerminated
  }

  /// Terminate an orphaned activation.
  public static var rpcTerminateOrphan: MachError.Code {
    return .rpcTerminateOrphan
  }

  /// Allow an orphaned activation to continue executing.
  public static var rpcContinueOrphan: MachError.Code {
    return .rpcContinueOrphan
  }

  /// Empty thread activation (No thread linked to it).
  public static var notSupported: MachError.Code {
    return .notSupported
  }

  /// Remote node down or inaccessible.
  public static var nodeDown: MachError.Code {
    return .nodeDown
  }

  /// A signalled thread was not actually waiting.
  public static var notWaiting: MachError.Code {
    return .notWaiting
  }

  /// Some thread-oriented operation (semaphore_wait) timed out.
  public static var operationTimedOut: MachError.Code {
    return .operationTimedOut
  }

  /// During a page fault, indicates that the page was rejected as a
  /// result of a signature check.
  public static var codesignError: MachError.Code {
    return .codesignError
  }

  /// The requested property cannot be changed at this time.
  public static var policyStatic: MachError.Code {
    return .policyStatic
  }
}

public struct ErrorUserInfoKey : RawRepresentable, _SwiftNewtypeWrapper, Equatable, Hashable, _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSString
  public init(rawValue: String) { self.rawValue = rawValue }
  public var rawValue: String
}

public extension ErrorUserInfoKey {
  @available(*, deprecated, renamed: "NSUnderlyingErrorKey")
  static let underlyingErrorKey = ErrorUserInfoKey(rawValue: NSUnderlyingErrorKey)

  @available(*, deprecated, renamed: "NSLocalizedDescriptionKey")
  static let localizedDescriptionKey = ErrorUserInfoKey(rawValue: NSLocalizedDescriptionKey)

  @available(*, deprecated, renamed: "NSLocalizedFailureReasonErrorKey")
  static let localizedFailureReasonErrorKey = ErrorUserInfoKey(rawValue: NSLocalizedFailureReasonErrorKey)

  @available(*, deprecated, renamed: "NSLocalizedRecoverySuggestionErrorKey")
  static let localizedRecoverySuggestionErrorKey = ErrorUserInfoKey(rawValue: NSLocalizedRecoverySuggestionErrorKey)

  @available(*, deprecated, renamed: "NSLocalizedRecoveryOptionsErrorKey")
  static let localizedRecoveryOptionsErrorKey = ErrorUserInfoKey(rawValue: NSLocalizedRecoveryOptionsErrorKey)

  @available(*, deprecated, renamed: "NSRecoveryAttempterErrorKey")
  static let recoveryAttempterErrorKey = ErrorUserInfoKey(rawValue: NSRecoveryAttempterErrorKey)

  @available(*, deprecated, renamed: "NSHelpAnchorErrorKey")
  static let helpAnchorErrorKey = ErrorUserInfoKey(rawValue: NSHelpAnchorErrorKey)

  @available(*, deprecated, renamed: "NSStringEncodingErrorKey")
  static let stringEncodingErrorKey = ErrorUserInfoKey(rawValue: NSStringEncodingErrorKey)

  @available(*, deprecated, renamed: "NSURLErrorKey")
  static let NSURLErrorKey = ErrorUserInfoKey(rawValue: Foundation.NSURLErrorKey)

  @available(*, deprecated, renamed: "NSFilePathErrorKey")
  static let filePathErrorKey = ErrorUserInfoKey(rawValue: NSFilePathErrorKey)
}
