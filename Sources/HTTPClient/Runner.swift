import Foundation
import Protocol

public struct RequestRunResult: Sendable, Equatable {
    public var itemID: UUID
    public var itemName: String
    public var request: HTTPRequest
    public var response: HTTPResponse
    public var report: TestReport
    public var environment: Environment

    public init(
        itemID: UUID,
        itemName: String,
        request: HTTPRequest,
        response: HTTPResponse,
        report: TestReport,
        environment: Environment
    ) {
        self.itemID = itemID
        self.itemName = itemName
        self.request = request
        self.response = response
        self.report = report
        self.environment = environment
    }
}

public struct CollectionRunResult: Sendable, Equatable {
    public var collectionID: UUID
    public var collectionName: String
    public var itemResults: [RequestRunResult]
    public var environment: Environment

    public init(
        collectionID: UUID,
        collectionName: String,
        itemResults: [RequestRunResult],
        environment: Environment
    ) {
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.itemResults = itemResults
        self.environment = environment
    }
}

public enum RunnerError: Error, Sendable {
    case renderFailed(RequestRenderError)
}

public final class CollectionRunner: @unchecked Sendable {
    private let sender: any RequestSending

    public init(sender: any RequestSending = NIORequestSender()) {
        self.sender = sender
    }

    public func run(item: RequestItem, environment: Environment) async throws -> RequestRunResult {
        var runtimeEnvironment = environment

        var request: HTTPRequest
        switch item.request.render(using: runtimeEnvironment) {
        case .success(let rendered):
            request = rendered
        case .failure(let error):
            throw RunnerError.renderFailed(error)
        }

        ScriptRunner.applyPreRequest(
            item.preRequest,
            request: &request,
            environment: &runtimeEnvironment
        )

        let response = try await sender.send(request)
        let report = ScriptRunner.runTests(
            item.tests,
            response: response,
            environment: &runtimeEnvironment
        )

        return RequestRunResult(
            itemID: item.id,
            itemName: item.name,
            request: request,
            response: response,
            report: report,
            environment: runtimeEnvironment
        )
    }

    public func run(
        collection: RequestCollection,
        environment: Environment,
        stopOnFailure: Bool = false
    ) async throws -> CollectionRunResult {
        var runtimeEnvironment = environment
        var results: [RequestRunResult] = []

        for item in collection.items {
            let result = try await run(item: item, environment: runtimeEnvironment)
            results.append(result)
            runtimeEnvironment = result.environment

            if stopOnFailure, !result.report.succeeded {
                break
            }
        }

        return CollectionRunResult(
            collectionID: collection.id,
            collectionName: collection.name,
            itemResults: results,
            environment: runtimeEnvironment
        )
    }
}
