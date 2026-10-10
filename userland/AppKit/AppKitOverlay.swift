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
// Finch: AppKit's Swift overlay, which Apple compiles into AppKit.framework
// (module AppKit; userland/AppKit/build.sh compiles this file in the same
// way). From Swift's historical overlay stdlib/public/Darwin/AppKit
// (swift-5.2.5-RELEASE: AppKit.swift, NSGraphics.swift, NSEvent.swift,
// AppKit_FoundationExtensions.swift, NSError.swift), joined into one file;
// Finch's changes are marked "Finch:". Apple's current overlay has more
// (diffable data sources, NSView.Invalidating, text suggestions, the AppKit
// attribute scope); docs/design/APPKIT.md lists the gaps.

import Foundation
@_exported import AppKit

// MARK: - AppKit.swift


extension NSCursor : __DefaultCustomPlaygroundQuickLookable {
  @available(*, deprecated, message: "NSCursor._defaultCustomPlaygroundQuickLook will be removed in a future Swift version")
  public var _defaultCustomPlaygroundQuickLook: PlaygroundQuickLook {
    return .image(image)
  }
}

internal struct _NSViewQuickLookState {
  static var views = Set<NSView>()
}

extension NSView : __DefaultCustomPlaygroundQuickLookable {
  @available(*, deprecated, message: "NSView._defaultCustomPlaygroundQuickLook will be removed in a future Swift version")
  public var _defaultCustomPlaygroundQuickLook: PlaygroundQuickLook {
    // if you set NSView.needsDisplay, you can get yourself in a recursive scenario where the same view
    // could need to draw itself in order to get a QLObject for itself, which in turn if your code was
    // instrumented to log on-draw, would cause yourself to get back here and so on and so forth
    // until you run out of stack and crash
    // This code checks that we aren't trying to log the same view recursively - and if so just returns
    // an empty view, which is probably a safer option than crashing
    // FIXME: is there a way to say "cacheDisplayInRect butDoNotRedrawEvenIfISaidSo"?
    if _NSViewQuickLookState.views.contains(self) {
      return .view(NSImage())
    } else {
      _NSViewQuickLookState.views.insert(self)
      let result: PlaygroundQuickLook
      if let b = bitmapImageRepForCachingDisplay(in: bounds) {
        cacheDisplay(in: bounds, to: b)
        result = .view(b)
      } else {
        result = .view(NSImage())
      }
      _NSViewQuickLookState.views.remove(self)
      return result
    }
  }
}

// Overlays for variadics.

public extension NSGradient {
  convenience init?(colorsAndLocations objects: (NSColor, CGFloat)...) {
    self.init(
      colors: objects.map { $0.0 },
      atLocations: objects.map { $0.1 },
      colorSpace: NSColorSpace.genericRGB)
  }
}

// Fix the ARGV type of NSApplicationMain, which nonsensically takes
// argv as a const char**.
public func NSApplicationMain(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
  return argv.withMemoryRebound(to: UnsafePointer<CChar>.self, capacity: Int(argc)) {
    __NSApplicationMain(argc, $0)
  }
}

extension NSApplication {
  @available(swift 4)
  public static func loadApplication() {
    _ = NSApplication.shared  // Finch: what NSApplicationLoad() does (Finch has no NSApplicationLoad yet)
  }
}

extension NSColor : _ExpressibleByColorLiteral {
  @nonobjc
  public required convenience init(_colorLiteralRed red: Float, green: Float,
                                   blue: Float, alpha: Float) {
    self.init(red: CGFloat(red), green: CGFloat(green),
              blue: CGFloat(blue), alpha: CGFloat(alpha))
  }
}

public typealias _ColorLiteralType = NSColor

extension NSImage : _ExpressibleByImageLiteral {
  private convenience init!(failableImageLiteral name: String) {
    self.init(named: .init(name))
  }

  @nonobjc
  public required convenience init(imageLiteralResourceName name: String) {
    self.init(failableImageLiteral: name)
  }
}

public typealias _ImageLiteralType = NSImage

// Numeric backed types

@available(swift 4)
public protocol _AppKitKitNumericRawRepresentable : RawRepresentable, Comparable
  where RawValue: Comparable & Numeric { }

extension _AppKitKitNumericRawRepresentable {
  public static func <(lhs: Self, rhs: Self) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }

  public static func +(lhs: Self, rhs: RawValue) -> Self {
    return Self(rawValue: lhs.rawValue + rhs)!
  }

  public static func +(lhs: RawValue, rhs: Self) -> Self {
    return Self(rawValue: lhs + rhs.rawValue)!
  }

  public static func -(lhs: Self, rhs: RawValue) -> Self {
    return Self(rawValue: lhs.rawValue - rhs)!
  }

  public static func -(lhs: Self, rhs: Self) -> RawValue {
    return lhs.rawValue - rhs.rawValue
  }

  public static func +=(lhs: inout Self, rhs: RawValue) {
    lhs = Self(rawValue: lhs.rawValue + rhs)!
  }

  public static func -=(lhs: inout Self, rhs: RawValue) {
    lhs = Self(rawValue: lhs.rawValue - rhs)!
  }
}

@available(swift 4)
extension NSAppKitVersion : _AppKitKitNumericRawRepresentable { }

@available(swift 4)
extension NSLayoutConstraint.Priority : _AppKitKitNumericRawRepresentable { }

@available(swift 4)
extension NSStackView.VisibilityPriority : _AppKitKitNumericRawRepresentable { }

@available(swift 4)
extension NSToolbarItem.VisibilityPriority : _AppKitKitNumericRawRepresentable { }

@available(macOS 10.12.2, *)
@available(swift 4)
extension NSTouchBarItem.Priority : _AppKitKitNumericRawRepresentable { }

@available(swift 4)
extension NSWindow.Level : _AppKitKitNumericRawRepresentable { }

@available(swift 4)
extension NSFont.Weight : _AppKitKitNumericRawRepresentable { }

// MARK: - NSGraphics.swift


extension NSRect {
  /// Fills this rect in the current NSGraphicsContext in the context's fill
  /// color.
  /// The compositing operation of the fill defaults to the context's
  /// compositing operation, not necessarily using `.copy` like `NSRectFill()`.
  /// - precondition: There must be a set current NSGraphicsContext.
  @available(swift 4)
  public func fill(using operation: NSCompositingOperation =
    NSGraphicsContext.current?.compositingOperation ?? .sourceOver) {
    precondition(NSGraphicsContext.current != nil,
                 "There must be a set current NSGraphicsContext")
    __NSRectFillUsingOperation(self, operation)
  }
    
  /// Draws a frame around the inside of this rect in the current
  /// NSGraphicsContext in the context's fill color
  /// The compositing operation of the fill defaults to the context's
  /// compositing operation, not necessarily using `.copy` like `NSFrameRect()`.
  /// - precondition: There must be a set current NSGraphicsContext.
  @available(swift 4)
  public func frame(withWidth width: CGFloat = 1.0,
                    using operation: NSCompositingOperation =
    NSGraphicsContext.current?.compositingOperation ?? .sourceOver) {
    precondition(NSGraphicsContext.current != nil,
                 "There must be a set current NSGraphicsContext")
    __NSFrameRectWithWidthUsingOperation(self, width, operation)
  }
    
  /// Modifies the current graphics context clipping path by intersecting it
  /// with this rect.
  /// This permanently modifies the graphics state, so the current state should
  /// be saved beforehand and restored afterwards.
  /// - precondition: There must be a set current NSGraphicsContext.
  @available(swift 4)
  public func clip() {
    precondition(NSGraphicsContext.current != nil,
                 "There must be a set current NSGraphicsContext")
    __NSRectClip(self)
  }
}

extension Sequence where Iterator.Element == NSRect {
  /// Fills this list of rects in the current NSGraphicsContext in the context's
  /// fill color.
  /// The compositing operation of the fill defaults to the context's
  /// compositing operation, not necessarily using `.copy` like `NSRectFill()`.
  /// - precondition: There must be a set current NSGraphicsContext.
  @available(swift 4)
  public func fill(using operation: NSCompositingOperation =
    NSGraphicsContext.current?.compositingOperation ?? .sourceOver) {
    precondition(NSGraphicsContext.current != nil,
                 "There must be a set current NSGraphicsContext")
    let rects = Array(self)
    let count = rects.count
    guard count > 0 else { return }
    rects.withUnsafeBufferPointer { rectBufferPointer in
      guard let rectArray = rectBufferPointer.baseAddress else { return }
      __NSRectFillListUsingOperation(rectArray, count, operation)
    }
  }
    
  /// Modifies the current graphics context clipping path by intersecting it
  /// with the graphical union of this list of rects
  /// This permanently modifies the graphics state, so the current state should
  /// be saved beforehand and restored afterwards.
  /// - precondition: There must be a set current NSGraphicsContext.
  @available(swift 4)
  public func clip() {
    precondition(NSGraphicsContext.current != nil,
                 "There must be a set current NSGraphicsContext")
    let rects = Array(self)
    let count = rects.count
    guard count > 0 else { return }
    rects.withUnsafeBufferPointer { rectBufferPointer in
      guard let rectArray = rectBufferPointer.baseAddress else { return }
      __NSRectClipList(rectArray, count)
    }
  }
}

extension Sequence where Iterator.Element == (CGRect, NSColor) {
  /// Fills this list of rects in the current NSGraphicsContext with that rect's
  /// associated color
  /// The compositing operation of the fill defaults to the context's
  /// compositing operation, not necessarily using `.copy` like `NSRectFill()`.
  /// - precondition: There must be a set current NSGraphicsContext.
  @available(swift 4)
  public func fill(using operation: NSCompositingOperation =
    NSGraphicsContext.current?.compositingOperation ?? .sourceOver) {
    precondition(NSGraphicsContext.current != nil,
                 "There must be a set current NSGraphicsContext")
    let rects = map { $0.0 }
    let colors = map { $0.1 }
    let count = rects.count
    guard count > 0 else { return }
    rects.withUnsafeBufferPointer { rectBufferPointer in
      colors.withUnsafeBufferPointer { colorBufferPointer in
        guard let rectArray = rectBufferPointer.baseAddress else { return }
        guard let colorArray = colorBufferPointer.baseAddress else { return }
        __NSRectFillListWithColorsUsingOperation(
            rectArray, colorArray, count, operation)
      }
    }
  }
}

extension Sequence where Iterator.Element == (CGRect, gray: CGFloat) {
  /// Fills this list of rects in the current NSGraphicsContext with that rect's
  /// associated gray component value in the DeviceGray color space.
  /// The compositing operation of the fill defaults to the context's
  /// compositing operation, not necessarily using `.copy` like
  /// `NSRectFillListWithGrays()`.
  /// - precondition: There must be a set current NSGraphicsContext.
  @available(swift 4)
  public func fill(using operation: NSCompositingOperation =
    NSGraphicsContext.current?.compositingOperation ?? .sourceOver) {
    // NSRectFillListWithGrays does not have a variant taking an operation, but
    // is added here for consistency with the other drawing operations.
    guard let graphicsContext = NSGraphicsContext.current else {
      fatalError("There must be a set current NSGraphicsContext")
    }
    let cgContext: CGContext
    if #available(macOS 10.10, *) {
      cgContext = graphicsContext.cgContext
    } else {
      cgContext = Unmanaged<CGContext>.fromOpaque(
        graphicsContext.graphicsPort).takeUnretainedValue()
    }
    cgContext.saveGState()
    forEach {
      cgContext.setFillColor(gray: $0.gray, alpha: 1.0)
      __NSRectFillUsingOperation($0.0, operation)
    }
    cgContext.restoreGState()
  }
}

extension NSWindow.Depth {
  @available(swift 4)
  public static func bestDepth(
    colorSpaceName: NSColorSpaceName,
    bitsPerSample: Int,
    bitsPerPixel: Int,
    isPlanar: Bool
    ) -> (NSWindow.Depth, isExactMatch: Bool) {
    var isExactMatch: ObjCBool = false
    let depth = __NSBestDepth(
        colorSpaceName,
        bitsPerSample, bitsPerPixel, isPlanar, &isExactMatch)
    return (depth, isExactMatch: isExactMatch.boolValue)
  }
  @available(swift 4)
  public static var availableDepths: [NSWindow.Depth] {
    // __NSAvailableWindowDepths is NULL terminated, the length is not known up front
    let depthsCArray = __NSAvailableWindowDepths()
    var depths: [NSWindow.Depth] = []
    var length = 0
    var depth = depthsCArray[length]
    while depth.rawValue != 0 {
      depths.append(depth)
      length += 1
      depth = depthsCArray[length]
    }
    return depths
  }
}

extension NSAnimationEffect {
  // NOTE: older overlays called this class _CompletionHandlerDelegate.
  // The two must coexist without a conflicting ObjC class name, so it
  // was renamed. The old name must not be used in the new runtime.
  private class __CompletionHandlerDelegate : NSObject {
    var completionHandler: () -> Void = { }
    @objc func animationEffectDidEnd(_ contextInfo: UnsafeMutableRawPointer?) {
      completionHandler()
    }
  }
  @available(swift 4)
  public func show(centeredAt centerLocation: NSPoint, size: NSSize,
                   completionHandler: @escaping () -> Void = { }) {
    let delegate = __CompletionHandlerDelegate()
    delegate.completionHandler = completionHandler
    // Note that the delegate of `__NSShowAnimationEffect` is retained for the
    // duration of the animation.
    __NSShowAnimationEffect(
        self,
        centerLocation,
        size,
        delegate,
        #selector(__CompletionHandlerDelegate.animationEffectDidEnd(_:)),
        nil)
  }
}

extension NSSound {
  @available(swift 4)
  public static func beep() {
    __NSBeep()
  }
}

// MARK: - NSEvent.swift


extension NSEvent {
    public struct SpecialKey : RawRepresentable, Equatable, Hashable {
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
        public let rawValue: Int
        public var unicodeScalar: Unicode.Scalar {
            return Unicode.Scalar(rawValue)!
        }
    }
    
    /// Returns nil if the receiver is not a "special" key event.
    open var specialKey: SpecialKey? {
        guard let unicodeScalars = charactersIgnoringModifiers?.unicodeScalars else {
            return nil
        }
        guard unicodeScalars.count == 1 else {
            return nil
        }
        guard let codePoint = unicodeScalars.first?.value else {
            return nil
        }
        switch codePoint {
        case 0x0003:
            return .enter
            
        case 0x0008:
            return .backspace
            
        case 0x0009:
            return .tab
            
        case 0x000a:
            return .newline
            
        case 0x000c:
            return .formFeed
            
        case 0x000d:
            return .carriageReturn
            
        case 0x0019:
            return .backTab
            
        case 0x007f:
            return .delete
            
        case 0x2028:
            return .lineSeparator
            
        case 0x2029:
            return .paragraphSeparator
            
        case 0xF700..<0xF900:
            return SpecialKey(rawValue: Int(codePoint))
            
        default:
            return nil
        }
    }
}

extension NSEvent.SpecialKey {
    
    static public let upArrow = NSEvent.SpecialKey(rawValue: 0xF700)
    static public let downArrow = NSEvent.SpecialKey(rawValue: 0xF701)
    static public let leftArrow = NSEvent.SpecialKey(rawValue: 0xF702)
    static public let rightArrow = NSEvent.SpecialKey(rawValue: 0xF703)
    static public let f1 = NSEvent.SpecialKey(rawValue: 0xF704)
    static public let f2 = NSEvent.SpecialKey(rawValue: 0xF705)
    static public let f3 = NSEvent.SpecialKey(rawValue: 0xF706)
    static public let f4 = NSEvent.SpecialKey(rawValue: 0xF707)
    static public let f5 = NSEvent.SpecialKey(rawValue: 0xF708)
    static public let f6 = NSEvent.SpecialKey(rawValue: 0xF709)
    static public let f7 = NSEvent.SpecialKey(rawValue: 0xF70A)
    static public let f8 = NSEvent.SpecialKey(rawValue: 0xF70B)
    static public let f9 = NSEvent.SpecialKey(rawValue: 0xF70C)
    static public let f10 = NSEvent.SpecialKey(rawValue: 0xF70D)
    static public let f11 = NSEvent.SpecialKey(rawValue: 0xF70E)
    static public let f12 = NSEvent.SpecialKey(rawValue: 0xF70F)
    static public let f13 = NSEvent.SpecialKey(rawValue: 0xF710)
    static public let f14 = NSEvent.SpecialKey(rawValue: 0xF711)
    static public let f15 = NSEvent.SpecialKey(rawValue: 0xF712)
    static public let f16 = NSEvent.SpecialKey(rawValue: 0xF713)
    static public let f17 = NSEvent.SpecialKey(rawValue: 0xF714)
    static public let f18 = NSEvent.SpecialKey(rawValue: 0xF715)
    static public let f19 = NSEvent.SpecialKey(rawValue: 0xF716)
    static public let f20 = NSEvent.SpecialKey(rawValue: 0xF717)
    static public let f21 = NSEvent.SpecialKey(rawValue: 0xF718)
    static public let f22 = NSEvent.SpecialKey(rawValue: 0xF719)
    static public let f23 = NSEvent.SpecialKey(rawValue: 0xF71A)
    static public let f24 = NSEvent.SpecialKey(rawValue: 0xF71B)
    static public let f25 = NSEvent.SpecialKey(rawValue: 0xF71C)
    static public let f26 = NSEvent.SpecialKey(rawValue: 0xF71D)
    static public let f27 = NSEvent.SpecialKey(rawValue: 0xF71E)
    static public let f28 = NSEvent.SpecialKey(rawValue: 0xF71F)
    static public let f29 = NSEvent.SpecialKey(rawValue: 0xF720)
    static public let f30 = NSEvent.SpecialKey(rawValue: 0xF721)
    static public let f31 = NSEvent.SpecialKey(rawValue: 0xF722)
    static public let f32 = NSEvent.SpecialKey(rawValue: 0xF723)
    static public let f33 = NSEvent.SpecialKey(rawValue: 0xF724)
    static public let f34 = NSEvent.SpecialKey(rawValue: 0xF725)
    static public let f35 = NSEvent.SpecialKey(rawValue: 0xF726)
    static public let insert = NSEvent.SpecialKey(rawValue: 0xF727)
    static public let deleteForward = NSEvent.SpecialKey(rawValue: 0xF728)
    static public let home = NSEvent.SpecialKey(rawValue: 0xF729)
    static public let begin = NSEvent.SpecialKey(rawValue: 0xF72A)
    static public let end = NSEvent.SpecialKey(rawValue: 0xF72B)
    static public let pageUp = NSEvent.SpecialKey(rawValue: 0xF72C)
    static public let pageDown = NSEvent.SpecialKey(rawValue: 0xF72D)
    static public let printScreen = NSEvent.SpecialKey(rawValue: 0xF72E)
    static public let scrollLock = NSEvent.SpecialKey(rawValue: 0xF72F)
    static public let pause = NSEvent.SpecialKey(rawValue: 0xF730)
    static public let sysReq = NSEvent.SpecialKey(rawValue: 0xF731)
    static public let `break` = NSEvent.SpecialKey(rawValue: 0xF732)
    static public let reset = NSEvent.SpecialKey(rawValue: 0xF733)
    static public let stop = NSEvent.SpecialKey(rawValue: 0xF734)
    static public let menu = NSEvent.SpecialKey(rawValue: 0xF735)
    static public let user = NSEvent.SpecialKey(rawValue: 0xF736)
    static public let system = NSEvent.SpecialKey(rawValue: 0xF737)
    static public let print = NSEvent.SpecialKey(rawValue: 0xF738)
    static public let clearLine = NSEvent.SpecialKey(rawValue: 0xF739)
    static public let clearDisplay = NSEvent.SpecialKey(rawValue: 0xF73A)
    static public let insertLine = NSEvent.SpecialKey(rawValue: 0xF73B)
    static public let deleteLine = NSEvent.SpecialKey(rawValue: 0xF73C)
    static public let insertCharacter = NSEvent.SpecialKey(rawValue: 0xF73D)
    static public let deleteCharacter = NSEvent.SpecialKey(rawValue: 0xF73E)
    static public let prev = NSEvent.SpecialKey(rawValue: 0xF73F)
    static public let next = NSEvent.SpecialKey(rawValue: 0xF740)
    static public let select = NSEvent.SpecialKey(rawValue: 0xF741)
    static public let execute = NSEvent.SpecialKey(rawValue: 0xF742)
    static public let undo = NSEvent.SpecialKey(rawValue: 0xF743)
    static public let redo = NSEvent.SpecialKey(rawValue: 0xF744)
    static public let find = NSEvent.SpecialKey(rawValue: 0xF745)
    static public let help = NSEvent.SpecialKey(rawValue: 0xF746)
    static public let modeSwitch = NSEvent.SpecialKey(rawValue: 0xF747)
    
    static public let enter = NSEvent.SpecialKey(rawValue: 0x0003)
    static public let backspace = NSEvent.SpecialKey(rawValue: 0x0008)
    static public let tab = NSEvent.SpecialKey(rawValue: 0x0009)
    static public let newline = NSEvent.SpecialKey(rawValue: 0x000a)
    static public let formFeed = NSEvent.SpecialKey(rawValue: 0x000c)
    static public let carriageReturn = NSEvent.SpecialKey(rawValue: 0x000d)
    static public let backTab = NSEvent.SpecialKey(rawValue: 0x0019)
    static public let delete = NSEvent.SpecialKey(rawValue: 0x007f)
    static public let lineSeparator = NSEvent.SpecialKey(rawValue: 0x2028)
    static public let paragraphSeparator = NSEvent.SpecialKey(rawValue: 0x2029)
}

// MARK: - AppKit_FoundationExtensions.swift


// NSCollectionView extensions
extension IndexPath {
    
    /// Initialize for use with `NSCollectionView`.
    public init(item: Int, section: Int) {
        self.init(indexes: [section, item])
    }
    
    /// The item of this index path, when used with `NSCollectionView`.
    ///
    /// - precondition: The index path must have exactly two elements.
    public var item : Int {
        get {
            precondition(count == 2, "Invalid index path for use with NSCollectionView. This index path must contain exactly two indices specifying the section and item.")
            return self[1]
        }
        set {
            precondition(count == 2, "Invalid index path for use with NSCollectionView. This index path must contain exactly two indices specifying the section and item.")
            self[1] = newValue
        }
    }
    
    /// The section of this index path, when used with `NSCollectionView`.
    ///
    /// - precondition: The index path must have exactly two elements.
    public var section : Int {
        get {
            precondition(count == 2, "Invalid index path for use with NSCollectionView. This index path must contain exactly two indices specifying the section and item.")
            return self[0]
        }
        set {
            precondition(count == 2, "Invalid index path for use with NSCollectionView. This index path must contain exactly two indices specifying the section and item.")
            self[0] = newValue
        }
    }
    
}

extension URLResourceValues {
    /// Returns all thumbnails as a single NSImage.
    @available(macOS 10.10, *)
    public var thumbnail : NSImage? {
        return allValues[URLResourceKey.thumbnailKey] as? NSImage
    }
    
    /// The color of the assigned label.
    public var labelColor: NSColor? {
        return allValues[URLResourceKey.labelColorKey] as? NSColor
    }
    
    /// The icon normally displayed for the resource
    public var effectiveIcon: AnyObject? {
        return allValues[URLResourceKey.effectiveIconKey] as? NSImage
    }
    
    /// The custom icon assigned to the resource, if any (Currently not implemented)
    public var customIcon: NSImage? {
        return allValues[URLResourceKey.customIconKey] as? NSImage
    }
    
    /// Returns a dictionary of NSImage objects keyed by size.
    @available(macOS 10.10, *)
    public var thumbnailDictionary : [URLThumbnailDictionaryItem : NSImage]? {
        return allValues[URLResourceKey.thumbnailDictionaryKey] as? [URLThumbnailDictionaryItem : NSImage]
    }

}

// MARK: - NSError.swift

extension CocoaError.Code {
  public static var textReadInapplicableDocumentType: CocoaError.Code {
    return CocoaError.Code(rawValue: 65806)
  }
  public static var textWriteInapplicableDocumentType: CocoaError.Code {
    return CocoaError.Code(rawValue: 66062)
  }
  public static var serviceApplicationNotFound: CocoaError.Code {
    return CocoaError.Code(rawValue: 66560)
  }
  public static var serviceApplicationLaunchFailed: CocoaError.Code {
    return CocoaError.Code(rawValue: 66561)
  }
  public static var serviceRequestTimedOut: CocoaError.Code {
    return CocoaError.Code(rawValue: 66562)
  }
  public static var serviceInvalidPasteboardData: CocoaError.Code {
    return CocoaError.Code(rawValue: 66563)
  }
  public static var serviceMalformedServiceDictionary: CocoaError.Code {
    return CocoaError.Code(rawValue: 66564)
  }
  public static var serviceMiscellaneousError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66800)
  }
  public static var sharingServiceNotConfigured: CocoaError.Code {
    return CocoaError.Code(rawValue: 67072)
  }
  @available(macOS 10.13, *)
  public static var fontAssetDownloadError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66304)
  }
}

// Names deprecated late in Swift 3
extension CocoaError.Code {
  @available(*, deprecated, renamed: "textReadInapplicableDocumentType")
  public static var textReadInapplicableDocumentTypeError: CocoaError.Code {
    return CocoaError.Code(rawValue: 65806)
  }
  @available(*, deprecated, renamed: "textWriteInapplicableDocumentType")
  public static var textWriteInapplicableDocumentTypeError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66062)
  }
  @available(*, deprecated, renamed: "serviceApplicationNotFound")
  public static var serviceApplicationNotFoundError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66560)
  }
  @available(*, deprecated, renamed: "serviceApplicationLaunchFailed")
  public static var serviceApplicationLaunchFailedError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66561)
  }
  @available(*, deprecated, renamed: "serviceRequestTimedOut")
  public static var serviceRequestTimedOutError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66562)
  }
  @available(*, deprecated, renamed: "serviceInvalidPasteboardData")
  public static var serviceInvalidPasteboardDataError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66563)
  }
  @available(*, deprecated, renamed: "serviceMalformedServiceDictionary")
  public static var serviceMalformedServiceDictionaryError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66564)
  }
  @available(*, deprecated, renamed: "serviceMiscellaneousError")
  public static var serviceMiscellaneous: CocoaError.Code {
    return CocoaError.Code(rawValue: 66800)
  }
  @available(*, deprecated, renamed: "sharingServiceNotConfigured")
  public static var sharingServiceNotConfiguredError: CocoaError.Code {
    return CocoaError.Code(rawValue: 67072)
  }
}

extension CocoaError {
  public static var textReadInapplicableDocumentType: CocoaError.Code {
    return CocoaError.Code(rawValue: 65806)
  }
  public static var textWriteInapplicableDocumentType: CocoaError.Code {
    return CocoaError.Code(rawValue: 66062)
  }
  public static var serviceApplicationNotFound: CocoaError.Code {
    return CocoaError.Code(rawValue: 66560)
  }
  public static var serviceApplicationLaunchFailed: CocoaError.Code {
    return CocoaError.Code(rawValue: 66561)
  }
  public static var serviceRequestTimedOut: CocoaError.Code {
    return CocoaError.Code(rawValue: 66562)
  }
  public static var serviceInvalidPasteboardData: CocoaError.Code {
    return CocoaError.Code(rawValue: 66563)
  }
  public static var serviceMalformedServiceDictionary: CocoaError.Code {
    return CocoaError.Code(rawValue: 66564)
  }
  public static var serviceMiscellaneous: CocoaError.Code {
    return CocoaError.Code(rawValue: 66800)
  }
  public static var sharingServiceNotConfigured: CocoaError.Code {
    return CocoaError.Code(rawValue: 67072)
  }
  @available(macOS 10.13, *)
  public static var fontAssetDownloadError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66304)
  }
}

// Names deprecated late in Swift 3
extension CocoaError {
  @available(*, deprecated, renamed: "textReadInapplicableDocumentType")
  public static var textReadInapplicableDocumentTypeError: CocoaError.Code {
    return CocoaError.Code(rawValue: 65806)
  }
  @available(*, deprecated, renamed: "textWriteInapplicableDocumentType")
  public static var textWriteInapplicableDocumentTypeError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66062)
  }
  @available(*, deprecated, renamed: "serviceApplicationNotFound")
  public static var serviceApplicationNotFoundError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66560)
  }
  @available(*, deprecated, renamed: "serviceApplicationLaunchFailed")
  public static var serviceApplicationLaunchFailedError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66561)
  }
  @available(*, deprecated, renamed: "serviceRequestTimedOut")
  public static var serviceRequestTimedOutError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66562)
  }
  @available(*, deprecated, renamed: "serviceInvalidPasteboardData")
  public static var serviceInvalidPasteboardDataError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66563)
  }
  @available(*, deprecated, renamed: "serviceMalformedServiceDictionary")
  public static var serviceMalformedServiceDictionaryError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66564)
  }
  @available(*, deprecated, renamed: "serviceMiscellaneous")
  public static var serviceMiscellaneousError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66800)
  }
  @available(*, deprecated, renamed: "sharingServiceNotConfigured")
  public static var sharingServiceNotConfiguredError: CocoaError.Code {
    return CocoaError.Code(rawValue: 67072)
  }
}

extension CocoaError {
  public var isServiceError: Bool {
    return code.rawValue >= 66560 && code.rawValue <= 66817
  }

  public var isSharingServiceError: Bool {
    return code.rawValue >= 67072 && code.rawValue <= 67327
  }

  public var isTextReadWriteError: Bool {
    return code.rawValue >= 65792 && code.rawValue <= 66303
  }

  @available(macOS 10.13, *)
  public var isFontError: Bool {
    return code.rawValue >= 66304 && code.rawValue <= 66335
  }
}

extension CocoaError {
  @available(*, deprecated, renamed: "textReadInapplicableDocumentType")
  public static var TextReadInapplicableDocumentTypeError: CocoaError.Code {
    return CocoaError.Code(rawValue: 65806)
  }
  @available(*, deprecated, renamed: "textWriteInapplicableDocumentType")
  public static var TextWriteInapplicableDocumentTypeError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66062)
  }
  @available(*, deprecated, renamed: "serviceApplicationNotFound")
  public static var ServiceApplicationNotFoundError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66560)
  }
  @available(*, deprecated, renamed: "serviceApplicationLaunchFailed")
  public static var ServiceApplicationLaunchFailedError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66561)
  }
  @available(*, deprecated, renamed: "serviceRequestTimedOut")
  public static var ServiceRequestTimedOutError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66562)
  }
  @available(*, deprecated, renamed: "serviceInvalidPasteboardData")
  public static var ServiceInvalidPasteboardDataError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66563)
  }
  @available(*, deprecated, renamed: "serviceMalformedServiceDictionary")
  public static var ServiceMalformedServiceDictionaryError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66564)
  }
  @available(*, deprecated, renamed: "serviceMiscellaneous")
  public static var ServiceMiscellaneousError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66800)
  }
  @available(*, deprecated, renamed: "sharingServiceNotConfigured")
  public static var SharingServiceNotConfiguredError: CocoaError.Code {
    return CocoaError.Code(rawValue: 67072)
  }
}

extension CocoaError.Code {
  @available(*, deprecated, renamed: "textReadInapplicableDocumentType")
  public static var TextReadInapplicableDocumentTypeError: CocoaError.Code {
    return CocoaError.Code(rawValue: 65806)
  }
  @available(*, deprecated, renamed: "textWriteInapplicableDocumentType")
  public static var TextWriteInapplicableDocumentTypeError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66062)
  }
  @available(*, deprecated, renamed: "serviceApplicationNotFound")
  public static var ServiceApplicationNotFoundError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66560)
  }
  @available(*, deprecated, renamed: "serviceApplicationLaunchFailed")
  public static var ServiceApplicationLaunchFailedError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66561)
  }
  @available(*, deprecated, renamed: "serviceRequestTimedOut")
  public static var ServiceRequestTimedOutError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66562)
  }
  @available(*, deprecated, renamed: "serviceInvalidPasteboardData")
  public static var ServiceInvalidPasteboardDataError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66563)
  }
  @available(*, deprecated, renamed: "serviceMalformedServiceDictionary")
  public static var ServiceMalformedServiceDictionaryError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66564)
  }
  @available(*, deprecated, renamed: "serviceMiscellaneous")
  public static var ServiceMiscellaneousError: CocoaError.Code {
    return CocoaError.Code(rawValue: 66800)
  }
  @available(*, deprecated, renamed: "sharingServiceNotConfigured")
  public static var SharingServiceNotConfiguredError: CocoaError.Code {
    return CocoaError.Code(rawValue: 67072)
  }
}

// MARK: - NSMenuItem

@available(macOS 14.0, *)
extension NSMenuItem {
  /// A menu section's header (+sectionHeaderWithTitle:, refined for Swift as Apple's is).
  public static func sectionHeader(title: String) -> NSMenuItem {
    return __sectionHeader(withTitle: title)
  }
}
