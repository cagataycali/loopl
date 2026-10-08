#if DEBUG
import Foundation
import Loopl
#if canImport(UIKit)
import UIKit
#endif

/// DEBUG corpus for `--design-history-corpus N`: deterministic conversations (fixed UUIDs, fixed text) so a share → train run
/// from the app is reproducible. Mix: calculator + current_time tool turns, short explanations, and every 8th thread a
/// picture (rendered here — coloured shapes + a number) whose answer names exactly what is drawn.
enum HistoryCorpus {
    static let colors: [(String, (CGFloat, CGFloat, CGFloat))] = [
        ("red", (0.86, 0.15, 0.15)), ("blue", (0.15, 0.35, 0.86)), ("green", (0.13, 0.6, 0.25)),
        ("orange", (0.95, 0.55, 0.1)), ("purple", (0.55, 0.25, 0.75)),
    ]
    static let shapes = ["circle", "square", "triangle"]
    static let topics: [(String, String)] = [
        ("What is an agent loop?", "A loop where the model either answers or asks for a tool; the app runs the tool, appends the result, and asks again until the model answers plainly."),
        ("Why run a language model on the phone?", "Privacy, no network round trip, and it keeps working offline — the conversation never leaves the device."),
        ("What does a tool result look like to the model?", "Plain text appended to the conversation. Errors start with `ERROR:` so the model can change its arguments and try again."),
        ("What is 4-bit quantisation?", "Storing each weight in 4 bits instead of 16, with a scale per small group — about a quarter of the memory for a small accuracy cost."),
        ("What is loopl?", "loopl is a Swift SDK and iOS app for running agents with on-device language models, tools and memory."),
        ("How do I keep a model on an external drive?", "Settings › Storage → choose a folder on the drive; loopl downloads straight to it and opens it when the drive is plugged in."),
        ("What is a LoRA?", "A low-rank adapter: two small matrices trained next to a frozen weight, merged back in after training."),
        ("Give me one tip for writing good prompts.", "Say what a good answer looks like — the format, the length and what to leave out."),
    ]
    static let zones = ["Europe/Istanbul", "America/New_York", "Asia/Tokyo", "Europe/London", "America/Los_Angeles"]

    static func id(_ i: Int) -> UUID { UUID(uuidString: String(format: "8A6C0A1E-1000-4D8B-9B3C-%012X", i))! }

    static func threads(count: Int, modelName: String, modelId: String, tools: [ToolSpec]) -> [SavedConversation] {
        (0..<count).map { i in
            let updated = Date(timeIntervalSince1970: 1_790_000_000 - Double(i) * 3_600)
            let items: [SavedConversation.Item]
            var title: String
            switch i % 8 {
            case 0:
                let (a, b) = (shape(i), shape(i + 1))
                let n = 10 + i % 90
                title = "What is in this picture? (\(i))"
                items = [.user("What do you see in this picture?", images: [picture(a, b, n)]),
                         .assistant("A \(a.0) \(a.1) on the left and a \(b.0) \(b.1) on the right, with the number **\(n)** underneath.")]
            case 1, 4:
                let x = 3 + i, y = 7 + (i * 13) % 50
                title = "What is \(x) × \(y)?"
                items = [.user(title), .tool(name: "calculator", args: ["expression": .string("\(x)*\(y)")], result: "\(x)*\(y) = \(x * y)", isError: false, ms: 0.4, images: nil),
                         .assistant("\(x) × \(y) = **\(x * y)**.")]
            case 2, 6:
                let z = zones[i % zones.count], city = z.split(separator: "/").last!.replacingOccurrences(of: "_", with: " ")
                let hh = (i * 7) % 24, mm = (i * 11) % 60
                title = "What time is it in \(city)?"
                items = [.user(title), .tool(name: "current_time", args: ["timezone": .string(z)], result: String(format: "2026-10-06 %02d:%02d (%@)", hh, mm, z), isError: false, ms: 1.1, images: nil),
                         .assistant(String(format: "It is **%02d:%02d** in %@.", hh, mm, city))]
            default:
                let t = topics[i % topics.count]
                title = t.0
                items = [.user(t.0), .assistant(t.1)]
            }
            if title.count > 60 { title = String(title.prefix(60)) }
            return SavedConversation(id: id(i), title: title, updated: updated, modelName: modelName, items: items, modelId: modelId, tools: tools)
        }
    }

    static func shape(_ i: Int) -> (String, String) { (colors[i % colors.count].0, shapes[(i / 2) % shapes.count]) }

    /// 320×200 PNG: two shapes and a number — what the answer says, pixel for pixel.
    static func picture(_ a: (String, String), _ b: (String, String), _ n: Int) -> ImageBlock {
        #if canImport(UIKit)
        let size = CGSize(width: 320, height: 200)
        let img = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            for (k, s) in [a, b].enumerated() {
                let c = colors.first { $0.0 == s.0 }!.1
                UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1).setFill()
                let r = CGRect(x: 40 + CGFloat(k) * 160, y: 20, width: 100, height: 100)
                let path: UIBezierPath
                switch s.1 {
                case "circle": path = UIBezierPath(ovalIn: r)
                case "square": path = UIBezierPath(rect: r)
                default:
                    path = UIBezierPath(); path.move(to: CGPoint(x: r.midX, y: r.minY))
                    path.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); path.addLine(to: CGPoint(x: r.minX, y: r.maxY)); path.close()
                }
                path.fill()
            }
            let text = "\(n)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 44), .foregroundColor: UIColor.black]
            let ts = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: 135), withAttributes: attrs)
        }
        return ImageBlock(data: img.pngData() ?? Data(), mime: "image/png", width: 320, height: 200, alt: "\(a.0) \(a.1) and \(b.0) \(b.1), \(n)")
        #else
        return ImageBlock(data: Data(), mime: "image/png", width: 0, height: 0, alt: nil)
        #endif
    }
}
#endif
