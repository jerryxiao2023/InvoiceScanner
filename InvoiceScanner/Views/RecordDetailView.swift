import SwiftUI

/// 记录详情：可再次编辑 + 删除
struct RecordDetailView: View {
    @EnvironmentObject private var store: RecordStore
    @Environment(\.dismiss) private var dismiss
    let recordID: UUID

    @State private var editing = false
    @State private var confirmDelete = false

    private var record: InvoiceRecord? {
        store.records.first { $0.id == recordID }
    }

    var body: some View {
        Group {
            if let rec = record {
                List {
                    Section("票面") {
                        kv("发票号码", rec.invoiceNumber)
                        kv("开票日期", rec.invoiceDate)
                        kv("开票单位（销售方）", rec.sellerName)
                        kv("收票单位（购买方）", rec.buyerName)
                    }
                    Section("金额") {
                        moneyKV("不含税金额", rec.amountExcludingTax)
                        kv("税率", rec.taxRate.map { String(format: "%g%%", $0) } ?? rec.taxRatesText)
                        moneyKV("税额", rec.taxAmount)
                        moneyKV("含税金额", rec.amountIncludingTax)
                    }
                    if !rec.invoiceType.isEmpty || !rec.note.isEmpty {
                        Section("其他") {
                            if !rec.invoiceType.isEmpty { kv("票种", rec.invoiceType) }
                            if !rec.note.isEmpty { kv("备注", rec.note) }
                        }
                    }
                    if let cg = store.loadImage(rec.imagePath) {
                        Section("原图") {
                            Image(uiImage: UIImage(cgImage: cg))
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .frame(maxHeight: 240)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    if !rec.rawText.isEmpty {
                        Section("OCR 原文") {
                            Text(rec.rawText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("发票详情")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("编辑") { editing = true }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                    }
                }
                .sheet(isPresented: $editing) {
                    NavigationStack {
                        InvoiceEditView(record: rec, isNew: false,
                                        image: store.loadImage(rec.imagePath),
                                        onSaved: { editing = false })
                    }
                }
                .alert("删除这条记录？", isPresented: $confirmDelete) {
                    Button("删除", role: .destructive) {
                        if let r = record { store.delete(r) }
                        dismiss()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("记录及其关联原图将被移除，不可恢复")
                }
            } else {
                Text("记录不存在")
            }
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v.isEmpty ? "未识别" : v).multilineTextAlignment(.trailing)
        }
    }

    private func moneyKV(_ k: String, _ v: Double?) -> some View {
        kv(k, v.map { String(format: "%.2f", $0) } ?? "")
    }
}
