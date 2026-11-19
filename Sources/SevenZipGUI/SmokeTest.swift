import Foundation

/// End-to-end check of the bundled engine, used by `build-app.sh --smoke-test`.
enum SmokeTest {
    static func run() async -> Bool {
        guard let binary = SevenZipLocator.locate() else {
            print("FAIL: 7zz not found")
            return false
        }
        print("PASS: engine at \(binary.path)")

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("sevenzipgui-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        do {
            let source = root.appendingPathComponent("source", isDirectory: true)
            try fileManager.createDirectory(at: source, withIntermediateDirectories: true)

            let hello = Data("hello from SevenZip GUI\n".utf8)
            let noise = Data((0..<256_000).map { _ in UInt8.random(in: 0...255) })
            try hello.write(to: source.appendingPathComponent("hello.txt"))
            try noise.write(to: source.appendingPathComponent("noise.bin"))
            try fileManager.createDirectory(
                at: source.appendingPathComponent("nested", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("nested file\n".utf8).write(to: source.appendingPathComponent("nested/inner.txt"))

            // 7z round trip
            let sevenZip = root.appendingPathComponent("archive.7z")
            let createResult = try await SevenZipRunner().run(
                arguments: SevenZipCommand.compress(
                    sources: [source],
                    output: sevenZip,
                    format: .sevenZip,
                    level: 5,
                    password: "",
                    encryptFileNames: false
                )
            )
            guard fileManager.fileExists(atPath: sevenZip.path),
                  (try fileManager.attributesOfItem(atPath: sevenZip.path)[.size] as? Int ?? 0) > 0 else {
                print("FAIL: 7z archive was not created")
                return false
            }
            print("PASS: created 7z (\(createResult.output.contains("Everything is Ok") ? "reported ok" : "archive present"))")

            let sevenZipOut = root.appendingPathComponent("out-7z", isDirectory: true)
            _ = try await SevenZipRunner().run(
                arguments: SevenZipCommand.extract(
                    archive: sevenZip,
                    destination: sevenZipOut,
                    password: ""
                )
            )
            guard try Data(contentsOf: sevenZipOut.appendingPathComponent("source/hello.txt")) == hello,
                  try Data(contentsOf: sevenZipOut.appendingPathComponent("source/noise.bin")) == noise,
                  try Data(contentsOf: sevenZipOut.appendingPathComponent("source/nested/inner.txt"))
                    == Data("nested file\n".utf8) else {
                print("FAIL: 7z round trip content mismatch")
                return false
            }
            print("PASS: extracted 7z matches source")

            // Password-protected 7z, including encrypted headers
            let locked = root.appendingPathComponent("locked.7z")
            _ = try await SevenZipRunner().run(
                arguments: SevenZipCommand.compress(
                    sources: [source],
                    output: locked,
                    format: .sevenZip,
                    level: 5,
                    password: "correct horse",
                    encryptFileNames: true
                )
            )
            let lockedOut = root.appendingPathComponent("out-locked", isDirectory: true)
            _ = try await SevenZipRunner().run(
                arguments: SevenZipCommand.extract(
                    archive: locked,
                    destination: lockedOut,
                    password: "correct horse"
                )
            )
            guard try Data(contentsOf: lockedOut.appendingPathComponent("source/hello.txt")) == hello else {
                print("FAIL: encrypted 7z round trip mismatch")
                return false
            }
            print("PASS: encrypted 7z round trip")

            // ZIP round trip
            let zip = root.appendingPathComponent("archive.zip")
            _ = try await SevenZipRunner().run(
                arguments: SevenZipCommand.compress(
                    sources: [source],
                    output: zip,
                    format: .zip,
                    level: 5,
                    password: "",
                    encryptFileNames: false
                )
            )
            let zipOut = root.appendingPathComponent("out-zip", isDirectory: true)
            _ = try await SevenZipRunner().run(
                arguments: SevenZipCommand.extract(
                    archive: zip,
                    destination: zipOut,
                    password: ""
                )
            )
            guard try Data(contentsOf: zipOut.appendingPathComponent("source/hello.txt")) == hello else {
                print("FAIL: zip round trip content mismatch")
                return false
            }
            print("PASS: zip round trip")

            // Encrypted ZIP (AES-256) round trip
            let lockedZip = root.appendingPathComponent("locked.zip")
            _ = try await SevenZipRunner().run(
                arguments: SevenZipCommand.compress(
                    sources: [source],
                    output: lockedZip,
                    format: .zip,
                    level: 5,
                    password: "zip secret",
                    encryptFileNames: false
                )
            )
            let lockedZipOut = root.appendingPathComponent("out-locked-zip", isDirectory: true)
            _ = try await SevenZipRunner().run(
                arguments: SevenZipCommand.extract(
                    archive: lockedZip,
                    destination: lockedZipOut,
                    password: "zip secret"
                )
            )
            guard try Data(contentsOf: lockedZipOut.appendingPathComponent("source/hello.txt")) == hello else {
                print("FAIL: encrypted zip round trip mismatch")
                return false
            }
            print("PASS: encrypted zip round trip")

            print("SMOKE TEST PASSED")
            return true
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return false
        }
    }
}
