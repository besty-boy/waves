import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class WriterPreviewController: ObservableObject {
    weak var webView: WKWebView?
    @Published var pdf: Data?
    @Published var error: String?
    private var waiting = false
    private var producing = false
    func requestPDF() { waiting = true; completePDFIfReady() }
    func completePDFIfReady() {
        guard waiting, !producing, let webView, !webView.isLoading, webView.url != nil else { return }
        producing = true
        // Use the platform print layout so long documents have real A4 pages.
        #if os(macOS)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("WavePDF-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let info = NSPrintInfo(dictionary: [.jobDisposition: NSPrintInfo.JobDisposition.save, .jobSavingURL: file])
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false; operation.showsProgressPanel = false
        if operation.run(), let data = try? Data(contentsOf: file) { pdf = data }
        else { error = "Le PDF n’a pas pu être créé. Réessayez après le chargement de l’aperçu." }
        #else
        let renderer = UIPrintPageRenderer()
        let paper = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: 36, dy: 36)), forKey: "printableRect")
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let output = NSMutableData()
        UIGraphicsBeginPDFContextToData(output, paper, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for index in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage(); renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        if output.length > 0 { pdf = output as Data }
        else { error = "Le PDF n’a pas pu être créé. Réessayez après le chargement de l’aperçu." }
        #endif
        waiting = false; producing = false
    }
}

#if os(macOS)
private typealias PreviewRepresentable = NSViewRepresentable
#else
private typealias PreviewRepresentable = UIViewRepresentable
#endif

struct WriterPreview: PreviewRepresentable {
    let markdown: String
    let baseURL: URL
    var attachments: [String] = []
    var fontFamily: String = "Quattro"
    var colorScheme: String = "light dark"
    var onOpenNote: (String) -> Void
    @ObservedObject var controller: WriterPreviewController

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
    #endif
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = coordinator
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        #endif
        controller.webView = view
        return view
    }

    private func update(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.parent = self
        controller.webView = view
        let styleKey = "\(fontFamily)|\(colorScheme)"
        let needsAssets = coordinator.lastBaseURL != baseURL || coordinator.lastAttachments != attachments
        let needsFullReload = needsAssets || coordinator.lastStyleKey != styleKey || !coordinator.hasLoadedPage
        let markdownChanged = coordinator.lastMarkdown != markdown
        guard needsFullReload || markdownChanged else { return }

        coordinator.lastMarkdown = markdown
        coordinator.lastStyleKey = styleKey

        // Fast path: live edits in split preview patch <article> in-place with zero white flash, zero disk writes, and zero scroll reset.
        if !needsFullReload, coordinator.hasLoadedPage {
            coordinator.scheduleLivePatch(markdown: markdown, in: view)
            return
        }

        coordinator.liveUpdateTask?.cancel()
        coordinator.hasLoadedPage = false
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WavePreview-" + coordinator.id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if needsAssets {
                coordinator.lastBaseURL = baseURL
                coordinator.lastAttachments = attachments
                if let files = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                    for source in files where ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(source.pathExtension.lowercased()) {
                        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                        let destination = folder.appendingPathComponent(source.lastPathComponent)
                        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                        try FileManager.default.copyItem(at: source, to: destination)
                    }
                }
            }
            let file = folder.appendingPathComponent("index.html")
            let html = WriterMarkdown.html(markdown, fontFamily: fontFamily, colorScheme: colorScheme)
            try html.write(to: file, atomically: true, encoding: .utf8)
            coordinator.previewFile = file
            view.loadFileURL(file, allowingReadAccessTo: folder)
        } catch { controller.error = error.localizedDescription }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WriterPreview
        let id = UUID()
        var lastMarkdown: String?
        var lastBaseURL: URL?
        var lastAttachments: [String]?
        var lastStyleKey: String?
        var previewFile: URL?
        var hasLoadedPage = false
        var liveUpdateTask: Task<Void, Never>?

        init(_ parent: WriterPreview) { self.parent = parent }
        deinit {
            liveUpdateTask?.cancel()
            if let previewFile { try? FileManager.default.removeItem(at: previewFile.deletingLastPathComponent()) }
        }

        @MainActor
        func scheduleLivePatch(markdown: String, in webView: WKWebView) {
            liveUpdateTask?.cancel()
            liveUpdateTask = Task { @MainActor [weak webView] in
                do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
                guard !Task.isCancelled, let webView else { return }
                let bodyHTML = WriterMarkdown.body(markdown)
                _ = try? await webView.callAsyncJavaScript(
                    "const article = document.querySelector('article'); if (article) { article.innerHTML = body; }",
                    arguments: ["body": bodyHTML],
                    contentWorld: .page
                )
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasLoadedPage = true
            parent.controller.completePDFIfReady()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.controller.error = error.localizedDescription
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { decisionHandler(.allow); return }
            if url.scheme == "wave-note" { parent.onOpenNote(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
            else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
            }
            decisionHandler(.cancel)
        }
    }
}
