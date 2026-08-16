import CoreMedia
import CryptoKit
import Darwin
import Foundation

let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func nowString() -> String {
    iso8601Formatter.string(from: Date())
}

func writeJSON<T: Encodable>(_ value: T, to url: URL, pretty: Bool = true) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try data.write(to: url, options: .atomic)
}

func appendJSONLine<T: Encodable>(_ value: T, to handle: FileHandle) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    try handle.write(contentsOf: data)
}

func resolvePath(_ path: String, relativeTo directory: URL) -> URL {
    let expanded = NSString(string: path).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
    return directory.appendingPathComponent(expanded).standardizedFileURL
}

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func artifactRecord(for url: URL) throws -> ArtifactRecord {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    return ArtifactRecord(path: url.path, sha256: try sha256(of: url), bytes: bytes)
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
        return "unknown"
    }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
        return "unknown"
    }
    return String(cString: value)
}

func hostSnapshot() -> HostSnapshot {
    let info = ProcessInfo.processInfo
    let version = info.operatingSystemVersion
    return HostSnapshot(
        computerName: Host.current().localizedName ?? "unknown",
        hostName: info.hostName,
        hardwareModel: sysctlString("hw.model"),
        architecture: sysctlString("hw.machine"),
        operatingSystem: info.operatingSystemVersionString,
        operatingSystemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    )
}

func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

func thermalStateString() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

func fourCCString(_ value: OSType) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
    return String(format: "0x%08x", value)
}

func millisecondsSince(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func distribution(_ values: [Double]) -> NumericDistribution {
    guard !values.isEmpty else {
        return NumericDistribution(count: 0, minimum: 0, mean: 0, median: 0, percentile95: 0, maximum: 0)
    }
    let sorted = values.sorted()
    func percentile(_ fraction: Double) -> Double {
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[max(0, min(index, sorted.count - 1))]
    }
    return NumericDistribution(
        count: values.count,
        minimum: sorted[0],
        mean: values.reduce(0, +) / Double(values.count),
        median: percentile(0.5),
        percentile95: percentile(0.95),
        maximum: sorted[sorted.count - 1]
    )
}

func runCommand(_ executable: String, _ arguments: [String], directory: URL? = nil) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return nil
    }
}
