import XCTest
@testable import Pollymetric

final class DataDirectoryTests: XCTestCase {
    func testOverrideIsOptional() {
        XCTAssertNil(DataDirectory.override(in: [:]))
        XCTAssertNil(DataDirectory.override(in: ["POLLYMETRIC_DATA_DIR": ""]))
        XCTAssertEqual(DataDirectory.override(in: ["POLLYMETRIC_DATA_DIR": "/tmp/pollymetric test"])?.path,
                       "/tmp/pollymetric test")
    }

    func testPersistentStoresUseOverride() throws {
        let root = try XCTUnwrap(DataDirectory.override())
        XCTAssertEqual(Lynis.dataDirectory, root)
        XCTAssertEqual(HistoryStore.shared.url, root.appendingPathComponent("history.sqlite"))
        XCTAssertEqual(QueryDiskCache.directory, root.appendingPathComponent("cache", isDirectory: true))
    }
}
