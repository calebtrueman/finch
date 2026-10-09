// SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
// Finch: from Swift's stdlib/private/OSLog/OSLogPrivacy.swift at swift-6.3.1-RELEASE (the
// open prototype of the os overlay's new logging API), changed to match the
// layout and ABI of Apple's os overlay (macOS 26.4 SDK interface).
//===----------------- OSLogPrivacy.swift ---------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// This file defines the APIs for specifying privacy in the log messages and also
// the logic for encoding them in the byte buffer passed to the libtrace library.

/// Privacy options for specifying privacy level of the interpolated expressions
/// in the string interpolations passed to the log APIs.
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
@frozen
public struct OSLogPrivacy {

  @usableFromInline
  internal enum PrivacyOption {
    case `private`
    case `public`
    case sensitive
    case auto
  }

  public enum Mask {
    case hash
    case none
    @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
    case _mailName
    @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
    case _mailAddress
    @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
    case _mailSubject
    @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
    case _mailSummary
    @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
    case _mailAccount
    @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
    case _mailbox
    @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
    case _mailboxPath
    @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
    case _mailAttachmentFileName
  }

  /// Masks for Mail's private log fields (an SPI of Apple's overlay).
  @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
  public enum _MailMask {
    case name
    case address
    case subject
    case summary
    case account
    case mailbox
    case mailboxPath
    case attachmentFileName
  }

  @usableFromInline
  internal var privacy: PrivacyOption

  @usableFromInline
  internal var mask: Mask

  @_transparent
  @usableFromInline
  internal init(privacy: PrivacyOption, mask: Mask) {
    self.privacy = privacy
    self.mask = mask
  }

  @_semantics("constant_evaluable")
  @_optimize(none)
  @inlinable
  public static var `public`: OSLogPrivacy {
    OSLogPrivacy(privacy: .public, mask: .none)
  }

  @_semantics("constant_evaluable")
  @_optimize(none)
  @inlinable
  public static var `private`: OSLogPrivacy {
    OSLogPrivacy(privacy: .private, mask: .none)
  }

  @_semantics("constant_evaluable")
  @_optimize(none)
  @inlinable
  public static func `private`(mask: Mask) -> OSLogPrivacy {
    OSLogPrivacy(privacy: .private, mask: mask)
  }

  @_semantics("constant_evaluable")
  @_optimize(none)
  @inlinable
  public static var sensitive: OSLogPrivacy {
    OSLogPrivacy(privacy: .sensitive, mask: .none)
  }

  @_semantics("constant_evaluable")
  @_optimize(none)
  @inlinable
  public static func sensitive(mask: Mask) -> OSLogPrivacy {
    OSLogPrivacy(privacy: .sensitive, mask: mask)
  }

  @_semantics("constant_evaluable")
  @_optimize(none)
  @inlinable
  public static var auto: OSLogPrivacy {
    OSLogPrivacy(privacy: .auto, mask: .none)
  }

  @_semantics("constant_evaluable")
  @_optimize(none)
  @inlinable
  public static func auto(mask: Mask) -> OSLogPrivacy {
    OSLogPrivacy(privacy: .auto, mask: mask)
  }

  /// A private value masked as one of Mail's fields.
  @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
  @_spi(Mail)
  public static func mail(_ field: _MailMask) -> OSLogPrivacy {
    let mask: Mask
    switch field {
    case .name: mask = ._mailName
    case .address: mask = ._mailAddress
    case .subject: mask = ._mailSubject
    case .summary: mask = ._mailSummary
    case .account: mask = ._mailAccount
    case .mailbox: mask = ._mailbox
    case .mailboxPath: mask = ._mailboxPath
    case .attachmentFileName: mask = ._mailAttachmentFileName
    }
    return OSLogPrivacy(privacy: .private, mask: mask)
  }

  @inlinable
  @_semantics("constant_evaluable")
  @_optimize(none)
  internal var argumentFlag: UInt8 {
    switch privacy {
    case .private:
      return 0x1
    case .public:
      return 0x2
    case .sensitive:
      return 0x5
    default:
      return 0
    }
  }

  @inlinable
  @_semantics("constant_evaluable")
  @_optimize(none)
  internal var isAtleastPrivate: Bool {
    switch privacy {
    case .public:
      return false
    case .auto:
      return false
    default:
      return true
    }
  }

  @inlinable
  @_semantics("constant_evaluable")
  @_optimize(none)
  internal var needsPrivacySpecifier: Bool {
    if case .hash = mask {
      return true
    }
    switch privacy {
    case .auto:
      return false
    default:
      return true
    }
  }

  @inlinable
  @_transparent
  internal var hasMask: Bool {
    if case .none = mask {
      return false
    }
    return true
  }

  /// The mask's eight-byte tag as libtrace reads it: its name in ASCII,
  /// least significant byte first ("hash", "mailname", ...).
  @inlinable
  @_transparent
  internal var maskValue: UInt64 {
    switch mask {
    case ._mailName: return 0x656d_616e_6c69_616d
    case ._mailAddress: return 0x7264_6461_6c69_616d
    case ._mailSubject: return 0x6a62_7573_6c69_616d
    case ._mailSummary: return 0x6d6d_7573_6c69_616d
    case ._mailAccount: return 0x6f63_6361_6c69_616d
    case ._mailbox: return 0x78_6f62_6c69_616d
    case ._mailboxPath: return 0x7075_626d_6c69_616d
    case ._mailAttachmentFileName: return 0x6174_7461_6c69_616d
    case .hash, .none: return 0x6873_6168
    @unknown default: return 0x6873_6168
    }
  }

  @inlinable
  @_semantics("constant_evaluable")
  @_optimize(none)
  internal var privacySpecifier: String? {
    let hasMask = self.hasMask
    var isAuto = false
    if case .auto = privacy {
      isAuto = true
    }
    if isAuto, !hasMask {
      return nil
    }
    var specifier: String
    switch privacy {
    case .public:
      specifier = "public"
    case .private:
      specifier = "private"
    case .sensitive:
      specifier = "sensitive"
    default:
      specifier = ""
    }
    if hasMask {
      if !isAuto {
        specifier += ","
      }
      specifier += "mask."
      specifier += maskSpecifier
    }
    return specifier
  }

  @inlinable
  @_transparent
  internal var maskSpecifier: String {
    switch mask {
    case ._mailName: return "mailname"
    case ._mailAddress: return "mailaddr"
    case ._mailSubject: return "mailsubj"
    case ._mailSummary: return "mailsumm"
    case ._mailAccount: return "mailacco"
    case ._mailbox: return "mailbox"
    case ._mailboxPath: return "mailmbup"
    case ._mailAttachmentFileName: return "mailatta"
    case .hash, .none: return "hash"
    @unknown default: return "hash"
    }
  }
}
