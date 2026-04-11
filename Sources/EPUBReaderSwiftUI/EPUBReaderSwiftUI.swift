// The Swift Programming Language
// https://docs.swift.org/swift-book
import SwiftUI
import Combine
@_exported @preconcurrency import ReadiumShared
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumStreamer
import ReadiumAdapterGCDWebServer

// MARK: - Public Type Aliases
/// Re-exported so users don't need `import ReadiumShared` for basic usage.
public typealias EPUBReaderSwiftUILocator = Locator
public typealias EPUBReaderSwiftUILink = ReadiumShared.Link

// MARK: - Highlight Types

/// A color for a user highlight.
public enum EPUBHighlightColor: String, Codable, CaseIterable, Sendable {
    case yellow, green, blue, red, purple

    /// Maps to a UIColor for Readium's Decoration tint.
    public var uiColor: UIColor {
        switch self {
        case .yellow: return .systemYellow
        case .green:  return .systemGreen
        case .blue:   return .systemBlue
        case .red:    return .systemRed
        case .purple: return .systemPurple
        }
    }
}

/// The visual style of a highlight decoration.
public enum EPUBHighlightStyle: String, Codable, Sendable {
    case highlight
    case underline
}

/// A user highlight in a publication.
///
/// Readium only renders highlights — your app is responsible for persisting them.
/// Pass highlights in via a `Binding<[EPUBHighlight]>` and the library will
/// render them using Readium's Decoration API.
public struct EPUBHighlight: Identifiable, Equatable, Hashable {
    public var id: String
    public var locator: Locator
    public var color: EPUBHighlightColor
    public var style: EPUBHighlightStyle
    /// An optional user note attached to the highlight.
    public var note: String?

    /// The highlighted text, if available.
    public var highlightText: String? {
        locator.text.highlight
    }

    public init(
        id: String = UUID().uuidString,
        locator: Locator,
        color: EPUBHighlightColor = .yellow,
        style: EPUBHighlightStyle = .highlight,
        note: String? = nil
    ) {
        self.id = id
        self.locator = locator
        self.color = color
        self.style = style
        self.note = note
    }
}

// MARK: - EPUBHighlight + Codable
// Readium's `Locator` does not conform to `Codable`; it uses custom
// JSON serialisation via `jsonString` / `init(jsonString:)`.  We bridge
// that here so consumers can still encode / decode `EPUBHighlight`
// with standard `JSONEncoder` / `JSONDecoder`.
extension EPUBHighlight: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, locatorJSON, color, style, note
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(color, forKey: .color)
        try container.encode(style, forKey: .style)
        try container.encodeIfPresent(note, forKey: .note)

        // Serialize Locator via Readium's own JSON representation.
        guard let locatorString = locator.jsonString else {
            throw EncodingError.invalidValue(locator, .init(
                codingPath: encoder.codingPath,
                debugDescription: "Locator could not be serialized to JSON string"
            ))
        }
        try container.encode(locatorString, forKey: .locatorJSON)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        color = try container.decode(EPUBHighlightColor.self, forKey: .color)
        style = try container.decode(EPUBHighlightStyle.self, forKey: .style)
        note = try container.decodeIfPresent(String.self, forKey: .note)

        let locatorString = try container.decode(String.self, forKey: .locatorJSON)
        guard let loc = try Locator(jsonString: locatorString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .locatorJSON,
                in: container,
                debugDescription: "Invalid Locator JSON string"
            )
        }
        locator = loc
    }

    /// Converts to a Readium `Decoration` for rendering.
    func toDecoration(isActive: Bool = false) -> Decoration {
        let decoStyle: Decoration.Style
        switch style {
        case .highlight:
            decoStyle = .highlight(tint: color.uiColor, isActive: isActive)
        case .underline:
            decoStyle = .underline(tint: color.uiColor, isActive: isActive)
        }
        return Decoration(id: id, locator: locator, style: decoStyle)
    }
}

/// Event fired when the user taps an existing highlight.
public struct EPUBHighlightTapEvent {
    /// The tapped highlight.
    public let highlight: EPUBHighlight
    /// The bounding rect of the highlight in the navigator view's coordinate space.
    /// Useful for anchoring a popover.
    public let rect: CGRect?
}

// MARK: - Bookmark Types

/// A user bookmark in a publication.
///
/// Your app owns the `[EPUBBookmark]` array and is responsible for persisting it.
/// Pass bookmarks in via a `Binding<[EPUBBookmark]>` and the library will
/// expose toggle/query actions through `EPUBReaderOverlayContext`.
public struct EPUBBookmark: Identifiable, Equatable, Hashable {
    public var id: String
    public var locator: Locator
    public var createdAt: Date
    /// Explicit chapter title, set when the bookmark is created.
    /// Falls back to `locator.title` if not provided.
    public var title: String?
    /// A short text preview captured from the page when the bookmark was created.
    public var textPreview: String?

    /// The chapter title — prefers the explicit `title`, then the locator's title.
    public var chapterTitle: String? {
        if let t = title, !t.isEmpty { return t }
        if let t = locator.title, !t.isEmpty { return t }
        return nil
    }

    /// A display label: chapter title if available, otherwise a text preview
    /// from the bookmarked position, or a progression percentage as last resort.
    public var displayTitle: String {
        if let t = chapterTitle { return t }
        if let t = textPreview, !t.isEmpty { return t }
        if let prog = progression { return "Page at \(Int(prog * 100))%" }
        return "Bookmark"
    }

    /// The total reading progression at the bookmark (0.0–1.0).
    public var progression: Double? {
        locator.locations.totalProgression
    }

    public init(
        id: String = UUID().uuidString,
        locator: Locator,
        title: String? = nil,
        textPreview: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.locator = locator
        self.title = title
        self.textPreview = textPreview
        self.createdAt = createdAt
    }
}

// MARK: - EPUBBookmark + Codable
extension EPUBBookmark: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, locatorJSON, createdAt, title, textPreview
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(textPreview, forKey: .textPreview)

        guard let locatorString = locator.jsonString else {
            throw EncodingError.invalidValue(locator, .init(
                codingPath: encoder.codingPath,
                debugDescription: "Locator could not be serialized to JSON string"
            ))
        }
        try container.encode(locatorString, forKey: .locatorJSON)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        textPreview = try container.decodeIfPresent(String.self, forKey: .textPreview)

        let locatorString = try container.decode(String.self, forKey: .locatorJSON)
        guard let loc = try Locator(jsonString: locatorString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .locatorJSON,
                in: container,
                debugDescription: "Invalid Locator JSON string"
            )
        }
        locator = loc
    }
}

// MARK: - Default Highlight Edit Sheet
/// Built-in sheet for editing or deleting a highlight (color, style, note, delete).
/// Shown automatically when the user taps a highlight and no custom
/// `onHighlightTapped` handler is provided.
public struct DefaultHighlightEditSheet: View {
    let highlight: EPUBHighlight
    let onChangeColor: (EPUBHighlightColor) -> Void
    let onToggleStyle: () -> Void
    let onUpdateNote: (String?) -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    @State private var noteText: String = ""

    public init(
        highlight: EPUBHighlight,
        onChangeColor: @escaping (EPUBHighlightColor) -> Void,
        onToggleStyle: @escaping () -> Void,
        onUpdateNote: @escaping (String?) -> Void,
        onDelete: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.highlight = highlight
        self.onChangeColor = onChangeColor
        self.onToggleStyle = onToggleStyle
        self.onUpdateNote = onUpdateNote
        self.onDelete = onDelete
        self.onDismiss = onDismiss
        _noteText = State(initialValue: highlight.note ?? "")
    }

    public var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("Edit Highlight")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    // Save note on dismiss — treat empty string as nil
                    let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                    onUpdateNote(trimmed.isEmpty ? nil : trimmed)
                    onDismiss()
                }
            }

            // Highlighted text preview
            if let text = highlight.highlightText {
                Text("\u{201C}\(text)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Color picker row
            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    ForEach(EPUBHighlightColor.allCases, id: \.self) { color in
                        Button {
                            onChangeColor(color)
                        } label: {
                            Circle()
                                .fill(Color(color.uiColor))
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.primary, lineWidth: highlight.color == color ? 2.5 : 0)
                                )
                        }
                    }
                }
            }

            // Note field
            VStack(alignment: .leading, spacing: 8) {
                Text("Note")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $noteText)
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(UIColor.separator), lineWidth: 0.5)
                    )
                    .overlay(alignment: .topLeading) {
                        if noteText.isEmpty {
                            Text("Add a note\u{2026}")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
            }

            HStack(spacing: 16) {
                // Toggle style
                Button {
                    onToggleStyle()
                } label: {
                    Label(
                        highlight.style == .highlight ? "Switch to Underline" : "Switch to Highlight",
                        systemImage: highlight.style == .highlight ? "underline" : "highlighter"
                    )
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)

                Spacer()

                // Delete
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

// MARK: - TOC Context
/// All the state and actions available to a custom table of contents view.
public struct EPUBReaderTOCContext {
    /// The flat list of TOC entries. Each entry may have `.children`.
    public let tableOfContents: [EPUBReaderSwiftUILink]
    /// The reader's current locator (href, title, progression, etc.).
    public let currentLocator: EPUBReaderSwiftUILocator?
    /// Call this with a TOC link to navigate to it.
    public let navigateToLink: (EPUBReaderSwiftUILink) -> Void
    /// Dismiss the TOC sheet.
    public let dismiss: () -> Void
}

// MARK: - EPUB Source
public enum EPUBSource {
    /// A local file URL pointing to an .epub file already on disk.
    case fileURL(URL)
    /// A remote URL string. The package will download and cache the file automatically.
    case remoteURL(String, useCache: Bool = true)
}

// MARK: - Overlay Context
/// All the state and actions available to a custom reader overlay.
public struct EPUBReaderOverlayContext {
    // Book metadata
    public let title: String?
    public let author: String?

    // Reading state
    public let currentLocator: EPUBReaderSwiftUILocator?
    public var chapterTitle: String? { currentLocator?.title }
    public var totalProgression: Double? { currentLocator?.locations.totalProgression }

    // Controls visibility (toggled by tapping the page)
    public let showControls: Bool

    // Font size — bind to a Slider or stepper in your overlay
    public var fontSize: Binding<Double>

    // Bookmarks
    /// Whether the current page/chapter has a bookmark.
    public let isCurrentPageBookmarked: Bool
    /// All bookmarks (read-only snapshot for listing in custom overlays).
    public let bookmarks: [EPUBBookmark]
    /// Toggles a bookmark for the current reading position — adds if none
    /// exists for this chapter, removes the matching one otherwise.
    public let toggleBookmark: () -> Void
    /// Opens the built-in bookmarks list sheet.
    public let showBookmarkList: () -> Void
    /// Navigate to a specific locator (e.g. a bookmark's locator).
    public let navigateToLocator: (Locator) -> Void
    /// Delete a bookmark by its ID.
    public let deleteBookmark: (String) -> Void

    // Actions
    public let close: () -> Void
    public let showTableOfContents: () -> Void
    public let toggleControls: () -> Void
    /// Navigate to a specific overall progression (0.0 → 1.0).
    public let goToProgression: (Double) -> Void
}

// MARK: - Default Overlay
/// The built-in overlay used when no custom overlay is provided.
public struct DefaultEPUBReaderOverlay: View {
    public let context: EPUBReaderOverlayContext

    public init(context: EPUBReaderOverlayContext) {
        self.context = context
    }

    public var body: some View {
        VStack {
            if context.showControls {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()

            if context.showControls {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Top bar
    private var topBar: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: context.close) {
                    Image(systemName: "xmark")
                        .font(.title3)
                }

                Button(action: context.showTableOfContents) {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                }

                Button(action: context.toggleBookmark) {
                    Image(systemName: context.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.title3)
                        .foregroundStyle(context.isCurrentPageBookmarked ? Color.accentColor : .primary)
                }

                // Bookmarks list (show badge with count)
                Button(action: context.showBookmarkList) {
                    Image(systemName: "books.vertical")
                        .font(.title3)
                }
                .overlay(alignment: .topTrailing) {
                    if !context.bookmarks.isEmpty {
                        Text("\(context.bookmarks.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(3)
                            .background(Color.accentColor)
                            .clipShape(Circle())
                            .offset(x: 6, y: -6)
                    }
                }

                Text(context.title ?? "Unknown Title")
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                if let author = context.author {
                    Text(author)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Font Size")
                    .font(.caption)

                HStack {
                    Text("A")
                        .font(.caption)

                    Slider(value: context.fontSize, in: 0.75...2.0, step: 0.25)

                    Text("A")
                        .font(.title3)

                    Text("\(Int(context.fontSize.wrappedValue * 100))%")
                        .font(.caption)
                        .frame(width: 50)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding()
    }

    // MARK: - Bottom bar
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let chapterTitle = context.chapterTitle {
                Text(chapterTitle)
                    .font(.caption)
                    .lineLimit(1)
            }

            if let progression = context.totalProgression {
                HStack {
                    ProgressView(value: progression)
                    Text("\(Int(progression * 100))%")
                        .font(.caption2)
                        .frame(width: 40)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding()
    }
}

// MARK: - EPUBReaderView
public struct EPUBReaderView<Overlay: View, TOCView: View>: View {
    let source: EPUBSource
    let initialLocator: Locator?
    let initialPreferences: EPUBReaderSwiftUIPreferences
    let onClose: (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void
    let overlay: (EPUBReaderOverlayContext) -> Overlay
    let tocView: (EPUBReaderTOCContext) -> TOCView

    // Highlight support
    @Binding var highlights: [EPUBHighlight]
    let onHighlightCreated: ((EPUBHighlight) -> Void)?
    let onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)?

    // Bookmark support
    @Binding var bookmarks: [EPUBBookmark]

    @MainActor @StateObject private var viewModel = EPUBReaderViewModel()
    @State private var fontSize: Double
    @State private var showControls = false
    @State private var showTOC = false
    @State private var showBookmarkList = false
    @State private var currentLocator: Locator?

    // Internal state for the built-in highlight popover
    @State private var editingHighlight: EPUBHighlight?
    @State private var showHighlightPopover = false
    @State private var highlightPopoverAnchor: CGPoint = .zero

    /// Initialize with an `EPUBSource`, a custom overlay, and a custom TOC view.
    public init(
        source: EPUBSource,
        initialLocator: EPUBReaderSwiftUILocator? = nil,
        initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(),
        highlights: Binding<[EPUBHighlight]> = .constant([]),
        onHighlightCreated: ((EPUBHighlight) -> Void)? = nil,
        onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)? = nil,
        bookmarks: Binding<[EPUBBookmark]> = .constant([]),
        onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void,
        @ViewBuilder overlay: @escaping (EPUBReaderOverlayContext) -> Overlay,
        @ViewBuilder tocView: @escaping (EPUBReaderTOCContext) -> TOCView
    ) {
        self.source = source
        self.initialLocator = initialLocator
        self.initialPreferences = initialPreferences
        self._highlights = highlights
        self.onHighlightCreated = onHighlightCreated
        self.onHighlightTapped = onHighlightTapped
        self._bookmarks = bookmarks
        self.onClose = onClose
        self.overlay = overlay
        self.tocView = tocView
        _fontSize = State(initialValue: initialPreferences.fontSize)
    }

    /// Convenience: remote URL with custom overlay and TOC.
    public init(remoteURL: String, useCache: Bool = true, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), highlights: Binding<[EPUBHighlight]> = .constant([]), onHighlightCreated: ((EPUBHighlight) -> Void)? = nil, onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)? = nil, bookmarks: Binding<[EPUBBookmark]> = .constant([]), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void, @ViewBuilder overlay: @escaping (EPUBReaderOverlayContext) -> Overlay, @ViewBuilder tocView: @escaping (EPUBReaderTOCContext) -> TOCView) {
        self.init(source: .remoteURL(remoteURL, useCache: useCache), initialLocator: initialLocator, initialPreferences: initialPreferences, highlights: highlights, onHighlightCreated: onHighlightCreated, onHighlightTapped: onHighlightTapped, bookmarks: bookmarks, onClose: onClose, overlay: overlay, tocView: tocView)
    }

    /// Convenience: local file URL with custom overlay and TOC.
    public init(url: URL, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), highlights: Binding<[EPUBHighlight]> = .constant([]), onHighlightCreated: ((EPUBHighlight) -> Void)? = nil, onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)? = nil, bookmarks: Binding<[EPUBBookmark]> = .constant([]), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void, @ViewBuilder overlay: @escaping (EPUBReaderOverlayContext) -> Overlay, @ViewBuilder tocView: @escaping (EPUBReaderTOCContext) -> TOCView) {
        self.init(source: .fileURL(url), initialLocator: initialLocator, initialPreferences: initialPreferences, highlights: highlights, onHighlightCreated: onHighlightCreated, onHighlightTapped: onHighlightTapped, bookmarks: bookmarks, onClose: onClose, overlay: overlay, tocView: tocView)
    }
}

// MARK: - Default overlay + default TOC inits (fully backward-compatible)
extension EPUBReaderView where Overlay == DefaultEPUBReaderOverlay, TOCView == DefaultEPUBReaderTOCView {

    public init(source: EPUBSource, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), highlights: Binding<[EPUBHighlight]> = .constant([]), onHighlightCreated: ((EPUBHighlight) -> Void)? = nil, onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)? = nil, bookmarks: Binding<[EPUBBookmark]> = .constant([]), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void) {
        self.init(source: source, initialLocator: initialLocator, initialPreferences: initialPreferences, highlights: highlights, onHighlightCreated: onHighlightCreated, onHighlightTapped: onHighlightTapped, bookmarks: bookmarks, onClose: onClose, overlay: { DefaultEPUBReaderOverlay(context: $0) }, tocView: { DefaultEPUBReaderTOCView(context: $0) })
    }

    public init(remoteURL: String, useCache: Bool = true, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), highlights: Binding<[EPUBHighlight]> = .constant([]), onHighlightCreated: ((EPUBHighlight) -> Void)? = nil, onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)? = nil, bookmarks: Binding<[EPUBBookmark]> = .constant([]), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void) {
        self.init(source: .remoteURL(remoteURL, useCache: useCache), initialLocator: initialLocator, initialPreferences: initialPreferences, highlights: highlights, onHighlightCreated: onHighlightCreated, onHighlightTapped: onHighlightTapped, bookmarks: bookmarks, onClose: onClose)
    }

    public init(url: URL, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), highlights: Binding<[EPUBHighlight]> = .constant([]), onHighlightCreated: ((EPUBHighlight) -> Void)? = nil, onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)? = nil, bookmarks: Binding<[EPUBBookmark]> = .constant([]), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void) {
        self.init(source: .fileURL(url), initialLocator: initialLocator, initialPreferences: initialPreferences, highlights: highlights, onHighlightCreated: onHighlightCreated, onHighlightTapped: onHighlightTapped, bookmarks: bookmarks, onClose: onClose)
    }
}

// MARK: - Default overlay + custom TOC
extension EPUBReaderView where Overlay == DefaultEPUBReaderOverlay {

    public init(source: EPUBSource, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), highlights: Binding<[EPUBHighlight]> = .constant([]), onHighlightCreated: ((EPUBHighlight) -> Void)? = nil, onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)? = nil, bookmarks: Binding<[EPUBBookmark]> = .constant([]), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void, @ViewBuilder tocView: @escaping (EPUBReaderTOCContext) -> TOCView) {
        self.init(source: source, initialLocator: initialLocator, initialPreferences: initialPreferences, highlights: highlights, onHighlightCreated: onHighlightCreated, onHighlightTapped: onHighlightTapped, bookmarks: bookmarks, onClose: onClose, overlay: { DefaultEPUBReaderOverlay(context: $0) }, tocView: tocView)
    }

    public init(remoteURL: String, useCache: Bool = true, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), highlights: Binding<[EPUBHighlight]> = .constant([]), onHighlightCreated: ((EPUBHighlight) -> Void)? = nil, onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)? = nil, bookmarks: Binding<[EPUBBookmark]> = .constant([]), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void, @ViewBuilder tocView: @escaping (EPUBReaderTOCContext) -> TOCView) {
        self.init(source: .remoteURL(remoteURL, useCache: useCache), initialLocator: initialLocator, initialPreferences: initialPreferences, highlights: highlights, onHighlightCreated: onHighlightCreated, onHighlightTapped: onHighlightTapped, bookmarks: bookmarks, onClose: onClose, tocView: tocView)
    }

    public init(url: URL, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), highlights: Binding<[EPUBHighlight]> = .constant([]), onHighlightCreated: ((EPUBHighlight) -> Void)? = nil, onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)? = nil, bookmarks: Binding<[EPUBBookmark]> = .constant([]), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void, @ViewBuilder tocView: @escaping (EPUBReaderTOCContext) -> TOCView) {
        self.init(source: .fileURL(url), initialLocator: initialLocator, initialPreferences: initialPreferences, highlights: highlights, onHighlightCreated: onHighlightCreated, onHighlightTapped: onHighlightTapped, bookmarks: bookmarks, onClose: onClose, tocView: tocView)
    }
}

// MARK: - Custom overlay + default TOC
extension EPUBReaderView where TOCView == DefaultEPUBReaderTOCView {

    public init(source: EPUBSource, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), highlights: Binding<[EPUBHighlight]> = .constant([]), onHighlightCreated: ((EPUBHighlight) -> Void)? = nil, onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)? = nil, bookmarks: Binding<[EPUBBookmark]> = .constant([]), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void, @ViewBuilder overlay: @escaping (EPUBReaderOverlayContext) -> Overlay) {
        self.init(source: source, initialLocator: initialLocator, initialPreferences: initialPreferences, highlights: highlights, onHighlightCreated: onHighlightCreated, onHighlightTapped: onHighlightTapped, bookmarks: bookmarks, onClose: onClose, overlay: overlay, tocView: { DefaultEPUBReaderTOCView(context: $0) })
    }

    public init(remoteURL: String, useCache: Bool = true, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), highlights: Binding<[EPUBHighlight]> = .constant([]), onHighlightCreated: ((EPUBHighlight) -> Void)? = nil, onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)? = nil, bookmarks: Binding<[EPUBBookmark]> = .constant([]), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void, @ViewBuilder overlay: @escaping (EPUBReaderOverlayContext) -> Overlay) {
        self.init(source: .remoteURL(remoteURL, useCache: useCache), initialLocator: initialLocator, initialPreferences: initialPreferences, highlights: highlights, onHighlightCreated: onHighlightCreated, onHighlightTapped: onHighlightTapped, bookmarks: bookmarks, onClose: onClose, overlay: overlay)
    }

    public init(url: URL, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), highlights: Binding<[EPUBHighlight]> = .constant([]), onHighlightCreated: ((EPUBHighlight) -> Void)? = nil, onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)? = nil, bookmarks: Binding<[EPUBBookmark]> = .constant([]), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void, @ViewBuilder overlay: @escaping (EPUBReaderOverlayContext) -> Overlay) {
        self.init(source: .fileURL(url), initialLocator: initialLocator, initialPreferences: initialPreferences, highlights: highlights, onHighlightCreated: onHighlightCreated, onHighlightTapped: onHighlightTapped, bookmarks: bookmarks, onClose: onClose, overlay: overlay)
    }
}

// MARK: - EPUBReaderView body & helpers
extension EPUBReaderView {

    public var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            if viewModel.isLoading {
                VStack(spacing: 16) {
                    ProgressView(viewModel.loadingMessage)
                    
                    Button(action: {
                        onClose(nil, EPUBReaderSwiftUIPreferences(fontSize: fontSize))
                    }) {
                        Text("Cancel")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.red)
                            .cornerRadius(8)
                    }
                }
            } else if let error = viewModel.error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                    Text("Error loading EPUB")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()

                    Button(action: {
                        onClose(nil, EPUBReaderSwiftUIPreferences(fontSize: fontSize))
                    }) {
                        Text("Close")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                }
            } else if let publication = viewModel.publication {
                readerContent(publication: publication)
            }
        }
        .task {
            await viewModel.loadEPUB(source: source, initialLocator: initialLocator)
        }
        .sheet(isPresented: $showTOC) {
            tocView(EPUBReaderTOCContext(
                tableOfContents: viewModel.tableOfContents,
                currentLocator: currentLocator,
                navigateToLink: { link in
                    Task { await viewModel.navigateToLink(link) }
                    showTOC = false
                },
                dismiss: { showTOC = false }
            ))
        }
        .sheet(isPresented: $showBookmarkList) {
            DefaultBookmarkListView(
                bookmarks: bookmarks,
                onNavigate: { bookmark in
                    Task { await viewModel.navigateToLocator(bookmark.locator) }
                    showBookmarkList = false
                },
                onDelete: { id in
                    bookmarks.removeAll { $0.id == id }
                },
                onDismiss: { showBookmarkList = false }
            )
        }
        // Built-in highlight popover anchored near the tapped highlight
        .overlay(
            Color.clear
                .frame(width: 1, height: 1)
                .position(highlightPopoverAnchor)
                .popover(isPresented: $showHighlightPopover) {
                    if let hl = editingHighlight {
                        DefaultHighlightEditSheet(
                            highlight: hl,
                            onChangeColor: { newColor in
                                if let idx = highlights.firstIndex(where: { $0.id == hl.id }) {
                                    highlights[idx].color = newColor
                                    editingHighlight = highlights[idx]
                                }
                            },
                            onToggleStyle: {
                                if let idx = highlights.firstIndex(where: { $0.id == hl.id }) {
                                    highlights[idx].style = highlights[idx].style == .highlight ? .underline : .highlight
                                    editingHighlight = highlights[idx]
                                }
                            },
                            onUpdateNote: { newNote in
                                if let idx = highlights.firstIndex(where: { $0.id == hl.id }) {
                                    highlights[idx].note = newNote
                                }
                            },
                            onDelete: {
                                highlights.removeAll { $0.id == hl.id }
                                showHighlightPopover = false
                            },
                            onDismiss: {
                                showHighlightPopover = false
                            }
                        )
                        .frame(width: 320)
                    }
                }
        )
    }

    /// The effective `onHighlightCreated` handler: uses the consumer's
    /// callback if provided, otherwise falls back to appending to the
    /// highlights binding automatically.  Returns nil when the consumer
    /// has not opted-in to highlighting at all.
    private var resolvedOnHighlightCreated: ((EPUBHighlight) -> Void)? {
        onHighlightCreated
    }

    /// The effective `onHighlightTapped` handler: uses the consumer's
    /// callback if provided, otherwise falls back to showing the built-in
    /// popover — but only when highlighting is enabled.
    private var resolvedOnHighlightTapped: ((EPUBHighlightTapEvent) -> Void)? {
        if onHighlightTapped != nil { return onHighlightTapped }
        // Show the default edit popover only if the caller opted-in to highlighting.
        guard onHighlightCreated != nil else { return nil }
        return { event in
            editingHighlight = event.highlight
            // Position the popover anchor at the top-center of the highlight rect
            if let rect = event.rect {
                highlightPopoverAnchor = CGPoint(x: rect.midX, y: rect.minY)
            } else {
                highlightPopoverAnchor = CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY)
            }
            showHighlightPopover = true
        }
    }

    private func readerContent(publication: Publication) -> some View {
        ZStack {
            EPUBNavigatorWrapper(
                publication: publication,
                httpServer: viewModel.httpServer,
                initialLocator: initialLocator,
                fontSize: $fontSize,
                currentLocator: $currentLocator,
                highlights: $highlights,
                onHighlightCreated: resolvedOnHighlightCreated,
                onHighlightTapped: resolvedOnHighlightTapped,
                viewModel: viewModel,
                onTap: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                }
            )
            .ignoresSafeArea()

            let isBookmarked: Bool = {
                guard let loc = currentLocator else { return false }
                return bookmarks.contains(where: { Self.bookmarkMatchesLocator($0, loc) })
            }()

            let context = EPUBReaderOverlayContext(
                title: publication.metadata.title,
                author: publication.metadata.authors.first?.name,
                currentLocator: currentLocator,
                showControls: showControls,
                fontSize: $fontSize,
                isCurrentPageBookmarked: isBookmarked,
                bookmarks: bookmarks,
                toggleBookmark: {
                    guard let loc = currentLocator else { return }
                    if let idx = bookmarks.firstIndex(where: { Self.bookmarkMatchesLocator($0, loc) }) {
                        bookmarks.remove(at: idx)
                    } else {
                        let chapterTitle = Self.chapterTitle(for: loc, in: viewModel.tableOfContents)
                        let preview = Self.textPreview(from: loc)
                        // Create the bookmark immediately, then fetch page text async
                        let bookmark = EPUBBookmark(locator: loc, title: chapterTitle, textPreview: preview)
                        bookmarks.append(bookmark)
                        // Grab visible text from the web view to enrich the preview
                        Task {
                            if let pageText = await viewModel.getVisiblePageText(maxLength: 150) {
                                if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
                                    bookmarks[idx].textPreview = pageText
                                }
                            }
                        }
                    }
                },
                showBookmarkList: { showBookmarkList = true },
                navigateToLocator: { locator in
                    Task { await viewModel.navigateToLocator(locator) }
                },
                deleteBookmark: { id in
                    bookmarks.removeAll { $0.id == id }
                },
                close: {
                    let preferences = EPUBReaderSwiftUIPreferences(fontSize: fontSize)
                    onClose(currentLocator, preferences)
                },
                showTableOfContents: { showTOC = true },
                toggleControls: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                },
                goToProgression: { progression in
                    Task {
                        await viewModel.goToProgression(progression)
                    }
                }
            )

            overlay(context)
        }
    }

    /// Checks whether a bookmark matches a given locator (same page).
    /// Uses `locations.progression` (most granular) as primary match.
    private static func bookmarkMatchesLocator(_ bookmark: EPUBBookmark, _ locator: Locator) -> Bool {
        guard "\(bookmark.locator.href)" == "\(locator.href)" else { return false }

        // Prefer progression — it's the most granular indicator of position
        // within a resource. Use a very tight tolerance.
        if let bmProg = bookmark.locator.locations.progression,
           let locProg = locator.locations.progression {
            return abs(bmProg - locProg) < 0.001
        }

        // Fall back to position only if progression isn't available
        if let bmPos = bookmark.locator.locations.position,
           let locPos = locator.locations.position {
            return bmPos == locPos
        }

        return false
    }

    /// Finds the best matching chapter title for a locator by walking
    /// the table of contents.  Returns the locator's own title as a
    /// fallback, or `nil` if nothing is available.
    private static func chapterTitle(for locator: Locator, in toc: [ReadiumShared.Link]) -> String? {
        let locHref = "\(locator.href)"

        func hrefMatches(_ linkHrefRaw: String) -> Bool {
            let linkHref = linkHrefRaw.components(separatedBy: "#").first ?? linkHrefRaw
            let locBase = locHref.components(separatedBy: "#").first ?? locHref
            if linkHref == locBase { return true }
            if locBase.hasSuffix("/\(linkHref)") || locBase.hasSuffix(linkHref) { return true }
            if linkHref.hasSuffix("/\(locBase)") || linkHref.hasSuffix(locBase) { return true }
            return false
        }

        // Walk TOC (including children) and find the last link whose
        // href matches — "last" because TOC is ordered and deeper
        // entries are more specific.
        func search(_ links: [ReadiumShared.Link]) -> String? {
            var best: String?
            for link in links {
                if hrefMatches("\(link.href)") {
                    if let t = link.title, !t.isEmpty { best = t }
                }
                if let childResult = search(link.children) {
                    best = childResult
                }
            }
            return best
        }
        if let title = search(toc) { return title }
        if let title = locator.title, !title.isEmpty { return title }
        return nil
    }

    /// Builds a short text preview from the locator's text fields.
    /// Readium may populate `text.highlight`, `text.before`, or `text.after`
    /// depending on the context.  We concatenate whatever is available and
    /// truncate to a readable snippet.
    private static func textPreview(from locator: Locator, maxLength: Int = 120) -> String? {
        let parts = [
            locator.text.highlight,
            locator.text.before,
            locator.text.after
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
         .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return nil }

        let joined = parts.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        if joined.count <= maxLength { return joined }
        let truncated = String(joined.prefix(maxLength))
        // Break at last space to avoid cutting a word
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "\u{2026}"
        }
        return truncated + "\u{2026}"
    }
}

// MARK: - ViewModel
@MainActor
public class EPUBReaderViewModel: ObservableObject {
    @Published public var publication: Publication?
    @Published public var isLoading = false
    @Published public var loadingMessage = "Loading EPUB..."
    @Published public var error: String?
    @Published public var tableOfContents: [ReadiumShared.Link] = []

    private(set) var httpServer: HTTPServer!
    private var navigator: EPUBNavigatorViewController?
    private let httpClient: HTTPClient
    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener

    public init() {
        self.httpClient = DefaultHTTPClient()
        self.assetRetriever = AssetRetriever(httpClient: httpClient)
        self.publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
    }

    func setNavigator(_ navigator: EPUBNavigatorViewController) {
        self.navigator = navigator
    }

    func navigateToLink(_ link: ReadiumShared.Link) async {
        guard let locator = await publication?.locate(link) else { return }
        await navigator?.go(to: locator)
    }

    func navigateToLocator(_ locator: Locator) async {
        await navigator?.go(to: locator)
    }

    /// Grabs a short snippet of visible text from the current page via JavaScript.
    func getVisiblePageText(maxLength: Int = 200) async -> String? {
        guard let navigator = navigator else { return nil }
        let js = """
        (function() {
            // Find the exact text position at the top-left of the visible area
            var startRange = null;
            // Probe from top-left, scanning down to find actual text
            for (var y = 0; y < window.innerHeight && !startRange; y += 5) {
                for (var x = 10; x < window.innerWidth * 0.5 && !startRange; x += 10) {
                    var r = document.caretRangeFromPoint(x, y);
                    if (r && r.startContainer && r.startContainer.nodeType === 3) {
                        startRange = r;
                    }
                }
            }
            if (!startRange) return '';

            // Create a range from that point to the end of the body
            var range = document.createRange();
            range.setStart(startRange.startContainer, startRange.startOffset);
            range.setEnd(document.body, document.body.childNodes.length);
            var text = range.toString().trim();
            return text.substring(0, \(maxLength + 50));
        })();
        """
        let result = await navigator.evaluateJavaScript(js)
        switch result {
        case .success(let value):
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                guard !trimmed.isEmpty else { return nil }
                if trimmed.count <= maxLength { return trimmed }
                let truncated = String(trimmed.prefix(maxLength))
                if let lastSpace = truncated.lastIndex(of: " ") {
                    return String(truncated[..<lastSpace]) + "\u{2026}"
                }
                return truncated + "\u{2026}"
            }
            return nil
        case .failure:
            return nil
        }
    }

    func goToProgression(_ progression: Double) async {
        guard let publication = publication,
              let navigator = navigator else { return }

        let locator: Locator? = await publication.locate(progression: progression)
        guard let locator else { return }
        let _ = await navigator.go(to: locator)
    }

    func loadEPUB(source: EPUBSource, initialLocator: Locator?) async {
        isLoading = true
        error = nil

        // Resolve the local file URL from the source
        let localURL: URL
        switch source {
        case .fileURL(let url):
            loadingMessage = "Loading EPUB..."
            localURL = url
        case .remoteURL(let urlString, let useCache):
            loadingMessage = "Downloading EPUB..."
            do {
                localURL = try await EPUBDownloader.downloadEPUB(from: urlString, useCache: useCache)
                loadingMessage = "Loading EPUB..."
            } catch {
                self.error = "Download failed: \(error.localizedDescription)"
                isLoading = false
                return
            }
        }

        await openEPUB(from: localURL, initialLocator: initialLocator)
    }

    /// Opens an EPUB from a local file URL (shared logic).
    private func openEPUB(from url: URL, initialLocator: Locator?) async {
        self.httpServer = GCDHTTPServer(assetRetriever: assetRetriever)

        guard let fileURL = FileURL(url: url) else {
            error = "Invalid file URL"
            isLoading = false
            return
        }

        let assetResult = await assetRetriever.retrieve(url: fileURL.anyURL.absoluteURL!)

        switch assetResult {
        case .success(let asset):
            let openResult = await publicationOpener.open(
                asset: asset,
                allowUserInteraction: true,
                sender: nil
            )

            switch openResult {
            case .success(let pub):
                self.publication = pub
                
                // Load table of contents
                let tocResult = await pub.tableOfContents()
                switch tocResult {
                case .success(let toc):
                    self.tableOfContents = toc
                case .failure:
                    self.tableOfContents = []
                }
                
            case .failure(let err):
                self.error = "Failed to open: \(err.localizedDescription)"
            }

        case .failure(let err):
            self.error = "Failed to retrieve: \(err.localizedDescription)"
        }

        isLoading = false
    }
}

// MARK: - Navigator Container VC
/// A thin parent view controller that sits above `EPUBNavigatorViewController`
/// in the responder chain.  Readium routes custom `EditingAction` selectors up
/// the responder chain, so the "Highlight" menu item must be handled by a
/// UIViewController — not by an NSObject Coordinator.
public class EPUBNavigatorContainerViewController: UIViewController {
    var navigator: EPUBNavigatorViewController?
    var onHighlightCreated: ((EPUBHighlight) -> Void)?

    /// Selector target for the "Highlight" editing action.
    @objc func highlightSelection() {
        guard let navigator = navigator,
              let selection = navigator.currentSelection else { return }

        let highlight = EPUBHighlight(locator: selection.locator)
        onHighlightCreated?(highlight)
        navigator.clearSelection()
    }

    /// Forward `canPerformAction` so the "Highlight" item appears in the menu.
    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(highlightSelection) {
            return navigator?.currentSelection != nil && onHighlightCreated != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

// MARK: - Navigator Wrapper
public struct EPUBNavigatorWrapper: UIViewControllerRepresentable {
    let publication: Publication
    let httpServer: HTTPServer
    let initialLocator: Locator?
    @Binding var fontSize: Double
    @Binding var currentLocator: Locator?

    // Highlight support
    @Binding var highlights: [EPUBHighlight]
    var onHighlightCreated: ((EPUBHighlight) -> Void)?
    var onHighlightTapped: ((EPUBHighlightTapEvent) -> Void)?

    @ObservedObject var viewModel: EPUBReaderViewModel
    var onTap: (() -> Void)?

    /// The decoration group name used for user highlights.
    private static let highlightGroup = "user-highlights"

    public func makeUIViewController(context: Context) -> EPUBNavigatorContainerViewController {
        let container = EPUBNavigatorContainerViewController()
        container.onHighlightCreated = onHighlightCreated

        // Add "Highlight" editing action only when the caller opted-in.
        var editingActions = EditingAction.defaultActions
        if onHighlightCreated != nil {
            editingActions.append(
                EditingAction(title: "Highlight", action: #selector(EPUBNavigatorContainerViewController.highlightSelection))
            )
        }

        let config = EPUBNavigatorViewController.Configuration(editingActions: editingActions)

        guard let navigator = try? EPUBNavigatorViewController(
            publication: publication,
            initialLocation: initialLocator,
            config: config,
            httpServer: httpServer
        ) else {
            fatalError("Failed to initialize EPUBNavigatorViewController")
        }

        // Embed navigator as a child of the container
        container.addChild(navigator)
        container.view.addSubview(navigator.view)
        navigator.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            navigator.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            navigator.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            navigator.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            navigator.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
        ])
        navigator.didMove(toParent: container)
        container.navigator = navigator

        context.coordinator.parent = self

        // Set delegate BEFORE navigator is returned and can start loading
        navigator.delegate = context.coordinator
        viewModel.setNavigator(navigator)

        // Keep a reference so the Coordinator can call navigator APIs
        context.coordinator.navigator = navigator

        // Apply initial font size synchronously before first render
        let prefs = EPUBPreferences(fontSize: fontSize)
        navigator.submitPreferences(prefs)

        // Add tap gesture
        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap)
        )
        tapGesture.delegate = context.coordinator
        navigator.view.addGestureRecognizer(tapGesture)

        // Apply initial decorations for any pre-existing highlights
        let decorations = highlights.map { $0.toDecoration() }
        navigator.apply(decorations: decorations, in: Self.highlightGroup)
        context.coordinator.lastHighlights = highlights

        // Observe taps on highlight decorations (only when a tap handler exists)
        if onHighlightTapped != nil {
            navigator.observeDecorationInteractions(inGroup: Self.highlightGroup) { event in
                // Suppress the overlay toggle for this tap
                context.coordinator.suppressNextTap = true
                guard let tapped = context.coordinator.parent.highlights.first(where: { $0.id == event.decoration.id }) else { return }
                context.coordinator.parent.onHighlightTapped?(
                    EPUBHighlightTapEvent(highlight: tapped, rect: event.rect)
                )
            }
        }

        return container
    }

    public func updateUIViewController(_ container: EPUBNavigatorContainerViewController, context: Context) {
        context.coordinator.parent = self
        container.onHighlightCreated = onHighlightCreated

        guard let navigator = container.navigator else { return }

        // --- Font size ---
        if context.coordinator.lastFontSize != fontSize {
            context.coordinator.lastFontSize = fontSize

            Task { @MainActor in
                let currentLoc = navigator.currentLocation

                let prefs = EPUBPreferences(fontSize: fontSize)
                navigator.submitPreferences(prefs)

                if let loc = currentLoc {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await navigator.go(to: loc)
                }
            }
        }

        // --- Highlights (re-apply decorations when anything changes: add/remove, color, style) ---
        if highlights != context.coordinator.lastHighlights {
            context.coordinator.lastHighlights = highlights
            let decorations = highlights.map { $0.toDecoration() }
            navigator.apply(decorations: decorations, in: Self.highlightGroup)
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public class Coordinator: NSObject, EPUBNavigatorDelegate, UIGestureRecognizerDelegate {
        var parent: EPUBNavigatorWrapper
        var lastFontSize: Double
        /// Tracks the last applied highlights so we re-apply when anything changes (color, style, etc.).
        var lastHighlights: [EPUBHighlight] = []
        /// Weak reference to the navigator for creating highlights from selection.
        weak var navigator: EPUBNavigatorViewController?
        /// Set to `true` when a highlight decoration tap fires, so the
        /// simultaneous UITapGestureRecognizer doesn't toggle the overlay.
        var suppressNextTap = false

        init(_ parent: EPUBNavigatorWrapper) {
            self.parent = parent
            self.lastFontSize = parent.fontSize
        }

        @objc func handleTap() {
            // Don't toggle overlay while the user has text selected
            // (e.g. the "Highlight" menu is showing).
            if navigator?.currentSelection != nil {
                return
            }
            // Delay slightly so the decoration-interaction callback
            // (which arrives asynchronously from Readium's JS bridge)
            // has time to set `suppressNextTap` before we check it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self else { return }
                if self.suppressNextTap {
                    self.suppressNextTap = false
                    return
                }
                self.parent.onTap?()
            }
        }

        // MARK: - UIGestureRecognizerDelegate

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        // MARK: - EPUBNavigatorDelegate

        public func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            parent.currentLocator = locator
        }

        public func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
            print("Navigator error: \(error)")
        }

        public func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
            UIApplication.shared.open(url)
        }
    }
}

public struct EPUBReaderSwiftUIPreferences: Codable {
    public var fontSize: Double = 1.0
    // Add more preferences as needed (font family, theme, etc.)
    
    public init(fontSize: Double = 1.0) {
        self.fontSize = fontSize
    }
}

/// Backward-compatible alias.
public typealias ReadingPreferences = EPUBReaderSwiftUIPreferences

// MARK: - Default Table of Contents
/// The built-in TOC view used when no custom TOC is provided.
public struct DefaultEPUBReaderTOCView: View {
    public let context: EPUBReaderTOCContext

    public init(context: EPUBReaderTOCContext) {
        self.context = context
    }

    public var body: some View {
        NavigationView {
            if context.tableOfContents.isEmpty {
                Text("No table of contents available")
                    .foregroundColor(.secondary)
            } else {
                List(context.tableOfContents, id: \.href) { link in
                    Button(action: { context.navigateToLink(link) }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(link.title ?? "Untitled")
                                .foregroundColor(.primary)

                            if !link.children.isEmpty {
                                ForEach(link.children, id: \.href) { child in
                                    Button(action: { context.navigateToLink(child) }) {
                                        Text(child.title ?? "Untitled")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .padding(.leading, 16)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .navigationTitle("Table of Contents")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { context.dismiss() }
                    }
                }
            }
        }
    }
}

/// Backward-compatible alias.
public typealias TableOfContentsView = DefaultEPUBReaderTOCView

// MARK: - Default Bookmark List View
/// Built-in sheet for viewing, navigating to, and deleting bookmarks.
public struct DefaultBookmarkListView: View {
    let bookmarks: [EPUBBookmark]
    let onNavigate: (EPUBBookmark) -> Void
    let onDelete: (String) -> Void
    let onDismiss: () -> Void

    public init(
        bookmarks: [EPUBBookmark],
        onNavigate: @escaping (EPUBBookmark) -> Void,
        onDelete: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.bookmarks = bookmarks
        self.onNavigate = onNavigate
        self.onDelete = onDelete
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationView {
            Group {
                if bookmarks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bookmark")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("No bookmarks yet")
                            .foregroundStyle(.secondary)
                        Text("Tap the bookmark icon while reading to save your place.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                onNavigate(bookmark)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "bookmark.fill")
                                        .foregroundColor(.accentColor)
                                        .font(.body)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(bookmark.displayTitle)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if let preview = bookmark.textPreview, !preview.isEmpty,
                                       preview != bookmark.chapterTitle {
                                        Text(preview)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }

                                    HStack(spacing: 8) {
                                        if let prog = bookmark.progression {
                                                Text("\(Int(prog * 100))%")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }

                                            Text(bookmark.createdAt, style: .date)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.quaternary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete { offsets in
                            for idx in offsets {
                                onDelete(bookmarks[idx].id)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }
}

public class EPUBDownloader {
    public enum DownloadError: Error {
        case invalidURL
        case downloadFailed
        case fileSystemError
    }
    
    public static func downloadEPUB(from urlString: String, useCache: Bool = true) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw DownloadError.invalidURL
        }

        // Create a permanent location in Documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileName = url.lastPathComponent.isEmpty ? "downloaded.epub" : url.lastPathComponent
        let destinationURL = documentsPath.appendingPathComponent(fileName)

        // Check if file already exists and useCache is true
        if useCache && FileManager.default.fileExists(atPath: destinationURL.path) {
            print("📦 Using cached EPUB: \(fileName)")
            return destinationURL
        }

        // Download the file
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DownloadError.downloadFailed
        }

        // Remove existing file if it exists
        try? FileManager.default.removeItem(at: destinationURL)

        // Move downloaded file to permanent location
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)

        print("📥 Downloaded EPUB: \(fileName)")
        return destinationURL
    }
}