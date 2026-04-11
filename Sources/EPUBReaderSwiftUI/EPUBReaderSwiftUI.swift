// The Swift Programming Language
// https://docs.swift.org/swift-book
import SwiftUI
import Combine
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumStreamer
import ReadiumAdapterGCDWebServer

// MARK: - Public Type Aliases
/// Re-exported so users don't need `import ReadiumShared` for basic usage.
public typealias EPUBReaderSwiftUILocator = Locator

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
public struct EPUBReaderView<Overlay: View>: View {
    let source: EPUBSource
    let initialLocator: Locator?
    let initialPreferences: EPUBReaderSwiftUIPreferences
    let onClose: (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void
    let overlay: (EPUBReaderOverlayContext) -> Overlay

    @MainActor @StateObject private var viewModel = EPUBReaderViewModel()
    @State private var fontSize: Double
    @State private var showControls = false
    @State private var showTOC = false
    @State private var currentLocator: Locator?

    /// Initialize with an `EPUBSource` and a custom overlay.
    public init(source: EPUBSource, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void, @ViewBuilder overlay: @escaping (EPUBReaderOverlayContext) -> Overlay) {
        self.source = source
        self.initialLocator = initialLocator
        self.initialPreferences = initialPreferences
        self.onClose = onClose
        self.overlay = overlay
        _fontSize = State(initialValue: initialPreferences.fontSize)
    }

    /// Convenience: remote URL with custom overlay.
    public init(remoteURL: String, useCache: Bool = true, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void, @ViewBuilder overlay: @escaping (EPUBReaderOverlayContext) -> Overlay) {
        self.init(source: .remoteURL(remoteURL, useCache: useCache), initialLocator: initialLocator, initialPreferences: initialPreferences, onClose: onClose, overlay: overlay)
    }

    /// Convenience: local file URL with custom overlay.
    public init(url: URL, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void, @ViewBuilder overlay: @escaping (EPUBReaderOverlayContext) -> Overlay) {
        self.init(source: .fileURL(url), initialLocator: initialLocator, initialPreferences: initialPreferences, onClose: onClose, overlay: overlay)
    }
}

// MARK: - Default overlay inits (backward-compatible)
extension EPUBReaderView where Overlay == DefaultEPUBReaderOverlay {

    /// Initialize with an `EPUBSource` (local file or remote URL). Uses the default overlay.
    public init(source: EPUBSource, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void) {
        self.init(source: source, initialLocator: initialLocator, initialPreferences: initialPreferences, onClose: onClose) { context in
            DefaultEPUBReaderOverlay(context: context)
        }
    }

    /// Convenience: open a remote EPUB by URL string. Downloads and caches automatically. Uses the default overlay.
    public init(remoteURL: String, useCache: Bool = true, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void) {
        self.init(source: .remoteURL(remoteURL, useCache: useCache), initialLocator: initialLocator, initialPreferences: initialPreferences, onClose: onClose)
    }

    /// Convenience: open a local EPUB file URL (backwards-compatible). Uses the default overlay.
    public init(url: URL, initialLocator: EPUBReaderSwiftUILocator? = nil, initialPreferences: EPUBReaderSwiftUIPreferences = EPUBReaderSwiftUIPreferences(), onClose: @escaping (EPUBReaderSwiftUILocator?, EPUBReaderSwiftUIPreferences) -> Void) {
        self.init(source: .fileURL(url), initialLocator: initialLocator, initialPreferences: initialPreferences, onClose: onClose)
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
            TableOfContentsView(
                tableOfContents: viewModel.tableOfContents,
                onSelectLink: { link in
                    Task {
                        await viewModel.navigateToLink(link)
                    }
                    showTOC = false
                }
            )
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
                viewModel: viewModel,
                onTap: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                }
            )
            .ignoresSafeArea()

            let context = EPUBReaderOverlayContext(
                title: publication.metadata.title,
                author: publication.metadata.authors.first?.name,
                currentLocator: currentLocator,
                showControls: showControls,
                fontSize: $fontSize,
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

// MARK: - Navigator Wrapper
public struct EPUBNavigatorWrapper: UIViewControllerRepresentable {
    let publication: Publication
    let httpServer: HTTPServer
    let initialLocator: Locator?
    @Binding var fontSize: Double
    @Binding var currentLocator: Locator?
    @ObservedObject var viewModel: EPUBReaderViewModel
    var onTap: (() -> Void)?

    public func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        let config = EPUBNavigatorViewController.Configuration()
        
        guard let navigator = try? EPUBNavigatorViewController(
            publication: publication,
            initialLocation: initialLocator,
            config: config,
            httpServer: httpServer
        ) else {
            fatalError("Failed to initialize EPUBNavigatorViewController")
        }

        context.coordinator.parent = self
        
        // Set delegate BEFORE navigator is returned and can start loading
        navigator.delegate = context.coordinator
        viewModel.setNavigator(navigator)
        
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

        return navigator
    }

    public func updateUIViewController(_ navigator: EPUBNavigatorViewController, context: Context) {
        context.coordinator.parent = self
        
        // Only update if fontSize actually changed
        if context.coordinator.lastFontSize != fontSize {
            context.coordinator.lastFontSize = fontSize
            
            Task { @MainActor in
                // Get current locator before changing preferences
                let currentLoc = navigator.currentLocation
                
                // Apply new preferences
                let prefs = EPUBPreferences(fontSize: fontSize)
                navigator.submitPreferences(prefs)
                
                // Navigate back to the same location to maintain reading position
                if let loc = currentLoc {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay for layout
                    await navigator.go(to: loc)
                }
            }
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public class Coordinator: NSObject, EPUBNavigatorDelegate, UIGestureRecognizerDelegate {
        var parent: EPUBNavigatorWrapper
        var lastFontSize: Double

        init(_ parent: EPUBNavigatorWrapper) {
            self.parent = parent
            self.lastFontSize = parent.fontSize
        }

        @objc func handleTap() {
            parent.onTap?()
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

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

// MARK: - Table of Contents
public struct TableOfContentsView: View {
    let tableOfContents: [ReadiumShared.Link]
    let onSelectLink: (ReadiumShared.Link) -> Void
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationView {
            if tableOfContents.isEmpty {
                Text("No table of contents available")
                    .foregroundColor(.secondary)
            } else {
                List(tableOfContents, id: \.href) { link in
                    TOCRow(link: link, onSelectLink: onSelectLink)
                }
                .navigationTitle("Table of Contents")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

struct TOCRow: View {
    let link: ReadiumShared.Link
    let onSelectLink: (ReadiumShared.Link) -> Void

    var body: some View {
        Button(action: {
            onSelectLink(link)
        }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(link.title ?? "Untitled")
                    .foregroundColor(.primary)

                if !link.children.isEmpty {
                    ForEach(link.children, id: \.href) { child in
                        Text(child.title ?? "Untitled")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 16)
                    }
                }
            }
            .padding(.vertical, 4)
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
