import SwiftUI
import PhotosUI
import UIKit

/// 新增发票：拍照 / 相册 → OCR → 字段确认编辑
struct AddInvoiceView: View {
    @EnvironmentObject private var store: RecordStore
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var processing = false
    @State private var pendingImage: CGImage?
    @State private var pendingRecord: InvoiceRecord?
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if processing {
                    Spacer()
                    ProgressView("正在识别发票字段…")
                    Spacer()
                } else if let rec = pendingRecord {
                    InvoiceEditView(record: rec, isNew: true,
                                    image: pendingImage,
                                    onSaved: { dismiss() })
                } else {
                    Spacer()
                    Image(systemName: "doc.text.viewfinder")
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)
                    Text("拍摄或导入发票照片\n自动识别票面字段")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Button {
                        showCamera = true
                    } label: {
                        Label("拍照识别", systemImage: "camera")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    if let msg = errorMsg {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    Text("提示：正面平放、光线均匀、充满画面，识别更准")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(24)
            .navigationTitle("识别发票")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    if let image { process(image) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: pickerItem) { item in
                guard let item else { return }
                pickerItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let img = UIImage(data: data)?.normalizedCGImage() else {
                        errorMsg = "读取照片失败"; return
                    }
                    process(img)
                }
            }
        }
        .interactiveDismissDisabled(processing)
    }

    private func process(_ cg: CGImage) {
        processing = true
        errorMsg = nil
        let work = OCRService.downscale(cg, maxSide: 2200)
        Task.detached(priority: .userInitiated) {
            var record = InvoiceRecord()
            var image = work
            do {
                let lines = try OCRService.recognize(cgImage: image)
                let rows = OCRService.groupRows(lines)
                record = InvoiceParser.parse(rows: rows)
            } catch {
                await MainActor.run { errorMsg = "识别失败：\(error.localizedDescription)" }
                image = cg
            }
            let final = record
            let img = image
            await MainActor.run {
                pendingImage = img
                pendingRecord = final
                processing = false
            }
        }
    }
}

// MARK: - 字段确认编辑页（识别结果 / 详情共用表单）

struct InvoiceEditView: View {
    @EnvironmentObject private var store: RecordStore
    @Environment(\.dismiss) private var dismiss

    @State var record: InvoiceRecord
    var isNew: Bool
    var image: CGImage?
    var onSaved: () -> Void

    @State private var amountExclStr: String = ""
    @State private var taxRateStr: String = ""
    @State private var taxStr: String = ""
    @State private var amountInclStr: String = ""
    @State private var showRaw = false
    @State private var showImage = false

    var body: some View {
        Form {
            Section {
                if let cg = image ?? store.loadImage(record.imagePath) {
                    Image(uiImage: UIImage(cgImage: cg))
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity)
                        .onTapGesture { showImage = true }
                }
                if isNew && !record.missingFields.isEmpty {
                    Label("未识别：\(record.missingFields.joined(separator: "、"))——可手动补填",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if isNew, let dup = store.findDuplicate(number: record.invoiceNumber) {
                    Label("该发票号码已存在（\(dup.sellerName.isEmpty ? "未知单位" : dup.sellerName)，\(dup.invoiceDate)）——疑似重复录入",
                          systemImage: "doc.on.doc.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("票面信息") {
                field("发票号码", text: $record.invoiceNumber)
                field("开票日期", text: $record.invoiceDate, placeholder: "yyyy-MM-dd")
                field("开票单位（销售方）", text: $record.sellerName)
                field("收票单位（购买方）", text: $record.buyerName)
            }

            Section("金额") {
                money("不含税金额", text: $amountExclStr)
                money("税率（%）", text: $taxRateStr)
                money("税额", text: $taxStr)
                money("含税金额（价税合计）", text: $amountInclStr)
                if !record.taxRatesText.isEmpty {
                    HStack { Text("票面税率"); Spacer(); Text(record.taxRatesText).foregroundStyle(.secondary) }
                        .font(.footnote)
                }
            }

            Section("备注") {
                TextField("选填", text: $record.note)
            }

            if !record.rawText.isEmpty {
                Section {
                    Button(showRaw ? "收起 OCR 原文" : "查看 OCR 原文（核对用）") {
                        showRaw.toggle()
                    }
                    if showRaw {
                        Text(record.rawText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(isNew ? "确认字段" : "编辑记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
                    .font(.headline)
            }
        }
        .fullScreenCover(isPresented: $showImage) {
            if let cg = image ?? store.loadImage(record.imagePath) {
                ZoomableImage(image: cg)
                    .background(Color.black.ignoresSafeArea())
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        HStack {
            Text(label).frame(width: 120, alignment: .leading)
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
        }
    }

    private func money(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 160, alignment: .leading)
            TextField("0.00", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        record.amountExcludingTax = Double(amountExclStr)
        record.taxRate = Double(taxRateStr)
        record.taxAmount = Double(taxStr)
        record.amountIncludingTax = Double(amountInclStr)
        if let img = image, record.imagePath.isEmpty {
            record.imagePath = store.saveImage(img, for: record)
        }
        if isNew { store.add(record) } else { store.update(record) }
        onSaved()
        if !isNew { dismiss() }
    }
}

// MARK: - 拍照

struct CameraPicker: UIViewControllerRepresentable {
    var onResult: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onResult: (UIImage?) -> Void
        init(onResult: @escaping (UIImage?) -> Void) { self.onResult = onResult }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onResult(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onResult(nil)
        }
    }
}

// MARK: - 图片工具

extension UIImage {
    /// 处理 EXIF 方向 → 直接可用的 CGImage
    func normalizedCGImage() -> CGImage? {
        if imageOrientation == .up, let cg = cgImage { return cg }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }
}

struct ZoomableImage: View {
    let image: CGImage
    @State private var scale: CGFloat = 1

    var body: some View {
        Image(uiImage: UIImage(cgImage: image))
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .gesture(
                MagnificationGesture()
                    .onChanged { scale = min(4, max(1, $0)) }
            )
            .onTapGesture(count: 2) {
                withAnimation { scale = scale > 1 ? 1 : 2.5 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
