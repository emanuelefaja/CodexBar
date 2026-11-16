import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import SweetCookieKit
#endif
import Testing
@testable import CodexBarCore

struct OpenAIWebProfileTests {
    @Test
    func `only the selected database and exact onboard key are read`() throws {
        let fixture = try ProfileFixture()
        defer { fixture.remove() }
        let selected = fixture.profile
        let token = try OpenAIWebProfileReader.loadToken(
            selected,
            accessAllowed: { true },
            approvedRoots: { [fixture.root] },
            readEntries: { directory in
                #expect(directory == fixture.levelDB)
                return [
                    .init(key: "other-origin:oai-auth:onboard", value: #"{"accessToken":"wrong-origin"}"#),
                    .init(key: "oai-auth:onboard", value: #"{"accessToken":"synthetic-access","refreshToken":false}"#),
                    .init(key: "oai-auth:other", value: #"{"accessToken":"wrong-key"}"#),
                ]
            })
        #expect(token == "synthetic-access")
        // No cookie database or Local State exists. Selection does not require or discover either.
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Local State").path))
    }

    @Test
    func `suppressed gate prevents even root discovery`() {
        var rootsRead = false
        var entriesRead = false
        #expect(throws: OpenAIWebError.self) {
            try OpenAIWebProfileReader.loadToken(
                .init(browserID: "chrome", profileID: "/not-accessed"),
                accessAllowed: { false },
                approvedRoots: { rootsRead = true; return [] },
                readEntries: { _ in entriesRead = true; return [] })
        }
        #expect(!rootsRead && !entriesRead)
    }

    @Test(arguments: ["", "relative/Profile 1", "/outside/Profile 1", "/synthetic/../Profile 1"])
    func `invalid profile paths never reach local storage reader`(path: String) {
        var called = false
        #expect(throws: OpenAIWebError.self) {
            try OpenAIWebProfileReader.loadToken(
                .init(browserID: "chrome", profileID: path),
                accessAllowed: { true },
                approvedRoots: { [] },
                readEntries: { _ in called = true; return [] })
        }
        #expect(!called)
    }

    @Test(arguments: ["profile", "storage", "leveldb", "file", "root"])
    func `symlink escapes cannot reach the storage reader`(component: String) throws {
        let fixture = try ProfileFixture()
        defer { fixture.remove() }
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target: URL = switch component {
        case "profile": fixture.selected
        case "storage": fixture.selected.appendingPathComponent("Local Storage")
        case "leveldb": fixture.levelDB
        case "root": fixture.root
        default: fixture.levelDB.appendingPathComponent("000001.log")
        }
        if component != "file" { try FileManager.default.removeItem(at: target) }
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        var called = false
        #expect(throws: OpenAIWebError.self) {
            try OpenAIWebProfileReader.loadToken(
                fixture.profile,
                accessAllowed: { true },
                approvedRoots: { [fixture.root] },
                readEntries: { _ in called = true; return [] })
        }
        #expect(!called)
    }

    @Test
    func `absent selected storage never falls back to another profile`() throws {
        let fixture = try ProfileFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.levelDB)
        var called = false
        #expect(throws: OpenAIWebError.self) {
            try OpenAIWebProfileReader.loadToken(
                fixture.profile,
                accessAllowed: { true },
                approvedRoots: { [fixture.root] },
                readEntries: { _ in called = true; return [] })
        }
        #expect(!called)
    }

    @Test(arguments: ["{}", #"{"accessToken":null}"#, #"{"accessToken":123}"#, "not-json"])
    func `onboard payload must contain a string accessToken`(value: String) throws {
        let fixture = try ProfileFixture()
        defer { fixture.remove() }
        #expect(throws: OpenAIWebError.self) {
            try OpenAIWebProfileReader.loadToken(
                fixture.profile,
                accessAllowed: { true },
                approvedRoots: { [fixture.root] },
                readEntries: { _ in [.init(key: "oai-auth:onboard", value: value)] })
        }
    }

    @Test
    func `ambiguous onboard records are not selected by order`() throws {
        let fixture = try ProfileFixture()
        defer { fixture.remove() }
        #expect(throws: OpenAIWebError.self) {
            try OpenAIWebProfileReader.loadToken(
                fixture.profile,
                accessAllowed: { true },
                approvedRoots: { [fixture.root] },
                readEntries: { _ in [
                    .init(key: "oai-auth:onboard", value: #"{"accessToken":"synthetic-first"}"#),
                    .init(key: "oai-auth:onboard", value: #"{"accessToken":"synthetic-second"}"#),
                ] })
        }
    }

    #if os(macOS)
    @Test(arguments: [false, true])
    func `strict current reader decodes the live onboard value`(utf16: Bool) throws {
        let fixture = try ProfileFixture()
        defer { fixture.remove() }
        try fixture.writeCurrentStorage(utf16: utf16)
        #expect(try fixture.loadCurrentToken() == "synthetic-current")
    }

    @Test(arguments: ["deleted", "orphan", "truncated", "checksum"])
    func `strict reader rejects stale or incomplete storage`(mutation: String) throws {
        let fixture = try ProfileFixture()
        defer { fixture.remove() }
        try fixture.writeCurrentStorage()
        #expect(try fixture.loadCurrentToken() == "synthetic-current")
        let log = fixture.levelDB.appendingPathComponent("000004.log")
        var data = try Data(contentsOf: log)
        switch mutation {
        case "deleted":
            data += try #require(Data(base64Encoded: ProfileFixture.deletion))
            try data.write(to: log)
        case "orphan":
            try FileManager.default.removeItem(at: fixture.levelDB.appendingPathComponent("CURRENT"))
        case "truncated":
            data += Data([1, 2, 3])
            try data.write(to: log)
        default:
            var record = try #require(Data(base64Encoded: ProfileFixture.deletion))
            record[0] ^= 1
            data += record
            try data.write(to: log)
        }
        #expect(throws: OpenAIWebError.self) { try fixture.loadCurrentToken() }
    }

    @Test
    func `test gate suppresses real home without inspecting browser storage`() {
        #expect(BrowserCookieAccessGate.cookieStoreAccessDecision(
            homeDirectories: BrowserCookieClient.defaultHomeDirectories(),
            processName: "xctest",
            environment: ["XCTestConfigurationFilePath": "/synthetic/test"])
            == .suppressed)
    }
    #endif
}

private struct ProfileFixture {
    let base: URL
    let root: URL
    let selected: URL
    let levelDB: URL
    var profile: ProviderBrowserProfile {
        .init(browserID: "chrome", profileID: self.selected.path)
    }

    init() throws {
        // Resolve an existing directory with realpath: Foundation can reintroduce the /var symlink.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let path = try #require(realpath(temporary.path, nil))
        defer { free(path) }
        self.base = URL(fileURLWithPath: String(cString: path))
        self.root = self.base.appendingPathComponent("Chrome", isDirectory: true)
        self.selected = self.root.appendingPathComponent("Profile 1", isDirectory: true)
        self.levelDB = self.selected.appendingPathComponent("Local Storage/leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: self.levelDB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: self.root.appendingPathComponent("Profile 2/Local Storage/leveldb"), withIntermediateDirectories: true)
    }

    #if os(macOS)
    static let deletion =
        "RO4tUzwAAQIAAAAAAAAAAQAAAAAuX2h0dHBzOi8vcGxhdGZvcm0ub3BlbmFpLmNvbQABb2FpLWF1dGg6b25ib2FyZA=="

    func writeCurrentStorage(utf16: Bool = false) throws {
        let latin = "lzckCnYAAQEAAAAAAAAAAQAAAAEuX2h0dHBzOi8vcGxhdGZvcm0ub3BlbmFpLmNvbQAB"
            + "b2FpLWF1dGg6b25ib2FyZDkBeyJhY2Nlc3NUb2tlbiI6InN5bnRoZXRpYy1jdXJyZW50IiwicmVmcmVzaFRva2VuIjpmYWxzZX0="
        let wide = "uRN/jK4AAQEAAAAAAAAAAQAAAAEuX2h0dHBzOi8vcGxhdGZvcm0ub3BlbmFpLmNvbQAB"
            + "b2FpLWF1dGg6b25ib2FyZHEAewAiAGEAYwBjAGUAcwBzAFQAbwBrAGUAbgAiADoAIgBzAHkAbgB0AGgAZQB0AGkAYwAt"
            + "AGMAdQByAHIAZQBuAHQAIgAsACIAcgBlAGYAcgBlAHMAaABUAG8AawBlAG4AIgA6AGYAYQBsAHMAZQB9AA=="
        try Data("MANIFEST-000001\n".utf8).write(to: self.levelDB.appendingPathComponent("CURRENT"))
        let manifest = try #require(Data(base64Encoded: "KAYrrQYAAQIEAwUEAQ=="))
        try manifest.write(to: self.levelDB.appendingPathComponent("MANIFEST-000001"))
        let log = try #require(Data(base64Encoded: utf16 ? wide : latin))
        try log.write(to: self.levelDB.appendingPathComponent("000004.log"))
    }

    func loadCurrentToken() throws -> String {
        try OpenAIWebProfileReader.loadToken(
            self.profile,
            accessAllowed: { true },
            approvedRoots: { [self.root] },
            readEntries: OpenAIWebProfileReader.readCurrentEntries)
    }
    #endif

    func remove() { try? FileManager.default.removeItem(at: self.base) }
}

struct OpenAIWebRedirectTests {
    @Test(arguments: ["https://api.openai.com/other", "https://elsewhere.invalid/capture"])
    func `redirect delegate refuses same and cross origin without network`(destination: String) throws {
        let configuration = OpenAIWebTransport.makeConfiguration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.timeoutIntervalForRequest == 20)
        #expect(configuration.timeoutIntervalForResource == 40)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let original = try #require(URL(string: "https://api.openai.com/v1/dashboard/onboarding/login"))
        let task = session.dataTask(with: original) // Never resumed.
        let redirect = try #require(HTTPURLResponse(
            url: original, statusCode: 302, httpVersion: nil, headerFields: ["Location": destination]))
        let invoked = LockIsolated(false)
        try OpenAIWebRedirectGuard().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: #require(URL(string: destination))))
        { request in
            #expect(request == nil)
            invoked.setValue(true)
        }
        #expect(invoked.value)
    }
}
