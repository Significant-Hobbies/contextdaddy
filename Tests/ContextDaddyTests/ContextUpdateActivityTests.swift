import XCTest
@testable import ContextDaddy

final class ContextUpdateActivityTests: XCTestCase {
    @MainActor func testNestedManagementOperationsKeepRelaunchBlocked() async throws {
        XCTAssertEqual(ContextUpdateActivity.operations, 0)
        try await ContextUpdateActivity.perform {
            XCTAssertEqual(ContextUpdateActivity.operations, 1)
            try await ContextUpdateActivity.perform {
                XCTAssertEqual(ContextUpdateActivity.operations, 2)
                try Task.checkCancellation()
            }
            XCTAssertEqual(ContextUpdateActivity.operations, 1)
        }
        XCTAssertEqual(ContextUpdateActivity.operations, 0)
    }

    @MainActor func testFailureReleasesOperationGuard() async {
        do {
            try await ContextUpdateActivity.perform { throw CancellationError() }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(ContextUpdateActivity.operations, 0)
        }
    }
}
