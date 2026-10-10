// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ShareLink and SharePreview, to Apple's interface. A share link is a button whose action shows
// AppKit's sharing service picker under it, for the link's items: URLs and strings as they are,
// other transferables as text. The subject goes to the chosen service, and the message comes
// before the items. Previews only describe the items to a share sheet, which the picker's menu
// doesn't show, so they're kept but not drawn.

public import CoreTransferable
public import Foundation
import AppKit
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

// MARK: - SharePreview

@available(OpenSwiftUI_v4_0, *)
public struct SharePreview<Image, Icon> where Image: Transferable, Icon: Transferable {
    var title: Text
    var image: Image?
    var icon: Icon?

    public init(_ titleKey: LocalizedStringKey, image: Image, icon: Icon) {
        self.init(Text(titleKey), image: image, icon: icon)
    }

    @_disfavoredOverload
    public init<S>(_ title: S, image: Image, icon: Icon) where S: StringProtocol {
        self.init(Text(title), image: image, icon: icon)
    }

    public init(_ title: Text, image: Image, icon: Icon) {
        self.title = title
        self.image = image
        self.icon = icon
    }
}

@available(*, unavailable) extension SharePreview: Sendable {}

@available(OpenSwiftUI_v4_0, *)
extension SharePreview where Image == Never {
    public init(_ titleKey: LocalizedStringKey, icon: Icon) { self.init(Text(titleKey), icon: icon) }

    @_disfavoredOverload
    public init<S>(_ title: S, icon: Icon) where S: StringProtocol { self.init(Text(title), icon: icon) }

    public init(_ title: Text, icon: Icon) {
        self.title = title
        self.image = nil
        self.icon = icon
    }
}

@available(OpenSwiftUI_v4_0, *)
extension SharePreview where Icon == Never {
    public init(_ titleKey: LocalizedStringKey, image: Image) { self.init(Text(titleKey), image: image) }

    @_disfavoredOverload
    public init<S>(_ title: S, image: Image) where S: StringProtocol { self.init(Text(title), image: image) }

    public init(_ title: Text, image: Image) {
        self.title = title
        self.image = image
        self.icon = nil
    }
}

@available(OpenSwiftUI_v4_0, *)
extension SharePreview where Image == Never, Icon == Never {
    public init(_ titleKey: LocalizedStringKey) { self.init(Text(titleKey)) }

    @_disfavoredOverload
    public init<S>(_ title: S) where S: StringProtocol { self.init(Text(title)) }

    public init(_ title: Text) {
        self.title = title
        self.image = nil
        self.icon = nil
    }
}

// MARK: - ShareLink

@available(OpenSwiftUI_v4_0, *)
public struct DefaultShareLinkLabel: View {
    var title: Text?

    @MainActor
    @preconcurrency
    public var body: some View {
        Label { title ?? Text("Share") } icon: { Image(systemName: "square.and.arrow.up") }
    }
}

@available(*, unavailable) extension DefaultShareLinkLabel: Sendable {}

@available(OpenSwiftUI_v4_0, *)
public struct ShareLink<Data, PreviewImage, PreviewIcon, Label>: View
    where Data: RandomAccessCollection, PreviewImage: Transferable, PreviewIcon: Transferable, Label: View,
    Data.Element: Transferable {
    var items: Data
    var subject: Text?
    var message: Text?
    var preview: ((Data.Element) -> SharePreview<PreviewImage, PreviewIcon>)?
    var label: Label

    nonisolated init(items: Data, subject: Text?, message: Text?,
                     preview: ((Data.Element) -> SharePreview<PreviewImage, PreviewIcon>)?, label: Label) {
        self.items = items
        self.subject = subject
        self.message = message
        self.preview = preview
        self.label = label
    }

    public init(items: Data, subject: Text? = nil, message: Text? = nil,
                preview: @escaping (Data.Element) -> SharePreview<PreviewImage, PreviewIcon>, @ViewBuilder label: () -> Label) {
        self.init(items: items, subject: subject, message: message, preview: preview, label: label())
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _FinchShareButton(items: items.map(_finchShareItem), subject: subject, message: message, label: label)
    }
}

@available(*, unavailable) extension ShareLink: Sendable {}

/// An item as the picker takes it: URLs and strings as they are, anything else as its text.
private func _finchShareItem<T: Transferable>(_ item: T) -> NSObject {
    switch item {
    case let url as URL: url as NSURL
    case let string as String: string as NSString
    case let string as AttributedString: String(string.characters) as NSString
    default: String(describing: item) as NSString
    }
}

@available(OpenSwiftUI_v4_0, *)
extension ShareLink {
    nonisolated public init<I>(item: I, subject: Text? = nil, message: Text? = nil,
                               preview: SharePreview<PreviewImage, PreviewIcon>, @ViewBuilder label: () -> Label)
        where Data == CollectionOfOne<I>, I: Transferable {
        self.init(items: CollectionOfOne(item), subject: subject, message: message, preview: { _ in preview }, label: label())
    }
}

@available(OpenSwiftUI_v4_0, *)
extension ShareLink where PreviewImage == Never, PreviewIcon == Never, Data.Element == URL {
    nonisolated public init(items: Data, subject: Text? = nil, message: Text? = nil, @ViewBuilder label: () -> Label) {
        self.init(items: items, subject: subject, message: message, preview: nil, label: label())
    }
}

@available(OpenSwiftUI_v4_0, *)
extension ShareLink where PreviewImage == Never, PreviewIcon == Never, Data.Element == String {
    nonisolated public init(items: Data, subject: Text? = nil, message: Text? = nil, @ViewBuilder label: () -> Label) {
        self.init(items: items, subject: subject, message: message, preview: nil, label: label())
    }
}

@available(OpenSwiftUI_v4_0, *)
extension ShareLink where PreviewImage == Never, PreviewIcon == Never {
    nonisolated public init(item: URL, subject: Text? = nil, message: Text? = nil, @ViewBuilder label: () -> Label)
        where Data == CollectionOfOne<URL> {
        self.init(items: CollectionOfOne(item), subject: subject, message: message, preview: nil, label: label())
    }

    nonisolated public init(item: String, subject: Text? = nil, message: Text? = nil, @ViewBuilder label: () -> Label)
        where Data == CollectionOfOne<String> {
        self.init(items: CollectionOfOne(item), subject: subject, message: message, preview: nil, label: label())
    }
}

@available(OpenSwiftUI_v4_0, *)
extension ShareLink where Label == DefaultShareLinkLabel {
    nonisolated public init(items: Data, subject: Text? = nil, message: Text? = nil,
                            preview: @escaping (Data.Element) -> SharePreview<PreviewImage, PreviewIcon>) {
        self.init(items: items, subject: subject, message: message, preview: preview, label: DefaultShareLinkLabel())
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, items: Data, subject: Text? = nil, message: Text? = nil,
                            preview: @escaping (Data.Element) -> SharePreview<PreviewImage, PreviewIcon>) {
        self.init(Text(titleKey), items: items, subject: subject, message: message, preview: preview)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, items: Data, subject: Text? = nil, message: Text? = nil,
                               preview: @escaping (Data.Element) -> SharePreview<PreviewImage, PreviewIcon>)
        where S: StringProtocol {
        self.init(Text(title), items: items, subject: subject, message: message, preview: preview)
    }

    nonisolated public init(_ title: Text, items: Data, subject: Text? = nil, message: Text? = nil,
                            preview: @escaping (Data.Element) -> SharePreview<PreviewImage, PreviewIcon>) {
        self.init(items: items, subject: subject, message: message, preview: preview, label: DefaultShareLinkLabel(title: title))
    }

    nonisolated public init<I>(item: I, subject: Text? = nil, message: Text? = nil, preview: SharePreview<PreviewImage, PreviewIcon>)
        where Data == CollectionOfOne<I>, I: Transferable {
        self.init(items: CollectionOfOne(item), subject: subject, message: message, preview: { _ in preview },
                  label: DefaultShareLinkLabel())
    }

    nonisolated public init<I>(_ titleKey: LocalizedStringKey, item: I, subject: Text? = nil, message: Text? = nil,
                               preview: SharePreview<PreviewImage, PreviewIcon>) where Data == CollectionOfOne<I>, I: Transferable {
        self.init(Text(titleKey), item: item, subject: subject, message: message, preview: preview)
    }

    @_disfavoredOverload
    nonisolated public init<S, I>(_ title: S, item: I, subject: Text? = nil, message: Text? = nil,
                                  preview: SharePreview<PreviewImage, PreviewIcon>)
        where Data == CollectionOfOne<I>, S: StringProtocol, I: Transferable {
        self.init(Text(title), item: item, subject: subject, message: message, preview: preview)
    }

    nonisolated public init<I>(_ title: Text, item: I, subject: Text? = nil, message: Text? = nil,
                               preview: SharePreview<PreviewImage, PreviewIcon>) where Data == CollectionOfOne<I>, I: Transferable {
        self.init(items: CollectionOfOne(item), subject: subject, message: message, preview: { _ in preview },
                  label: DefaultShareLinkLabel(title: title))
    }
}

@available(OpenSwiftUI_v4_0, *)
extension ShareLink where PreviewImage == Never, PreviewIcon == Never, Label == DefaultShareLinkLabel, Data.Element == URL {
    nonisolated public init(items: Data, subject: Text? = nil, message: Text? = nil) {
        self.init(items: items, subject: subject, message: message, preview: nil, label: DefaultShareLinkLabel())
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, items: Data, subject: Text? = nil, message: Text? = nil) {
        self.init(Text(titleKey), items: items, subject: subject, message: message)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, items: Data, subject: Text? = nil, message: Text? = nil) where S: StringProtocol {
        self.init(Text(title), items: items, subject: subject, message: message)
    }

    nonisolated public init(_ title: Text, items: Data, subject: Text? = nil, message: Text? = nil) {
        self.init(items: items, subject: subject, message: message, preview: nil, label: DefaultShareLinkLabel(title: title))
    }
}

@available(OpenSwiftUI_v4_0, *)
extension ShareLink where PreviewImage == Never, PreviewIcon == Never, Label == DefaultShareLinkLabel, Data.Element == String {
    nonisolated public init(items: Data, subject: Text? = nil, message: Text? = nil) {
        self.init(items: items, subject: subject, message: message, preview: nil, label: DefaultShareLinkLabel())
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, items: Data, subject: Text? = nil, message: Text? = nil) {
        self.init(Text(titleKey), items: items, subject: subject, message: message)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, items: Data, subject: Text? = nil, message: Text? = nil) where S: StringProtocol {
        self.init(Text(title), items: items, subject: subject, message: message)
    }

    nonisolated public init(_ title: Text, items: Data, subject: Text? = nil, message: Text? = nil) {
        self.init(items: items, subject: subject, message: message, preview: nil, label: DefaultShareLinkLabel(title: title))
    }
}

@available(OpenSwiftUI_v4_0, *)
extension ShareLink where PreviewImage == Never, PreviewIcon == Never, Label == DefaultShareLinkLabel {
    nonisolated public init(item: URL, subject: Text? = nil, message: Text? = nil) where Data == CollectionOfOne<URL> {
        self.init(items: CollectionOfOne(item), subject: subject, message: message, preview: nil, label: DefaultShareLinkLabel())
    }

    nonisolated public init(item: String, subject: Text? = nil, message: Text? = nil) where Data == CollectionOfOne<String> {
        self.init(items: CollectionOfOne(item), subject: subject, message: message, preview: nil, label: DefaultShareLinkLabel())
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, item: URL, subject: Text? = nil, message: Text? = nil)
        where Data == CollectionOfOne<URL> {
        self.init(Text(titleKey), item: item, subject: subject, message: message)
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, item: String, subject: Text? = nil, message: Text? = nil)
        where Data == CollectionOfOne<String> {
        self.init(Text(titleKey), item: item, subject: subject, message: message)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, item: URL, subject: Text? = nil, message: Text? = nil)
        where Data == CollectionOfOne<URL>, S: StringProtocol {
        self.init(Text(title), item: item, subject: subject, message: message)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, item: String, subject: Text? = nil, message: Text? = nil)
        where Data == CollectionOfOne<String>, S: StringProtocol {
        self.init(Text(title), item: item, subject: subject, message: message)
    }

    nonisolated public init(_ title: Text, item: URL, subject: Text? = nil, message: Text? = nil)
        where Data == CollectionOfOne<URL> {
        self.init(items: CollectionOfOne(item), subject: subject, message: message, preview: nil,
                  label: DefaultShareLinkLabel(title: title))
    }

    nonisolated public init(_ title: Text, item: String, subject: Text? = nil, message: Text? = nil)
        where Data == CollectionOfOne<String> {
        self.init(items: CollectionOfOne(item), subject: subject, message: message, preview: nil,
                  label: DefaultShareLinkLabel(title: title))
    }
}

// MARK: - The button

/// The share button: its label, with an anchor behind it for the picker to show under.
struct _FinchShareButton<Label: View>: View {
    var items: [NSObject]
    var subject: Text?
    var message: Text?
    var label: Label

    @Environment(\.self) private var environment
    @State private var anchor = _FinchShareAnchor.Box()

    var body: some View {
        Button {
            share()
        } label: {
            label
        }
        .background(_FinchShareAnchor(box: anchor))
    }

    private func share() {
        guard let view = anchor.view else { return }
        var shared: [NSObject] = items
        if let message { shared.insert(message._resolveText(in: environment) as NSString, at: 0) }
        let picker = NSSharingServicePicker(items: shared)
        let delegate = _FinchSharePickerDelegate(subject: subject?._resolveText(in: environment))
        picker.delegate = delegate
        withExtendedLifetime(delegate) {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }
}

/// Gives the chosen service the link's subject.
final class _FinchSharePickerDelegate: NSObject, NSSharingServicePickerDelegate {
    let subject: String?

    init(subject: String?) {
        self.subject = subject
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if let subject { service?.subject = subject }
    }
}

/// An empty view behind the button, kept in a box for the button's action.
struct _FinchShareAnchor: NSViewRepresentable {
    final class Box {
        weak var view: NSView?
    }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    var box: Box

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        box.view = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        box.view = view
    }
}
