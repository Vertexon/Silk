import Foundation

/// One message posted from JavaScript through `webkit.messageHandlers.spyder`.
/// Every field except `type` is optional so a single type can describe the
/// whole bridge protocol.
struct BridgeMessage: Decodable {
    let type: String
    let id: String?
    let ok: Bool?
    let error: String?
    let durationMs: Double?
    let text: String?
    let stream: String?
    let detail: String?
    let version: String?
    let packages: [String]?
    let message: String?
    let variables: [VariablePayload]?
    let plots: [PlotPayload]?
    let preview: VariablePreviewPayload?
    let help: SymbolHelpPayload?
    let name: String?
    let removed: Bool?
    let files: [FilePayload]?
    let base64: String?
    let size: Int?
    let count: Int?

    init?(body: Any) {
        guard
            let dictionary = body as? [String: Any],
            dictionary["type"] is String,
            let data = try? JSONSerialization.data(withJSONObject: dictionary),
            let decoded = try? JSONDecoder().decode(BridgeMessage.self, from: data)
        else {
            return nil
        }
        self = decoded
    }
}

struct VariablePayload: Decodable, Sendable {
    let name: String?
    let type: String?
    let shape: String?
    let summary: String?
    let kind: String?
}

struct PlotPayload: Decodable, Sendable {
    let png: String
    let width: Int?
    let height: Int?
    let figure: Int?
}

struct VariablePreviewPayload: Decodable, Sendable {
    let name: String?
    let kind: String?
    let columns: [String]?
    let rows: [[String]]?
    let totalRows: Int?
    let totalColumns: Int?
    let note: String?
    let repr: String?
    let error: String?
}

struct FilePayload: Decodable, Sendable {
    let name: String?
    let size: Int?
}

struct SymbolHelpPayload: Decodable, Sendable {
    let symbol: String?
    let title: String?
    let signature: String?
    let module: String?
    let doc: String?
    let error: String?
}
