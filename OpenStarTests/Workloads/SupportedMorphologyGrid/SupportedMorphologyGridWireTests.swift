import Foundation
import Testing
@testable import OpenStar

struct SupportedMorphologyGridWireTests {
    private typealias Fixture = SupportedMorphologyGridFixture

    @Test func frozenIdentitiesAndCPUCapabilityAreExact() throws {
        #expect(SupportedMorphologyGridContract.executionContractID == "openstar.supported-morphology-grid-execution.v1")
        #expect(SupportedMorphologyGridContract.executionContractVersion == "1.0")
        #expect(SupportedMorphologyGridContract.supportPolicyID == "openstar.morphology-support.two-effective-widths.v1")
        #expect(SupportedMorphologyGridContract.morphologyFamilyID == "openstar.microlensing-residual-morphology.v1")
        #expect(SupportedMorphologyGridContract.componentTemplateFamilyID == "openstar.curve-family.symmetric-radial-amplification.v1")
        let handler = SupportedMorphologyGridWorkloadHandler()
        #expect(handler.workloadIDs == ["openstar.supported-morphology-grid.v1"])
        #expect(handler.desiredBatchCount == 8)
        #expect(handler.capabilities == [WorkloadCapability(
            workloadID: "openstar.supported-morphology-grid.v1", executionBackends: [.cpu],
            validatorID: "openstar.supported-morphology-grid.local-double.v1",
            datasetSchemaID: "openstar.dataset.supported-morphology-grid.v1",
            payloadSchemaID: "openstar.payload.supported-morphology-grid-shard.v1",
            resultSchemaID: "openstar.result.supported-morphology-grid-shard.v1"
        )])
        #expect(try SupportedMorphologyGridWorkloadModule.handlers().count == 1)
    }

    @Test func datasetIdentitiesAndPolicyAreRequiredBeforeNumericalDecoding() throws {
        let keys = ["datasetSchemaID", "morphologyFamilyID", "componentTemplateFamilyID",
                    "executionContractID", "executionContractVersion", "supportPolicyID", "modelClassID"]
        for model in Fixture.models {
            for key in keys {
                for replacement in ["unknown", NSNull(), 1, true] as [Any] {
                    var object = Fixture.object(model: model)
                    object[key] = replacement
                    #expect(throws: MorphologyGridError.self) { try Fixture.decode(object) }
                }
                var missing = Fixture.object(model: model)
                missing.removeValue(forKey: key)
                #expect(throws: MorphologyGridError.self) { try Fixture.decode(missing) }
            }
            var extensible = Fixture.object(model: model)
            extensible["opaqueMetadata"] = ["unused": true]
            extensible["reference"] = NSNull()
            #expect(try Fixture.decode(extensible).modelClassID == model)
        }
        var old = Fixture.object()
        old["datasetSchemaID"] = MorphologyGridContract.datasetSchemaID
        old["executionContractID"] = MorphologyGridContract.executionContractID
        #expect(throws: MorphologyGridError.self) { try Fixture.decode(old) }

        var badIdentityAndNumbers = Fixture.object()
        badIdentityAndNumbers["supportPolicyID"] = "unknown"
        badIdentityAndNumbers["morphologyGrid"] = NSNull()
        do {
            _ = try Fixture.decode(badIdentityAndNumbers)
            Issue.record("Expected identity rejection")
        } catch let error as MorphologyGridError {
            #expect(error == .invalidDataset("supportPolicyID is invalid"))
        }
    }

    @Test func nestedStructuresRemainStrictForEveryModel() throws {
        for model in Fixture.models {
            let original = Fixture.object(model: model)
            for key in ["genericSeriesID", "coordinates", "values", "inverseVariances", "extra"] {
                var object = original
                var series = object["series"] as! [[String: Any]]
                if key == "extra" { series[0][key] = 1 } else { series[0].removeValue(forKey: key) }
                object["series"] = series
                #expect(throws: MorphologyGridError.self) { try Fixture.decode(object) }
            }
            let grid = original["morphologyGrid"] as! [String: Any]
            for key in Array(grid.keys) + ["extra"] {
                var object = original
                var malformed = grid
                if key == "extra" { malformed[key] = Fixture.axis() } else { malformed.removeValue(forKey: key) }
                object["morphologyGrid"] = malformed
                #expect(throws: MorphologyGridError.self) { try Fixture.decode(object) }
            }
            for key in grid.keys {
                var object = original
                var malformed = grid
                var axis = grid[key] as! [String: Any]
                axis["extra"] = 0
                malformed[key] = axis
                object["morphologyGrid"] = malformed
                #expect(throws: MorphologyGridError.self) { try Fixture.decode(object) }
            }
        }
    }

    @Test func finiteSamplesCanonicalOrderingAndSafeGridRangesFailClosed() throws {
        var cases: [[String: Any]] = []
        for field in ["id", "candidatesPerWorkUnit"] {
            for value in ["", NSNull(), -1, 0, 1.5, 9_007_199_254_740_992] as [Any] {
                var object = Fixture.object()
                object[field] = value
                cases.append(object)
            }
        }
        for coordinates in [[3.0, 3, 5], [5.0, 4, 3]] {
            var object = Fixture.object()
            object["series"] = [Fixture.series(coordinates)]
            cases.append(object)
        }
        for weights in [[1.0, -1, 1], [0.0, 0, 0], [1.0, 0, 0], [1.0]] {
            var object = Fixture.object()
            object["series"] = [Fixture.series([3, 4, 5], weights: weights)]
            cases.append(object)
        }
        for axis in [
            Fixture.axis(0, count: 0), Fixture.axis(0, step: 0), Fixture.axis(0, count: 9_007_199_254_740_992),
            Fixture.axis(0, count: 9_007_199_254_740_991), // Sample-candidate product is unsafe.
            Fixture.axis(Double.greatestFiniteMagnitude, step: Double.greatestFiniteMagnitude, count: 2),
            ["values": [0.0, 0.0]], ["values": []],
        ] as [[String: Any]] {
            var object = Fixture.object()
            var grid = object["morphologyGrid"] as! [String: Any]
            grid["centerAxis"] = axis
            object["morphologyGrid"] = grid
            cases.append(object)
        }
        for logValue in [-1000.0, 1000.0] {
            var object = Fixture.object()
            var grid = object["morphologyGrid"] as! [String: Any]
            grid["logScaleAxis"] = Fixture.axis(logValue)
            object["morphologyGrid"] = grid
            cases.append(object)
        }
        for ids in [["series-001", "series-001"], ["series-002", "series-001"]] {
            var object = Fixture.object()
            object["series"] = ids.map { Fixture.series([3, 4, 5], id: $0) }
            cases.append(object)
        }
        var zeroSeparation = Fixture.object(model: .orderedNegativePositiveDoublet)
        var grid = zeroSeparation["morphologyGrid"] as! [String: Any]
        grid["separationAxis"] = Fixture.axis(0)
        zeroSeparation["morphologyGrid"] = grid
        cases.append(zeroSeparation)
        var noPairs = Fixture.object(model: .independentPulses)
        grid = noPairs["morphologyGrid"] as! [String: Any]
        grid["centerAxis"] = Fixture.axis(0, count: 1)
        noPairs["morphologyGrid"] = grid
        cases.append(noPairs)
        for object in cases {
            #expect(throws: MorphologyGridError.self) { try Fixture.decode(object) }
        }
        let json = String(decoding: try Fixture.data(Fixture.object()), as: UTF8.self)
        for replacement in ["1e999", "NaN", "Infinity"] {
            let arrayStart = try #require(json.range(of: "\"coordinates\":[")).upperBound
            let firstComma = try #require(json[arrayStart...].firstIndex(of: ","))
            var nonfinite = json
            nonfinite.replaceSubrange(arrayStart..<firstComma, with: replacement)
            #expect(throws: MorphologyGridError.self) {
                try SupportedMorphologyGridJSONDatasetDecoder().decode(Data(nonfinite.utf8))
            }
        }
    }

    @Test func workUnitIdentitiesPolicyExactFieldsAndSafeRangesAreStrict() async throws {
        let handler = SupportedMorphologyGridWorkloadHandler()
        let data = try Fixture.data(Fixture.object())
        let badUnits = [
            Fixture.unit(workloadID: MorphologyGridContract.workloadID), Fixture.unit(workloadID: "unknown"),
            Fixture.unit(datasetSchemaID: nil), Fixture.unit(datasetSchemaID: MorphologyGridContract.datasetSchemaID),
            Fixture.unit(payloadSchemaID: nil), Fixture.unit(payloadSchemaID: MorphologyGridContract.payloadSchemaID),
            Fixture.unit(resultSchemaID: nil), Fixture.unit(resultSchemaID: MorphologyGridContract.resultSchemaID),
            Fixture.unit(datasetID: nil), Fixture.unit(datasetID: "other"),
            Fixture.unit(start: 2, count: 1), Fixture.unit(start: 1, count: 2),
            Fixture.unit(model: .orderedNegativePositiveDoublet),
        ]
        for unit in badUnits { await expectInvalid(handler, unit: unit, data: data) }
        let original = try #require(Fixture.payload().objectValue)
        for key in original.keys {
            var missing = original
            missing.removeValue(forKey: key)
            await expectInvalid(handler, unit: Fixture.unit(payload: .object(missing)), data: data)
        }
        var extra = original
        extra["extra"] = .number(1)
        await expectInvalid(handler, unit: Fixture.unit(payload: .object(extra)), data: data)
        for key in ["supportPolicyID", "morphologyFamilyID", "modelClassID"] {
            for value in [JSONValue.null, .number(1), .bool(true), .string("unknown")] {
                var payload = original
                payload[key] = value
                await expectInvalid(handler, unit: Fixture.unit(payload: .object(payload)), data: data)
            }
        }
        for key in ["gridStartIndex", "gridCount"] {
            for value in [JSONValue.null, .bool(true), .string("1"), .number(-1), .number(0.5),
                                     .number(.infinity), .number(.nan), .number(9_007_199_254_740_992)] {
                var payload = original
                payload[key] = value
                await expectInvalid(handler, unit: Fixture.unit(payload: .object(payload)), data: data)
            }
        }
        for payload in [JSONValue.null, .array([]), .string("payload")] {
            await expectInvalid(handler, unit: Fixture.unit(payload: payload), data: data)
        }
        await expectInvalid(handler, unit: Fixture.unit(count: 0), data: data)
        await expectInvalid(handler, unit: Fixture.unit(), data: nil)
        await expectInvalid(handler, unit: Fixture.unit(), data: Data("{}".utf8))
        // Old handler must reject the new identity tuple even with a valid old dataset.
        let oldDataset = try Fixture.numericalDataset(Fixture.object())
        var oldObject = Fixture.object()
        oldObject["datasetSchemaID"] = oldDataset.datasetSchemaID
        oldObject["executionContractID"] = oldDataset.executionContractID
        await #expect(throws: MorphologyGridError.self) {
            try await MorphologyGridWorkloadHandler().execute(workUnit: Fixture.unit(), datasetData: Fixture.data(oldObject))
        }
    }

    @Test func batchDecodesOnceAndFansOutMissingMalformedAndCancelledDatasets() async throws {
        let decoder = SupportedCountingDecoder()
        let handler = SupportedMorphologyGridWorkloadHandler(datasetDecoder: decoder)
        let units = [Fixture.unit(), Fixture.unit(count: 1), Fixture.unit(count: 0)]
        let members = try await handler.executeBatch(workUnits: units, datasetData: Fixture.data(Fixture.object()))
        #expect(decoder.count == 1)
        #expect(members.count == 3)
        #expect(try members[0].result.get().payload.objectValue?["bestCandidate"] != .null)
        #expect(try members[1].result.get().payload.objectValue?["bestCandidate"] == .null)
        #expect(throws: MorphologyGridError.self) { try members[2].result.get() }
        for data in [nil, Data("{}".utf8)] as [Data?] {
            let failed = try await handler.executeBatch(workUnits: units, datasetData: data)
            #expect(failed.map(\.workUnit.id) == units.map(\.id))
            for member in failed { #expect(throws: MorphologyGridError.self) { try member.result.get() } }
        }
        let cancelled = SupportedMorphologyGridWorkloadHandler(datasetDecoder: SupportedCancellingDecoder())
        let data = try Fixture.data(Fixture.object())
        await #expect(throws: WorkloadCancellation.self) {
            try await cancelled.execute(workUnit: units[0], datasetData: data)
        }
        for member in try await cancelled.executeBatch(workUnits: units, datasetData: data) {
            #expect(throws: WorkloadCancellation.self) { try member.result.get() }
        }
    }

    private func expectInvalid(_ handler: SupportedMorphologyGridWorkloadHandler, unit: WorkUnit, data: Data?) async {
        do {
            _ = try await handler.execute(workUnit: unit, datasetData: data)
            Issue.record("Expected invalid input")
        } catch let error as MorphologyGridError {
            #expect(error.workFailureKind == .invalidInput)
        } catch { Issue.record("Unexpected error: \(error)") }
    }
}

nonisolated
private final class SupportedCountingDecoder: SupportedMorphologyGridDatasetDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var decodeCount = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return decodeCount
    }
    func decode(_ data: Data) throws -> SupportedMorphologyGridDataset {
        lock.lock()
        decodeCount += 1
        lock.unlock()
        return try SupportedMorphologyGridJSONDatasetDecoder().decode(data)
    }
}

nonisolated
private struct SupportedCancellingDecoder: SupportedMorphologyGridDatasetDecoding {
    func decode(_ data: Data) throws -> SupportedMorphologyGridDataset { throw CancellationError() }
}
