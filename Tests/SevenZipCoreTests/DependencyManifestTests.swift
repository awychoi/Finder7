import XCTest
@testable import SevenZipCore

final class DependencyManifestTests: XCTestCase {
    func testRoundTripAndShape() throws {
        let manifest = DependencyManifest(
            appName: "SevenZip",
            appVersion: "0.1.0",
            engineVersion: "26.06"
        )
        let data = try manifest.jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schema"] as? Int, 1)
        let app = try XCTUnwrap(object["app"] as? [String: Any])
        XCTAssertEqual(app["name"] as? String, "SevenZip")
        XCTAssertEqual(app["version"] as? String, "0.1.0")
        let dependencies = try XCTUnwrap(object["dependencies"] as? [[String: Any]])
        XCTAssertEqual(dependencies.count, 1)
        XCTAssertEqual(dependencies[0]["repo"] as? String, "ip7z/7zip")
        XCTAssertEqual(dependencies[0]["version"] as? String, "26.06")
        XCTAssertEqual(dependencies[0]["path"] as? String, "7zz")

        let decoded = try JSONDecoder().decode(DependencyManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.engineVersion, "26.06")
        try decoded.validate()
    }

    func testEncodingIsStable() throws {
        let manifest = DependencyManifest(appName: "SevenZip", appVersion: "0.1.0", engineVersion: "26.06")
        XCTAssertEqual(try manifest.jsonData(), try manifest.jsonData())
        let text = try XCTUnwrap(String(data: manifest.jsonData(), encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("\"repo\" : \"ip7z/7zip\""))
    }

    func testRejectsUnsupportedSchemaAndMissingEngine() throws {
        var manifest = DependencyManifest(appName: "SevenZip", appVersion: "0.1.0", engineVersion: "26.06")
        manifest.schema = 2
        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(error as? DependencyManifestError, .unsupportedSchema(2))
        }

        manifest.schema = 1
        manifest.dependencies = []
        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(error as? DependencyManifestError, .missingEngineDependency)
        }

        manifest.dependencies = [
            .init(repo: "ip7z/7zip", version: "not-a-version", path: "7zz")
        ]
        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(error as? DependencyManifestError, .invalidEngineVersion("not-a-version"))
        }
    }

    func testReadWrite() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("homelab-app-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try DependencyManifest.write(
            appName: "SevenZip",
            appVersion: "0.1.0",
            engineVersion: "26.06",
            to: url
        )
        XCTAssertEqual(try DependencyManifest.read(from: url).engineVersion, "26.06")
    }
}
