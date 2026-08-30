import Foundation
import Testing
@testable import OpenStar

struct CurveGridWorkloadTests {
    @Test
    func capabilityModuleCatalogAndBatchContractAreExact() throws {
        let worker = CurveGridWorkloadHandler()
        #expect(worker.workloadIDs == ["openstar.curve-grid.v1"])
        #expect(worker.capabilities == [
            WorkloadCapability(
                workloadID: "openstar.curve-grid.v1",
                executionBackends: [.cpu],
                validatorID: "openstar.curve-grid.local-double.v1",
                datasetSchemaID: "openstar.dataset.curve-grid.v1",
                payloadSchemaID: "openstar.payload.curve-grid-shard.v1",
                resultSchemaID: "openstar.result.curve-grid-shard.v1"
            ),
        ])
        #expect(worker.desiredBatchCount == 8)

        let moduleHandlers = try CurveGridWorkloadModule.handlers()
        #expect(moduleHandlers.count == 1)
        #expect(moduleHandlers[0].workloadIDs == ["openstar.curve-grid.v1"])

        let router = try WorkloadRouter()
        #expect(
            router.supportedCapabilities.contains(worker.capabilities[0])
        )

        let curveGridRouter = try WorkloadRouter(handlers: [worker])
        #expect(curveGridRouter.desiredBatchCount == 8)
    }

    @Test
    func strictDatasetAndPayloadDecodePublishedFields() throws {
        let dataset = try CurveGridJSONDatasetDecoder().decode(
            CurveGridFixture.datasetData()
        )
        #expect(dataset.id == CurveGridFixture.datasetID)
        #expect(dataset.datasetSchemaID == CurveGridContract.datasetSchemaID)
        #expect(dataset.coordinates == [-2, -1, 0, 1, 2])
        #expect(dataset.values.count == 5)
        #expect(dataset.inverseVariances == [1, 1, 1, 1, 1])
        #expect(dataset.curveGrid.familyID == CurveGridContract.familyID)
        #expect(dataset.curveGrid.centerAxis.count == 3)
        #expect(dataset.curveGrid.logScaleAxis.count == 3)
        #expect(dataset.curveGrid.logShapeAxis.count == 3)
        #expect(dataset.curveGrid.candidatesPerWorkUnit == 5)

        let payload = try CurveGridPayload(CurveGridFixture.payload())
        #expect(payload.familyID == CurveGridContract.familyID)
        #expect(payload.gridStartIndex == 0)
        #expect(payload.gridCount == 27)
    }

    @Test
    func opaqueTopLevelDatasetFieldsAreIgnored() throws {
        let data = try CurveGridFixture.datasetData { object in
            object["metadata"] = [
                "labels": ["opaque", "coordinator-owned"],
                "revision": 7,
            ]
            object["reference"] = NSNull()
            object["provenance"] = [
                "source": ["kind": "external"],
            ]
        }

        let dataset = try CurveGridJSONDatasetDecoder().decode(data)
        #expect(dataset.id == CurveGridFixture.datasetID)
        #expect(dataset.datasetSchemaID == CurveGridContract.datasetSchemaID)
        #expect(dataset.coordinates == CurveGridFixture.coordinates)
        #expect(dataset.values == CurveGridFixture.values)
        #expect(dataset.inverseVariances == CurveGridFixture.inverseVariances)
        #expect(dataset.curveGrid.familyID == CurveGridContract.familyID)
    }

    @Test
    func missingAndWrongContractIDsAreRejected() async throws {
        let worker = CurveGridWorkloadHandler()
        let data = try CurveGridFixture.datasetData()
        let units = [
            CurveGridFixture.workUnit(workloadID: "wrong"),
            CurveGridFixture.workUnit(datasetSchemaID: nil),
            CurveGridFixture.workUnit(datasetSchemaID: "wrong"),
            CurveGridFixture.workUnit(payloadSchemaID: nil),
            CurveGridFixture.workUnit(payloadSchemaID: "wrong"),
            CurveGridFixture.workUnit(resultSchemaID: nil),
            CurveGridFixture.workUnit(resultSchemaID: "wrong"),
            CurveGridFixture.workUnit(datasetID: nil),
            CurveGridFixture.workUnit(datasetID: "wrong"),
            CurveGridFixture.workUnit(payload: .object([
                "familyID": .string("wrong"),
                "gridStartIndex": .number(0),
                "gridCount": .number(1),
            ])),
            CurveGridFixture.workUnit(payload: .object([
                "familyID": .string(CurveGridContract.familyID),
                "gridStartIndex": .number(0),
                "gridCount": .number(1),
                "extra": .number(1),
            ])),
            CurveGridFixture.workUnit(payload: .null),
        ]
        for unit in units {
            await expectInvalidInput(worker: worker, unit: unit, data: data)
        }

        let wrongDatasetSchema = try CurveGridFixture.datasetData { object in
            object["datasetSchemaID"] = "wrong"
        }
        await expectInvalidInput(
            worker: worker,
            unit: CurveGridFixture.workUnit(),
            data: wrongDatasetSchema
        )

        let wrongDatasetFamily = try CurveGridFixture.datasetData { object in
            var grid = object["curveGrid"] as! [String: Any]
            grid["familyID"] = "wrong"
            object["curveGrid"] = grid
        }
        await expectInvalidInput(
            worker: worker,
            unit: CurveGridFixture.workUnit(),
            data: wrongDatasetFamily
        )

        await expectInvalidInput(
            worker: worker,
            unit: CurveGridFixture.workUnit(),
            data: nil
        )
    }

    @Test
    func invalidSamplesAndWeightsAreRejected() throws {
        let datasets = [
            CurveGridFixture.typedDataset(coordinates: [-1, 0]),
            CurveGridFixture.typedDataset(values: [1, 2, 3]),
            CurveGridFixture.typedDataset(
                inverseVariances: [1, 1, 0, 1, 1]
            ),
            CurveGridFixture.typedDataset(
                inverseVariances: [1, 1, -1, 1, 1]
            ),
            CurveGridFixture.typedDataset(
                coordinates: [-2, -1, .infinity, 1, 2]
            ),
            CurveGridFixture.typedDataset(
                values: [1, 2, .nan, 2, 1]
            ),
            CurveGridFixture.typedDataset(
                inverseVariances: [1, 1, .infinity, 1, 1]
            ),
        ]
        for dataset in datasets {
            #expect(throws: CurveGridError.self) {
                try dataset.validate()
            }
        }
    }

    @Test
    func fractionalBooleanInvalidAxisAndOverflowValuesAreRejected() throws {
        for invalidValue in [JSONValue.number(0.5), JSONValue.bool(true)] {
            #expect(throws: CurveGridError.self) {
                _ = try CurveGridPayload(.object([
                    "familyID": .string(CurveGridContract.familyID),
                    "gridStartIndex": invalidValue,
                    "gridCount": .number(1),
                ]))
            }
            #expect(throws: CurveGridError.self) {
                _ = try CurveGridPayload(.object([
                    "familyID": .string(CurveGridContract.familyID),
                    "gridStartIndex": .number(0),
                    "gridCount": invalidValue,
                ]))
            }
        }

        #expect(throws: CurveGridError.self) {
            _ = try CurveGridPayload(.object([
                "familyID": .string(CurveGridContract.familyID),
                "gridStartIndex": .number(Double.greatestFiniteMagnitude),
                "gridCount": .number(1),
            ]))
        }

        let invalidAxes = [
            CurveGridFixture.typedDataset(
                centerAxis: CurveGridAxis(start: 0, step: 1, count: 0)
            ),
            CurveGridFixture.typedDataset(
                centerAxis: CurveGridAxis(start: 0, step: 0, count: 2)
            ),
            CurveGridFixture.typedDataset(
                centerAxis: CurveGridAxis(
                    start: Double.greatestFiniteMagnitude,
                    step: Double.greatestFiniteMagnitude,
                    count: 2
                )
            ),
            CurveGridFixture.typedDataset(
                logScaleAxis: CurveGridAxis(start: 710, step: 1, count: 1)
            ),
            CurveGridFixture.typedDataset(
                logShapeAxis: CurveGridAxis(start: -1_000, step: 1, count: 1)
            ),
            CurveGridFixture.typedDataset(candidatesPerWorkUnit: 0),
            CurveGridFixture.typedDataset(
                centerAxis: CurveGridAxis(start: 0, step: 1, count: Int.max),
                logScaleAxis: CurveGridAxis(start: 0, step: 1, count: 2),
                logShapeAxis: CurveGridAxis(start: 0, step: 1, count: 2)
            ),
        ]
        for dataset in invalidAxes {
            #expect(throws: CurveGridError.self) {
                try dataset.validate()
            }
        }

        for countValue in [1.5 as Any, true as Any] {
            let data = try CurveGridFixture.datasetData { object in
                var grid = object["curveGrid"] as! [String: Any]
                var axis = grid["centerAxis"] as! [String: Any]
                axis["count"] = countValue
                grid["centerAxis"] = axis
                object["curveGrid"] = grid
            }
            #expect(throws: CurveGridError.self) {
                _ = try CurveGridJSONDatasetDecoder().decode(data)
            }
        }
    }

    @Test
    func JSONSafeIntegerBoundsAreEnforcedWithoutLargeAllocations() throws {
        let maximum = CurveGridContract.maximumJSONSafeInteger
        let aboveMaximum = maximum + 1

        let startBoundary = try CurveGridPayload(.object([
            "familyID": .string(CurveGridContract.familyID),
            "gridStartIndex": .number(Double(maximum)),
            "gridCount": .number(1),
        ]))
        #expect(startBoundary.gridStartIndex == maximum)

        let countBoundary = try CurveGridPayload(.object([
            "familyID": .string(CurveGridContract.familyID),
            "gridStartIndex": .number(0),
            "gridCount": .number(Double(maximum)),
        ]))
        #expect(countBoundary.gridCount == maximum)

        for payload in [
            JSONValue.object([
                "familyID": .string(CurveGridContract.familyID),
                "gridStartIndex": .number(Double(aboveMaximum)),
                "gridCount": .number(1),
            ]),
            JSONValue.object([
                "familyID": .string(CurveGridContract.familyID),
                "gridStartIndex": .number(0),
                "gridCount": .number(Double(aboveMaximum)),
            ]),
        ] {
            #expect(throws: CurveGridError.self) {
                _ = try CurveGridPayload(payload)
            }
        }

        let tinyStep = Double.leastNonzeroMagnitude
        let totalAboveMaximumFactor = 100_000_000
        let sampleProductCount = maximum
            / CurveGridFixture.coordinates.count + 1
        let datasets = [
            CurveGridFixture.typedDataset(
                centerAxis: CurveGridAxis(
                    start: 0,
                    step: tinyStep,
                    count: aboveMaximum
                )
            ),
            CurveGridFixture.typedDataset(
                candidatesPerWorkUnit: aboveMaximum
            ),
            CurveGridFixture.typedDataset(
                centerAxis: CurveGridAxis(
                    start: 0,
                    step: tinyStep,
                    count: totalAboveMaximumFactor
                ),
                logScaleAxis: CurveGridAxis(
                    start: 0,
                    step: tinyStep,
                    count: totalAboveMaximumFactor
                ),
                logShapeAxis: CurveGridAxis(start: 0, step: 1, count: 1)
            ),
            CurveGridFixture.typedDataset(
                centerAxis: CurveGridAxis(
                    start: 0,
                    step: tinyStep,
                    count: maximum
                ),
                logScaleAxis: CurveGridAxis(
                    start: 0,
                    step: tinyStep,
                    count: maximum
                ),
                logShapeAxis: CurveGridAxis(start: 0, step: 1, count: 1)
            ),
            CurveGridFixture.typedDataset(
                centerAxis: CurveGridAxis(
                    start: 0,
                    step: tinyStep,
                    count: sampleProductCount
                ),
                logScaleAxis: CurveGridAxis(start: 0, step: 1, count: 1),
                logShapeAxis: CurveGridAxis(start: 0, step: 1, count: 1)
            ),
        ]
        for dataset in datasets {
            #expect(throws: CurveGridError.self) {
                try dataset.validate()
            }
        }
    }

    @Test
    func outOfRangeShardsAreRejectedWithoutIntegerOverflow() throws {
        let dataset = CurveGridFixture.typedDataset()
        for payloadValue in [
            CurveGridFixture.payload(start: 27, count: 1),
            CurveGridFixture.payload(start: 25, count: 3),
            CurveGridFixture.payload(start: 0, count: 0),
            CurveGridFixture.payload(start: -1, count: 1),
        ] {
            #expect(throws: CurveGridError.self) {
                let payload = try CurveGridPayload(payloadValue)
                try payload.validate(in: dataset.curveGrid)
            }
        }
    }

    @Test
    func flatteningAndInverseMappingAreExact() throws {
        let grid = CurveGridFixture.typedDataset().curveGrid
        #expect(try grid.totalCandidateCount() == 27)
        for centerIndex in 0..<3 {
            for scaleIndex in 0..<3 {
                for shapeIndex in 0..<3 {
                    let indices = CurveGridIndices(
                        centerIndex: centerIndex,
                        scaleIndex: scaleIndex,
                        shapeIndex: shapeIndex
                    )
                    let expected = ((centerIndex * 3) + scaleIndex) * 3
                        + shapeIndex
                    #expect(
                        try CurveGridIndexing.flatten(indices, in: grid)
                            == expected
                    )
                    #expect(
                        try CurveGridIndexing.inverse(expected, in: grid)
                            == indices
                    )
                }
            }
        }
    }

    @Test
    func goldenVectorSelectsPublishedWinner() throws {
        let result = try CurveGridEvaluator.search(
            dataset: CurveGridFixture.typedDataset(),
            payload: CurveGridPayload(CurveGridFixture.payload())
        )
        #expect(result.evaluatedCandidateCount == 27)
        #expect(result.invalidCandidateCount == 0)
        #expect(result.best.gridIndex == 13)
        #expect(result.best.center == 0)
        #expect(result.best.logScale == 0)
        #expect(result.best.logShape == 0)
        #expect(abs(result.best.offset - 0.5) < 1e-12)
        #expect(abs(result.best.amplitude - 2.0) < 1e-12)
        #expect(result.best.weightedResidualSumSquares < 1e-20)
    }

    @Test
    func tiesChooseSmallerIndexAndPartialShardsStayLocal() throws {
        let tieDataset = CurveGridFixture.typedDataset(
            values: [1, 1, 1, 1, 1],
            centerAxis: CurveGridAxis(start: -0.5, step: 1, count: 2),
            logScaleAxis: CurveGridAxis(start: 0, step: 1, count: 1),
            logShapeAxis: CurveGridAxis(start: 0, step: 1, count: 1)
        )
        let tieResult = try CurveGridEvaluator.search(
            dataset: tieDataset,
            payload: CurveGridPayload(CurveGridFixture.payload(start: 0, count: 2))
        )
        #expect(tieResult.best.gridIndex == 0)
        #expect(tieResult.best.weightedResidualSumSquares == 0)

        let partialResult = try CurveGridEvaluator.search(
            dataset: CurveGridFixture.typedDataset(),
            payload: CurveGridPayload(
                CurveGridFixture.payload(start: 10, count: 5)
            )
        )
        #expect(partialResult.best.gridIndex == 13)
        #expect(partialResult.evaluatedCandidateCount == 5)
    }

    @Test
    func invalidCandidatesAreCountedWithoutSuppressingValidOnes() throws {
        let dataset = CurveGridFixture.typedDataset(
            centerAxis: CurveGridAxis(start: 0, step: 1, count: 1),
            logScaleAxis: CurveGridAxis(start: 0, step: 1, count: 1),
            logShapeAxis: CurveGridAxis(start: 0, step: 400, count: 2)
        )
        let result = try CurveGridEvaluator.search(
            dataset: dataset,
            payload: CurveGridPayload(CurveGridFixture.payload(start: 0, count: 2))
        )
        #expect(result.best.gridIndex == 0)
        #expect(result.evaluatedCandidateCount == 2)
        #expect(result.invalidCandidateCount == 1)
    }

    @Test
    func resultPayloadIsExactAndCatalogRoutesExecution() async throws {
        let router = try WorkloadRouter()
        let execution = try await router.execute(
            workUnit: CurveGridFixture.workUnit(),
            datasetData: CurveGridFixture.datasetData()
        )
        let payload = try #require(execution.payload.objectValue)
        #expect(Set(payload.keys) == [
            "familyID",
            "gridStartIndex",
            "gridCount",
            "bestGridIndex",
            "bestCenter",
            "bestLogScale",
            "bestLogShape",
            "bestOffset",
            "bestAmplitude",
            "bestWeightedResidualSumSquares",
            "evaluatedCandidateCount",
            "invalidCandidateCount",
        ])
        #expect(payload["familyID"]?.stringValue == CurveGridContract.familyID)
        #expect(payload["gridStartIndex"]?.intValue == 0)
        #expect(payload["gridCount"]?.intValue == 27)
        #expect(payload["bestGridIndex"]?.intValue == 13)
        #expect(payload["bestCenter"]?.doubleValue == 0)
        #expect(payload["bestLogScale"]?.doubleValue == 0)
        #expect(payload["bestLogShape"]?.doubleValue == 0)
        let bestOffset = try #require(payload["bestOffset"]?.doubleValue)
        let bestAmplitude = try #require(payload["bestAmplitude"]?.doubleValue)
        let bestResidual = try #require(
            payload["bestWeightedResidualSumSquares"]?.doubleValue
        )
        #expect(abs(bestOffset - 0.5) < 1e-12)
        #expect(abs(bestAmplitude - 2) < 1e-12)
        #expect(bestResidual < 1e-20)
        #expect(payload["evaluatedCandidateCount"]?.intValue == 27)
        #expect(payload["invalidCandidateCount"]?.intValue == 0)
        #expect(execution.summary?.title == "Curve-grid search")
        #expect(execution.legacyResultFields.bestFrequency == nil)
        #expect(execution.legacyResultFields.bestPeriodDays == nil)
        #expect(execution.legacyResultFields.bestPower == nil)
    }

    @Test
    func localWinnerValidationAcceptsExactAndRejectsInconsistentResult() throws {
        let dataset = CurveGridFixture.typedDataset()
        let result = try CurveGridEvaluator.search(
            dataset: dataset,
            payload: CurveGridPayload(CurveGridFixture.payload())
        )
        try CurveGridLocalValidator.validate(result.best, dataset: dataset)

        let inconsistent = CurveGridCandidate(
            gridIndex: result.best.gridIndex,
            center: result.best.center,
            logScale: result.best.logScale,
            logShape: result.best.logShape,
            offset: result.best.offset.nextUp,
            amplitude: result.best.amplitude,
            weightedResidualSumSquares:
                result.best.weightedResidualSumSquares
        )
        do {
            try CurveGridLocalValidator.validate(inconsistent, dataset: dataset)
            Issue.record("Expected inconsistent local result to fail")
        } catch let error as CurveGridError {
            #expect(error.workFailureKind == .workloadValidation)
        }
    }

    @Test
    func batchPreservesOrderAndIsolatesSiblingFailure() async throws {
        let worker = CurveGridWorkloadHandler()
        let units = [
            CurveGridFixture.workUnit(start: 0, count: 5),
            CurveGridFixture.workUnit(payload: .object([
                "familyID": .string("wrong"),
                "gridStartIndex": .number(5),
                "gridCount": .number(5),
            ])),
            CurveGridFixture.workUnit(start: 10, count: 5),
        ]
        let members = try await worker.executeBatch(
            workUnits: units,
            datasetData: CurveGridFixture.datasetData()
        )
        #expect(members.count == units.count)
        #expect(members.map(\.workUnit.id) == units.map(\.id))
        _ = try members[0].result.get()
        do {
            _ = try members[1].result.get()
            Issue.record("Expected invalid batch child to fail")
        } catch let error as CurveGridError {
            #expect(error.workFailureKind == .invalidInput)
        }
        let third = try members[2].result.get()
        #expect(third.payload["bestGridIndex"]?.intValue == 13)
    }

    @Test
    func compatibleBatchDecodesSharedDatasetOnce() async throws {
        let decoder = CurveGridCountingDecoder()
        let worker = CurveGridWorkloadHandler(datasetDecoder: decoder)
        let units = [
            CurveGridFixture.workUnit(start: 0, count: 5),
            CurveGridFixture.workUnit(start: 5, count: 5),
            CurveGridFixture.workUnit(start: 10, count: 5),
        ]
        let members = try await worker.executeBatch(
            workUnits: units,
            datasetData: CurveGridFixture.datasetData()
        )
        #expect(members.count == units.count)
        #expect(decoder.decodeCount == 1)
        for member in members {
            _ = try member.result.get()
        }
    }

    @Test
    func cancellationUsesRecoverableClassification() async throws {
        let worker = CurveGridWorkloadHandler()
        let data = try CurveGridFixture.datasetData()
        let unit = CurveGridFixture.workUnit()
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await worker.execute(workUnit: unit, datasetData: data)
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancelled curve-grid execution to fail")
        } catch let error as WorkloadCancellation {
            #expect(error.workFailureKind == .environmentUnavailable)
        } catch {
            Issue.record("Expected WorkloadCancellation, received \(error)")
        }
    }

    private func expectInvalidInput(
        worker: CurveGridWorkloadHandler,
        unit: WorkUnit,
        data: Data?
    ) async {
        do {
            _ = try await worker.execute(workUnit: unit, datasetData: data)
            Issue.record("Expected invalid curve-grid input to fail")
        } catch let error as CurveGridError {
            #expect(error.workFailureKind == .invalidInput)
        } catch {
            Issue.record("Expected CurveGridError, received \(error)")
        }
    }
}

private enum CurveGridFixture {
    static let datasetID = "curve-grid-dataset"
    static let coordinates = [-2.0, -1.0, 0.0, 1.0, 2.0]
    static let values = [
        2.5869967789998038,
        2.8094010767585034,
        3.1832815729997477,
        2.8094010767585034,
        2.5869967789998038,
    ]
    static let inverseVariances = [1.0, 1.0, 1.0, 1.0, 1.0]

    static func typedDataset(
        coordinates: [Double] = CurveGridFixture.coordinates,
        values: [Double] = CurveGridFixture.values,
        inverseVariances: [Double] = CurveGridFixture.inverseVariances,
        centerAxis: CurveGridAxis = CurveGridAxis(
            start: -0.5,
            step: 0.5,
            count: 3
        ),
        logScaleAxis: CurveGridAxis = CurveGridAxis(
            start: -0.6931471805599453,
            step: 0.6931471805599453,
            count: 3
        ),
        logShapeAxis: CurveGridAxis = CurveGridAxis(
            start: -0.6931471805599453,
            step: 0.6931471805599453,
            count: 3
        ),
        candidatesPerWorkUnit: Int = 5
    ) -> CurveGridDataset {
        CurveGridDataset(
            id: datasetID,
            datasetSchemaID: CurveGridContract.datasetSchemaID,
            coordinates: coordinates,
            values: values,
            inverseVariances: inverseVariances,
            curveGrid: CurveGridDefinition(
                familyID: CurveGridContract.familyID,
                centerAxis: centerAxis,
                logScaleAxis: logScaleAxis,
                logShapeAxis: logShapeAxis,
                candidatesPerWorkUnit: candidatesPerWorkUnit
            )
        )
    }

    static func datasetData(
        mutate: (inout [String: Any]) -> Void = { _ in }
    ) throws -> Data {
        var object: [String: Any] = [
            "id": datasetID,
            "datasetSchemaID": CurveGridContract.datasetSchemaID,
            "coordinates": coordinates,
            "values": values,
            "inverseVariances": inverseVariances,
            "curveGrid": [
                "familyID": CurveGridContract.familyID,
                "centerAxis": [
                    "start": -0.5,
                    "step": 0.5,
                    "count": 3,
                ],
                "logScaleAxis": [
                    "start": -0.6931471805599453,
                    "step": 0.6931471805599453,
                    "count": 3,
                ],
                "logShapeAxis": [
                    "start": -0.6931471805599453,
                    "step": 0.6931471805599453,
                    "count": 3,
                ],
                "candidatesPerWorkUnit": 5,
            ],
        ]
        mutate(&object)
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    static func payload(start: Int = 0, count: Int = 27) -> JSONValue {
        .object([
            "familyID": .string(CurveGridContract.familyID),
            "gridStartIndex": .number(Double(start)),
            "gridCount": .number(Double(count)),
        ])
    }

    static func workUnit(
        workloadID: String = CurveGridContract.workloadID,
        datasetSchemaID: String? = CurveGridContract.datasetSchemaID,
        payloadSchemaID: String? = CurveGridContract.payloadSchemaID,
        resultSchemaID: String? = CurveGridContract.resultSchemaID,
        datasetID: String? = CurveGridFixture.datasetID,
        payload: JSONValue? = nil,
        start: Int = 0,
        count: Int = 27
    ) -> WorkUnit {
        WorkUnit(
            id: UUID(),
            projectID: "curve-grid-project",
            workloadID: workloadID,
            datasetSchemaID: datasetSchemaID,
            payloadSchemaID: payloadSchemaID,
            resultSchemaID: resultSchemaID,
            datasetID: datasetID,
            payload: payload ?? self.payload(start: start, count: count)
        )
    }
}

private final class CurveGridCountingDecoder:
    CurveGridDatasetDecoding, @unchecked Sendable
{
    private let lock = NSLock()
    private var count = 0
    private let wrapped = CurveGridJSONDatasetDecoder()

    var decodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func decode(_ data: Data) throws -> CurveGridDataset {
        lock.lock()
        count += 1
        lock.unlock()
        return try wrapped.decode(data)
    }
}
