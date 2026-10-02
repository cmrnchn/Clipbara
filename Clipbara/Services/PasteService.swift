import AppKit

@MainActor
struct PasteService {

    private static let tempDir = NSTemporaryDirectory() + "Clipbara/"

    /// Backing key for the "Always Paste as Plain Text" setting (Settings > General).
    nonisolated static let alwaysPlainTextDefaultsKey = "alwaysPastePlainText"

    /// Called after this service mutates the general pasteboard, before control
    /// returns to the run loop. Callers use it to ignore that write without
    /// discarding a copy the user makes before the next clipboard poll.
    var onDidWritePasteboard: (() -> Void)?

    /// Called after every successful paste so callers (AppState) can erase sensitive
    /// items immediately when "erase after first paste" is enabled.
    var onDidPaste: ((ClipboardItem) -> Void)?

    /// Whether stripping formatting is meaningful for this item (RTF/HTML only).
    static func supportsPlainText(_ item: ClipboardItem) -> Bool {
        switch item.contentType {
        case .richText, .html:
            return !(item.textContent?.isEmpty ?? true)
        default:
            return false
        }
    }

    /// Combines the setting with the Shift modifier using XOR.
    /// Setting off: Shift strips formatting. Setting on: Shift keeps formatting.
    static func resolvePlainText() -> Bool {
        let always = UserDefaults.standard.bool(forKey: alwaysPlainTextDefaultsKey)
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        return always != shiftHeld
    }

    /// - Parameter asPlainText: `nil` resolves from the setting combined with the Shift modifier.
    func paste(item: ClipboardItem, asPlainText: Bool? = nil) {
        if asPlainText ?? Self.resolvePlainText(), Self.supportsPlainText(item) {
            guard pastePlainText(item: item) else { return }
            didWritePasteboard(item)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let text = item.decryptedTextContent()
        let data = item.decryptedRawData()

        switch item.contentType {
        case .plainText, .html, .richText:
            if let text {
                pasteboard.setString(text, forType: .string)
            }
            // Also set original format for rich text / HTML
            if item.contentType == .richText {
                pasteboard.setData(data, forType: .rtf)
            } else if item.contentType == .html {
                pasteboard.setData(data, forType: .html)
            }

        case .image:
            guard let image = NSImage(data: data),
                  let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                pasteboard.setData(data, forType: .tiff)
                break
            }

            // 임시 PNG 파일 저장 — 터미널 앱(Ghostty 등)이 파일 경로로 이미지를 전달
            let tempURL = Self.writeTempPNG(pngData, sourceApp: item.sourceAppName)

            // NSURL writeObjects로 파일 URL을 먼저 쓴 뒤 PNG/TIFF 추가
            // — Ghostty가 이미지 파일로 인식하려면 이 순서가 필요
            if let tempURL {
                pasteboard.writeObjects([tempURL as NSURL])
            }
            pasteboard.setData(pngData, forType: .png)
            pasteboard.setData(tiffData, forType: .tiff)

        case .url:
            if let text {
                pasteboard.setString(text, forType: .string)
                if let url = URL(string: text) {
                    pasteboard.setString(url.absoluteString, forType: .URL)
                }
            }

        case .fileURL:
            if let text,
               let urlString = String(data: data, encoding: .utf8) {
                pasteboard.setString(urlString, forType: .fileURL)
                pasteboard.setString(text, forType: .string)
            }

        case .color:
            if let text {
                pasteboard.setString(text, forType: .string)
            }

        case .unknown:
            pasteboard.setData(data, forType: .string)
        }

        didWritePasteboard(item)
    }

    /// Writes plain text. Returns false when there is nothing to put on the pasteboard,
    /// so callers do not treat a no-op as a successful paste.
    @discardableResult
    func pastePlainText(item: ClipboardItem) -> Bool {
        guard let text = item.decryptedTextContent() else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    private func didWritePasteboard(_ item: ClipboardItem) {
        onDidWritePasteboard?()
        onDidPaste?(item)
    }

    /// 오래된 임시 파일 정리 (1시간 이상)
    func cleanupTempFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.tempDir) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for file in files {
            let path = Self.tempDir + file
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? fm.removeItem(atPath: path)
        }
    }

    private static let filenameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    private static func writeTempPNG(_ data: Data, sourceApp: String?) -> URL? {
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let asciiOnly = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_")
        let safeName = sourceApp?
            .unicodeScalars.filter { asciiOnly.contains($0) }
            .reduce(into: "") { $0.append(String($1)) }
            .trimmingCharacters(in: .whitespaces)
        let appName = (safeName?.isEmpty ?? true) ? "Clipbara" : safeName!
        let timestamp = filenameDateFormatter.string(from: Date())
        let filename = "\(appName) \(timestamp).png" as String
        let url = URL(fileURLWithPath: tempDir + filename)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
