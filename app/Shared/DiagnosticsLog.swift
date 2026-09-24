import Foundation

struct DiagnosticEvent: Codable {
    let time: Date
    let event: String
    let projectID: UUID?
    let detail: String
}

final class DiagnosticsLog {
    private let url: URL
    private let maxBytes: Int

    init(root: URL, maxBytes: Int = AnimationBudget.standard.maxLogBytes) {
        url = root.appendingPathComponent("diagnostics.jsonl")
        self.maxBytes = maxBytes
    }

    func append(event: String, projectID: UUID?, detail: String) {
        let entry = DiagnosticEvent(time: .now, event: event,
                                    projectID: projectID, detail: detail)
        guard let line = try? JSONEncoder().encode(entry) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let previous = (try? Data(contentsOf: url)) ?? Data()
            var lines = previous.split(separator: 10).map { Data($0) }
            lines.append(line)
            var output = Data()
            for item in lines.reversed() {
                if output.count + item.count + 1 > maxBytes { break }
                output.insert(10, at: 0)
                output.insert(contentsOf: item, at: 0)
            }
            try output.write(to: url, options: .atomic)
        } catch {
            // Diagnostics must never hide the original publication or read error.
        }
    }

    func read() -> [DiagnosticEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 10).compactMap {
            try? JSONDecoder().decode(DiagnosticEvent.self, from: Data($0))
        }
    }
}
