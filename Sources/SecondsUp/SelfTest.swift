import Foundation

enum SelfTest {
    static func run(arguments: [String]) -> Int {
        do {
            let source = try value(after: "--source", in: arguments)
            let output = try value(after: "--output", in: arguments)
            let startText = try value(after: "--start", in: arguments)
            guard let start = Double(startText) else {
                throw SelfTestError.invalidArgument("--start")
            }

            let service = MediaService.detect()
            let sourceURL = URL(fileURLWithPath: source)
            let outputURL = URL(fileURLWithPath: output)
            let metadata = try service.probeMetadata(for: sourceURL)
            let exported = try service.exportLosslessSecond(
                source: sourceURL,
                outputFolder: outputURL,
                start: start,
                metadata: metadata
            )
            let expectedFrames = metadata.fps > 0 ? Int(metadata.fps.rounded()) : nil
            let validation = try service.validateClip(exported, expectedFrames: expectedFrames)

            print("source=\(sourceURL.path)")
            print("exported=\(exported.path)")
            print(String(format: "fps=%.3f duration=%.3f", metadata.fps, metadata.duration))
            print(validation.summary(expectedFrames: expectedFrames))
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func value(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            throw SelfTestError.missingArgument(flag)
        }
        return arguments[index + 1]
    }
}

private enum SelfTestError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let flag):
            return "Brak argumentu \(flag)."
        case .invalidArgument(let flag):
            return "Nieprawidlowa wartosc argumentu \(flag)."
        }
    }
}
