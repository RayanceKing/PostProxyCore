import Foundation
import Testing
@testable import Protocol
@testable import Storage

@Test("History store returns newest records first")
func historyStoreOrdering() async {
    let store = InMemoryHistoryStore()

    for index in 1...3 {
        let request = HTTPRequest(
            name: "r\(index)",
            url: URL(string: "https://example.com/\(index)")!,
            method: .get
        )
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(), durationMS: index)
        await store.save(HistoryRecord(request: request, response: response))
    }

    let list = await store.list(limit: 2)
    #expect(list.count == 2)
    #expect(list[0].request.name == "r3")
    #expect(list[1].request.name == "r2")
}
