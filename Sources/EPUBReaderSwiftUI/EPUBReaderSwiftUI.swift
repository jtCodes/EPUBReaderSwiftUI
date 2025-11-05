// The Swift Programming Language
// https://docs.swift.org/swift-book
import SwiftUI
import Combine
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumStreamer
import ReadiumAdapterGCDWebServer

// MARK: - EPUBReaderView
public struct EPUBReaderView: View {
    let url: URL
    let initialLocator: Locator?
    let initialPreferences: ReadingPreferences  // Add this
    let onClose: (Locator?, ReadingPreferences) -> Void  // Pass back preferences too

    @MainActor @StateObject private var viewModel = EPUBReaderViewModel()
    @State private var fontSize: Double
    @State private var showControls = false
    @State private var showTOC = false
    @State private var currentLocator: Locator?

    public init(url: URL, initialLocator: Locator?, initialPreferences: ReadingPreferences = ReadingPreferences(), onClose: @escaping (Locator?, ReadingPreferences) -> Void) {
        self.url = url
        self.initialLocator = initialLocator
        self.initialPreferences = initialPreferences
        self.onClose = onClose
        _fontSize = State(initialValue: initialPreferences.fontSize)
    }

    public var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            if viewModel.isLoading {
                VStack(spacing: 16) {
                    ProgressView("Loading EPUB...")
                    
                    Button(action: {
                        onClose(nil, ReadingPreferences(fontSize: fontSize))
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
                        onClose(nil, ReadingPreferences(fontSize: fontSize))
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
            await viewModel.loadEPUB(from: url, initialLocator: initialLocator)
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

            VStack {
                if showControls {
                    topBar(publication: publication)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                if showControls {
                    bottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private func topBar(publication: Publication) -> some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: {
                    let preferences = ReadingPreferences(fontSize: fontSize)
                    onClose(currentLocator, preferences)
                }) {
                    Image(systemName: "xmark")
                        .font(.title3)
                }

                Button(action: { showTOC = true }) {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                }

                Text(publication.metadata.title ?? "Unknown Title")
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                if let author = publication.metadata.authors.first?.name {
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

                    Slider(value: $fontSize, in: 0.75...2.0, step: 0.25)

                    Text("A")
                        .font(.title3)

                    Text("\(Int(fontSize * 100))%")
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

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let locator = currentLocator {
                if let title = locator.title {
                    Text(title)
                        .font(.caption)
                        .lineLimit(1)
                }

                if let progression = locator.locations.totalProgression {
                    HStack {
                        ProgressView(value: progression)
                        Text("\(Int(progression * 100))%")
                            .font(.caption2)
                            .frame(width: 40)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding()
    }
}

// MARK: - ViewModel
@MainActor
public class EPUBReaderViewModel: ObservableObject {
    @Published public var publication: Publication?
    @Published public var isLoading = false
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

    func loadEPUB(from url: URL, initialLocator: Locator?) async {
        isLoading = true
        error = nil

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

public struct ReadingPreferences: Codable {
    public var fontSize: Double = 1.0
    // Add more preferences as needed (font family, theme, etc.)
    
    public init(fontSize: Double = 1.0) {
        self.fontSize = fontSize
    }
}

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
