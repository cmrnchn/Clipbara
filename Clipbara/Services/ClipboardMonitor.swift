import AppKit
import SwiftData
import CryptoKit

@MainActor
@Observable
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let classifier = ContentTypeClassifier()
    private let screenshotManager = ScreenshotManager()
    private var modelContext: ModelContext?
    private var excludedBundleIds: Set<String> = []
    private var sensitiveRules: [SensitiveRule] = []
    private var shouldSkipNextChange: Bool = false
    private var expectingScreenshot: Bool = false
    private var pollTickCount: Int = 0
    /// Set for the duration of one capture. AppleScript domain checks spin the
    /// main run loop, which can deliver a nested workspace notification.
    /// Skipping that nested call leaves any newer pasteboard change unconsumed
    /// so the next poll records it.
    private var isCapturingPasteboard: Bool = false
    private var deactivationObserver: NSObjectProtocol?

    private var sensitiveTTLSeconds: Double {
        let stored = UserDefaults.standard.double(forKey: "sensitiveTTLSeconds")
        return stored > 0 ? stored : 45
    }

    var isMonitoring: Bool = false
    var latestItems: [ClipboardItem] = []
    var historyLimit: Int {
        get { UserDefaults.standard.object(forKey: "historyLimit") as? Int ?? 500 }
        set { UserDefaults.standard.set(newValue, forKey: "historyLimit") }
    }

    func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        lastChangeCount = NSPasteboard.general.changeCount
        loadExcludedApps()
        loadSensitiveRules()
        isMonitoring = true
        installDeactivationObserver()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        removeDeactivationObserver()
        isMonitoring = false
    }

    func toggle() {
        if isMonitoring { stop() } else if let ctx = modelContext { start(modelContext: ctx) }
    }

    func refreshLatestItems() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.copiedAt, order: .reverse)]
        )
        var limited = descriptor
        limited.fetchLimit = 5
        latestItems = (try? modelContext.fetch(limited)) ?? []
    }

    private func poll() {
        pollTickCount += 1
        if pollTickCount % 10 == 0 {
            purgeExpiredSensitiveItems()
        }

        capturePasteboardChange(from: NSWorkspace.shared.frontmostApplication)
    }

    /// Records a pasteboard change attributed to `sourceApp`.
    ///
    /// Polling alone mis-attributes copies. The timer only notices a change up
    /// to half a second later, and by then the user has often already switched
    /// to the app they want to paste into — the normal path for a password
    /// copied out of a banking site or a sensitive app. That lands the secret
    /// in plaintext history, where it is backed up and never auto-erased.
    /// App exclusion is skipped the same way.
    ///
    /// `NSWorkspace.didDeactivateApplicationNotification` fires at the moment
    /// of the switch, while the pasteboard change still belongs to the app
    /// that just resigned. Copies with no app switch keep using the frontmost
    /// app on the next poll.
    private func capturePasteboardChange(from sourceApp: NSRunningApplication?) {
        guard !isCapturingPasteboard else { return }
        isCapturingPasteboard = true
        defer { isCapturingPasteboard = false }

        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        if shouldSkipNextChange {
            shouldSkipNextChange = false
            expectingScreenshot = false
            return
        }

        if let bundleId = sourceApp?.bundleIdentifier,
           excludedBundleIds.contains(bundleId) {
            expectingScreenshot = false
            return
        }

        guard let content = classifier.classify(pasteboard) else {
            expectingScreenshot = false
            return
        }

        let hash = SHA256.hash(data: content.rawData)
            .compactMap { String(format: "%02x", $0) }
            .joined()

        // Duplicate check within last 10 seconds
        if isDuplicate(hash: hash) {
            expectingScreenshot = false
            return
        }

        let isSensitive = matchesSensitiveRule(frontApp: sourceApp)

        // Determine source type: screenshot if expectingScreenshot and it's an image
        let sourceType: SourceType = (expectingScreenshot && content.contentType == .image) ? .screenshot : .clipboard

        let item = ClipboardItem(
            contentType: content.contentType,
            rawData: content.rawData,
            textContent: content.textContent,
            sourceAppName: sourceApp?.localizedName,
            sourceAppBundleId: sourceApp?.bundleIdentifier,
            contentHash: hash,
            isSensitive: isSensitive,
            sourceType: sourceType
        )

        expectingScreenshot = false

        if isSensitive {
            item.expiresAt = Date().addingTimeInterval(sensitiveTTLSeconds)
        } else if content.contentType == .image {
            // Sensitive images skip the plaintext thumbnail — it would otherwise sit
            // on disk unencrypted even while the raw bytes are ciphertext.
            item.thumbnailData = generateThumbnail(from: content.rawData)
        }

        modelContext?.insert(item)
        try? modelContext?.save()
        cleanupOldItems()
        refreshLatestItems()
    }

    /// 히스토리 제한 초과 시 오래된 아이템 삭제 (isPinned 아이템 보존)
    private func cleanupOldItems() {
        guard let modelContext, historyLimit > 0 else { return }

        let countDescriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { !$0.isPinned }
        )
        let unpinnedCount = (try? modelContext.fetchCount(countDescriptor)) ?? 0

        guard unpinnedCount > historyLimit else { return }

        let deleteCount = unpinnedCount - historyLimit
        var fetchDescriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { !$0.isPinned },
            sortBy: [SortDescriptor(\.copiedAt, order: .forward)]
        )
        fetchDescriptor.fetchLimit = deleteCount

        guard let itemsToDelete = try? modelContext.fetch(fetchDescriptor) else { return }

        for item in itemsToDelete {
            // 연관 PinboardEntry 제거
            let itemId = item.id
            let entryDescriptor = FetchDescriptor<PinboardEntry>(
                predicate: #Predicate { $0.clipboardItem?.id == itemId }
            )
            if let entries = try? modelContext.fetch(entryDescriptor) {
                for entry in entries {
                    modelContext.delete(entry)
                }
            }
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    private func isDuplicate(hash: String) -> Bool {
        guard let modelContext else { return false }
        let tenSecondsAgo = Date().addingTimeInterval(-10)
        let predicate = #Predicate<ClipboardItem> { item in
            item.contentHash == hash && item.copiedAt > tenSecondsAgo
        }
        let descriptor = FetchDescriptor<ClipboardItem>(predicate: predicate)
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0
        return count > 0
    }

    private func generateThumbnail(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let maxSize: CGFloat = 320
        let size = image.size
        let scale = min(maxSize / size.width, maxSize / size.height, 1.0)
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        let thumbnail = NSImage(size: newSize)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        thumbnail.unlockFocus()

        guard let tiffData = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData
    }

    func skipNextChange() {
        shouldSkipNextChange = true
    }

    func captureScreenshot() {
        Task {
            expectingScreenshot = true
            _ = await screenshotManager.captureScreenshot()
            // If capture was cancelled or failed, clear the flag after a timeout
            try? await Task.sleep(for: .seconds(2))
            if expectingScreenshot {
                expectingScreenshot = false
            }
        }
    }

    private func installDeactivationObserver() {
        removeDeactivationObserver()
        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.isMonitoring else { return }
                // Missing payload means we cannot attribute the copy. Leave the
                // change for the poll, which uses the current frontmost app.
                guard let resigned = Self.resignedApplication(in: notification) else { return }
                self.capturePasteboardChange(from: resigned)
            }
        }
    }

    private func removeDeactivationObserver() {
        if let deactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(deactivationObserver)
            self.deactivationObserver = nil
        }
    }

    private static func resignedApplication(in notification: Notification) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    func loadExcludedApps() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ExcludedApp>()
        let apps = (try? modelContext.fetch(descriptor)) ?? []
        excludedBundleIds = Set(apps.map(\.bundleId))
    }

    func loadSensitiveRules() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<SensitiveRule>()
        sensitiveRules = (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Deletes a sensitive item immediately (e.g. right after it's pasted), regardless
    /// of its TTL. Used by the "erase after first paste" setting.
    func eraseSensitiveItemNow(_ item: ClipboardItem) {
        guard item.isSensitive, let modelContext else { return }
        deleteWithPinboardEntries([item], in: modelContext)
        try? modelContext.save()
        refreshLatestItems()
    }

    private func matchesSensitiveRule(frontApp: NSRunningApplication?) -> Bool {
        guard let frontApp, !sensitiveRules.isEmpty else { return false }

        for rule in sensitiveRules {
            switch rule.kind {
            case .app:
                if frontApp.bundleIdentifier == rule.pattern { return true }
            case .process:
                if let name = frontApp.localizedName, name.localizedCaseInsensitiveContains(rule.pattern) {
                    return true
                }
            case .domain:
                continue
            }
        }

        // Domain rules need a synchronous Apple Events round-trip to the browser, so
        // only pay that cost when there's a domain rule and the front app is a browser.
        guard let bundleID = frontApp.bundleIdentifier,
              BrowserURLProvider.isSupportedBrowser(bundleID) else { return false }
        let domainRules = sensitiveRules.filter { $0.kind == .domain }
        guard !domainRules.isEmpty,
              let host = BrowserURLProvider.currentURL(forBundleID: bundleID)?.host else { return false }
        return domainRules.contains { host == $0.pattern || host.hasSuffix("." + $0.pattern) }
    }

    private func purgeExpiredSensitiveItems() {
        guard let modelContext else { return }
        let now = Date()
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.isSensitive && $0.expiresAt != nil && $0.expiresAt! <= now }
        )
        guard let expired = try? modelContext.fetch(descriptor), !expired.isEmpty else { return }
        deleteWithPinboardEntries(expired, in: modelContext)
        try? modelContext.save()
        refreshLatestItems()
    }

    private func deleteWithPinboardEntries(_ items: [ClipboardItem], in modelContext: ModelContext) {
        for item in items {
            let itemId = item.id
            let entryDescriptor = FetchDescriptor<PinboardEntry>(
                predicate: #Predicate { $0.clipboardItem?.id == itemId }
            )
            if let entries = try? modelContext.fetch(entryDescriptor) {
                for entry in entries {
                    modelContext.delete(entry)
                }
            }
            modelContext.delete(item)
        }
    }
}
