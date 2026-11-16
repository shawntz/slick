// Checks and makes the EdDSA (Ed25519) signatures that Sparkle verifies before it installs an
// update. It reads no keychain and makes no network request.
//
//   update-signature verify <public key> <file> <signature>
//       Exits 0 when <signature> is a valid signature of the file's bytes under <public key>, and 1
//       when it is not. The key and the signature are base64, as SUPublicEDKey and the appcast's
//       sparkle:edSignature carry them.
//   update-signature sign-throwaway <file>
//       Makes a new key pair in memory, signs the file, prints "public <key>" and
//       "signature <signature>" on two lines, and forgets the private key. The dry run uses it, so
//       the whole signing path runs without the owner's key. The private key is never printed,
//       written or passed on.
//
// scripts/release.sh compiles it once per run with swiftc, because a script started with
// `swift <file>` compiles itself on every call.
import CryptoKit
import Foundation

/// Ends the tool with a message on standard error.
func stop(_ message: String, status: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("update-signature: \(message)\n".utf8))
    exit(status)
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { stop("cannot read \(path)") }
    return data
}

/// Base64 that must decode to exactly `length` bytes.
func decode(_ text: String, length: Int, what: String) -> Data {
    guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
        data.count == length
    else { stop("the \(what) is not base64 of \(length) bytes") }
    return data
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "verify" where arguments.count == 4:
    let keyData = decode(arguments[1], length: 32, what: "public key")
    let signature = decode(arguments[3], length: 64, what: "signature")
    let file = readFile(arguments[2])
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
        stop("the public key is not an Ed25519 key")
    }
    if key.isValidSignature(signature, for: file) {
        print("ok: the signature of \((arguments[2] as NSString).lastPathComponent) matches the public key")
        exit(0)
    }
    stop("the signature does not match the file and the public key", status: 1)
case "sign-throwaway" where arguments.count == 2:
    let file = readFile(arguments[1])
    let key = Curve25519.Signing.PrivateKey()
    guard let signature = try? key.signature(for: file) else { stop("could not sign \(arguments[1])") }
    print("public \(key.publicKey.rawRepresentation.base64EncodedString())")
    print("signature \(signature.base64EncodedString())")
default:
    stop(
        "usage: update-signature verify <public key> <file> <signature> | update-signature sign-throwaway <file>",
        status: 64)
}
