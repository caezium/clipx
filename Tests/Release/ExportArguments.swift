import Foundation

/// Exercise production export arguments without launching a GUI test host.
@main
struct ExportArguments {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
              let preset = ExportPreset.allBuiltIn.first(where: { $0.id == arguments[3] }) else {
            throw NSError(domain: "clipx.release-test", code: 1)
        }
        let ffmpeg = FFmpegBackend.buildArguments(
            sourcePath: arguments[1], inMs: 1000, outMs: 3000,
            preset: preset, outputPath: arguments[2], rotation: 90, speed: 2
        )
        FileHandle.standardOutput.write(try JSONEncoder().encode(ffmpeg))
    }
}
