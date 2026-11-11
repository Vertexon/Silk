import Foundation
import WebKit

/// Locates and loads the headless host document from the app bundle.
///
/// Xcode's synchronized folders may either preserve the `Web` subdirectory or
/// flatten resources into the bundle root, so every lookup tries both shapes.
enum WebHostAssets {
    static let messageHandlerName = "spyder"

    static func load(into webView: WKWebView) throws {
        if let htmlURL = locate(name: "host", extension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
            return
        }

        guard
            let scriptURL = locate(name: "bootstrap", extension: "js"),
            let script = try? String(contentsOf: scriptURL, encoding: .utf8)
        else {
            throw BridgeError.hostPageMissing
        }

        webView.loadHTMLString(inlineDocument(script: script), baseURL: Bundle.main.bundleURL)
    }

    static func locate(name: String, extension fileExtension: String) -> URL? {
        let subdirectories: [String?] = [nil, "Web", "Resources", "Resources/Web"]
        for subdirectory in subdirectories {
            if let url = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory) {
                return url
            }
        }

        let flat = Bundle.main.bundleURL.appendingPathComponent("\(name).\(fileExtension)")
        if FileManager.default.fileExists(atPath: flat.path) {
            return flat
        }
        return nil
    }

    /// Used when `host.html` is missing but `bootstrap.js` was bundled.
    private static func inlineDocument(script: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden;}</style>
        </head>
        <body>
        <script>
        \(script)
        </script>
        </body>
        </html>
        """
    }
}
