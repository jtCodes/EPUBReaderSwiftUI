# EPUBReaderSwiftUI

A SwiftUI‑first component for rendering EPUB books in iOS/macOS apps.

## 📦 Overview

EPUBReaderSwiftUI enables you to display `.epub` files within a SwiftUI view or container.  
It supports the essential EPUB workflow: file selection, unpacking, and rendering of chapters/HTML content, while using a SwiftUI‑friendly interface.

## ✅ Features

- SwiftUI view (`EPUBReaderSwiftUI`) that can be integrated into your view hierarchy.  
- Supports loading local EPUB files via URL.  
- Renders content via WKWebView (or equivalent) inside SwiftUI.  
- Navigation across chapters, table of contents support.  
- Customisation points: theming, font size, paging/navigation.  
- Bookmark / reading‑progress support (if implemented).  
- Compatibility with modern Swift / SwiftUI toolchain.

## 🧭 Getting Started

### Installation

Add `EPUBReaderSwiftUI` as a Swift Package in Xcode:  
```
File → Add Packages… → `https://github.com/jtCodes/EPUBReaderSwiftUI.git`
```

Alternatively, integrate manually by copying the `Sources/EPUBReaderSwiftUI` folder.

### Usage

```swift
import SwiftUI
import EPUBReaderSwiftUI
import ReadiumShared

struct ContentView: View {
    @State private var showReader = false
    @State private var savedLocator: Locator?
    @State private var savedPreferences = ReadingPreferences()
    @State private var epubURL: URL?
    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            if isDownloading {
                ProgressView("Downloading EPUB...")
            } else {
                Button("Open EPUB") {
                    Task {
                        isDownloading = true
                        errorMessage = nil
                        
                        do {
                            // Option 1: Download from URL
                            epubURL = try await EPUBDownloader.downloadEPUB(from: "https://www.gutenberg.org/ebooks/9662.epub3.images")
                            
                            // Option 2: Or use local file
                            // epubURL = Bundle.main.url(forResource: "republic", withExtension: "epub")
                            
                            showReader = true
                        } catch {
                            errorMessage = "Failed to load EPUB: \(error.localizedDescription)"
                        }
                        
                        isDownloading = false
                    }
                }
                
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .padding()
                }
            }
        }
        .fullScreenCover(isPresented: $showReader) {
            if let url = epubURL {
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

### Customisation

You can configure reader options (font size, theme) via `EPUBReaderViewConfiguration` (if provided).  
You can also observe reading progress or chapter changes via published properties / delegate callbacks.

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
- UI for bookmarks, highlights, annotations may not be included out‑of‑the‑box (you may need to extend).  
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
