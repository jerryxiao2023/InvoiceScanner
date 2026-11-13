import Foundation

/// 发票字段解析器
/// 输入：OCR 聚合后的行（每行 = 同一水平带内的碎片，已按 x 排序）
/// 策略：标签锚点（发票号码/开票日期/价税合计/购买方/销售方…）逐行匹配，
///       名称类字段用「锚点行 + 相邻行」双重兜底，数值字段取锚点行内金额并做推导。
enum InvoiceParser {

    // MARK: - 主入口

    static func parse(rows: [[OCRLine]]) -> InvoiceRecord {
        var rec = InvoiceRecord()
        let texts = rows.map { OCRService.rowText($0) }      // 原始行文本（保留空格）
        let norm  = texts.map { normalize($0) }              // 去空格+全角归一，用于标签匹配
        rec.rawText = texts.joined(separator: "\n")

        // 票种
        for t in norm {
            if t.contains("电子发票") || t.contains("增值税电子") || t.contains("增值税专用") || t.contains("增值税普通") || t.contains("纸质发票") {
                rec.invoiceType = t
                break
            }
        }

        rec.invoiceNumber = parseNumber(norm: norm)
        rec.invoiceDate = parseDate(norm: norm)
        rec.taxRatesText = parseRates(texts: texts)

        let amounts = parseAmounts(norm: norm)
        rec.amountIncludingTax = amounts.includingTax
        rec.amountExcludingTax = amounts.excludingTax
        rec.taxAmount = amounts.tax

        let names = parseNames(norm: norm)
        rec.buyerName = names.buyer
        rec.sellerName = names.seller

        // 数值推导（仅有部分字段时补全，推导值标注在税额）
        derive(&rec)
        return rec
    }

    // MARK: - 文本工具

    /// OCR 数字常见混淆字符 → 数字
    private static func cleanDigits(_ s: String) -> String {
        let map: [Character: Character] = [
            "０":"0","１":"1","２":"2","３":"3","４":"4","５":"5","６":"6","７":"7","８":"8","９":"9",
            "，":",","。":".","％":"%",
            "O":"0","o":"0","Ó":"0","ò":"0",
            "I":"1","i":"1","l":"1","|":"1","！":"1"
        ]
        return String(s.compactMap { ch in
            if ch.isNumber { return ch }
            if let m = map[ch] { return m }
            if ch == " " || ch == "," || ch == "." || ch == "%" { return ch }
            return nil   // 数字上下文里丢弃其他噪声
        })
    }

    /// 标签匹配用：去空格 + 全角冒号/括号归一
    static func normalize(_ s: String) -> String {
        let spaced: [Character: Character] = ["：":":", "（":"(", "）":")", "，":",", "。":"."]
        return String(s.map { spaced[$0] ?? $0 }).replacingOccurrences(of: " ", with: "")
    }

    /// 从行文本中提取金额（含 ¥ 前缀优先），返回最大的数值（价税合计/合计行取最大值即为总金额）
    private static func money(in text: String, preferLargest: Bool = true) -> Double? {
        let pattern = "[¥￥]\\s*([0-9OoIlil|,，.。]+)|(?:^|[^0-9.,])([1-9][0-9OoIlil|,，.。]{2,}\\.[0-9OoIlil|]{2})"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        var values: [Double] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for idx in [1, 2] {
                let r = m.range(at: idx)
                if r.location == NSNotFound { continue }
                let raw = cleanDigits(ns.substring(with: r))
                let v = Double(raw.replacingOccurrences(of: ",", with: ""))
                if v != nil && v! > 0.004 { values.append(v!) }
            }
        }
        guard !values.isEmpty else { return nil }
        return preferLargest ? values.max() : values.first
    }

    private static func matches(_ text: String, _ pattern: String) -> NSTextCheckingResult? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        return re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    // MARK: - 字段解析

    private static func parseNumber(norm: [String]) -> String {
        // 1) 标签同行（允许 OCR 混淆字符，稍后清洗）
        for t in norm {
            if let m = matches(t, "发票号码:?([0-9OoIlil|]{8,24})") {
                let ns = t as NSString
                return cleanDigits(ns.substring(with: m.range(at: 1))).replacingOccurrences(of: ",", with: "")
            }
        }
        // 2) 兜底：独立 20 位（数电票）或 8 位号码；排除「校验码」行
        for (i, t) in norm.enumerated() {
            if t.contains("校验") { continue }
            if let m = matches(t, "(^|[^0-9])([0-9]{20})([^0-9]|$)") {
                let ns = t as NSString
                let _ = i
                return ns.substring(with: m.range(at: 2))
            }
        }
        for t in norm {
            if t.contains("校验") { continue }
            if let m = matches(t, "(^|[^0-9])([0-9]{8})([^0-9]|$)") {
                let ns = t as NSString
                return ns.substring(with: m.range(at: 2))
            }
        }
        return ""
    }

    private static func parseDate(norm: [String]) -> String {
        for t in norm {
            if let m = matches(t, "开票日期:?(\\d{4})年(\\d{1,2})月(\\d{1,2})日") {
                let ns = t as NSString
                let y = ns.substring(with: m.range(at: 1))
                let mo = cleanDigits(ns.substring(with: m.range(at: 2)))
                let d = cleanDigits(ns.substring(with: m.range(at: 3)))
                return String(format: "%@-%02d-%02d", y, Int(mo) ?? 0, Int(d) ?? 0)
            }
        }
        // 兜底：任意 「yyyy年mm月dd日」
        for t in norm {
            if let m = matches(t, "(\\d{4})年(\\d{1,2})月(\\d{1,2})日") {
                let ns = t as NSString
                let y = ns.substring(with: m.range(at: 1))
                let mo = cleanDigits(ns.substring(with: m.range(at: 2)))
                let d = cleanDigits(ns.substring(with: m.range(at: 3)))
                return String(format: "%@-%02d-%02d", y, Int(mo) ?? 0, Int(d) ?? 0)
            }
        }
        return ""
    }

    private static func parseRates(texts: [String]) -> String {
        var seen = [String]()
        // 在原始行文本上匹配（去空格归一会把 ¥1000.00 和 13% 黏在一起），前面不能是数字/小数点
        let pattern = "(?<![0-9.,])([0-9]{1,2}(?:\\.[0-9]+)?)\\s*[%％]"
        for t in texts {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = t as NSString
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let v = cleanDigits(ns.substring(with: m.range(at: 1)))
                let rate = Double(v.replacingOccurrences(of: ",", with: ""))
                if rate != nil, rate! >= 0.5, rate! <= 20 {
                    let label = String(format: "%g%%", rate!)
                    if !seen.contains(label) { seen.append(label) }
                }
            }
        }
        return seen.joined(separator: "/")
    }

    private struct Amounts {
        var includingTax: Double?
        var excludingTax: Double?
        var tax: Double?
    }

    private static func parseAmounts(norm: [String]) -> Amounts {
        var a = Amounts()
        // 价税合计（含税）：取该行最大金额（大写行同时出现 ¥小写数字）
        for t in norm {
            if t.contains("价税合计") {
                a.includingTax = money(in: t)
                break
            }
        }
        // 明细合计行：金额合计 / 税额合计，或老式「合计 ¥x ¥y」双金额
        for t in norm {
            if t.contains("税额合计") || t.contains("税额") && t.contains("¥") {
                if a.tax == nil { a.tax = money(in: t) }
            }
            if t.contains("金额合计") || (t.contains("金额") && t.contains("¥")) {
                if a.excludingTax == nil { a.excludingTax = money(in: t) }
            }
        }
        if a.excludingTax == nil || a.tax == nil {
            for t in norm {
                if t.contains("合计") && !t.contains("价税") && !t.contains("大写") {
                    let nums = allMoney(in: t)
                    if nums.count == 2 {
                        // 金额 > 税额（税率 ≤ 20%）
                        a.excludingTax = a.excludingTax ?? nums.max()
                        a.tax = a.tax ?? nums.min()
                    } else if nums.count == 1 {
                        if a.excludingTax == nil && a.tax != nil { a.excludingTax = nums[0] }
                        else if a.tax == nil && a.excludingTax != nil { a.tax = nums[0] }
                    }
                    break
                }
            }
        }
        return a
    }

    private static func allMoney(in text: String) -> [Double] {
        guard let re = try? NSRegularExpression(pattern: "[¥￥]\\s*([0-9OoIlil|,，.。]+)") else { return [] }
        let ns = text as NSString
        var out: [Double] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let raw = cleanDigits(ns.substring(with: m.range(at: 1))).replacingOccurrences(of: ",", with: "")
            if let v = Double(raw), v > 0.004 { out.append(v) }
        }
        return out
    }

    private struct Names {
        var buyer = ""
        var seller = ""
    }

    private static func parseNames(norm: [String]) -> Names {
        var n = Names()
        let buyerAnchor = norm.firstIndex { $0.contains("购买方") || $0.contains("收票单位") }
        let sellerAnchor = norm.firstIndex { $0.contains("销售方") || $0.contains("开票单位") }

        func nameValue(from t: String) -> String? {
            guard let m = matches(t, "名称:?(.{2,})$") else { return nil }
            let ns = t as NSString
            var v = ns.substring(with: m.range(at: 1))
            // 名称后可能直接黏连「统一社会信用代码/地址/开户行」等标签
            for cut in ["统一社会", "信用代码", "税号", "纳税人识别", "地址", "开户行", "开户", "银行账号", "账号"] {
                if let r = v.range(of: cut) { v = String(v[..<r.lowerBound]) }
            }
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: ":：（）() "))
            return v.count >= 2 ? v : nil
        }

        // 1) 锚点行内联名称
        if let bi = buyerAnchor, let v = nameValue(from: norm[bi]) { n.buyer = v }
        if let si = sellerAnchor, let v = nameValue(from: norm[si]) { n.seller = v }

        // 2) 锚点之后向下找最近的「名称」行
        func nearestNameAfter(_ start: Int, until stop: Int?) -> String? {
            guard start >= 0, start < norm.count else { return nil }
            var i = start + 1
            while i < norm.count {
                if let stop = stop, i >= stop { break }
                if norm[i].contains("价税合计") || norm[i].contains("合计") && i > start + 6 { break }
                if let v = nameValue(from: norm[i]) { return v }
                i += 1
            }
            return nil
        }
        if n.buyer.isEmpty, let bi = buyerAnchor {
            n.buyer = nearestNameAfter(bi, until: sellerAnchor) ?? ""
        }
        if n.seller.isEmpty, let si = sellerAnchor {
            n.seller = nearestNameAfter(si, until: nil) ?? ""
        }

        // 3) 终极兜底：全票恰有两个「名称」行 → 顺序即 购买方 → 销售方
        if n.buyer.isEmpty || n.seller.isEmpty {
            let nameRows = norm.compactMap { t -> String? in
                t.contains("名称") ? nameValue(from: t) : nil
            }
            let uniq = nameRows.filter { $0 != n.buyer && $0 != n.seller }
            if n.buyer.isEmpty, uniq.indices.contains(0) { n.buyer = uniq[0] }
            if n.seller.isEmpty, uniq.indices.contains(1) { n.seller = uniq[1] }
        }
        return n
    }

    // MARK: - 数值推导

    private static func derive(_ rec: inout InvoiceRecord) {
        // 多税率时不做推导（比例不确定）
        let rate = rec.taxRate
        if rec.taxRate == nil, rec.taxRatesText.contains("%"), !rec.taxRatesText.contains("/") {
            rec.taxRate = Double(rec.taxRatesText.replacingOccurrences(of: "%", with: ""))
        }
        if let incl = rec.amountIncludingTax, let r = rec.taxRate ?? rate {
            if rec.amountExcludingTax == nil {
                rec.amountExcludingTax = ((incl / (1 + r / 100)) * 100).rounded() / 100
            }
            if rec.taxAmount == nil, let excl = rec.amountExcludingTax {
                rec.taxAmount = ((incl - excl) * 100).rounded() / 100
            }
        }
        if let excl = rec.amountExcludingTax, let r = rec.taxRate, rec.amountIncludingTax == nil {
            rec.amountIncludingTax = ((excl * (1 + r / 100)) * 100).rounded() / 100
        }
        if let excl = rec.amountExcludingTax, let incl = rec.amountIncludingTax, rec.taxAmount == nil {
            rec.taxAmount = ((incl - excl) * 100).rounded() / 100
        }
    }
}
