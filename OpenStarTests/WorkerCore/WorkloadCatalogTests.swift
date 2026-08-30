import Foundation
import Testing
@testable import OpenStar

struct WorkloadCatalogTests {
    @Test func legacyHandlersAndCapabilitiesRemainRegisteredFirst() throws {
        let handlers = try WorkloadCatalog.handlers()
        let legacyHandlers = Array(handlers.prefix(2))

        #expect(legacyHandlers.map(\.workloadIDs) == [
            ["openstar.lomb-scargle.v1", "openstar.tess-period-search.v1"],
            ["openstar.box-period-search.v1"]
        ])
        #expect(legacyHandlers.flatMap(\.capabilities) == [
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

    @Test func catalogIncludesModuleHandlersInOrder() throws {
        let catalogHandlers = try WorkloadCatalog.handlers()

        var moduleHandlers: [any OpenStarWorkloadHandler] = []
        moduleHandlers.append(
            contentsOf: try CurveGridWorkloadModule.handlers()
        )
        moduleHandlers.append(
            contentsOf: try SignalCorrelationWorkloadModule.handlers()
        )
        moduleHandlers.append(
            contentsOf: try SeasonalChangePointWorkloadModule.handlers()
        )
        moduleHandlers.append(
            contentsOf: try HarmonicGridWorkloadModule.handlers()
        )

        let catalogModuleHandlers = Array(catalogHandlers.dropFirst(2))

        #expect(catalogHandlers.count == 2 + moduleHandlers.count)
        #expect(
            catalogModuleHandlers.map(\.workloadIDs)
                == moduleHandlers.map(\.workloadIDs)
        )
        #expect(
            catalogModuleHandlers.flatMap(\.capabilities)
                == moduleHandlers.flatMap(\.capabilities)
        )
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

    @Test func schemaAwareCapabilityEncodesAllSchemaIdentities() throws {
        let capability = WorkloadCapability(
            workloadID: "schema-aware",
            executionBackends: [.cpu],
            validatorID: nil,
            datasetSchemaID: "dataset.v1",
            payloadSchemaID: "payload.v1",
            resultSchemaID: "result.v1"
        )
        let encoded = try encodedObject(capability)
        let object = try #require(encoded)

        #expect(object["datasetSchemaID"] as? String == "dataset.v1")
        #expect(object["payloadSchemaID"] as? String == "payload.v1")
        #expect(object["resultSchemaID"] as? String == "result.v1")
    }

    @Test func legacyCapabilityOmitsNilSchemaIdentities() throws {
        let capability = WorkloadCapability(
            workloadID: "legacy", executionBackends: [.cpu], validatorID: nil
        )
        let encoded = try encodedObject(capability)
        let object = try #require(encoded)

        #expect(object["datasetSchemaID"] == nil)
        #expect(object["payloadSchemaID"] == nil)
        #expect(object["resultSchemaID"] == nil)
    }

    @Test func workUnitDecodesSchemaIdentityTuple() throws {
        let id = UUID()
        let unit = try JSONDecoder().decode(
            WorkUnit.self,
            from: Data(
                """
                {"id":"\(id.uuidString)","projectID":"p","workloadID":"w",\
                "datasetSchemaID":"dataset.v1","payloadSchemaID":"payload.v1",\
                "resultSchemaID":"result.v1"}
                """.utf8
            )
        )

        #expect(unit.datasetSchemaID == "dataset.v1")
        #expect(unit.payloadSchemaID == "payload.v1")
        #expect(unit.resultSchemaID == "result.v1")
    }

    @Test func successfulResultEchoesResultSchemaIdentity() {
        let member = WorkloadBatchMember(
            workUnit: schemaWorkUnit(),
            result: .success(WorkloadExecution(
                duration: 1, payload: .null, summary: nil,
                legacyResultFields: .none
            ))
        )

        #expect(
            workResult(for: member, nodeID: UUID()).resultSchemaID
                == "result.v1"
        )
    }

    @Test func failedResultEchoesResultSchemaIdentity() {
        let member = WorkloadBatchMember(
            workUnit: schemaWorkUnit(),
            result: .failure(WorkloadCancellation())
        )

        #expect(
            workResult(for: member, nodeID: UUID()).resultSchemaID
                == "result.v1"
        )
    }

    private func encodedObject<T: Encodable>(
        _ value: T
    ) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(value)
        ) as? [String: Any]
    }

    private func schemaWorkUnit() -> WorkUnit {
        WorkUnit(
            id: UUID(), projectID: "project", workloadID: "workload",
            resultSchemaID: "result.v1"
        )
    }
}

private struct CatalogTestHandler: OpenStarWorkloadHandler {
    let workloadIDs: [String]
    let capabilities: [WorkloadCapability]

    init(workloadID: String) {
        workloadIDs = [workloadID]
        capabilities = [.init(
            workloadID: workloadID,
            executionBackends: [.cpu],
            validatorID: nil
        )]
    }

    func execute(
        workUnit: WorkUnit,
        datasetData: Data?
    ) async throws -> WorkloadExecution {
        WorkloadExecution(
            duration: 0,
            payload: .null,
            summary: nil,
            legacyResultFields: .none
        )
    }
}
