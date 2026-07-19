import Foundation

/// Builds the on-disk destination for a downloaded file, laid out
/// Infuse-style: Movies/<Title> (<Year>)/… and Shows/<Show>/Season NN/….
public enum DownloadPaths {
    public static func destination(root: URL, for item: LibraryItem) -> URL {
        destination(root: root, mediaKind: item.mediaKind, title: item.title,
                    year: item.year, season: item.season, filename: item.filename)
    }

    public static func destination(root: URL, mediaKind: String, title: String,
                                   year: Int?, season: Int?, filename: String) -> URL {
        let file = filename   // preserved verbatim (release name + extension)
        switch mediaKind {
        case "movie":
            let folder = year.map { "\(title) (\($0))" } ?? title
            return root.appendingPathComponent("Movies")
                .appendingPathComponent(sanitize(folder))
                .appendingPathComponent(file)
        default:
            guard let season else {
                return root.appendingPathComponent(file)   // no parsed season
            }
            let seasonFolder = season == 0 ? "Specials" : String(format: "Season %02d", season)
            return root.appendingPathComponent("Shows")
                .appendingPathComponent(sanitize(title))
                .appendingPathComponent(seasonFolder)
                .appendingPathComponent(file)
        }
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
         .replacingOccurrences(of: ":", with: "-")
    }
}
