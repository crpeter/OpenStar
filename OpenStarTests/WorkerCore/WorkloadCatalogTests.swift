import Foundation
import Testing
@testable import OpenStar

struct WorkloadCatalogTests {
    @Test func existingHandlersAndCapabilitiesRemainRegisteredInOrder() throws {
        let handlers = try WorkloadCatalog.handlers()

        #expect(handlers.map(\.workloadIDs) == [
            ["openstar.lomb-scargle.v1", "openstar.tess-period-search.v1"],
            ["openstar.box-period-search.v1"]
        ])
        #expect(handlers.flatMap(\.capabilities) == [
            WorkloadCapability(
                workloadID: "openstar.lomb-scargle.v1",
                executionBackends: [.metal],
                validatorID: LombScargleValidation.validatorID
            ),
            WorkloadCapability(
                workloadID: "openstar.tess-period-search.v1",
                executionBackends: [.metal],
                validatorID: LombScargleValidation.validatorID
            ),
            WorkloadCapability(
                workloadID: "openstar.box-period-search.v1",
                executionBackends: [.cpu],
                validatorID: nil
            )
        ])
    }

    @Test func futureModulesAdvertiseNothing() {
        #expect(CurveGridWorkloadModule.handlers().isEmpty)
        #expect(SignalCorrelationWorkloadModule.handlers().isEmpty)
        #expect(SeasonalChangePointWorkloadModule.handlers().isEmpty)
        #expect(HarmonicGridWorkloadModule.handlers().isEmpty)
    }

    @Test func catalogConstructionIsDeterministic() throws {
        let first = try WorkloadCatalog.handlers()
        let second = try WorkloadCatalog.handlers()
        #expect(first.map(\.workloadIDs) == second.map(\.workloadIDs))
        #expect(first.flatMap(\.capabilities) == second.flatMap(\.capabilities))
    }

    @Test func duplicateWorkloadIDsFailClosed() {
        #expect(throws: WorkloadRouterError.self) {
            try WorkloadRouter(handlers: [
                CatalogTestHandler(workloadID: "duplicate"),
                CatalogTestHandler(workloadID: "duplicate")
            ])
        }
    }

    @Test func unsupportedWorkloadsFailClosed() async throws {
        let router = try WorkloadRouter(handlers: [
            CatalogTestHandler(workloadID: "supported")
        ])
        let unit = WorkUnit(
            id: UUID(), projectID: "project", workloadID: "unsupported"
        )

        await #expect(throws: WorkloadRouterError.self) {
            try await router.execute(workUnit: unit, datasetData: nil)
        }
    }

    @Test func legacyWorkUnitJSONDecodesWithoutSchemaIdentities() throws {
        let id = UUID()
        let unit = try JSONDecoder().decode(
            WorkUnit.self,
            from: Data(
                #"{"id":"\#(id.uuidString)","projectID":"p","workloadID":"openstar.box-period-search.v1"}"#.utf8
            )
        )
        #expect(unit.workloadID == "openstar.box-period-search.v1")
        #expect(unit.datasetSchemaID == nil)
        #expect(unit.payloadSchemaID == nil)
        #expect(unit.resultSchemaID == nil)
    }
}

private struct CatalogTestHandler: OpenStarWorkloadHandler {
    let workloadIDs: [String]
    let capabilities: [WorkloadCapability]

    init(workloadID: String) {
        workloadIDs = [workloadID]
        capabilities = [.init(
            workloadID: workloadID, executionBackends: [.cpu], validatorID: nil
        )]
    }

    func execute(workUnit: WorkUnit, datasetData: Data?) async throws -> WorkloadExecution {
        WorkloadExecution(
            duration: 0, payload: .null, summary: nil,
            legacyResultFields: .none
        )
    }
}
