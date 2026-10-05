import SwiftUI
import SwiftData

@main
struct ClipbaraApp: App {
    @State private var appState = AppState()
    @StateObject private var updaterViewModel = CheckForUpdatesViewModel()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ClipboardItem.self,
            Pinboard.self,
            PinboardEntry.self,
            ExcludedApp.self,
            SensitiveRule.self,
        ])

        let storeURL = StoreManager.resolveStoreURL()
        let config = ModelConfiguration(url: storeURL)

        func openStore() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: [config])
        }

        func recoverStore(_ open: () throws -> ModelContainer) -> ModelContainer? {
            if StoreManager.restoreBackup(at: storeURL) {
                do {
                    return try open()
                } catch {
                    StoreManager.logger.error("Restored backup failed to open: \(error.localizedDescription)")
                }
            }

            // Keep the unopenable files. The next successful launch snapshots
            // whatever new store we create below and must not overwrite the only
            // remaining copy of the old database.
            _ = StoreManager.archiveUnopenedFiles(at: storeURL)
            do {
                return try open()
            } catch {
                StoreManager.logger.error("Recovery failed: \(error.localizedDescription)")
                return nil
            }
        }

        // The backup is the last database that successfully opened. Snapshot the
        // closed files first, but replace that backup only after this open
        // succeeds. Doing it the other way copied an unopenable store over the
        // last good backup and then deleted the store, so history came back empty.
        switch StoreManager.captureSnapshot(at: storeURL) {
        case .noStore:
            do {
                return try openStore()
            } catch {
                StoreManager.logger.error("Failed to create store: \(error.localizedDescription)")
            }

        case .captureFailed:
            StoreManager.logger.error("Could not snapshot the clipboard store; the previous backup was left untouched")
            if let container = try? openStore() {
                return container
            }
            if let container = recoverStore(openStore) {
                return container
            }

        case .captured(let staging):
            do {
                let container = try openStore()
                if !StoreManager.commitSnapshot(staging, for: storeURL) {
                    StoreManager.logger.error("Clipboard store opened but the backup could not be updated")
                }
                return container
            } catch {
                StoreManager.logger.error("Failed to open store: \(error.localizedDescription)")
            }

            if let container = try? openStore() {
                if !StoreManager.commitSnapshot(staging, for: storeURL) {
                    StoreManager.logger.error("Clipboard store opened but the backup could not be updated")
                }
                return container
            }

            // Prefer the closed snapshot over the older backup. It still has the
            // clips from the last session if this open is what damaged the file.
            if StoreManager.restoreSnapshot(staging, over: storeURL),
               let container = try? openStore() {
                if !StoreManager.commitSnapshot(staging, for: storeURL) {
                    StoreManager.logger.error("Clipboard store opened but the backup could not be updated")
                }
                return container
            }

            StoreManager.discardSnapshot(staging)
            if let container = recoverStore(openStore) {
                return container
            }
        }

        // In-memory fallback. History is not persisted for this launch.
        do {
            StoreManager.logger.error("Starting with an in-memory clipboard store")
            return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        } catch {
            fatalError("Cannot create any ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        MenuBarExtra("Clipbara", systemImage: "clipboard") {
            MenuBarContentView()
                .environment(appState)
                .environmentObject(updaterViewModel)
                .modelContainer(sharedModelContainer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
                .environmentObject(updaterViewModel)
                .modelContainer(sharedModelContainer)
        }
    }

    init() {
        let context = sharedModelContainer.mainContext
        appState.start(modelContext: context, modelContainer: sharedModelContainer)

        // First-run welcome tour (NSApp is not ready in init, defer it)
        Task { @MainActor [appState, sharedModelContainer] in
            try? await Task.sleep(for: .milliseconds(400))
            OnboardingWindowController.shared.showIfNeeded(
                appState: appState,
                modelContainer: sharedModelContainer
            )
        }

        // Apply saved theme on launch (NSApp is not ready in init, defer it)
        DispatchQueue.main.async { [sharedModelContainer] in
            let theme = UserDefaults.standard.string(forKey: "appTheme") ?? "System"
            switch theme {
            case "Light": NSApp.appearance = NSAppearance(named: .aqua)
            case "Dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil
            }

            // Save SwiftData on app termination
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    try? sharedModelContainer.mainContext.save()
                }
            }

            // Save when app loses focus (guards against force-kill/power loss)
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    try? sharedModelContainer.mainContext.save()
                }
            }
        }
    }
}
