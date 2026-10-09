// SPDX-License-Identifier: MIT OR Apache-2.0
// The NSCocoaErrorDomain error swift-foundation's file operations throw
// (CocoaError+FilePath.swift). Apple's Foundation builds it in Objective-C
// (+[NSError _cocoaErrorWithCode:path:url:...]); Finch builds the same
// userInfo here, as swift-foundation's package build does.
internal import _ForSwiftFoundation

extension NSError {
    internal static func _cocoaError<E: Error>(
        withCode code: Int, path: String?, url: URL?, underlying: E?, variant: String?,
        source: String?, destination: String?, debugDescription: String?
    ) -> NSError {
        var userInfo: [String: Any] = [:]
        if let path { userInfo[NSFilePathErrorKey] = path }
        if let url { userInfo[NSURLErrorKey] = url }
        if let underlying { userInfo[NSUnderlyingErrorKey] = underlying as NSError }
        if let source { userInfo["NSSourceFilePathErrorKey"] = source }
        if let destination { userInfo["NSDestinationFilePath"] = destination }
        if let variant { userInfo[NSUserStringVariantErrorKey] = [variant] }
        if let debugDescription { userInfo[NSDebugDescriptionErrorKey] = debugDescription }
        return NSError(domain: NSCocoaErrorDomain, code: code, userInfo: userInfo)
    }
}
