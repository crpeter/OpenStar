import Foundation
import Testing
@testable import OpenStar

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
