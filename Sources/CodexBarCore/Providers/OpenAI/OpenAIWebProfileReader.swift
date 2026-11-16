import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(macOS)
import SweetCookieKit
#endif

/// No profile discovery, cookies, Keychain, token refresh, or writes. Only the pinned Platform origin is read.
enum OpenAIWebProfileReader {
    struct Entry: Sendable {
        let key: String
        let value: String
    }

    typealias EntryReader = (URL) throws -> [Entry]

    static func loadToken(_ profile: ProviderBrowserProfile) throws -> String {
        #if os(macOS)
        let homes = BrowserCookieClient.defaultHomeDirectories()
        return try self.loadToken(
            profile,
            accessAllowed: {
                BrowserCookieAccessGate.cookieStoreAccessDecision(homeDirectories: homes) == .allowed
            },
            approvedRoots: {
                // Only Chrome has a verified Platform local-storage contract. Do not search other browsers.
                ChromiumProfileLocator.roots(for: [.chrome], homeDirectories: homes).map(\.url)
            },
            readEntries: self.readCurrentEntries)
        #else
        throw OpenAIWebError.profileAccess
        #endif
    }

    #if os(macOS)
    static func readCurrentEntries(in directory: URL) -> [Entry] {
        let key = Data("_https://platform.openai.com\0".utf8) + Data([1]) + Data("oai-auth:onboard".utf8)
        guard let data = ChromiumLocalStorageReader.readCurrentValue(forRawKey: key, in: directory),
              data.count <= 262_145, let prefix = data.first else { return [] }
        let encoding: String.Encoding
        switch prefix {
        case 0: encoding = .utf16LittleEndian
        case 1: encoding = .isoLatin1
        default: return []
        }
        guard let value = String(data: data.dropFirst(), encoding: encoding) else { return [] }
        return [Entry(key: "oai-auth:onboard", value: value)]
    }
    #endif

    static func loadToken(
        _ profile: ProviderBrowserProfile,
        accessAllowed: () -> Bool,
        approvedRoots: () -> [URL],
        readEntries: EntryReader) throws -> String
    {
        // Gate even metadata reads. Unlike cookie shouldAttempt, this gate never asks for Safe Storage.
        guard accessAllowed() else { throw OpenAIWebError.profileAccess }
        try Task.checkCancellation()
        let directory = try self.validatedDirectory(profile, approvedRoots: approvedRoots())
        let entries: [Entry]
        do {
            entries = try readEntries(directory)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenAIWebError.profileAccess
        }
        try Task.checkCancellation()
        // Recheck containment after the read too; no result survives a changed profile/storage symlink.
        guard try self.validatedDirectory(profile, approvedRoots: approvedRoots()) == directory else {
            throw OpenAIWebError.profileAccess
        }
        let values = Set(entries.filter { $0.key == "oai-auth:onboard" }.map(\.value))
        guard values.count == 1, let value = values.first, value.utf8.count <= 262_144 else {
            throw OpenAIWebError.reopenPlatform
        }
        struct Onboard: Decodable { let accessToken: String }
        // Unknown keys, including refreshToken, are never decoded or retained.
        guard let onboard = try? JSONDecoder().decode(Onboard.self, from: Data(value.utf8)),
              !onboard.accessToken.isEmpty else { throw OpenAIWebError.reopenPlatform }
        return onboard.accessToken
    }

    static func validatedDirectory(_ profile: ProviderBrowserProfile, approvedRoots: [URL]) throws -> URL {
        guard profile.browserID == "chrome", profile.profileID.hasPrefix("/"),
              !profile.profileID.contains("\0"),
              !profile.profileID.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                  $0 == "." || $0 == ".."
              }) else { throw OpenAIWebError.profileAccess }
        let selected = URL(fileURLWithPath: profile.profileID)
        guard selected.path == profile.profileID,
              try self.physicalURL(selected).path == selected.path,
              approvedRoots.contains(where: { root in
                  (try? self.physicalURL(root).path) == root.path
                      && selected.deletingLastPathComponent().path == root.path
              }) else { throw OpenAIWebError.profileAccess }
        let localStorage = selected.appendingPathComponent("Local Storage", isDirectory: true)
        let levelDB = localStorage.appendingPathComponent("leveldb", isDirectory: true)
        for path in [localStorage, levelDB] {
            guard try self.physicalURL(path).path.hasPrefix(selected.path + "/") else {
                throw OpenAIWebError.profileAccess
            }
        }
        let canonical = try self.physicalURL(levelDB)
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: canonical, includingPropertiesForKeys: nil, options: [])
            // The LevelDB reader can open individual files. Those must not redirect outside this database either.
            guard files.allSatisfy({
                (try? self.physicalURL($0).path.hasPrefix(canonical.path + "/")) == true
            }) else {
                throw OpenAIWebError.profileAccess
            }
        } catch { throw OpenAIWebError.profileAccess }
        return canonical
    }

    private static func physicalURL(_ url: URL) throws -> URL {
        // Foundation can turn physical /private/var paths back into the /var symlink on macOS.
        // The strict LevelDB reader must receive the real path, not that presentation alias.
        guard let path = realpath(url.path, nil) else { throw OpenAIWebError.profileAccess }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }
}
