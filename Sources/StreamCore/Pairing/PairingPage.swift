import Foundation

public struct PairingFieldState: Sendable {
    public let name: String
    public let label: String
    public let isSet: Bool
    public let result: String?

    public init(name: String, label: String, isSet: Bool, result: String?) {
        self.name = name
        self.label = label
        self.isSet = isSet
        self.result = result
    }
}

/// The phone-facing form: inline CSS, no scripts, no external resources.
public enum PairingPage {
    public static func html(fields: [PairingFieldState], token: String) -> String {
        var rows = ""
        for f in fields {
            let name = esc(f.name)
            rows += "<label for=\"\(name)\">\(esc(f.label))</label>\n"
            if f.name == "addonURLs" {
                rows += "<textarea id=\"\(name)\" name=\"\(name)\" rows=\"4\" placeholder=\"One manifest URL per line\"></textarea>\n"
            } else {
                rows += "<input id=\"\(name)\" name=\"\(name)\" type=\"text\" autocapitalize=\"off\" autocorrect=\"off\" spellcheck=\"false\" placeholder=\"\(f.isSet ? "Saved - leave blank to keep" : "Not set")\">\n"
            }
            if f.isSet {
                rows += "<div class=\"clear\"><input id=\"clear_\(name)\" name=\"clear_\(name)\" type=\"checkbox\"> <label for=\"clear_\(name)\">Clear saved value</label></div>\n"
            }
            if let r = f.result { rows += "<p class=\"result\">\(esc(r))</p>\n" }
        }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Riptide setup</title>
        <style>
        body{font:17px -apple-system,system-ui,sans-serif;margin:0 auto;padding:16px;max-width:560px}
        label{display:block;margin:16px 0 4px;font-weight:600}
        input[type=text],textarea{width:100%;box-sizing:border-box;font-size:17px;padding:12px;border:1px solid #888;border-radius:8px}
        .clear label{display:inline;font-weight:400}
        .result{margin:6px 0 0;color:#555}
        button{width:100%;margin-top:24px;padding:14px;font-size:18px;border-radius:8px;border:0;background:#0a84ff;color:#fff}
        </style></head><body>
        <h1>Riptide setup</h1>
        <form method="post" action="/\(esc(token))">
        \(rows)<button type="submit">Send to TV</button>
        </form></body></html>
        """
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
