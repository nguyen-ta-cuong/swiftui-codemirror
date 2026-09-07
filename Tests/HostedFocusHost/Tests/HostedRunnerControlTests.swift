import XCTest

final class HostedRunnerControlTests: XCTestCase {
  func testSynchronousControlRunsOnMainThread() {
    XCTAssertTrue(Thread.isMainThread)
  }

  @MainActor
  func testAsyncControlAwaitsAndRunsOnMainThread() async throws {
    try await Task.sleep(nanoseconds: 1_000_000)
    XCTAssertTrue(Thread.isMainThread)
  }
}
