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

        let amounts = parseAmounts(rows: rows, norm: norm, texts: texts, rateText: rec.taxRatesText)
        rec.amountIncludingTax = amounts.includingTax
        rec.amountExcludingTax = amounts.excludingTax
        rec.taxAmount = amounts.tax

        let names = parseNames(rows: rows, norm: norm)
        rec.buyerName = names.buyer
        rec.sellerName = names.seller

        // 项目名称（明细首行 *分类*名称，如 *经纪代理服务*退货费）存入备注列；
        // 备注行本身的内容（订单号/行程等）一律忽略。首位 * 允许缺失（OCR 常丢行首符号）
        for t in texts {
            if let m = matches(t, "\\*?([^*\\s]{2,20})\\*\\s*([^*\\s]{1,30})") {
                let ns = t as NSString
                rec.note = "*" + ns.substring(with: m.range(at: 1)) + "*" + ns.substring(with: m.range(at: 2))
                break
            }
        }

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

    /// 单价等长小数（小数位 > 2，如 1086.79252830189）不是有效金额
    private static func isUnitPrice(_ cleaned: String) -> Bool {
        guard let dot = cleaned.firstIndex(of: ".") else { return false }
        let frac = cleaned[cleaned.index(after: dot)...]
        return frac.count > 2
    }

    /// 金额正则：分支1 = ¥（含 OCR 误读的 Y/y）前缀；分支2 = 无前缀的 N.NN 小数（≥2 位整数，防 20 位发票号误配）
    private static let moneyPattern = "[¥￥Yy]\\s*([0-9OoIlil|,，.。]+)|(?:^|[^0-9.,])([1-9][0-9OoIlil|,，.。]{1,}\\.[0-9OoIlil|]{2})(?![0-9OoIlil|])"

    /// 从行文本中提取金额（含 ¥ 前缀优先），返回最大的数值（价税合计/合计行取最大值即为总金额）
    private static func money(in text: String, preferLargest: Bool = true) -> Double? {
        let values = extractMoneyValues(in: text)
        guard !values.isEmpty else { return nil }
        return preferLargest ? values.max() : values.first
    }

    /// 提取行内全部候选金额（¥ 前缀 + N.NN 小数，单价等长小数已过滤）
    private static func extractMoneyValues(in text: String) -> [Double] {
        guard let re = try? NSRegularExpression(pattern: moneyPattern) else { return [] }
        let ns = text as NSString
        var values: [Double] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for idx in [1, 2] {
                let r = m.range(at: idx)
                if r.location == NSNotFound { continue }
                let raw = cleanDigits(ns.substring(with: r))
                if isUnitPrice(raw) { continue }          // 长小数=单价，跳过
                let v = Double(raw.replacingOccurrences(of: ",", with: ""))
                if v != nil && v! > 0.004 { values.append(v!) }
            }
        }
        return values
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
        // 2) 兜底：独立 20 位（数电票）或 8 位号码；排除「校验码」「备注/订单」行（订单号是干扰源）
        for (i, t) in norm.enumerated() {
            if t.contains("校验") || t.contains("备注") || t.contains("订单") { continue }
            if let m = matches(t, "(^|[^0-9])([0-9]{20})([^0-9]|$)") {
                let ns = t as NSString
                let _ = i
                return ns.substring(with: m.range(at: 2))
            }
        }
        for t in norm {
            if t.contains("校验") || t.contains("备注") || t.contains("订单") { continue }
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

    private static func parseAmounts(rows: [[OCRLine]], norm: [String], texts: [String], rateText: String) -> Amounts {
        var a = Amounts()
        // 1) 价税合计（含税）：优先取「(小写)」锚点之后的数字（大写金额是汉字，money 本来也取不到）
        for t in norm {
            if t.contains("价税合计") {
                if let r = t.range(of: "小写") {
                    a.includingTax = money(in: String(t[r.upperBound...])) ?? money(in: t)
                } else {
                    a.includingTax = money(in: t)
                }
                // 对屏拍摄时 (小写)¥ 数字常被读花 → 兜底解析大写汉字金额
                if a.includingTax == nil {
                    a.includingTax = chineseAmount(in: t)
                }
                break
            }
        }
        // 2) 明细合计行：金额合计 / 税额合计，或老式「合计 ¥x ¥y」双金额
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
                    let nums = extractMoneyValues(in: t)
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
        // 3) 明细行按列提取（¥ 全部读花时，按表头「金额/税额」列的 x 几何位置对齐取数）
        if a.excludingTax == nil || a.tax == nil {
            let d = detailColumnAmounts(rows: rows, norm: norm)
            if a.excludingTax == nil { a.excludingTax = d.excl }
            if a.tax == nil { a.tax = d.tax }
        }
        // 4) 税率一致性配对（最后兜底：用 明细金额×(1+税率) 与候选金额互相验证；
        //    必须用带空格的原始行文本——去空格会把相邻数字黏成串）
        if a.includingTax == nil || a.excludingTax == nil {
            let c = consistencyAmounts(texts: texts, rateText: rateText)
            if a.includingTax == nil { a.includingTax = c.includingTax }
            if a.excludingTax == nil { a.excludingTax = c.excludingTax }
            if a.tax == nil { a.tax = c.tax }
        }
        return a
    }

    /// 解析大写汉字金额（如「壹仟壹佰伍拾贰圆整」→ 1152.00）
    private static func chineseAmount(in t: String) -> Double? {
        var s = t
        if let r = s.range(of: "大写") {
            s = String(s[r.upperBound...]).replacingOccurrences(of: ")", with: "").replacingOccurrences(of: "）", with: "")
        }
        let digitMap: [Character: Int] = [
            "零":0,"〇":0,"一":1,"壹":1,"二":2,"贰":2,"两":2,"三":3,"叁":3,
            "四":4,"肆":4,"五":5,"伍":5,"六":6,"陆":6,"七":7,"柒":7,"八":8,"捌":8,"九":9,"玖":9
        ]
        let unitMap: [Character: Double] = ["十":10,"拾":10,"百":100,"佰":100,"千":1000,"仟":1000]
        let bigMap: [Character: Double] = ["万":10_000,"萬":10_000,"亿":100_000_000,"億":100_000_000]
        var result = 0.0, section = 0.0, frac = 0.0
        var digit = -1, sawDigit = false, intDone = false
        var intVal = 0.0
        for ch in s {
            if let d = digitMap[ch] { digit = d; sawDigit = true; continue }
            if intDone {
                if ch == "角" { frac += Double(max(digit, 0)) * 0.1; digit = -1 }
                else if ch == "分" { frac += Double(max(digit, 0)) * 0.01; digit = -1 }
                continue
            }
            if let u = unitMap[ch] {
                section += (digit >= 0 ? Double(digit) : 1) * u   // 「拾贰」= 12
                digit = -1
            } else if let b = bigMap[ch] {
                let val = section + (digit >= 0 ? Double(digit) : 0)
                if b > 50_000 { result = (result + val) * b }     // 亿
                else { result += val * b }                        // 万
                section = 0; digit = -1
            } else if ch == "圆" || ch == "元" {
                // 整数部分在「圆/元」处落袋，避免「叁拾叁元肆角」的尾数 3 被角的 4 覆盖
                intVal = result + section + (digit >= 0 ? Double(digit) : 0)
                result = 0; section = 0; digit = -1
                intDone = true
            }
        }
        if !intDone {
            intVal = result + section + (digit >= 0 ? Double(digit) : 0)
        }
        let total = intVal + frac
        guard sawDigit, total > 0.004, total < 1e10 else { return nil }
        return (total * 100).rounded() / 100
    }

    /// 明细行按列提取：找「项目名称…金额…税额」表头行，取表头「金额/税额」碎片中心 x，
    /// 其下各行中落在对应列（±0.085）的金额累加（多明细行天然求和=合计）
    private static func detailColumnAmounts(rows: [[OCRLine]], norm: [String]) -> (excl: Double?, tax: Double?) {
        guard let hi = norm.firstIndex(where: { $0.contains("项目名称") || ($0.contains("单价") && $0.contains("金额") && $0.contains("税额")) }) else {
            return (nil, nil)
        }
        var amtX: Double? = nil, taxX: Double? = nil
        for f in rows[hi] {
            let t = normalize(f.text)
            if amtX == nil, t.contains("金额"), !t.contains("价税") { amtX = f.x + f.w / 2 }
            if taxX == nil, t.contains("税额") { taxX = f.x + f.w / 2 }
        }
        guard amtX != nil || taxX != nil else { return (nil, nil) }
        var excl = 0.0, tax = 0.0
        var hasExcl = false, hasTax = false
        for i in (hi + 1)..<rows.count {
            let t = norm[i]
            if t.contains("价税合计") || t.contains("合计") || t.contains("小写") { break }
            for f in rows[i] {
                guard let v = money(in: f.text, preferLargest: false) else { continue }
                let cx = f.x + f.w / 2
                if let ax = amtX, abs(cx - ax) <= 0.085 { excl += v; hasExcl = true }
                if let tx = taxX, abs(cx - tx) <= 0.085 { tax += v; hasTax = true }
            }
        }
        let round2 = { (v: Double) in (v * 100).rounded() / 100 }
        return (hasExcl ? round2(excl) : nil, hasTax ? round2(tax) : nil)
    }

    /// 税率一致性配对：候选金额里找 v 与 v×(1+税率) 同时出现的组合
    /// （如 1086.79 × 1.06 = 1152.00 → 含税 1152 / 不含税 1086.79 / 税额 65.21）
    private static func consistencyAmounts(texts: [String], rateText: String) -> Amounts {
        guard rateText.contains("%"), !rateText.contains("/"),
              let r = Double(rateText.replacingOccurrences(of: "%", with: "")), r > 0, r <= 20 else {
            return Amounts()
        }
        var vals: [Double] = []
        for t in texts {
            let n = normalize(t)
            if n.contains("订单") || n.contains("校验") || n.contains("号码") || n.contains("大写") { continue }
            vals.append(contentsOf: extractMoneyValues(in: t))
        }
        guard vals.count >= 2 else { return Amounts() }
        let k = 1 + r / 100
        var a = Amounts()
        for v in vals.sorted(by: >) where v >= 1 {
            let exclTarget = v / k
            if let c = vals.first(where: { abs($0 - exclTarget) <= 0.02 && $0 > 0.99 && $0 < v }) {
                a.includingTax = v
                a.excludingTax = c
                a.tax = ((v - c) * 100).rounded() / 100
                return a
            }
            let inclTarget = v * k
            if let c = vals.first(where: { abs($0 - inclTarget) <= 0.02 && $0 > 0.99 && $0 > v }) {
                a.excludingTax = v
                a.includingTax = c
                a.tax = ((c - v) * 100).rounded() / 100
                return a
            }
        }
        return a
    }

    private struct Names {
        var buyer = ""
        var seller = ""
    }

    private static func parseNames(rows: [[OCRLine]], norm: [String]) -> Names {
        var n = Names()

        /// 名称尾巴可能黏连「统一社会信用代码/地址/开户行」等标签，逐个截断
        func cleanName(_ raw: String) -> String {
            var v = raw
            for cut in ["统一社会", "信用代码", "纳税人识别", "税号", "地址", "开户行", "开户", "银行账号", "账号", "电话", "销售方", "购买方", "开票单位", "收票单位", "名称"] {
                if let r = v.range(of: cut) { v = String(v[..<r.lowerBound]) }
            }
            // 竖排标签残片黏在名称尾部（如「…有限公司销售」）——真实公司名不会以「销售/购买」结尾
            var changed = true
            while changed {
                changed = false
                for tail in ["销售方信息", "购买方信息", "销售方", "购买方", "开票单位", "收票单位", "销售", "购买"] {
                    if v.hasSuffix(tail), v.count - tail.count >= 2 {
                        v = String(v.dropLast(tail.count))
                        changed = true
                    }
                }
            }
            return v.trimmingCharacters(in: CharacterSet(charactersIn: ":：（）() ，,。"))
        }

        /// 从归一化文本中提取第一个「名称:」之后的公司名（到下一个「名称」为止）
        func nameValue(from t: String) -> String? {
            guard let m = matches(t, "名称:?(.+?)(名称|$)") else { return nil }
            let ns = t as NSString
            let v = cleanName(ns.substring(with: m.range(at: 1)))
            return v.count >= 2 ? v : nil
        }

        /// 从一排碎片中提取第一个「名称」对应的公司名：
        /// 取「名称」碎片自身的余文 + 后续碎片，直到碰见下一个含「名称」的碎片为止
        /// （并排布局时一行里有两个名称，不能整行一起取）
        func nameValueFromFragments(_ frags: [OCRLine]) -> String? {
            var parts: [String] = []
            var started = false
            for f in frags {
                let t = normalize(f.text)
                if !started {
                    if t.contains("名称") {
                        started = true
                        if let m = matches(t, "名称:?(.*)$") {
                            let ns = t as NSString
                            parts.append(ns.substring(with: m.range(at: 1)))
                        }
                    }
                } else {
                    if t.contains("名称") { break }
                    // 跨过对方区域标签（如黏在购买方名称后的「销售方信息」残片）即停
                    if t.contains("销售方") || t.contains("购买方") || t.contains("开票单位") || t.contains("收票单位") { break }
                    parts.append(t)
                }
            }
            guard started else { return nil }
            let v = cleanName(parts.joined())
            return v.count >= 2 ? v : nil
        }

        // 定位「销售方/开票单位」与「购买方/收票单位」标签所在的（行, 碎片）
        var sellerLoc: (Int, Int)? = nil
        var buyerLoc: (Int, Int)? = nil
        for (ri, row) in rows.enumerated() {
            for (fi, frag) in row.enumerated() {
                let t = normalize(frag.text)
                if sellerLoc == nil, t.contains("销售方") || t.contains("开票单位") { sellerLoc = (ri, fi) }
                if buyerLoc == nil, t.contains("购买方") || t.contains("收票单位") || t.contains("购买单位") { buyerLoc = (ri, fi) }
            }
        }

        // 1) 行内提取（关键修复）：数电票购买方(左)与销售方(右)并排、被 OCR 合并进同一行，
        //    必须以「销售方」标签为切割点——右侧才是销售方名称，左侧才是购买方名称
        if let (ri, _) = buyerLoc {
            var t = normalize(OCRService.rowText(rows[ri]))
            if let r = t.range(of: "销售方") { t = String(t[..<r.lowerBound]) }   // 只取销售方之前
            if let r = t.range(of: "开票单位") { t = String(t[..<r.lowerBound]) }
            if let r = t.range(of: "购买方") { t = String(t[r.upperBound...]) }   // 跳过标签本身
            if let r = t.range(of: "收票单位") { t = String(t[r.upperBound...]) }
            if let v = nameValue(from: t) { n.buyer = v }
        }
        if let (ri, _) = sellerLoc {
            var t = normalize(OCRService.rowText(rows[ri]))
            if let r = t.range(of: "销售方") { t = String(t[r.upperBound...]) }   // 只取销售方之后
            else if let r = t.range(of: "开票单位") { t = String(t[r.upperBound...]) }
            if let v = nameValue(from: t) { n.seller = v }
        }

        // 2) 几何兜底：名称在锚点行的下一行时，按 x 坐标过滤
        //    购买方：向下找第一个名称行（购买方块在左，自然先出现）
        //    销售方：只看 x 不小于「销售方标签碎片」左缘的碎片——并排布局时排除左侧购买方的名称
        func nearestNameBelow(_ startRow: Int, minCenterX: Double?) -> String? {
            guard startRow + 1 < rows.count else { return nil }
            let anchorX = minCenterX
            var i = startRow + 1
            while i < rows.count {
                let t = normalize(OCRService.rowText(rows[i]))
                if t.contains("价税合计") || (t.contains("合计") && i > startRow + 6) { break }
                let slice = rows[i].filter { frag in
                    guard let ax = anchorX else { return true }
                    return (frag.x + frag.w / 2) >= ax - 0.03
                }
                if !slice.isEmpty, let v = nameValueFromFragments(slice) { return v }
                i += 1
            }
            return nil
        }
        if n.buyer.isEmpty, let (ri, _) = buyerLoc {
            n.buyer = nearestNameBelow(ri, minCenterX: nil) ?? ""
        }
        if n.seller.isEmpty, let (ri, fi) = sellerLoc {
            let ax = rows[ri][fi].x
            n.seller = nearestNameBelow(ri, minCenterX: ax) ?? ""
        }

        // 2.5) 几何兜底：同一行出现两个及以上「名称」碎片 → 最左=购买方，其后第一个=销售方
        //      （竖排标签被 OCR 打散导致找不到「销售方」锚点时的保险）
        if n.buyer.isEmpty || n.seller.isEmpty {
            for row in rows {
                let nameIdxs = row.enumerated().compactMap { normalize($0.element.text).contains("名称") ? $0.offset : nil }
                guard nameIdxs.count >= 2 else { continue }
                if n.buyer.isEmpty, let v = nameValueFromFragments(Array(row[nameIdxs[0]...])) { n.buyer = v }
                if n.seller.isEmpty, let v = nameValueFromFragments(Array(row[nameIdxs[1]...])) { n.seller = v }
                break
            }
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
        // 无税率时的互相补全（两两相加/相减）
        if let excl = rec.amountExcludingTax, let tax = rec.taxAmount, rec.amountIncludingTax == nil {
            rec.amountIncludingTax = ((excl + tax) * 100).rounded() / 100
        }
        if let incl = rec.amountIncludingTax, let tax = rec.taxAmount, rec.amountExcludingTax == nil {
            rec.amountExcludingTax = ((incl - tax) * 100).rounded() / 100
        }
    }
}
