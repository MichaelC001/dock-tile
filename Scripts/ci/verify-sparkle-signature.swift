// Release guard, run by release.yml between "Sign update for Sparkle" and "Update appcast". Checks
// that the EdDSA signature CI just made verifies against the SUPublicEDKey baked into the app —
// the key every installed copy uses to accept an update. A wrong SPARKLE_EDDSA_KEY secret would
// otherwise publish an update every user's Sparkle rejects, with nothing failing in CI (sign_update
// happily signs with any key). Also safe to run locally against a published release.
//
// Usage: swift verify-sparkle-signature.swift <file.dmg> <base64 signature> <Info.plist>
// Exit: 0 signature valid · 1 signature does NOT match, or the plist's key is not the pinned one
//       2 usage error, or an input cannot be read (a check that cannot verify must not pass)
import CryptoKit
import Foundation

/// The SUPublicEDKey every shipped copy trusts, pinned independently of the Info.plist, so a
/// regenerated key plus a matching plist edit cannot pass together by accident. A deliberate
/// change must also edit this line, which reviewing Scripts/ before approving a release catches.
/// It must never change: a new key orphans every installed copy.
let pinnedPublicKey = "x1Vq5xNOjXIGTPR55Gucpx6RPjCxXVsHy41b1shwBuA="

func stop(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count == 4 else { stop(2, "usage: verify-sparkle-signature <file.dmg> <base64 signature> <Info.plist>") }

guard let archive = FileManager.default.contents(atPath: args[1]), !archive.isEmpty else {
    stop(2, "cannot read the archive at \(args[1])")
}
guard let signature = Data(base64Encoded: args[2].trimmingCharacters(in: .whitespacesAndNewlines)),
      signature.count == 64 else {
    stop(2, "the signature is not 64 bytes of base64")
}
guard let plist = NSDictionary(contentsOfFile: args[3]),
      let publicKeyString = plist["SUPublicEDKey"] as? String,
      let publicKeyData = Data(base64Encoded: publicKeyString),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
    stop(2, "cannot read a valid SUPublicEDKey from \(args[3])")
}
guard publicKeyString == pinnedPublicKey else {
    stop(1, "FAIL: SUPublicEDKey in \(args[3]) is not the pinned key installed copies trust. "
        + "Changing it orphans every installed copy. Nothing must be published.")
}

guard publicKey.isValidSignature(signature, for: archive) else {
    stop(1, "FAIL: the Sparkle signature does not verify against the app's SUPublicEDKey — "
        + "SPARKLE_EDDSA_KEY is not the key installed copies trust. Nothing must be published.")
}
print("ok: Sparkle signature verifies against SUPublicEDKey (\(archive.count) bytes)")
