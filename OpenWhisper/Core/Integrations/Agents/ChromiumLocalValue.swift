import Foundation

/// Read-only lookup of one Chromium local-storage key. Never opens/locks or repairs the
/// application's live LevelDB. Sequence numbers include tombstones, so an old table cannot
/// resurrect a deleted value. All offsets and decompression sizes are bounded.
enum ChromiumLocalValue {
    static func read(directory: URL, origin: String, key: String) -> String? {
        let wanted = Data(("_" + origin + "\0\u{1}" + key).utf8)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        var latest: (UInt64, Data?)?
        func accept(_ sequence: UInt64, _ key: Data, _ value: Data?) {
            guard key == wanted, sequence >= (latest?.0 ?? 0) else { return }
            latest = (sequence, value)
        }
        for url in files where ["ldb", "sst", "log"].contains(url.pathExtension) {
            guard let data = try? Data(contentsOf: url), data.count <= 32_000_000 else { continue }
            let b = [UInt8](data)
            if url.pathExtension == "log" {
                for record in logRecords(b) {
                    let r = [UInt8](record)
                    guard r.count >= 12 else { continue }
                    let sequence = little(r, 0, 8), count = little(r, 8, 4)
                    guard count <= 100_000 else { continue }
                    var p = 12
                    for i in 0..<count {
                        guard p < r.count else { break }
                        let type = r[p]; p += 1
                        guard let key = field(r, &p) else { break }
                        if type == 0 { accept(sequence + i, key, nil) }
                        else if type == 1, let value = field(r, &p) { accept(sequence + i, key, value) }
                        else { break }
                    }
                }
            } else {
                guard b.count >= 48, little(b, b.count - 8, 8) == 0xdb4775248b80fb57 else { continue }
                var p = b.count - 48
                guard varint(b, &p) != nil, varint(b, &p) != nil,
                      let offset = varint(b, &p), let size = varint(b, &p),
                      let index = block(b, offset, size) else { continue }
                for (_, handle) in entries(index) {
                    var h = 0; let bytes = [UInt8](handle)
                    guard let offset = varint(bytes, &h), let size = varint(bytes, &h),
                          let payload = block(b, offset, size) else { continue }
                    for (key, value) in entries(payload) where key.count >= 8 {
                        let k = [UInt8](key), tag = little(k, k.count - 8, 8)
                        guard tag & 255 <= 1 else { continue }
                        accept(tag >> 8, Data(k.dropLast(8)), tag & 255 == 0 ? nil : value)
                    }
                }
            }
        }
        guard let data = latest?.1, let encoding = data.first else { return nil }
        if encoding == 1 { return String(data: data.dropFirst(), encoding: .utf8) }
        if encoding == 0 { return String(data: data.dropFirst(), encoding: .utf16LittleEndian) }
        return nil
    }

    static func little(_ b: [UInt8], _ p: Int, _ n: Int) -> UInt64 {
        guard p >= 0, n <= 8, p <= b.count - n else { return 0 }
        return (0..<n).reduce(0) { $0 | UInt64(b[p + $1]) << ($1 * 8) }
    }
    static func varint(_ b: [UInt8], _ p: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard p < b.count else { return nil }
            let byte = b[p]; p += 1
            if shift == 63 && byte > 1 { return nil }
            value |= UInt64(byte & 127) << shift
            if byte < 128 { return value }
        }
        return nil
    }
    static func field(_ b: [UInt8], _ p: inout Int) -> Data? {
        guard let length = varint(b, &p), length <= UInt64(b.count - p) else { return nil }
        defer { p += Int(length) }
        return Data(b[p..<p + Int(length)])
    }
    static func logRecords(_ b: [UInt8]) -> [Data] {
        var records: [Data] = [], fragment = Data(), assembling = false, p = 0
        while p + 7 <= b.count {
            let remaining = 32768 - p % 32768
            if remaining < 7 { p += remaining; continue }
            let length = Int(little(b, p + 4, 2)), type = b[p + 6]
            guard length <= remaining - 7, p + 7 + length <= b.count else { break }
            let data = Data(b[p + 7..<p + 7 + length]); p += 7 + length
            switch type {
            case 1: records.append(data); fragment = Data(); assembling = false
            case 2: fragment = data; assembling = true
            case 3: if assembling { fragment.append(data) }
            case 4: if assembling { fragment.append(data); records.append(fragment) }; fragment = Data(); assembling = false
            default: fragment = Data(); assembling = false
            }
        }
        return records
    }
    static func block(_ b: [UInt8], _ offset: UInt64, _ size: UInt64) -> [UInt8]? {
        guard offset < UInt64(b.count), size < UInt64(b.count) - offset,
              size <= 32_000_000 else { return nil }
        let p = Int(offset), n = Int(size), payload = Array(b[p..<p+n])
        switch b[p+n] { case 0: return payload; case 1: return unsnappy(payload); default: return nil }
    }
    static func entries(_ b: [UInt8]) -> [(Data, Data)] {
        guard b.count >= 4 else { return [] }
        let restarts = little(b, b.count - 4, 4)
        guard restarts <= UInt64((b.count - 4) / 4) else { return [] }
        let end = b.count - 4 - Int(restarts) * 4
        var p = 0, previous: [UInt8] = [], result: [(Data, Data)] = []
        while p < end {
            guard let shared = varint(b, &p), let added = varint(b, &p), let length = varint(b, &p),
                  shared <= UInt64(previous.count), p <= end, added <= UInt64(end - p),
                  length <= UInt64(end - p) - added else { return [] }
            let key = Array(previous.prefix(Int(shared))) + b[p..<p+Int(added)]; p += Int(added)
            let value = Data(b[p..<p+Int(length)]); p += Int(length)
            result.append((Data(key), value)); previous = key
        }
        return result
    }
    static func unsnappy(_ b: [UInt8]) -> [UInt8]? {
        var p = 0
        guard let size = varint(b, &p), size <= 32_000_000 else { return nil }
        var output: [UInt8] = []; output.reserveCapacity(Int(size))
        while p < b.count && output.count < size {
            let tag = b[p]; p += 1
            var length: Int, offset = 0
            switch tag & 3 {
            case 0:
                length = Int(tag >> 2) + 1
                if length > 60 {
                    let n = length - 60
                    guard p + n <= b.count else { return nil }
                    length = Int(little(b, p, n)) + 1; p += n
                }
                guard length <= b.count - p, length <= Int(size) - output.count else { return nil }
                output += b[p..<p+length]; p += length; continue
            case 1:
                guard p < b.count else { return nil }
                length = Int((tag >> 2) & 7) + 4
                offset = Int(tag & 224) << 3 | Int(b[p]); p += 1
            case 2, 3:
                let n = tag & 3 == 2 ? 2 : 4
                guard p + n <= b.count else { return nil }
                length = Int(tag >> 2) + 1; offset = Int(little(b, p, n)); p += n
            default: return nil
            }
            guard offset > 0, offset <= output.count, length <= Int(size) - output.count else { return nil }
            for _ in 0..<length { output.append(output[output.count - offset]) }
        }
        return output.count == size ? output : nil
    }
}
