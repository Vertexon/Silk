import Foundation

/// Describes where Pyodide lives and what to preload.
///
/// The loader prefers a Pyodide distribution copied into the app bundle and
/// falls back to a pinned jsDelivr build. Bundling makes the IDE fully offline;
/// the CDN keeps a fresh checkout runnable without a 30 MB download step.
struct PyodideConfiguration {
    var bundledIndexURLs: [String]
    var remoteIndexURLs: [String]
    var packages: [String]
    var dpi: Int

    var indexURLs: [String] { bundledIndexURLs + remoteIndexURLs }

    static var live: PyodideConfiguration {
        PyodideConfiguration(
            bundledIndexURLs: bundledIndexURLs(),
            remoteIndexURLs: remoteIndexURLs(),
            packages: ["numpy", "matplotlib", "scipy", "pandas", "sympy"],
            dpi: 120
        )
    }

    func bridgeJSON() throws -> String {
        let payload: [String: Any] = [
            "indexURLs": indexURLs,
            "packages": packages,
            "dpi": dpi,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw BridgeError.encodingFailed
        }
        return string
    }

    // MARK: Location resolution

    private static func bundledIndexURLs() -> [String] {
        var urls: [String] = []
        let names = ["pyodide", "Pyodide"]
        let subdirectories: [String?] = [nil, "Web", "Resources", "Resources/Web"]

        for name in names {
            for subdirectory in subdirectories {
                if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: subdirectory) {
                    urls.append(indexURL(for: url))
                }
            }
            let raw = Bundle.main.bundleURL.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: raw.path) {
                urls.append(indexURL(for: raw))
            }
        }
        return uniqued(urls)
    }

    private static func remoteIndexURLs() -> [String] {
        // Pin the runtime. Override with the `SpyderPyodideIndexURL` Info.plist
        // key or the same UserDefaults key when developing against a fork.
        let pinned = "https://cdn.jsdelivr.net/pyodide/v314.0.7/full/"
        let override = UserDefaults.standard.string(forKey: "SpyderPyodideIndexURL")
            ?? (Bundle.main.object(forInfoDictionaryKey: "SpyderPyodideIndexURL") as? String)

        var urls: [String] = []
        if let override, !override.isEmpty, let overrideURL = URL(string: override) {
            urls.append(indexURL(for: overrideURL))
        }
        urls.append(pinned)
        return uniqued(urls)
    }

    private static func indexURL(for directory: URL) -> String {
        var string = directory.absoluteString
        if !string.hasSuffix("/") { string += "/" }
        return string
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

enum BridgeError: LocalizedError {
    case encodingFailed
    case bridgeMissing
    case hostPageMissing

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode the JavaScript bridge payload."
        case .bridgeMissing:
            return "The Pyodide bridge script did not load. Add the Web folder to the app target's Copy Bundle Resources build phase."
        case .hostPageMissing:
            return "The Pyodide host page is missing from the app bundle."
        }
    }
}
