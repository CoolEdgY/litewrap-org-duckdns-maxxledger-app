import SwiftUI
import UIKit

/// Everything app-specific comes from litewrap.json, written by LiteWrap at build time.
struct AppConfig: Decodable {
    struct Health: Decodable {
        let enabled: Bool
        let types: [String]
        let tokenHeader: String?
    }

    let name: String
    let startUrl: String
    let themeColor: String?
    let backgroundColor: String?
    let health: Health

    static let shared: AppConfig = {
        guard let url = Bundle.main.url(forResource: "litewrap", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            fatalError("litewrap.json is missing or invalid")
        }
        return config
    }()

    var startURL: URL { URL(string: startUrl) ?? URL(string: "https://example.com")! }
    var host: String { startURL.host?.lowercased() ?? "" }
    var tokenHeader: String { health.tokenHeader ?? "X-LiteWrap-Token" }

    var theme: Color { Color(uiColor: UIColor(hex: themeColor ?? "") ?? .systemBackground) }
    var background: Color { Color(uiColor: UIColor(hex: backgroundColor ?? themeColor ?? "") ?? .systemBackground) }
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}
