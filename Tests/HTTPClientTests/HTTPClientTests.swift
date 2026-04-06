import Foundation
import Testing
@testable import HTTPClient

@Test("Request sender conforms to protocol")
func senderConformance() {
    let sender: any RequestSending = NIORequestSender()
    #expect(type(of: sender) == NIORequestSender.self)
}
