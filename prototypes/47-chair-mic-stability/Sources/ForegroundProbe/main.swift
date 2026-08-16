import Foundation

struct ForegroundProbe {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else {
            throw ProbeError.invalidArguments(usage)
        }
        let options = try parseOptions(Array(arguments.dropFirst()))
        switch command {
        case "inventory":
            let document = inventoryDocument()
            if let path = options["output"] {
                let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try writeJSON(document, to: url)
                print(url.path)
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(document), as: UTF8.self))
            }

        case "capture":
            guard Bundle.main.bundleIdentifier == "dev.clickai.grabrabbit.prototype.foreground47" else {
                throw ProbeError.invalidArguments("Capture must run from the signed app produced by scripts/build-capture-app.sh so Camera TCC has a stable identity.")
            }
            let deviceID = try required("device-id", options)
            let clipID = try required("clip-id", options)
            let lighting = try required("lighting", options)
            let output = URL(fileURLWithPath: NSString(string: try required("output", options)).expandingTildeInPath)
            _ = try await captureClip(
                deviceID: deviceID,
                clipID: clipID,
                lighting: lighting,
                outputDirectory: output
            )

        case "process":
            let manifest = URL(fileURLWithPath: NSString(string: try required("manifest", options)).expandingTildeInPath)
            let output = URL(fileURLWithPath: NSString(string: try required("output", options)).expandingTildeInPath)
            let result = try await processExperiment(manifestURL: manifest, outputDirectory: output)
            print("Processed \(result.clips.count) clip(s).")
            print("Run manifest: \(output.appendingPathComponent("run-manifest.json").path)")
            if !result.coverageGaps.isEmpty {
                print("Coverage gaps recorded: \(result.coverageGaps.count)")
            }

        case "help", "--help", "-h":
            print(usage)

        default:
            throw ProbeError.invalidArguments("Unknown command \(command)\n\n\(usage)")
        }
    }

    private static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--"), argument.count > 2 else {
                throw ProbeError.invalidArguments("Expected --name value, got \(argument)")
            }
            guard index + 1 < arguments.count else {
                throw ProbeError.invalidArguments("Missing value for \(argument)")
            }
            let name = String(argument.dropFirst(2))
            guard options[name] == nil else {
                throw ProbeError.invalidArguments("Duplicate option --\(name)")
            }
            options[name] = arguments[index + 1]
            index += 2
        }
        return options
    }

    private static func required(_ name: String, _ options: [String: String]) throws -> String {
        guard let value = options[name], !value.isEmpty else {
            throw ProbeError.invalidArguments("Missing required option --\(name)")
        }
        return value
    }

    private static let usage = """
    Grab Rabbit Q11 foreground stability prototype

      foreground-probe inventory [--output /absolute/path/inventory.json]

      foreground-probe capture \\
        --device-id EXACT_AVFOUNDATION_UNIQUE_ID \\
        --clip-id SOURCE-LIGHTING \\
        --lighting DESCRIPTION \\
        --output /absolute/path/to/captures

      foreground-probe process \\
        --manifest /absolute/path/to/experiment.json \\
        --output /absolute/path/to/evidence-directory

    Capture is fixed at 32 seconds with audible/printed stillness, speaking,
    occlusion, and chair-motion cues. Process runs P0 and P1 once on every source
    frame and writes full synchronized video, raw JSONL measurements, summaries,
    and a visual-review worksheet. It never infers a quality threshold or verdict.
    """
}

await ForegroundProbe.main()
