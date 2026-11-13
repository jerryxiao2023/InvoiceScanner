import Foundation
import Vision
import CoreImage

/// 单行 OCR 结果：文本 + 归一化坐标（origin 已换到左上角，y 向下）
struct OCRLine {
    var text: String
    var x: Double      // minX
    var y: Double      // minY（顶部）
    var w: Double
    var h: Double
}

/// 苹果 Vision 中文文字识别（端上离线，无需网络）
enum OCRService {

    static func recognize(cgImage: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false   // 发票号/金额不能被语言纠错改写

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results as? [VNRecognizedTextObservation] else {
            return []
        }
        var lines: [OCRLine] = []
        for obs in observations {
            guard let top = obs.topCandidates(1).first else { continue }
            let b = obs.boundingBox
            lines.append(OCRLine(
                text: top.string.trimmingCharacters(in: .whitespacesAndNewlines),
                x: Double(b.origin.x),
                y: Double(1 - b.maxY),   // 翻转到左上原点
                w: Double(b.width),
                h: Double(b.height)
            ))
        }
        return lines
    }

    /// 降采样到最长边 maxSide（提高识别速度，超采样对准确率无益）
    static func downscale(_ image: CGImage, maxSide: CGFloat) -> CGImage {
        let maxDim = CGFloat(max(image.width, image.height))
        guard maxDim > maxSide else { return image }
        let scale = maxSide / maxDim
        let w = Int(CGFloat(image.width) * scale)
        let h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// 按行聚合：y 接近的碎片合并为一行（标签与数值常被切成两个框）
    static func groupRows(_ lines: [OCRLine]) -> [[OCRLine]] {
        let sorted = lines.sorted { $0.y < $1.y }
        var rows: [[OCRLine]] = []
        var current: [OCRLine] = []
        var currentY: Double = -1
        for l in sorted {
            let h = max(l.h, 0.01)
            if currentY < 0 || abs(l.y - currentY) <= max(0.012, h * 0.6) {
                current.append(l)
                currentY = currentY < 0 ? l.y : (currentY * Double(current.count - 1) + l.y) / Double(current.count)
            } else {
                current.sort { $0.x < $1.x }
                rows.append(current)
                current = [l]
                currentY = l.y
            }
        }
        if !current.isEmpty {
            current.sort { $0.x < $1.x }
            rows.append(current)
        }
        return rows
    }

    /// 行内文本（碎片之间智能补空格：中文字符直接相连，数字/字母间留空）
    static func rowText(_ row: [OCRLine]) -> String {
        row.map { $0.text }.joined(separator: " ")
    }
}
