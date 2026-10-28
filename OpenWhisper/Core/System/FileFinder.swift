import AppKit
import Foundation

/// Opens the newest file a `FileQuery` describes. A folder alone ("İndirilenlerdeki son PDF")
/// is a plain listing of that folder; a name or a time ("geçen hafta düzenlediğim rapor")
/// asks Spotlight (`mdfind`), which is instant and needs nothing kept in memory.
enum FileFinder {
    static let notFound = "Dosya bulunamadı"

    static func open(_ query: FileQuery) async -> String {
        let found = await Task.detached(priority: .userInitiated) { newest(query) }.value
        guard let url = found else {
            owLog("[Files] Nothing for \(query)")
            return notFound
        }
        owLog("[Files] Opening \(url.path)")
        return NSWorkspace.shared.open(url) ? "Açılıyor: \(url.lastPathComponent)" : "\(url.lastPathComponent) açılamadı"
    }

    nonisolated static func newest(_ query: FileQuery, now: Date = Date()) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = query.folder.map { home.appendingPathComponent(folderName($0)) }
        let candidates: [URL]
        if let folder, query.name == nil, query.period == nil {
            candidates = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .addedToDirectoryDateKey],
                options: [.skipsHiddenFiles])) ?? []
        } else {
            candidates = spotlight(query, in: folder ?? home, now: now)
        }
        let range = query.period.map { period(of: $0, now: now) }
        return candidates
            .filter { url in
                // Folders are no answer; a Pages or Keynote package is a document.
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return !url.path.contains("/Library/") && !url.path.contains("/.") && url.pathExtension != "app"
                    && (values?.isDirectory != true || values?.isPackage == true)
            }
            .filter { url in query.kind.map { extensions(of: $0).contains(url.pathExtension.lowercased()) } ?? true }
            .compactMap { url -> (URL, Date)? in
                guard let date = date(of: url, downloads: query.folder == .downloads) else { return nil }
                if let range, !range.contains(date) { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }?.0
    }

    private nonisolated static func spotlight(_ query: FileQuery, in folder: URL, now: Date) -> [URL] {
        var terms: [String] = []
        if let name = query.name {
            let safe = name.replacingOccurrences(of: #"["\\*]"#, with: "", options: .regularExpression)
            terms.append(#"kMDItemFSName == "*\#(safe)*"cd"#)
        }
        if let period = query.period {
            terms.append("kMDItemFSContentChangeDate >= $time.iso(\(ISO8601DateFormatter().string(from: self.period(of: period, now: now).lowerBound)))")
        }
        if terms.isEmpty, let kind = query.kind {
            terms.append("(" + extensions(of: kind).map { #"kMDItemFSName == "*.\#($0)"c"# }.joined(separator: " || ") + ")")
        }
        // "Son düzenlediğim dosya": what the user opened this past week, so build output and
        // caches, which no one opens, stay out.
        if terms.isEmpty {
            terms.append("kMDItemLastUsedDate >= $time.iso(\(ISO8601DateFormatter().string(from: now.addingTimeInterval(-7 * 86400))))")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", folder.path, terms.joined(separator: " && ")]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .prefix(2000).map { URL(fileURLWithPath: String($0)) }
    }

    /// Downloads go by when they arrived; everything else by when it was last changed.
    private nonisolated static func date(of url: URL, downloads: Bool) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .addedToDirectoryDateKey])
        return downloads ? values?.addedToDirectoryDate ?? values?.contentModificationDate : values?.contentModificationDate
    }

    private nonisolated static func folderName(_ folder: FileQuery.Folder) -> String {
        switch folder {
        case .downloads: "Downloads"
        case .desktop: "Desktop"
        case .documents: "Documents"
        }
    }

    nonisolated static func extensions(of kind: FileQuery.Kind) -> Set<String> {
        switch kind {
        case .pdf: ["pdf"]
        case .word: ["doc", "docx", "pages", "rtf", "odt"]
        case .spreadsheet: ["xls", "xlsx", "numbers", "csv", "ods"]
        case .presentation: ["ppt", "pptx", "key", "odp"]
        case .image: ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"]
        case .video: ["mp4", "mov", "m4v", "mkv", "avi"]
        case .archive: ["zip", "rar", "7z", "tar", "gz", "dmg"]
        }
    }

    /// Weeks start on Monday, as in Turkey.
    nonisolated static func period(of period: FileQuery.Period, now: Date) -> Range<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: now)
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let month = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let end = now.addingTimeInterval(60)
        switch period {
        case .today: return today..<end
        case .yesterday: return calendar.date(byAdding: .day, value: -1, to: today)!..<today
        case .thisWeek: return week..<end
        case .lastWeek: return calendar.date(byAdding: .day, value: -7, to: week)!..<week
        case .thisMonth: return month..<end
        case .lastMonth: return calendar.date(byAdding: .month, value: -1, to: month)!..<month
        }
    }
}
