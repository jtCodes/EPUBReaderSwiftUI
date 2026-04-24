# EPUBReaderSwiftUI

A SwiftUI‑first component for rendering EPUB books.

<img width="300" height="650" alt="Simulator Screenshot - iPhone 17 Pro - 2025-10-25 at 12 18 45" src="https://github.com/user-attachments/assets/9575dbce-450d-402d-96da-07b0f4c0dc21" />
<img width="300" height="650" alt="Simulator Screenshot - iPhone 17 Pro - 2025-10-25 at 12 18 52" src="https://github.com/user-attachments/assets/f2d528c6-755e-43b1-83d7-659439e3cb6d" />


## 📦 Overview

EPUBReaderSwiftUI enables you to display `.epub` files within a SwiftUI view or container.  
It supports the essential EPUB workflow: file selection, unpacking, and rendering of chapters/HTML content, while using a SwiftUI‑friendly interface.

## ✅ Features

- Drop-in SwiftUI view (`EPUBReaderView`) — works with `.sheet`, `.fullScreenCover`, or inline.
- **Local & remote** EPUB loading — pass a file URL, a remote URL string, or an `EPUBSource` enum. Remote files are downloaded and cached automatically.
- **Customizable overlay** — replace the default reader chrome (toolbar, progress bar, font controls) with your own SwiftUI view via an `overlay:` closure.
- **Customizable table of contents** — supply a `tocView:` closure to build your own TOC UI, or use the built-in `DefaultEPUBReaderTOCView`.
- **Highlighting & notes** — select text to highlight, tap highlights to edit color/style, add notes, or delete. Built-in default UI or fully custom via callbacks.
- **Bookmarks** — toggle bookmarks from the overlay; the default overlay includes a bookmark button out of the box. Your app owns the array and persists it.
- Reading position persistence — save and restore the locator across sessions.
- Font-size control via `EPUBReaderSwiftUIPreferences`.
- Navigation across chapters, progress tracking.
- Renders content via WKWebView (Readium) inside SwiftUI.
- No need to `import ReadiumShared` — common types (`Locator`, `Link`) are re-exported.

## 🧭 Getting Started

### Installation

Add `EPUBReaderSwiftUI` as a Swift Package in Xcode:  
```
File → Add Packages… → `https://github.com/jtCodes/EPUBReaderSwiftUI.git`
```

Alternatively, integrate manually by copying the `Sources/EPUBReaderSwiftUI` folder.

### Usage

> **Note:** `ReadiumShared` is re-exported automatically — you only need `import EPUBReaderSwiftUI`.

#### ① Remote URL (simplest)

Pass a URL string directly. The package downloads, caches, and opens the file for you.

```swift
import SwiftUI
import EPUBReaderSwiftUI

struct RemoteURLExample: View {
    @State private var showReader = false
    @State private var savedLocator: EPUBReaderSwiftUILocator?
    @State private var savedPreferences = EPUBReaderSwiftUIPreferences()

    var body: some View {
        Button("Open Remote EPUB") {
            showReader = true
        }
        .fullScreenCover(isPresented: $showReader) {
            EPUBReaderView(
                remoteURL: "https://www.gutenberg.org/ebooks/9662.epub3.images",
                initialLocator: savedLocator,
                initialPreferences: savedPreferences
            ) { locator, preferences in
                savedLocator = locator
                savedPreferences = preferences
                showReader = false
            }
        }
    }
}
```

#### ② Local file URL

Load an `.epub` that's already on disk or in your app bundle.

```swift
struct LocalFileExample: View {
    @State private var showReader = false
    @State private var savedLocator: EPUBReaderSwiftUILocator?
    @State private var savedPreferences = EPUBReaderSwiftUIPreferences()

    var body: some View {
        Button("Open Local EPUB") {
            showReader = true
        }
        .fullScreenCover(isPresented: $showReader) {
            if let url = Bundle.main.url(forResource: "republic", withExtension: "epub") {
                EPUBReaderView(
                    url: url,
                    initialLocator: savedLocator,
                    initialPreferences: savedPreferences
                ) { locator, preferences in
                    savedLocator = locator
                    savedPreferences = preferences
                    showReader = false
                }
            }
        }
    }
}
```

#### ③ EPUBSource enum (choose at runtime)

Use the `EPUBSource` enum when you need to decide between local and remote at runtime.

```swift
struct SourceEnumExample: View {
    @State private var showReader = false
    @State private var savedLocator: EPUBReaderSwiftUILocator?
    @State private var savedPreferences = EPUBReaderSwiftUIPreferences()

    let source: EPUBSource = .remoteURL(
        "https://www.gutenberg.org/ebooks/9662.epub3.images",
        useCache: true
    )
    // Or: let source: EPUBSource = .fileURL(Bundle.main.url(forResource: "republic", withExtension: "epub")!)

    var body: some View {
        Button("Open EPUB") {
            showReader = true
        }
        .fullScreenCover(isPresented: $showReader) {
            EPUBReaderView(
                source: source,
                initialLocator: savedLocator,
                initialPreferences: savedPreferences
            ) { locator, preferences in
                savedLocator = locator
                savedPreferences = preferences
                showReader = false
            }
        }
    }
}
```

### Customization

#### Custom Overlay

Supply an `overlay` closure to replace the default reader chrome. You receive an `EPUBReaderOverlayContext` with all the state and actions you need (title, author, current locator, font-size binding, close/navigate callbacks, etc.).

```swift
struct CustomOverlayExample: View {
    @State private var showReader = false
    @State private var savedLocator: EPUBReaderSwiftUILocator?
    @State private var savedPreferences = EPUBReaderSwiftUIPreferences()

    var body: some View {
        Button("Open with Custom Overlay") {
            showReader = true
        }
        .fullScreenCover(isPresented: $showReader) {
            EPUBReaderView(
                remoteURL: "https://www.gutenberg.org/ebooks/9662.epub3.images",
                initialLocator: savedLocator,
                initialPreferences: savedPreferences
            ) { locator, preferences in
                savedLocator = locator
                savedPreferences = preferences
                showReader = false
            } overlay: { context in
                // Build any SwiftUI overlay you want.
                // 'context' exposes: .title, .author, .chapterTitle,
                // .totalProgression, .showControls, .fontSize,
                // .close(), .showTableOfContents(), .goToProgression(_:)
                VStack {
                    if context.showControls {
                        HStack {
                            Button(action: context.close) {
                                Image(systemName: "chevron.left")
                                Text("Library")
                            }
                            Spacer()
                            Button(action: context.showTableOfContents) {
                                Image(systemName: "list.bullet")
                            }
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                    }
                    Spacer()
                }
            }
        }
    }
}
```

#### Custom Table of Contents

Supply a `tocView` closure to replace the default TOC sheet. You receive an `EPUBReaderTOCContext` with the chapter list, current locator, and navigation/dismiss actions.

```swift
struct CustomTOCExample: View {
    @State private var showReader = false
    @State private var savedLocator: EPUBReaderSwiftUILocator?
    @State private var savedPreferences = EPUBReaderSwiftUIPreferences()

    var body: some View {
        Button("Open with Custom TOC") {
            showReader = true
        }
        .fullScreenCover(isPresented: $showReader) {
            EPUBReaderView(
                remoteURL: "https://www.gutenberg.org/ebooks/9662.epub3.images",
                initialLocator: savedLocator,
                initialPreferences: savedPreferences
            ) { locator, preferences in
                savedLocator = locator
                savedPreferences = preferences
                showReader = false
            } overlay: { context in
                // Keep the default overlay, only customize the TOC
                DefaultEPUBReaderOverlay(context: context)
            } tocView: { context in
                // 'context' exposes: .tableOfContents, .currentLocator,
                // .navigateToLink(_:), .dismiss()
                NavigationView {
                    List(context.tableOfContents, id: \.href) { link in
                        Button {
                            context.navigateToLink(link)
                        } label: {
                            Text(link.title ?? "Untitled")
                        }
                    }
                    .navigationTitle("Chapters")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Close") { context.dismiss() }
                        }
                    }
                }
            }
        }
    }
}
```

> **Tip:** You can customize just the overlay, just the TOC, or both. Omit either closure to keep the default.

#### Highlighting & Notes

EPUBReaderSwiftUI has built-in highlighting support powered by Readium's Decoration API. Users can select text, tap **Highlight** in the context menu, and then tap existing highlights to change their color, style, add a note, or delete them.

Highlighting is **opt-in** — the "Highlight" menu item only appears when you provide an `onHighlightCreated` callback. Your app owns the `[EPUBHighlight]` array and is responsible for persisting it (UserDefaults, Core Data, CloudKit, etc.).

##### Minimal example (built-in edit UI)

Pass `highlights` and `onHighlightCreated` — the library provides a default popover for editing color, style, notes, and deleting:

```swift
struct HighlightExample: View {
    @State private var showReader = false
    @State private var savedLocator: EPUBReaderSwiftUILocator?
    @State private var savedPreferences = EPUBReaderSwiftUIPreferences()
    @State private var highlights: [EPUBHighlight] = []

    var body: some View {
        Button("Open Reader") { showReader = true }
        .fullScreenCover(isPresented: $showReader) {
            EPUBReaderView(
                remoteURL: "https://www.gutenberg.org/ebooks/1497.epub3.images",
                initialLocator: savedLocator,
                initialPreferences: savedPreferences,
                highlights: $highlights,
                onHighlightCreated: { highlights.append($0) },
                onClose: { locator, preferences in
                    savedLocator = locator
                    savedPreferences = preferences
                    showReader = false
                }
            )
        }
    }
}
```

##### Custom highlight tap handler

To replace the built-in edit UI with your own, provide an `onHighlightTapped` callback:

```swift
EPUBReaderView(
    remoteURL: "https://example.com/book.epub",
    highlights: $highlights,
    onHighlightCreated: { highlights.append($0) },
    onHighlightTapped: { event in
        // event.highlight — the tapped EPUBHighlight
        // event.rect      — bounding rect for anchoring a popover
        selectedHighlight = event.highlight
        showMyCustomEditor = true
    },
    onClose: { locator, preferences in
        showReader = false
    }
)
```

##### EPUBHighlight

| Property | Type | Description |
|---|---|---|
| `id` | `String` | Unique identifier (UUID by default). |
| `locator` | `Locator` | Readium locator — position in the book. |
| `color` | `EPUBHighlightColor` | `.yellow`, `.green`, `.blue`, `.red`, `.purple`. |
| `style` | `EPUBHighlightStyle` | `.highlight` (background) or `.underline`. |
| `note` | `String?` | Optional user note attached to the highlight. |
| `highlightText` | `String?` | The selected text (read-only, from the locator). |

`EPUBHighlight` conforms to `Codable`, `Identifiable`, `Equatable`, and `Hashable`, so you can serialize it directly with `JSONEncoder`/`JSONDecoder`.

#### Bookmarks

Pass a `bookmarks` binding and the default overlay will show a bookmark toggle button (filled when the current chapter is bookmarked). No extra callbacks needed — the library handles add/remove automatically via `EPUBReaderOverlayContext.toggleBookmark`.

##### Minimal example

```swift
struct BookmarkExample: View {
    @State private var showReader = false
    @State private var savedLocator: EPUBReaderSwiftUILocator?
    @State private var savedPreferences = EPUBReaderSwiftUIPreferences()
    @State private var bookmarks: [EPUBBookmark] = []

    var body: some View {
        Button("Open Reader") { showReader = true }
        .fullScreenCover(isPresented: $showReader) {
            EPUBReaderView(
                remoteURL: "https://www.gutenberg.org/ebooks/1497.epub3.images",
                initialLocator: savedLocator,
                initialPreferences: savedPreferences,
                bookmarks: $bookmarks,
                onClose: { locator, preferences in
                    savedLocator = locator
                    savedPreferences = preferences
                    showReader = false
                }
            )
        }
    }
}
```

##### Custom overlay with bookmarks

In custom overlays, use the bookmark properties on `EPUBReaderOverlayContext`:

```swift
// Inside your custom overlay:
Button(action: context.toggleBookmark) {
    Image(systemName: context.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
}

// List all bookmarks:
ForEach(context.bookmarks) { bookmark in
    Text(bookmark.chapterTitle ?? "Unknown")
}
```

##### EPUBBookmark

| Property | Type | Description |
|---|---|---|
| `id` | `String` | Unique identifier (UUID by default). |
| `locator` | `Locator` | Readium locator — position in the book. |
| `createdAt` | `Date` | When the bookmark was created. |
| `chapterTitle` | `String?` | Chapter title (read-only, from the locator). |
| `progression` | `Double?` | Overall reading progression 0.0–1.0 (read-only). |

`EPUBBookmark` conforms to `Codable`, `Identifiable`, `Equatable`, and `Hashable`.

## 🔧 How it works (at a high level)

1. The EPUB file is unzipped into a temporary directory.  
2. The OPF file (manifest/spine) is parsed to discover chapters, metadata and Table of Contents.  
3. A `WKWebView` inside SwiftUI is used to display the HTML content of each chapter.  
4. Navigation controls allow moving between chapters or pages.  
5. State management handles current chapter, progress, bookmarks.

## 📚 Supported EPUB Features

- Standard EPUB 2/EPUB 3 packages (ZIP‑based).  
- Basic HTML + CSS rendering via WebKit.  
- Table of Contents.  
- Local images/fonts inside the EPUB.

## ⚠️ Limitations & Known Issues

- Does **not** support advanced EPUB features such as media overlays (audio syncing), fixed‑layout books, or interactive content (unless explicitly added).  
- Performance may degrade for very large books or very high font sizes — advisable to test on real devices.  
- Annotations beyond highlights and bookmarks are not included out-of-the-box (you may need to extend).  
- SwiftUI integration means there may be some bridging to UIKit/WebKit under the hood.

## 📖 License

MIT (or whichever license specified in the repository).  
See `LICENSE` for details.

## 🤝 Contributing

Contributions, bug reports and feature requests are welcome!  
Please open an issue or PR describing the improvement, and follow the code style (SwiftLint, SwiftFormat) as used in the project.

## 👤 Author

Created by [jtCodes](https://github.com/jtCodes) — thank you for sharing your work.

---

*Enjoy reading!*
