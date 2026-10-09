// SPDX-License-Identifier: MIT OR Apache-2.0
// The calendar identifiers CF's public header doesn't name (Apple's private
// CF header does), with CF's values.

extension CFCalendarIdentifier {
    internal static let coptic = CFCalendarIdentifier(rawValue: "coptic" as CFString)
    internal static let ethiopicAmeteMihret = CFCalendarIdentifier(rawValue: "ethiopic" as CFString)
    internal static let ethiopicAmeteAlem = CFCalendarIdentifier(rawValue: "ethiopic-amete-alem" as CFString)
}
