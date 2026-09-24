import Foundation

/// Имя App Group. При установке через SideStore/AltStore группа может переименовываться
/// (гипотеза: дописывается ID команды), и зашитое "group.widgetlab.app" перестаёт совпадать —
/// приложение и виджет не видят общих файлов. Поэтому перебираем группы из профиля подписи
/// внутри бандла (embedded.mobileprovision) и берём первую, чей контейнер реально открывается;
/// без профиля (симулятор) — базовое имя.
enum AppGroup {
    static let base = "group.widgetlab.app"

    private static let profile = ProvisioningProfile.load()

    static let identifier: String = {
        let candidates = profile.groups.sorted { a, b in
            a.hasPrefix(base) && !b.hasPrefix(base)
        } + [base]
        return candidates.first { FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: $0) != nil } ?? candidates[0]
    }()

    /// Всё, что нужно для разбора ошибки GROUP_UNAVAILABLE без угадывания.
    static var diagnostics: String {
        let bundle = Bundle.main.bundleIdentifier ?? "?"
        let profileState = profile.found ? "found" : "absent"
        let groups = profile.groups.isEmpty ? "none" : profile.groups.joined(separator: ", ")
        let team = profile.teamID ?? "?"
        return "tried \(identifier); profile \(profileState); groups: \(groups); team \(team); bundle \(bundle)"
    }

    static var source: String { profile.found ? "embedded.mobileprovision" : "base (no embedded.mobileprovision)" }

    private struct ProvisioningProfile {
        var found = false
        var groups: [String] = []
        var teamID: String?

        static func load() -> ProvisioningProfile {
            var result = ProvisioningProfile()
            guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
                  let data = try? Data(contentsOf: url) else { return result }
            result.found = true
            guard let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any]
            else { return result }
            let entitlements = plist["Entitlements"] as? [String: Any]
            result.groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
            result.teamID = (plist["TeamIdentifier"] as? [String])?.first
            return result
        }
    }
}
