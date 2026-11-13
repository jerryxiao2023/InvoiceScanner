import Foundation
import CoreGraphics
import CoreImage
import ImageIO

/// 本地记录存储：Documents/invoices.json + 发票原图 Documents/invoice_images/
final class RecordStore: ObservableObject {
    @Published var records: [InvoiceRecord] = []

    private static let listURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("invoices.json")
    private static let imageDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("invoice_images", isDirectory: true)

    init() {
        load()
        try? FileManager.default.createDirectory(at: Self.imageDir, withIntermediateDirectories: true)
    }

    // MARK: - 读写

    private func load() {
        guard let data = try? Data(contentsOf: Self.listURL) else { return }
        let decoded = try? JSONDecoder().decode([InvoiceRecord].self, from: data)
        records = decoded ?? []
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? encoder.encode(records) {
            try? data.write(to: Self.listURL, options: .atomic)
        }
    }

    // MARK: - 增删改

    @discardableResult
    func add(_ rec: InvoiceRecord) -> InvoiceRecord {
        records.insert(rec, at: 0)
        save()
        return rec
    }

    func update(_ rec: InvoiceRecord) {
        if let idx = records.firstIndex(where: { $0.id == rec.id }) {
            records[idx] = rec
            save()
        }
    }

    func delete(_ rec: InvoiceRecord) {
        records.removeAll { $0.id == rec.id }
        if !rec.imagePath.isEmpty {
            try? FileManager.default.removeItem(at: Self.imageDir.appendingPathComponent(rec.imagePath))
        }
        save()
    }

    /// 发票号码查重（防止重复录入）
    func findDuplicate(number: String, excluding id: UUID? = nil) -> InvoiceRecord? {
        guard !number.isEmpty else { return nil }
        return records.first { $0.duplicateKey == number && $0.id != id }
    }

    // MARK: - 原图

    func saveImage(_ image: CGImage, for rec: InvoiceRecord) -> String {
        let name = rec.id.uuidString + ".jpg"
        let url = Self.imageDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            return ""
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.6]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return "" }
        return name
    }

    func loadImage(_ name: String) -> CGImage? {
        guard !name.isEmpty else { return nil }
        let url = Self.imageDir.appendingPathComponent(name)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
