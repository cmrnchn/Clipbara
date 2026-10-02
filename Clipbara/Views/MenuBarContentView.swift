import SwiftUI
import SwiftData

struct MenuBarContentView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var updaterViewModel: CheckForUpdatesViewModel
    @Query(sort: \ClipboardItem.copiedAt, order: .reverse)
    private var recentItems: [ClipboardItem]

    private var topItems: [ClipboardItem] {
        Array(recentItems.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if topItems.isEmpty {
                Text("No clipboard history")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                Text("Quick Access")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(topItems) { item in
                            MenuBarThumbnailTile(item: item)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 70)
            }

            Divider()
                .padding(.vertical, 4)

            Toggle(isOn: Binding(
                get: { appState.clipboardMonitor.isMonitoring },
                set: { _ in appState.clipboardMonitor.toggle() }
            )) {
                Label("Clipboard Monitoring", systemImage: "clipboard")
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()
                .padding(.vertical, 4)

            Button {
                appState.togglePanel()
            } label: {
                HStack {
                    Text("Open History")
                    Spacer()
                    Text("\u{21E7}\u{2318}V")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()
                .padding(.vertical, 4)

            Button("Check for Updates...") {
                updaterViewModel.checkForUpdates()
            }
            .disabled(!updaterViewModel.canCheckForUpdates)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Button("Settings...") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Button("Quit Clipbara") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .padding(.bottom, 4)
        }
        .frame(width: 380)
    }
}

struct MenuBarThumbnailTile: View {
    let item: ClipboardItem
    @Environment(AppState.self) private var appState
    @State private var isHovered = false

    var body: some View {
        Button {
            appState.pasteService.paste(item: item)
        } label: {
            ZStack(alignment: .bottomLeading) {
                // Thumbnail background
                if item.isSensitive {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.2))
                } else if item.contentType == .image {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.1))

                    if let data = item.thumbnailData ?? item.decryptedRawData() as Data?,
                       let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .clipped()
                            .cornerRadius(6)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }

                // Type badge
                HStack(spacing: 3) {
                    Image(systemName: typeIcon)
                        .font(.system(size: 9, weight: .semibold))
                    Text(typeLabel)
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(Color.accentColor)
                .cornerRadius(4)
                .padding(4)

                // Hover overlay with details
                if isHovered {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayText)
                            .lineLimit(2)
                            .font(.system(size: 11, weight: .medium))

                        if let appName = item.sourceAppName {
                            Text(appName)
                                .lineLimit(1)
                                .font(.system(size: 9))
                                .opacity(0.8)
                        }

                        Text(RelativeTimeFormatter.string(for: item.copiedAt))
                            .lineLimit(1)
                            .font(.system(size: 9))
                            .opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(6)
                }
            }
            .frame(width: 60, height: 60)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var displayText: String {
        if item.isSensitive { return "Sensitive" }
        switch item.contentType {
        case .plainText, .richText, .html, .url:
            return item.textContent ?? "—"
        case .image:
            return "Image"
        case .fileURL:
            return item.textContent ?? "File"
        case .color:
            return item.textContent ?? "Color"
        case .unknown:
            return "Unknown"
        }
    }

    private var typeIcon: String {
        if item.isSensitive { return "lock.fill" }
        if item.isScreenshot { return "screenshot.fill" }
        return item.contentType.systemImage
    }

    private var typeLabel: String {
        if item.isSensitive { return "Secure" }
        if item.isScreenshot { return "SS" }
        switch item.contentType {
        case .plainText: return "TXT"
        case .richText: return "RTF"
        case .html: return "HTML"
        case .image: return "IMG"
        case .url: return "URL"
        case .fileURL: return "FILE"
        case .color: return "CLR"
        case .unknown: return "?"
        }
    }
}
