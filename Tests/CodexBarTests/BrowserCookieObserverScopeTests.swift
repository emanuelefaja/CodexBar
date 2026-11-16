import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct BrowserCookieObserverScopeTests {
    private enum ProbeError: Error {
        case expected
    }

    @Test
    func `concurrent observer scopes restore after nested throwing imports without leaking`() async {
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let events = LockIsolated<[String]>([])
                    BrowserCookieAccessGate.withAccessFailureObserver { browser, profileDenied in
                        events.setValue(events.value + ["outer:\(browser.rawValue):\(profileDenied)"])
                    } operation: {
                        BrowserCookieAccessGate.recordAccessFailure(for: .chrome)
                        do {
                            try BrowserCookieAccessGate.withAccessFailureObserver { browser, profileDenied in
                                events.setValue(events.value + ["inner:\(browser.rawValue):\(profileDenied)"])
                            } operation: {
                                BrowserCookieAccessGate.recordAccessFailure(for: .safari, profileDenied: true)
                                throw ProbeError.expected
                            }
                        } catch ProbeError.expected {
                            // The outer observer must be restored even when the import throws.
                        } catch {
                            Issue.record("Unexpected synthetic import error: \(error)")
                        }
                        BrowserCookieAccessGate.recordAccessFailure(for: .chrome)
                    }
                    BrowserCookieAccessGate.recordAccessFailure(for: .safari)
                    return events.value == ["outer:chrome:false", "inner:safari:true", "outer:chrome:false"]
                }
            }
            for await valid in group {
                #expect(valid)
            }
        }
    }
}
