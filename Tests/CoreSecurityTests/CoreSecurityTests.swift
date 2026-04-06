import Foundation
import Testing
@testable import CoreSecurity

@Test("Root CA is persisted and reused")
func rootCAPersistence() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("postproxycore-tests")
        .appendingPathComponent(UUID().uuidString)

    let manager1 = InMemoryCertificateManager(storageDirectory: tempDir)
    let pem1 = await manager1.rootCertificatePEM()

    let manager2 = InMemoryCertificateManager(storageDirectory: tempDir)
    let pem2 = await manager2.rootCertificatePEM()

    #expect(pem1 == pem2)
}

@Test("Leaf certificate identity is cached by host")
func leafIdentityCache() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("postproxycore-tests")
        .appendingPathComponent(UUID().uuidString)

    let manager = InMemoryCertificateManager(storageDirectory: tempDir)
    let first = try await manager.leafIdentity(for: "api.example.com")
    let second = try await manager.leafIdentity(for: "api.example.com")

    #expect(first.certificateChain.count == second.certificateChain.count)
    #expect(first.privateKey == second.privateKey)
}
