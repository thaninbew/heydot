import Foundation
import Security

/// The key WebKit protects CryptoKey objects with when a page (ChatGPT) keeps them in its storage.
///
/// Left to itself, WebKit keeps that key in a "HeyDot WebCrypto Master Key" keychain item. HeyDot has no Team ID,
/// so the keychain recognises each build by its own hash and macOS asks for the Mac password after every update.
/// HeyDot supplies its own key instead: 16 random bytes in Application Support/HeyDot (folder 0700, file 0600),
/// the same size WebKit makes. Anything that can read this file as you can already read the sign-in cookies.
enum WebCryptoKey {
    static let size = 16

    static func url(_ paths: Paths) -> URL { paths.support.appendingPathComponent("webcrypto.key") }

    /// The stored key, made on first use. nil only if it can't be read or written; WebKit then falls back to its
    /// keychain item.
    static func load(paths: Paths = Paths()) -> Data? {
        let url = url(paths)
        if let data = try? Data(contentsOf: url), data.count == size { return data }
        guard let key = generate() else { return nil }
        do {
            try Paths.ensureDirectory(paths.support, mode: 0o700)
            try key.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
            return key
        } catch {
            return nil
        }
    }

    static func generate() -> Data? {
        var key = Data(count: size)
        let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!) }
        return status == errSecSuccess ? key : nil
    }
}
