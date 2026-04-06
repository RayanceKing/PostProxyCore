import Foundation
import Crypto
import NIOSSL
import Protocol
import X509

public struct Certificate: Sendable, Equatable {
    public var commonName: String
    public var serialNumber: String
    public var createdAt: Date

    public init(commonName: String, serialNumber: String, createdAt: Date = Date()) {
        self.commonName = commonName
        self.serialNumber = serialNumber
        self.createdAt = createdAt
    }
}

public struct MITMTLSIdentity: Sendable {
    public let certificateChain: [NIOSSLCertificate]
    public let privateKey: NIOSSLPrivateKey

    public init(certificateChain: [NIOSSLCertificate], privateKey: NIOSSLPrivateKey) {
        self.certificateChain = certificateChain
        self.privateKey = privateKey
    }
}

public protocol MITMCertificateProviding: Sendable {
    func leafIdentity(for host: String) async throws -> MITMTLSIdentity
    func rootCertificatePEM() async throws -> String
    func rootCommonName() async -> String
    func makeRootTrustManager() async -> any RootTrustManaging
}

public protocol CertificateManaging: Sendable {
    func currentCertificate() async -> Certificate?
    func rotate(commonName: String) async -> Certificate
}

public enum CertificateAuthorityError: Error, Sendable {
    case invalidHost(String)
    case cannotBuildIdentity
}

public enum RootTrustError: Error, Sendable {
    case unsupportedPlatform
    case commandFailed(String)
}

public protocol RootTrustManaging: Sendable {
    func isRootInstalled() async throws -> Bool
    func installRootCertificate() async throws
    func uninstallRootCertificate() async throws
}

public struct UnsupportedRootTrustManager: RootTrustManaging {
    public init() {}

    public func isRootInstalled() async throws -> Bool {
        false
    }

    public func installRootCertificate() async throws {
        throw RootTrustError.unsupportedPlatform
    }

    public func uninstallRootCertificate() async throws {
        throw RootTrustError.unsupportedPlatform
    }
}

public actor InMemoryCertificateManager: CertificateManaging, MITMCertificateProviding {
    private struct RootIdentity {
        var key: X509.Certificate.PrivateKey
        var certificate: X509.Certificate
        var certificatePEM: String
    }

    private var certificate: Certificate?
    private let caCommonName: String
    private let storageDirectory: URL
    private let rootKey: X509.Certificate.PrivateKey
    private let rootCertificate: X509.Certificate
    private let rootCertificatePEMString: String
    private var leafCache: [String: MITMTLSIdentity] = [:]

    public init(
        caCommonName: String = "PostProxyCore Root CA",
        storageDirectory: URL? = nil
    ) {
        self.caCommonName = caCommonName
        self.storageDirectory = storageDirectory ?? Self.defaultStorageDirectory()

        if let loaded = try? Self.loadRootIdentity(from: self.storageDirectory) {
            self.rootKey = loaded.key
            self.rootCertificate = loaded.certificate
            self.rootCertificatePEMString = loaded.certificatePEM
        } else {
            let generated = try! Self.makeRootIdentity(caCommonName: caCommonName)
            self.rootKey = generated.key
            self.rootCertificate = generated.certificate
            self.rootCertificatePEMString = generated.certificatePEM
            try? Self.persistRootIdentity(generated, directory: self.storageDirectory)
        }
    }

    public func currentCertificate() -> Certificate? {
        certificate
    }

    public func rotate(commonName: String) -> Certificate {
        let newCertificate = Certificate(commonName: commonName, serialNumber: UUID().uuidString)
        certificate = newCertificate
        return newCertificate
    }

    public func rootCertificatePEM() -> String {
        rootCertificatePEMString
    }

    public func rootCommonName() -> String {
        caCommonName
    }

    public func makeRootTrustManager() -> any RootTrustManaging {
#if os(macOS)
        return MacOSRootTrustManager(commonName: caCommonName, certificatePEM: rootCertificatePEMString)
#else
        return UnsupportedRootTrustManager()
#endif
    }

    public func leafIdentity(for host: String) async throws -> MITMTLSIdentity {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            throw CertificateAuthorityError.invalidHost(host)
        }

        if let cached = leafCache[normalized] {
            return cached
        }

        let leafKey = X509.Certificate.PrivateKey(P256.Signing.PrivateKey())
        let leafName = try DistinguishedName {
            OrganizationName("PostProxyCore MITM")
            CommonName(normalized)
        }

        let leafCertificate = try X509.Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: leafKey.publicKey,
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(60 * 60 * 24 * 365),
            issuer: rootCertificate.subject,
            subject: leafName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try X509.Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true, keyEncipherment: true)
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(normalized)])
                SubjectKeyIdentifier(hash: leafKey.publicKey)
            },
            issuerPrivateKey: rootKey
        )

        let leafCertPEM = try leafCertificate.serializeAsPEM().pemString
        let leafKeyPEM = try leafKey.serializeAsPEM().pemString

        let nioLeafCert = try NIOSSLCertificate(bytes: Array(leafCertPEM.utf8), format: .pem)
        let nioRootCert = try NIOSSLCertificate(bytes: Array(rootCertificatePEMString.utf8), format: .pem)
        let nioLeafKey = try NIOSSLPrivateKey(bytes: Array(leafKeyPEM.utf8), format: .pem)

        let identity = MITMTLSIdentity(certificateChain: [nioLeafCert, nioRootCert], privateKey: nioLeafKey)
        leafCache[normalized] = identity
        return identity
    }

    private static func makeRootIdentity(caCommonName: String) throws -> RootIdentity {
        let key = X509.Certificate.PrivateKey(P256.Signing.PrivateKey())
        let rootName = try DistinguishedName {
            OrganizationName("PostProxyCore")
            CommonName(caCommonName)
        }

        let certificate = try X509.Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: key.publicKey,
            notValidBefore: Date().addingTimeInterval(-86400),
            notValidAfter: Date().addingTimeInterval(60 * 60 * 24 * 3650),
            issuer: rootName,
            subject: rootName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try X509.Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                KeyUsage(keyCertSign: true, cRLSign: true)
                SubjectKeyIdentifier(hash: key.publicKey)
            },
            issuerPrivateKey: key
        )

        return RootIdentity(
            key: key,
            certificate: certificate,
            certificatePEM: try certificate.serializeAsPEM().pemString
        )
    }

    private static func loadRootIdentity(from directory: URL) throws -> RootIdentity {
        let keyURL = directory.appendingPathComponent("root-ca-key.pem")
        let certURL = directory.appendingPathComponent("root-ca-cert.pem")

        let keyPEM = try String(contentsOf: keyURL, encoding: .utf8)
        let certPEM = try String(contentsOf: certURL, encoding: .utf8)

        let key = try X509.Certificate.PrivateKey(pemEncoded: keyPEM)
        let certificate = try X509.Certificate(pemEncoded: certPEM)

        return RootIdentity(key: key, certificate: certificate, certificatePEM: certPEM)
    }

    private static func persistRootIdentity(_ identity: RootIdentity, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let keyURL = directory.appendingPathComponent("root-ca-key.pem")
        let certURL = directory.appendingPathComponent("root-ca-cert.pem")

        try identity.key.serializeAsPEM().pemString.write(to: keyURL, atomically: true, encoding: .utf8)
        try identity.certificatePEM.write(to: certURL, atomically: true, encoding: .utf8)
    }

    private static func defaultStorageDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".postproxycore")
            .appendingPathComponent("certificates")
    }
}

#if os(macOS)
public final class MacOSRootTrustManager: RootTrustManaging {
    private let commonName: String
    private let certificatePEM: String

    public init(commonName: String, certificatePEM: String) {
        self.commonName = commonName
        self.certificatePEM = certificatePEM
    }

    public func isRootInstalled() async throws -> Bool {
        let result = try runSecurity([
            "find-certificate",
            "-c", commonName,
            "-a",
            "-p",
            "~/Library/Keychains/login.keychain-db"
        ])
        return result.stdout.contains("-----BEGIN CERTIFICATE-----")
    }

    public func installRootCertificate() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("postproxycore-root-ca.pem")

        try certificatePEM.write(to: tempURL, atomically: true, encoding: .utf8)

        _ = try runSecurity([
            "add-trusted-cert",
            "-d",
            "-r", "trustRoot",
            "-k", "~/Library/Keychains/login.keychain-db",
            tempURL.path
        ])
    }

    public func uninstallRootCertificate() async throws {
        _ = try runSecurity([
            "delete-certificate",
            "-c", commonName,
            "~/Library/Keychains/login.keychain-db"
        ])
    }

    private func runSecurity(_ arguments: [String]) throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments.map { argument in
            (argument as NSString).expandingTildeInPath
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw RootTrustError.commandFailed(stderr.isEmpty ? stdout : stderr)
        }

        return (stdout, stderr)
    }
}
#endif
