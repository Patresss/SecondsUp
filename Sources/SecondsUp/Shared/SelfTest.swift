import Foundation

enum SelfTest {
    static func run(arguments: [String]) -> Int {
        if arguments.contains("--analyze") {
            return runAnalyze(arguments: arguments)
        }
        if arguments.contains("--montage") {
            return runMontage(arguments: arguments)
        }
        return runExport(arguments: arguments)
    }

    private static func runAnalyze(arguments: [String]) -> Int {
        do {
            let source = try value(after: "--source", in: arguments)
            let service = MediaService()
            let sourceURL = URL(fileURLWithPath: source)
            let metadata = try service.probeMetadata(for: sourceURL)
            let keyframes = (try? service.keyframes(for: sourceURL)) ?? [0]
            let started = Date()
            let analysis = try VideoAnalyzer.analyze(
                url: sourceURL,
                metadata: metadata,
                keyframes: keyframes
            )
            let elapsed = Date().timeIntervalSince(started)

            print("source=\(sourceURL.path)")
            print(String(format: "duration=%.3f fps=%.3f", metadata.duration, metadata.fps))
            print("keyframes=\(analysis.keyframes.count) samples=\(analysis.sampleCount) waveform=\(analysis.waveform.count)")
            for (index, candidate) in analysis.candidates.enumerated() {
                print(String(
                    format: "candidate[%d] start=%.3f score=%.3f reason=%@",
                    index,
                    candidate.start,
                    candidate.score,
                    candidate.reason
                ))
            }
            print(String(format: "elapsed=%.2fs", elapsed))
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func runMontage(arguments: [String]) -> Int {
        do {
            let folder = try value(after: "--folder", in: arguments)
            let output = try value(after: "--output", in: arguments)
            let folderURL = URL(fileURLWithPath: folder)
            let outputURL = URL(fileURLWithPath: output)

            var settings = MontageSettings()
            settings.titleEnabled = true
            settings.titleText = "SecondsUp test"
            settings.titleDuration = 1.0
            if let music = try? value(after: "--music", in: arguments) {
                settings.musicPath = music
            }

            var clips: [(url: URL, caption: String)] = []
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where MediaService.videoExtensions.contains(url.pathExtension.lowercased()) {
                clips.append((url, DateParser.captionText(for: url.lastPathComponent)))
            }

            let renderer = MontageRenderer(tools: .detect())
            let result = try renderer.render(
                clips: clips,
                settings: settings,
                output: outputURL,
                onProgress: { update in
                    print(String(format: "[%3.0f%%] %@", update.fraction * 100, update.stage))
                }
            )
            let duration = try renderer.probeDuration(of: result)
            print("montage=\(result.path)")
            print(String(format: "duration=%.3f clips=%d", duration, clips.count))
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func runExport(arguments: [String]) -> Int {
        do {
            let source = try value(after: "--source", in: arguments)
            let output = try value(after: "--output", in: arguments)
            let startText = try value(after: "--start", in: arguments)
            guard let start = Double(startText) else {
                throw SelfTestError.invalidArgument("--start")
            }

            let service = MediaService()
            let sourceURL = URL(fileURLWithPath: source)
            let outputURL = URL(fileURLWithPath: output)
            let metadata = try service.probeMetadata(for: sourceURL)
            let keyframes = (try? service.keyframes(for: sourceURL)) ?? [0]
            let result = try service.exportSecond(
                source: sourceURL,
                outputFolder: outputURL,
                start: start,
                metadata: metadata,
                keyframes: keyframes
            )
            let expectedFrames = metadata.fps > 0 ? Int(metadata.fps.rounded()) : nil
            let validation = try service.validateClip(
                result.url,
                expectedFrames: expectedFrames,
                method: result.method
            )

            print("source=\(sourceURL.path)")
            print("exported=\(result.url.path)")
            print("method=\(result.method.rawValue)")
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
