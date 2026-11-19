import Foundation
import Combine
import CryptoKit
import Network
#if os(macOS)
import AppKit
#endif

struct WaveRelease: Equatable {
    let tag: String
    let name: String?
    let notes: String?
    let pageURL: URL?
    let assetURL: URL
    let assetSize: Int
    let assetDigest: String

    var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
    var title: String { "Wave \(version)" }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Checks GitHub releases of the public `waves` repository and installs
/// a newer version in place on macOS. Completely silent and zero-radio when offline.
@MainActor
final class UpdateService: ObservableObject {
    enum Banner: Equatable {
        case update(WaveRelease)
        case upToDate
        case failed(String)
        case tokenHint
        case progress(Double)
        case installing
    }

    static let repositorySlug = "besty-boy/waves"
    static let assetName = "Wave.zip"

    @Published private(set) var banner: Banner?
    @Published private(set) var release: WaveRelease?
    @Published private(set) var tokenConfigured = GitHubToken.isConfigured
    @Published private(set) var isOnline = true

    private var dismissedReleaseTag: String?
    private var periodicTask: Task<Void, Never>?
    private var isChecking = false
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.wave.network.monitor", qos: .utility)

    private let ignoredVersionKey = "wave.updates.ignoredVersion"

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.isOnline != satisfied else { return }
                self.isOnline = satisfied
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    deinit {
        periodicTask?.cancel()
        pathMonitor.cancel()
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Debug builds are "Wave Dev": they can check for updates but never replace themselves.
    static var isDevBuild: Bool {
        #if DEBUG
        true
        #else
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
        #endif
    }

    var isBusy: Bool {
        switch banner {
        case .progress, .installing: return true
        default: return false
        }
    }

    // MARK: - Launch

    func onLaunch() async {
        #if os(macOS)
        refreshTokenState()
        guard !Self.isDevBuild else { return }
        if isOnline {
            await check(manual: false)
        }
        startPeriodicChecks()
        #endif
    }

    private func startPeriodicChecks() {
        #if os(macOS)
        guard !Self.isDevBuild, periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000) }
                catch { return }
                guard let self else { return }
                if self.isOnline {
                    await self.check(manual: false)
                }
            }
        }
        #endif
    }

    // MARK: - Checking

    func refreshTokenState() {
        let configured = GitHubToken.isConfigured
        tokenConfigured = configured
        if banner == .tokenHint { banner = nil }
    }

    /// Called after the user updates the optional Keychain entry.
    func tokenDidChange() {
        refreshTokenState()
        #if os(macOS)
        guard !Self.isDevBuild, isOnline else { return }
        startPeriodicChecks()
        Task { await check(manual: false) }
        #endif
    }

    func check(manual: Bool) async {
        refreshTokenState()
        guard !isBusy, !isChecking else { return }
        guard isOnline else {
            if manual {
                banner = .failed("Aucune connexion réseau. Wave continue de fonctionner 100 % hors ligne.")
            }
            return
        }
        let token = GitHubToken.current
        isChecking = true
        defer { isChecking = false }
        do {
            let latest = try await Self.fetchLatestRelease(token: token)
            guard token == GitHubToken.current else { return }
            let isNewer = latest.map { Self.isVersion($0.tag, newerThan: appVersion) } ?? false
            let isIgnored = latest.map { UserDefaults.standard.string(forKey: ignoredVersionKey) == $0.tag } ?? false
            if let latest, isNewer, (manual || !isIgnored) {
                release = latest
                if manual {
                    dismissedReleaseTag = nil
                    banner = .update(latest)
                } else if dismissedReleaseTag != latest.tag, banner == nil {
                    banner = .update(latest)
                }
            } else {
                release = nil
                if manual { showUpToDateBriefly() }
            }
        } catch let urlError as URLError where Self.isOfflineError(urlError) {
            if manual {
                banner = .failed("Aucune connexion réseau. Wave continue de fonctionner 100 % hors ligne.")
            }
        } catch let error as UpdateError {
            if manual || release != nil {
                banner = .failed(error.localizedDescription)
            }
        } catch {
            if manual || release != nil {
                banner = .failed(error.localizedDescription)
            }
        }
    }

    private static func isOfflineError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    private func showUpToDateBriefly() {
        banner = .upToDate
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.banner == .upToDate else { return }
            self.banner = nil
        }
    }

    // MARK: - Banner actions

    func dismissBanner() {
        banner = nil
    }

    func later(_ release: WaveRelease) {
        dismissedReleaseTag = release.tag
        banner = nil
    }

    func ignore(_ release: WaveRelease) {
        UserDefaults.standard.set(release.tag, forKey: ignoredVersionKey)
        dismissedReleaseTag = release.tag
        self.release = nil
        banner = nil
    }

    // MARK: - Installing

    func install() async {
        guard !Self.isDevBuild, let release else { return }
        guard isOnline else {
            banner = .failed("Connexion réseau requise pour télécharger la mise à jour.")
            return
        }
        #if os(macOS)
        let token = GitHubToken.current
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            banner = .failed("Mise à jour impossible depuis cette copie de l'app.")
            return
        }
        if target.path.contains("/AppTranslocation/") {
            banner = .failed("Wave est exécutée depuis un emplacement temporaire. Déplacez Wave.app dans le dossier Applications, puis réessayez.")
            return
        }
        if !FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) {
            banner = .failed("Le dossier qui contient Wave.app n'est pas modifiable. Déplacez l'app dans un dossier accessible (par exemple Applications), puis réessayez.")
            return
        }
        banner = .progress(0)
        do {
            let work = try Self.makeTemporaryDirectory()
            let zip = work.appendingPathComponent(Self.assetName)
            try await downloadAsset(from: release.assetURL, token: token, to: zip)
            let extracted = work.appendingPathComponent("Extracted", isDirectory: true)
            let expectedSize = release.assetSize
            let expectedDigest = release.assetDigest
            try await Task.detached(priority: .userInitiated) {
                try Self.verifyDownload(zip, expectedSize: expectedSize, digest: expectedDigest)
                try Self.unzip(zip, to: extracted)
                try Self.verifySignature(of: extracted.appendingPathComponent("Wave.app", isDirectory: true))
            }.value
            let newApp = extracted.appendingPathComponent("Wave.app", isDirectory: true)
            let newAppValues = try newApp.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard newAppValues.isDirectory == true, newAppValues.isSymbolicLink != true else {
                throw UpdateError("L’archive ne contient pas une application valide.")
            }
            let infoPlist = newApp.appendingPathComponent("Contents/Info.plist")
            guard FileManager.default.fileExists(atPath: infoPlist.path) else {
                throw UpdateError("L'archive téléchargée ne contient pas Wave.app.")
            }
            let info = NSDictionary(contentsOf: infoPlist)
            let newBundleID = (info?["CFBundleIdentifier"] as? String) ?? ""
            guard newBundleID == Bundle.main.bundleIdentifier else {
                throw UpdateError("L'archive téléchargée ne correspond pas à cette app.")
            }
            guard (info?["CFBundleShortVersionString"] as? String) == release.version else {
                throw UpdateError("La version de l’application ne correspond pas à la version publiée.")
            }

            banner = .installing
            NotificationCenter.default.post(name: .waveFlushDrafts, object: nil)
            try Self.launchSwapScript(source: newApp, destination: target)
            try? await Task.sleep(nanoseconds: 400_000_000)
            NSApp.terminate(nil)
        } catch {
            banner = .failed(error.localizedDescription)
        }
        #else
        banner = .failed("La mise à jour automatique est disponible sur macOS uniquement.")
        #endif
    }

    // MARK: - GitHub API

    private struct ReleaseDTO: Decodable {
        struct Asset: Decodable {
            let name: String
            let url: String
            let size: Int
            let digest: String?
        }
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body, draft, prerelease, assets
            case htmlURL = "html_url"
        }
    }

    private static func fetchLatestRelease(token: String?) async throws -> WaveRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repositorySlug)/releases/latest") else {
            throw UpdateError("URL GitHub invalide.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Wave", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError("Réponse invalide de GitHub.")
        }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw UpdateError("Token GitHub refusé. Supprimez-le ou vérifiez ses droits dans Réglages.")
        case 403:
            throw UpdateError("Limite de requêtes GitHub atteinte. Réessayez plus tard ou ajoutez un token optionnel dans Réglages.")
        case 404:
            return nil
        default:
            throw UpdateError("GitHub a répondu \(http.statusCode).")
        }
        let dto = try JSONDecoder().decode(ReleaseDTO.self, from: data)
        guard dto.draft != true, dto.prerelease != true else { return nil }
        guard let asset = dto.assets.first(where: { $0.name == assetName }) else {
            throw UpdateError("Cette version ne contient pas \(assetName).")
        }
        guard let assetURL = URL(string: asset.url), assetURL.scheme == "https",
              assetURL.host == "api.github.com", asset.size > 0 else {
            throw UpdateError("Les informations de téléchargement de cette version sont invalides.")
        }
        guard let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw UpdateError("GitHub n’a pas fourni de somme de contrôle pour cette version.")
        }
        return WaveRelease(tag: dto.tagName,
                           name: dto.name,
                           notes: dto.body,
                           pageURL: dto.htmlURL.flatMap(URL.init(string:)),
                           assetURL: assetURL,
                           assetSize: asset.size,
                           assetDigest: digest)
    }

    static func versionComponents(_ string: String) -> [Int] {
        var value = string
        if value.hasPrefix("v") { value.removeFirst() }
        let core = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        return core.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }

    static func isVersion(_ tag: String, newerThan current: String) -> Bool {
        let a = versionComponents(tag)
        let b = versionComponents(current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - Download

    #if os(macOS)
    private func downloadAsset(from url: URL, token: String?, to destination: URL) async throws {
        guard url.scheme == "https", url.host == "api.github.com" else {
            throw UpdateError("Adresse de téléchargement GitHub invalide.")
        }
        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Wave \(appVersion)", forHTTPHeaderField: "User-Agent")
        let downloader = AssetDownloader()
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            downloader.start(request: request, destination: destination, progress: { [weak self] value in
                Task { @MainActor in self?.banner = .progress(value) }
            }, completion: { result in
                continuation.resume(with: result)
            })
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated private static func unzip(_ archive: URL, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let status = try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        guard status == 0 else {
            throw UpdateError("Impossible de décompresser l'archive (ditto \(status)).")
        }
    }

    nonisolated private static func verifyDownload(_ archive: URL, expectedSize: Int, digest: String) throws {
        let expected = String(digest.dropFirst("sha256:".count)).lowercased()
        guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
            throw UpdateError("Somme de contrôle de la version invalide.")
        }
        let actualSize = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard actualSize == expectedSize else {
            throw UpdateError("Le téléchargement est incomplet.")
        }
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw UpdateError("L’archive téléchargée ne correspond pas à la version publiée.")
        }
    }

    nonisolated private static func verifySignature(of app: URL) throws {
        guard try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UpdateError("La signature de l’application téléchargée est invalide.")
        }
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Launches a detached script that waits for this process to quit, swaps the
    /// app bundle, and reopens it.
    private static func launchSwapScript(source: URL, destination: URL) throws {
        let script = """
        #!/bin/bash
        pid=$1; src=$2; dst=$3
        for _ in $(seq 1 900); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        sleep 0.6
        xattr -dr com.apple.quarantine "$src" >/dev/null 2>&1
        parent=$(dirname "$dst")
        [ -w "$parent" ] || exit 3
        stage="$dst.new.$$"
        backup="$dst.old.$$"
        rm -rf "$stage" "$backup"
        ditto "$src" "$stage" || exit 4
        mv "$dst" "$backup" || { rm -rf "$stage"; exit 5; }
        mv "$stage" "$dst" || { mv "$backup" "$dst"; exit 6; }
        rm -rf "$backup"
        open "$dst"
        exit 0
        """
        let url = try makeTemporaryDirectory().appendingPathComponent("wave-update.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [url.path,
                             String(ProcessInfo.processInfo.processIdentifier),
                             source.path,
                             destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
    #endif
}

/// Downloads a release asset, dropping the optional Authorization header when
/// GitHub redirects to the signed storage URL.
private final class AssetDownloader: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    private var progressHandler: ((Double) -> Void)?
    private var completionHandler: ((Result<URL, Error>) -> Void)?
    private var destination: URL?
    private var session: URLSession?
    private var finished = false
    private var selfReference: AssetDownloader?

    func start(request: URLRequest,
               destination: URL,
               progress: @escaping (Double) -> Void,
               completion: @escaping (Result<URL, Error>) -> Void) {
        selfReference = self
        self.progressHandler = progress
        self.completionHandler = completion
        self.destination = destination
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: request).resume()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 {
                finish(.failure(UpdateError("Téléchargement refusé (HTTP \(http.statusCode)).")))
            } else {
                finish(.failure(UpdateError("Impossible de télécharger la mise à jour (HTTP \(http.statusCode)).")))
            }
            return
        }
        guard let destination else {
            finish(.failure(UpdateError("Destination de téléchargement manquante.")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var adjusted = request
        if request.url?.host != "api.github.com" {
            adjusted.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(adjusted)
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        session?.invalidateAndCancel()
        completionHandler?(result)
        completionHandler = nil
        progressHandler = nil
        selfReference = nil
    }
}
