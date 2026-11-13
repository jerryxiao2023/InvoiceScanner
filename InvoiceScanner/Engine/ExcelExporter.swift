import Foundation

/// Excel 导出：内置最小 ZIP（Store 模式）写入器，直接生成真实 .xlsx
/// 单元格全部用 inlineStr，避免共享字符串表；数字列用数值单元格，Excel 可直接求和
enum ExcelExporter {

    // MARK: - 对外接口

    static func export(records: [InvoiceRecord]) -> URL? {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("发票记录_\(Self.dateStamp()).xlsx")

        // 表头 + 数据
        let header = ["序号", "发票号码", "开票日期", "开票单位（销售方）", "收票单位（购买方）",
                      "不含税金额", "税率", "税额", "含税金额", "票种", "备注", "录入时间"]
        var cells: [[Cell]] = [header.map { Cell.text($0) }]
        for (i, r) in records.enumerated() {
            var row: [Cell] = [Cell.number(Double(i + 1))]
            row.append(Cell.text(r.invoiceNumber))
            row.append(Cell.text(r.invoiceDate))
            row.append(Cell.text(r.sellerName))
            row.append(Cell.text(r.buyerName))
            row.append(r.amountExcludingTax.map(Cell.number) ?? Cell.text(""))
            row.append(Cell.text(r.taxRate.map { String(format: "%g%%", $0) } ?? r.taxRatesText))
            row.append(r.taxAmount.map(Cell.number) ?? Cell.text(""))
            row.append(r.amountIncludingTax.map(Cell.number) ?? Cell.text(""))
            row.append(Cell.text(r.invoiceType))
            row.append(Cell.text(r.note))
            row.append(Cell.text(Self.dateTimeString(r.createdAt)))
            cells.append(row)
        }

        let sheetXML = sheet(cells: cells, numberCols: [0, 5, 7, 8])
        let files: [(String, String)] = [
            ("[Content_Types].xml", contentTypes),
            ("_rels/.rels", rels),
            ("xl/workbook.xml", workbook),
            ("xl/_rels/workbook.xml.rels", workbookRels),
            ("xl/styles.xml", styles),
            ("xl/worksheets/sheet1.xml", sheetXML)
        ]

        var entries: [ZipEntry] = []
        for (name, xml) in files {
            guard let data = xml.data(using: .utf8) else { return nil }
            entries.append(ZipEntry(name: name, data: data))
        }
        guard let zip = zipData(entries: entries) else { return nil }
        do {
            try zip.write(to: out, options: .atomic)
            return out
        } catch { return nil }
    }

    // MARK: - 单元格

    private enum Cell {
        case text(String)
        case number(Double)
    }

    private static func xmlEscape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // 过滤非法 XML 字符
                if ch.value >= 0x20 || ch == "\t" || ch == "\n" || ch == "\r" { out.unicodeScalars.append(ch) }
            }
        }
        return out
    }

    private static func sheet(cells: [[Cell]], numberCols: Set<Int>) -> String {
        var body = ""
        for (ri, row) in cells.enumerated() {
            var rowXML = ""
            for (ci, cell) in row.enumerated() {
                let ref = colName(ci) + String(ri + 1)
                switch cell {
                case .text(let s):
                    rowXML += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(s))</t></is></c>"
                case .number(let v):
                    rowXML += "<c r=\"\(ref)\"><v>\(v)</v></c>"
                }
            }
            body += "<row r=\"\(ri + 1)\">\(rowXML)</row>"
        }
        let last = colName(max(0, (cells.first?.count ?? 1) - 1)) + String(cells.count)
        let ranges = numberCols.compactMap { ci -> String? in
            guard cells.count > 1 else { return nil }
            return "\(colName(ci))2:\(colName(ci))\(cells.count)"
        }
        let merge = ranges.isEmpty ? "" : "<mergeCells count=\"0\"></mergeCells>"
        _ = merge
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>\(body)</sheetData>
        <dimension ref="A1:\(last)"/>
        </worksheet>
        """
    }

    private static func colName(_ i: Int) -> String {
        var n = i, s = ""
        repeat {
            s = String(UnicodeScalar(UInt8(65 + n % 26))) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmm"
        return f.string(from: Date())
    }

    private static func dateTimeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: - OOXML 骨架

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
    </Types>
    """

    private static let rels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static let workbook = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <sheets><sheet name="发票记录" sheetId="1" r:id="rId1"/></sheets>
    </workbook>
    """

    private static let workbookRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
    <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
    <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
    <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>
    </styleSheet>
    """

    // MARK: - 最小 ZIP 写入器（Store 模式，无压缩，标准 ZIP 结构）

    private struct ZipEntry {
        var name: String
        var data: Data
    }

    private static func zipData(entries: [ZipEntry]) -> Data? {
        var out = Data()
        var central = Data()
        var offsets: [UInt32] = []

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyMMddHHmmss"
        let t = dateFormatter.string(from: Date())
        let year = UInt16(max(1980, 2000 + Int(t.prefix(2))!)) - 1980
        let month = UInt16(Int(t.dropFirst(2).prefix(2))!)
        let day = UInt16(Int(t.dropFirst(4).prefix(2))!)
        let hour = UInt16(Int(t.dropFirst(6).prefix(2))!)
        let minute = UInt16(Int(t.dropFirst(8).prefix(2))!)
        let second = UInt16(Int(t.dropFirst(10).prefix(2))!)
        let dosDate = (year << 9) | (month << 5) | day
        let dosTime = (hour << 11) | (minute << 5) | (second >> 1)

        for e in entries {
            let nameData = e.name.data(using: .utf8)!
            let crc = crc32(e.data)
            offsets.append(UInt32(out.count))

            out.appendLE(UInt32(0x04034b50))         // local header
            out.appendLE(UInt16(20))                 // version
            out.appendLE(UInt16(0x0800))             // flags: UTF-8 name
            out.appendLE(UInt16(0))                  // method: store
            out.appendLE(dosTime); out.appendLE(dosDate)
            out.appendLE(crc)
            out.appendLE(UInt32(e.data.count)); out.appendLE(UInt32(e.data.count))
            out.appendLE(UInt16(nameData.count)); out.appendLE(UInt16(0))
            out.append(nameData)
            out.append(e.data)

            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20)); central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800)); central.appendLE(UInt16(0))
            central.appendLE(dosTime); central.appendLE(dosDate)
            central.appendLE(crc)
            central.appendLE(UInt32(e.data.count)); central.appendLE(UInt32(e.data.count))
            central.appendLE(UInt16(nameData.count))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))   // extra/comment len
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))   // disk/attrs
            central.appendLE(UInt32(0))                                // external attrs
            central.appendLE(offsets.last!)
            central.append(nameData)
        }

        let cdOffset = UInt32(out.count)
        out.append(central)
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count)); out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(central.count)); out.appendLE(cdOffset)
        out.appendLE(UInt16(0))
        return out
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c: UInt32 = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8(v >> 8))
    }
    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8(v >> 24))
    }
}
