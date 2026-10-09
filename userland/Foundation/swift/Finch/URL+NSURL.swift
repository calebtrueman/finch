// SPDX-License-Identifier: MIT OR Apache-2.0
// URL's Objective-C side on Finch. Apple's NSURL is swift-foundation's Swift
// subclass _NSSwiftURL (URL_ObjC.swift); Finch's NSURL is CoreFoundation's
// CFURL, so URL_ObjC.swift is left out, URL bridges to a CFURL made from its
// string (foundation_swift_nsurl_enabled() is false), and _NSSwiftURL is only
// the type swift-foundation's bridging code tests for: Finch never makes one.

internal class _NSSwiftURL: NSURL, @unchecked Sendable {
    let url: _SwiftURL

    init(url: _SwiftURL) {
        fatalError("Finch's URL bridges to CFURL, not _NSSwiftURL")
    }

    required init?(coder: NSCoder) {
        fatalError("_NSSwiftURL is not archived on Finch")
    }

    required init(itemProviderPreferredRepresentation: Data, typeIdentifier: String) throws {
        fatalError("_NSSwiftURL is not made from item providers on Finch")
    }
}

/// URLComponents bridged to Objective-C: an NSURLComponents carrying the
/// components (Finch's NSURLComponents is Objective-C; Apple's is
/// swift-foundation's _NSSwiftURLComponents, URLComponents_ObjC.swift).
internal final class _NSSwiftURLComponents: NSURLComponents, @unchecked Sendable {
    let components: URLComponents

    init(components: URLComponents) {
        self.components = components
        super.init()
        scheme = components.scheme
        percentEncodedUser = components.percentEncodedUser
        percentEncodedPassword = components.percentEncodedPassword
        if let host = components.encodedHost { encodedHost = host }
        port = components.port.map { NSNumber(value: $0) }
        percentEncodedPath = components.percentEncodedPath
        percentEncodedQuery = components.percentEncodedQuery
        percentEncodedFragment = components.percentEncodedFragment
    }
}

/// URLQueryItem bridged to Objective-C.
internal final class _NSSwiftURLQueryItem: NSURLQueryItem, @unchecked Sendable {
    init(queryItem: URLQueryItem) {
        super.init(name: queryItem.name, value: queryItem.value)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
