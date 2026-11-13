import Foundation

/// 一条发票记录（v1.0）
/// 所有金额以「元」为单位；税率以百分数存储（如 13 表示 13%）。
struct InvoiceRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var invoiceNumber: String = ""        // 发票号码
    var invoiceDate: String = ""          // 开票日期（yyyy-MM-dd）
    var sellerName: String = ""           // 开票单位（销售方）
    var buyerName: String = ""            // 收票单位（购买方）
    var amountExcludingTax: Double?       // 不含税金额
    var taxRate: Double?                  // 税率（%）
    var taxAmount: Double?                // 税额
    var amountIncludingTax: Double?       // 含税金额（价税合计）
    var taxRatesText: String = ""         // 票面全部税率（可能多个，如 "13%/9%"）
    var invoiceType: String = ""          // 票种（电子发票(普通发票) 等）
    var note: String = ""                 // 备注
    var rawText: String = ""              // OCR 原文（备查）
    var imagePath: String = ""            // 原图文件名（Documents/invoice_images/ 下）
    var createdAt: Date = Date()

    /// 关键字段齐全度（用于界面提示）
    var missingFields: [String] {
        var m: [String] = []
        if invoiceNumber.isEmpty { m.append("发票号码") }
        if invoiceDate.isEmpty { m.append("开票日期") }
        if sellerName.isEmpty { m.append("开票单位") }
        if buyerName.isEmpty { m.append("收票单位") }
        if amountExcludingTax == nil { m.append("不含税金额") }
        if taxRate == nil { m.append("税率") }
        if amountIncludingTax == nil { m.append("含税金额") }
        return m
    }

    /// 发票号码唯一性索引（台账查重用）
    var duplicateKey: String {
        invoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
