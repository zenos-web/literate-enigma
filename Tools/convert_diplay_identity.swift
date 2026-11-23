#!/usr/bin/env swift
import Foundation
import CryptoKit
import Security

enum ConversionError: LocalizedError {
    case usage
    case invalidInput(String)
    case outputNotEmpty
    case certificateExtraction
    case invalidCertificate
    case keyCertificateMismatch
    case invalidPrivateKeyLength(Int)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: convert_diplay_identity.swift <offline-mfi input directory> <empty output directory>"
        case .invalidInput(let name):
            return "Missing, empty, or oversized input: \(name)"
        case .outputNotEmpty:
            return "The output directory must be empty"
        case .certificateExtraction:
            return "Could not extract one DER certificate from certificate.p7b"
        case .invalidCertificate:
            return "The extracted accessory certificate is invalid"
        case .keyCertificateMismatch:
            return "The P-256 private key does not match the accessory certificate"
        case .invalidPrivateKeyLength(let count):
            return "Unexpected X9.63 P-256 private-key length: \(count)"
        }
    }
}

func readBounded(_ url: URL, maximum: Int = 65_536) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximum else {
        throw ConversionError.invalidInput(url.lastPathComponent)
    }
    let data = try Data(contentsOf: url, options: [.uncached])
    guard !data.isEmpty, data.count <= maximum else {
        throw ConversionError.invalidInput(url.lastPathComponent)
    }
    return data
}

func setOwnerOnlyPermissions(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func runOpenSSL(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw ConversionError.certificateExtraction
    }
}

func run() throws {
    let arguments: [String]
    if let separator = CommandLine.arguments.lastIndex(of: "--") {
        arguments = Array(CommandLine.arguments[CommandLine.arguments.index(after: separator)...])
    } else {
        arguments = Array(CommandLine.arguments.dropFirst())
    }
    guard arguments.count == 2 else { throw ConversionError.usage }
    let input = URL(fileURLWithPath: arguments[0], isDirectory: true).standardizedFileURL
    let output = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
    let manager = FileManager.default
    try manager.createDirectory(at: output, withIntermediateDirectories: false,
                                attributes: [.posixPermissions: 0o700])
    guard try manager.contentsOfDirectory(atPath: output.path).isEmpty else {
        throw ConversionError.outputNotEmpty
    }

    let chainInput = input.appendingPathComponent("certificate.p7b")
    let keyInput = input.appendingPathComponent("identity.pk8")
    let chainOutput = output.appendingPathComponent("certificate.p7b")
    let leafOutput = output.appendingPathComponent("leaf.cer")
    let temporaryPEM = output.appendingPathComponent("certificate-chain.pem")
    let keyOutput = output.appendingPathComponent("private.x963")
    var completed = false
    defer {
        try? manager.removeItem(at: temporaryPEM)
        if !completed {
            for url in [chainOutput, leafOutput, keyOutput] { try? manager.removeItem(at: url) }
        }
    }

    let chain = try readBounded(chainInput)
    try chain.write(to: chainOutput, options: .atomic)
    try setOwnerOnlyPermissions(chainOutput)

    try runOpenSSL(["pkcs7", "-inform", "DER", "-in", chainInput.path,
                    "-print_certs", "-out", temporaryPEM.path])
    try setOwnerOnlyPermissions(temporaryPEM)
    let pem = try readBounded(temporaryPEM)
    let marker = "-----BEGIN CERTIFICATE-----"
    guard String(decoding: pem, as: UTF8.self).components(separatedBy: marker).count - 1 == 1 else {
        throw ConversionError.certificateExtraction
    }
    try runOpenSSL(["x509", "-inform", "PEM", "-in", temporaryPEM.path,
                    "-outform", "DER", "-out", leafOutput.path])
    try setOwnerOnlyPermissions(leafOutput)

    let leaf = try readBounded(leafOutput)
    guard let certificate = SecCertificateCreateWithData(nil, leaf as CFData),
          let certificateKey = SecCertificateCopyKey(certificate) else {
        throw ConversionError.invalidCertificate
    }
    var publicKeyError: Unmanaged<CFError>?
    guard let certificatePublicBytes = SecKeyCopyExternalRepresentation(certificateKey, &publicKeyError) as Data? else {
        if let publicKeyError { throw publicKeyError.takeRetainedValue() }
        throw ConversionError.invalidCertificate
    }

    var pkcs8 = try readBounded(keyInput, maximum: 16_384)
    defer { pkcs8.resetBytes(in: 0..<pkcs8.count) }
    let privateKey = try P256.Signing.PrivateKey(derRepresentation: pkcs8)
    var x963 = privateKey.x963Representation
    defer { x963.resetBytes(in: 0..<x963.count) }
    guard x963.count == 97 else { throw ConversionError.invalidPrivateKeyLength(x963.count) }
    guard certificatePublicBytes == x963.prefix(65) else {
        throw ConversionError.keyCertificateMismatch
    }
    try x963.write(to: keyOutput, options: .atomic)
    try setOwnerOnlyPermissions(keyOutput)
    completed = true
    print("Identity conversion succeeded: certificate.p7b=\(chain.count) bytes, leaf.cer=\(leaf.count) bytes, private.x963=\(x963.count) bytes")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Identity conversion failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
