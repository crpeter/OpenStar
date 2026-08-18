import Foundation
import Testing
@testable import OpenStar

@Suite(.serialized)
struct OpenStarTests {
    private let workID = UUID()

    @Test func integerJSONConversionRejectsOutOfRangeNumbers() {
        #expect(JSONValue.number(4).intValue == 4)
        #expect(JSONValue.number(4.5).intValue == nil)
        #expect(JSONValue.number(Double.greatestFiniteMagnitude).intValue == nil)
    }

    @Test func lombScargleDecodesGenericScalarTimeSeriesDataset() throws {
        let data = Data(
            #"{"coordinates":[0,1,2],"values":[4,5,6]}"#.utf8
        )

        let dataset = try JSONDecoder().decode(
            LombScargleDataset.self,
            from: data
        )

        #expect(dataset.id == nil)
        #expect(dataset.coordinates == [0, 1, 2])
        #expect(dataset.values == [4, 5, 6])
    }

    @Test func lombScargleDecodesExistingTimeFluxDataset() throws {
        let data = Data(
            #"{"id":"legacy","mission":"TESS","times":[0,1],"flux":[2,3]}"#.utf8
        )

        let dataset = try JSONDecoder().decode(
            LombScargleDataset.self,
            from: data
        )

        #expect(dataset.id == "legacy")
        #expect(dataset.coordinates == [0, 1])
        #expect(dataset.values == [2, 3])
    }

    @Test func genericDatasetFieldsTakePrecedenceOverLegacyAliases() throws {
        let data = Data(
            #"{"coordinates":[1],"values":[2],"times":[3],"flux":[4]}"#.utf8
        )

        let dataset = try JSONDecoder().decode(
            LombScargleDataset.self,
            from: data
        )

        #expect(dataset.coordinates == [1])
        #expect(dataset.values == [2])
    }

    @Test func lombScargleAdvertisesGenericIDAndCompatibilityAlias() {
        #expect(LombScargleWorker.workloadID == "openstar.lomb-scargle.v1")
        #expect(
            LombScargleWorker.legacyWorkloadID ==
                "openstar.tess-period-search.v1"
        )
    }

    @Test func lombScargleUsesGenericPayload() throws {
        let unit = workUnit(
            payload: .object([
                "frequencyStartIndex": .number(40),
                "startFrequency": .number(0.25),
                "frequencyStep": .number(0.01),
                "frequencyCount": .number(20)
            ]),
            legacyStartFrequency: 99
        )

        let payload = try LombScargleWorker.workPayload(from: unit)

        #expect(payload.frequencyStartIndex == 40)
        #expect(payload.startFrequency == 0.25)
        #expect(payload.frequencyStep == 0.01)
        #expect(payload.frequencyCount == 20)
    }

    @Test func lombScargleSupportsExistingLegacyFields() throws {
        let unit = workUnit(
            payload: nil,
            legacyStartFrequency: 0.5
        )

        let payload = try LombScargleWorker.workPayload(from: unit)

        #expect(payload.frequencyStartIndex == 12)
        #expect(payload.startFrequency == 0.5)
        #expect(payload.frequencyStep == 0.02)
        #expect(payload.frequencyCount == 30)
    }

    @Test func lombScargleRejectsMalformedGenericPayloadRatherThanUsingLegacy() {
        let unit = workUnit(
            payload: .array([]),
            legacyStartFrequency: 0.5
        )

        #expect(throws: LombScargleError.self) {
            try LombScargleWorker.workPayload(from: unit)
        }
    }

    @Test func lombScargleRejectsUnsafeGridDimensions() {
        let unit = workUnit(
            payload: .object([
                "frequencyStartIndex": .number(-1),
                "startFrequency": .number(0.25),
                "frequencyStep": .number(0.01),
                "frequencyCount": .number(20)
            ]),
            legacyStartFrequency: nil
        )

        #expect(throws: LombScargleError.self) {
            try LombScargleWorker.workPayload(from: unit)
        }
    }

    @Test func workloadRouterSelectsHandlerByExactID() async throws {
        let router = try WorkloadRouter(
            handlers: [
                StubHandler(workloadID: "alpha"),
                StubHandler(workloadID: "beta")
            ]
        )

        let execution = try await router.execute(
            workUnit: workUnit(
                workloadID: "beta",
                payload: nil,
                legacyStartFrequency: nil
            ),
            datasetData: nil
        )

        #expect(execution.payload == .string("beta"))
    }

    @Test func workloadRouterRejectsDuplicateIDs() {
        #expect(throws: WorkloadRouterError.self) {
            try WorkloadRouter(
                handlers: [
                    StubHandler(workloadID: "duplicate"),
                    StubHandler(workloadID: "duplicate")
                ]
            )
        }
    }

    @Test func projectScopedDatasetAndStatusPathsEncodeIdentifiers() async throws {
        let recorder = RequestRecorder { request in
            switch request.url.flatMap({
                URLComponents(
                    url: $0,
                    resolvingAgainstBaseURL: false
                )?.percentEncodedPath
            }) {
            case "/v1/projects/project%20a/datasets/data%2Fset":
                return (Data("scoped".utf8), 200)
            case "/v1/projects/project%20a/status",
                 "/v1/projects/current/status":
                return (Self.statusData, 200)
            default:
                return (Data(), 404)
            }
        }
        let client = coordinatorClient(recorder: recorder)

        let data = try await client.datasetData(
            projectID: "project a",
            datasetID: "data/set"
        )
        _ = try await client.projectStatus(projectID: "project a")
        _ = try await client.projectStatus()

        #expect(data == Data("scoped".utf8))
        #expect(recorder.paths == [
            "/v1/projects/project%20a/datasets/data%2Fset",
            "/v1/projects/project%20a/status",
            "/v1/projects/current/status"
        ])
    }

    @MainActor
    @Test func datasetCacheIsScopedByProject() async throws {
        let recorder = RequestRecorder { request in
            let path = request.url!.path
            return (Data(path.utf8), 200)
        }
        let manager = ContributionManager(
            coordinator: coordinatorClient(recorder: recorder),
            workloadRouter: try WorkloadRouter(handlers: [])
        )

        let first = try await manager.datasetData(
            projectID: "project-a",
            datasetID: "dataset-x"
        )
        let second = try await manager.datasetData(
            projectID: "project-b",
            datasetID: "dataset-x"
        )
        let cached = try await manager.datasetData(
            projectID: "project-a",
            datasetID: "dataset-x"
        )

        #expect(first != second)
        #expect(cached == first)
        #expect(recorder.paths.count == 2)
    }

    @MainActor
    @Test func completedDisplayedProjectDoesNotPreventClaim() async throws {
        let recorder = RequestRecorder { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/nodes/register"):
                return (
                    Data(#"{"accepted":true,"message":"ok"}"#.utf8),
                    200
                )
            case ("GET", "/v1/projects/current/status"):
                return (Self.statusData, 200)
            case ("POST", "/v1/work/claim"):
                return (Data(), 204)
            default:
                return (Data(), 404)
            }
        }
        let manager = ContributionManager(
            coordinator: coordinatorClient(recorder: recorder),
            workloadRouter: try WorkloadRouter(handlers: [])
        )

        manager.start()
        try await Task.sleep(for: .milliseconds(200))
        manager.stop()

        #expect(recorder.paths.contains("/v1/work/claim"))
    }

    private static let statusData = Data(
        #"{"projectID":"display","workloadID":"test","totalWorkUnits":1,"pendingWorkUnits":0,"assignedWorkUnits":0,"completedWorkUnits":1,"retryCount":0}"#.utf8
    )

    private func coordinatorClient(
        recorder: RequestRecorder
    ) -> CoordinatorClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecorderURLProtocol.self]
        RecorderURLProtocol.recorder = recorder
        return CoordinatorClient(
            baseURL: URL(string: "https://coordinator.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func workUnit(
        workloadID: String = LombScargleWorker.workloadID,
        payload: JSONValue?,
        legacyStartFrequency: Double?
    ) -> WorkUnit {
        WorkUnit(
            id: workID,
            projectID: "project",
            workloadID: workloadID,
            datasetID: "dataset",
            payload: payload,
            frequencyStartIndex: 12,
            startFrequency: legacyStartFrequency,
            frequencyStep: 0.02,
            frequencyCount: 30
        )
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let response: (URLRequest) -> (Data, Int)
    private var recordedPaths: [String] = []

    init(response: @escaping (URLRequest) -> (Data, Int)) {
        self.response = response
    }

    var paths: [String] {
        lock.withLock { recordedPaths }
    }

    func handle(_ request: URLRequest) -> (Data, Int) {
        lock.withLock {
            recordedPaths.append(
                URLComponents(
                    url: request.url!,
                    resolvingAgainstBaseURL: false
                )!.percentEncodedPath
            )
        }
        return response(request)
    }
}

private final class RecorderURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder: RequestRecorder!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }
    override func startLoading() {
        let (data, status) = Self.recorder.handle(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct StubHandler: OpenStarWorkloadHandler {
    let workloadIDs: [String]
    let capabilities: [WorkloadCapability]

    init(workloadID: String) {
        workloadIDs = [workloadID]
        capabilities = [
            WorkloadCapability(
                workloadID: workloadID,
                executionBackends: [.cpu],
                validatorID: nil
            )
        ]
    }

    func execute(
        workUnit: WorkUnit,
        datasetData: Data?
    ) async throws -> WorkloadExecution {
        WorkloadExecution(
            duration: 0,
            payload: .string(workUnit.workloadID),
            summary: nil,
            legacyResultFields: .none
        )
    }
}
