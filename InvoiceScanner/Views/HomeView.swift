import SwiftUI
import PhotosUI

/// 主页：记录列表 + 新增入口 + Excel 导出
struct HomeView: View {
    @EnvironmentObject private var store: RecordStore
    @State private var showAdd = false
    @State private var exportItem: ExportItem?

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    emptyState
                } else {
                    recordList
                }
            }
            .navigationTitle("发票记录")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        export()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(store.records.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showAdd = true } label: {
                            Label("拍照识别", systemImage: "camera")
                        }
                        Button { showAdd = true } label: {
                            Label("从相册选择", systemImage: "photo.on.rectangle")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showAdd) { AddInvoiceView() }
            .sheet(item: $exportItem) { item in
                ShareSheet(items: [item.url])
            }
        }
    }

    // MARK: - 子视图

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("还没有发票记录")
                .font(.headline)
            Text("拍照或从相册导入发票，\n自动识别号码、日期、金额等字段")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showAdd = true
            } label: {
                Label("识别第一张发票", systemImage: "camera")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordList: some View {
        List {
            Section {
                ForEach(store.records) { rec in
                    NavigationLink {
                        RecordDetailView(recordID: rec.id)
                    } label: {
                        RecordRow(rec: rec)
                    }
                }
                .onDelete { idx in
                    for i in idx { store.delete(store.records[i]) }
                }
            }
            Section {
                summaryRow("记录数", "\(store.records.count) 条")
                summaryRow("含税金额合计", "¥ " + totalInclTaxString)
                summaryRow("税额合计", "¥ " + totalTaxString)
            } header: {
                Text("汇总")
            }
        }
    }

    private var totalInclTaxString: String {
        let t = store.records.compactMap(\.amountIncludingTax).reduce(0, +)
        return String(format: "%.2f", t)
    }

    private var totalTaxString: String {
        let t = store.records.compactMap(\.taxAmount).reduce(0, +)
        return String(format: "%.2f", t)
    }

    private func summaryRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.subheadline)
            Spacer()
            Text(v).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }

    private func export() {
        guard let url = ExcelExporter.export(records: store.records) else { return }
        exportItem = ExportItem(url: url)
    }
}

/// 分享条目（URL 不能直接 retroactive conforms Identifiable）
struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - 行视图

struct RecordRow: View {
    let rec: InvoiceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let v = rec.amountIncludingTax {
                    Text("¥ " + String(format: "%.2f", v))
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                }
            }
            HStack(spacing: 8) {
                Text(rec.invoiceDate.isEmpty ? "日期未识别" : rec.invoiceDate)
                Text("·")
                Text(rec.invoiceNumber.isEmpty ? "号码未识别" : "No.\(rec.invoiceNumber)")
                    .lineLimit(1)
                Spacer()
                if !rec.missingFields.isEmpty {
                    Text("缺\(rec.missingFields.count)项")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        let n = rec.sellerName.isEmpty ? rec.buyerName : rec.sellerName
        return n.isEmpty ? "未命名发票" : n
    }
}

// MARK: - 分享

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
