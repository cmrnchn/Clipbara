import Foundation
import AppKit
import SwiftData
import UniformTypeIdentifiers

enum SourceType: String, Codable {
    case clipboard
    case screenshot
    case drag
}

@Model
final class ClipboardItem {

    var id: UUID
    var contentTypeRaw: String
    @Attribute(.externalStorage) var rawData: Data
    var textContent: String?
    @Attribute(.externalStorage) var thumbnailData: Data?
    var sourceAppName: String?
    var sourceAppBundleId: String?
    var contentHash: String
    var copiedAt: Date
    var userTitle: String?
    var isPinned: Bool
    var isSensitive: Bool = false
    var expiresAt: Date?
    var sourceTypeRaw: String = SourceType.clipboard.rawValue

    var contentType: ContentType {
        get { ContentType(rawValue: contentTypeRaw) ?? .unknown }
        set { contentTypeRaw = newValue.rawValue }
    }

    var sourceType: SourceType {
        get { SourceType(rawValue: sourceTypeRaw) ?? .clipboard }
        set { sourceTypeRaw = newValue.rawValue }
    }

    var isScreenshot: Bool {
        sourceType == .screenshot
    }

    init(
        contentType: ContentType,
        rawData: Data,
        textContent: String? = nil,
        thumbnailData: Data? = nil,
        sourceAppName: String? = nil,
        sourceAppBundleId: String? = nil,
        contentHash: String,
        isSensitive: Bool = false,
        sourceType: SourceType = .clipboard
    ) {
        self.id = UUID()
        self.contentTypeRaw = contentType.rawValue
        self.isSensitive = isSensitive
        self.rawData = isSensitive ? (SensitiveEncryptionService.encrypt(rawData) ?? rawData) : rawData
        self.textContent = isSensitive
            ? textContent.flatMap { $0.data(using: .utf8) }
                .flatMap { SensitiveEncryptionService.encrypt($0) }?
                .base64EncodedString()
            : textContent
        self.thumbnailData = thumbnailData
        self.sourceAppName = sourceAppName
        self.sourceAppBundleId = sourceAppBundleId
        self.contentHash = contentHash
        self.copiedAt = Date()
        self.isPinned = false
        self.sourceTypeRaw = sourceType.rawValue
    }

    /// Plaintext bytes, decrypting on the fly for sensitive items. `rawData` itself
    /// stays ciphertext at rest — callers that render or paste content must go through
    /// this instead, and UI that lists/badges items must gate on `isSensitive` first
    /// rather than ever touching `rawData`/`textContent` directly.
    func decryptedRawData() -> Data {
        guard isSensitive, let plain = SensitiveEncryptionService.decrypt(rawData) else { return rawData }
        return plain
    }

    func decryptedTextContent() -> String? {
        guard isSensitive else { return textContent }
        guard let stored = textContent,
              let cipher = Data(base64Encoded: stored),
              let plain = SensitiveEncryptionService.decrypt(cipher) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    func dragProvider() -> NSItemProvider {
        let provider: NSItemProvider
        let plainText = decryptedTextContent()
        let plainData = decryptedRawData()

        switch contentType {
        case .plainText, .richText, .html, .unknown:
            provider = NSItemProvider(object: (plainText ?? "") as NSString)

        case .image:
            if let image = NSImage(data: plainData) {
                if !CaptureSafety.shouldWritePlaintextImageFile(isSensitive: isSensitive) {
                    provider = NSItemProvider(object: image)
                } else if let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let pngData = bitmap.representation(using: .png, properties: [:]) {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Clipbara", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let asciiOnly = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_")
                    let safeName = sourceAppName?
                        .unicodeScalars.filter { asciiOnly.contains($0) }
                        .reduce(into: "") { $0.append(String($1)) }
                        .trimmingCharacters(in: .whitespaces)
                    let appName = (safeName?.isEmpty ?? true) ? "Clipbara" : safeName!
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
                    let filename = "\(appName) \(formatter.string(from: copiedAt)).png"
                    let fileURL = dir.appendingPathComponent(filename)
                    try? pngData.write(to: fileURL)
                    provider = NSItemProvider(contentsOf: fileURL) ?? NSItemProvider(object: image)
                } else {
                    provider = NSItemProvider(object: image)
                }
            } else {
                provider = NSItemProvider()
            }

        case .url:
            if let text = plainText, let url = URL(string: text) {
                provider = NSItemProvider(object: url as NSURL)
            } else {
                provider = NSItemProvider(object: (plainText ?? "") as NSString)
            }

        case .fileURL:
            if let text = plainText, let url = URL(string: text) {
                provider = NSItemProvider(object: url as NSURL)
            } else {
                provider = NSItemProvider()
            }

        case .color:
            provider = NSItemProvider(object: (plainText ?? "") as NSString)
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.pasteClipClipboardItemID.identifier,
            visibility: .ownProcess
        ) { [id] completion in
            completion(id.uuidString.data(using: .utf8), nil)
            return nil
        }

        return provider
    }
}

extension UTType {
    static let pasteClipClipboardItemID = UTType(exportedAs: "com.minsang.PasteClip.clipboard-item-id")
}
