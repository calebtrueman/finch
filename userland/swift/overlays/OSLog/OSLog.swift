// SPDX-License-Identifier: MIT OR Apache-2.0
// The OSLog overlay (reading the unified log): a Swift sequence over an
// OSLogStore's entries and a typed view of a message component's argument,
// with the declarations of Apple's overlay (macOS 26.4 SDK). Finch's code.
// It talks to OSLog.framework only through Objective-C messages, so the
// library doesn't link the framework (Finch has none yet; the store's
// methods fail at run time until it does).

@_exported import OSLog
import Foundation

@available(macOS 10.15, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension OSLogStore {
  public func getEntries(
    with options: OSLogEnumerator.Options = [],
    at position: OSLogPosition? = nil,
    matching predicate: NSPredicate? = nil
  ) throws -> AnySequence<OSLogEntry> {
    let enumerator = try __entriesEnumerator(options: options, position: position,
                                             predicate: predicate)
    return AnySequence {
      AnyIterator { enumerator.nextObject().map { unsafeBitCast($0 as AnyObject, to: OSLogEntry.self) } }
    }
  }
}

@available(macOS 10.15, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension OSLogMessageComponent {
  public enum Argument {
    case undefined
    case data(Data)
    case double(Double)
    case signed(Int64)
    case string(String)
    case unsigned(UInt64)
  }

  public var argument: Argument {
    switch argumentCategory {
    case .data:
      if let value = argumentDataValue { return .data(value) }
    case .double:
      return .double(argumentDoubleValue)
    case .int64:
      return .signed(argumentInt64Value)
    case .string:
      if let value = argumentStringValue { return .string(value) }
    case .uInt64:
      return .unsigned(argumentUInt64Value)
    default:
      break
    }
    return .undefined
  }
}
