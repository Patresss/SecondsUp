import Foundation

enum MediaError: LocalizedError {
    case toolMissing(String)
    case commandFailed(String, String)
    case invalidJSON
    case noVideoStream
    case noDateInFileName
    case invalidExport(String)
    case cannotCreateImage
    case cancelled
    case emptyRender
    case incompatibleClips(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing(let name):
            return "\(name) nie zostal znaleziony."
        case .commandFailed(let command, let stderr):
            return stderr.isEmpty ? "Polecenie nie powiodlo sie: \(command)" : stderr
        case .invalidJSON:
            return "Nie udalo sie odczytac danych ffprobe."
        case .noVideoStream:
            return "Plik nie ma strumienia video."
        case .noDateInFileName:
            return "Nazwa pliku nie zawiera daty yyyy-mm-dd."
        case .invalidExport(let details):
            return "Eksport nie przeszedl walidacji: \(details)"
        case .cannotCreateImage:
            return "Nie udalo sie odczytac klatki podgladu."
        case .cancelled:
            return "Operacja przerwana."
        case .emptyRender:
            return "Brak klipow do zmontowania."
        case .incompatibleClips(let details):
            return "Tryb bezstratny wymaga identycznych parametrow wszystkich klipow "
                + "(kodek, rozdzielczosc, kolor). Odstajace klipy: \(details). "
                + "Uzyj trybu H.264 albo ProRes, ktory ujednolica klipy."
        }
    }
}

struct ToolSet: Sendable {
    let ffmpegURL: URL?
    let ffprobeURL: URL?

    var isReady: Bool {
        ffmpegURL != nil && ffprobeURL != nil
    }

    var statusText: String {
        if isReady {
            return "ffmpeg OK"
        }
        if ffmpegURL == nil && ffprobeURL == nil {
            return "Brak ffmpeg i ffprobe"
        }
        if ffmpegURL == nil {
            return "Brak ffmpeg"
        }
        return "Brak ffprobe"
    }

    static func detect() -> ToolSet {
        ToolSet(
            ffmpegURL: findExecutable("ffmpeg"),
            ffprobeURL: findExecutable("ffprobe")
        )
    }

    static func findExecutable(_ name: String) -> URL? {
        let candidatePaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]

        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for folder in pathValue.split(separator: ":") {
            let path = String(folder) + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }
}

enum FFmpegRunner {
    @discardableResult
    static func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        return try execute(process)
    }

    @discardableResult
    static func execute(_ process: Process) throws -> Data {
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let command = ([process.executableURL?.path ?? "?"] + (process.arguments ?? []))
                .joined(separator: " ")
            let stderr = String(data: errorData, encoding: .utf8) ?? ""
            throw MediaError.commandFailed(command, stderr)
        }

        return outputData
    }
}
