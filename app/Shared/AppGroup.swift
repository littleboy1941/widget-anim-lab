import Foundation

/// Имя App Group. При установке через SideStore/AltStore группа переименовывается
/// (дописывается ID команды), и зашитое "group.widgetlab.app" перестаёт совпадать —
/// приложение и виджет не видят общих файлов. Поэтому настоящее имя берём из профиля
/// подписи внутри бандла (embedded.mobileprovision), а без профиля (симулятор) — базовое.
enum AppGroup {
    static let base = "group.widgetlab.app"

    static let identifier: String = {
        let groups = provisionedGroups()
        if let match = groups.first(where: { $0.hasPrefix(base) }) { return match }
        if let any = groups.first { return any }
        return base
    }()

    /// Откуда взято имя — для dev-панели и журнала.
    static var source: String {
        provisionedGroups().isEmpty ? "base (no embedded.mobileprovision)" : "embedded.mobileprovision"
    }

    private static func provisionedGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }
}
