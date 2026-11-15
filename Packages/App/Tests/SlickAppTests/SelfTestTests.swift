import Kit
import Testing

@testable import SlickApp

@Suite("Selftest")
struct SelfTestTests {
    @Test func passesOutsideABundle() {
        let report = SelfTest.check(bundleIdentifier: nil)
        #expect(report.passed, "\(report.failures)")
        #expect(report.line.hasPrefix("selftest PASS "))
        #expect(report.line.contains("noop=ok"))
        #expect(report.line.contains("bundle=none"))
    }

    @Test func passesInsideTheRightBundle() {
        let report = SelfTest.check(bundleIdentifier: Brand.bundleID)
        #expect(report.passed)
        #expect(report.line.contains("bundle=\(Brand.bundleID)"))
    }

    @Test func failsInsideAnotherBundle() {
        let report = SelfTest.check(bundleIdentifier: "com.example.other")
        #expect(!report.passed)
        #expect(report.line.hasPrefix("selftest FAIL "))
    }
}
