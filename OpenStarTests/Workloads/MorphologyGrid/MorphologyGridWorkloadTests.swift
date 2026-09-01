import Foundation
import Testing
@testable import OpenStar

struct MorphologyGridWorkloadTests {
    @Test
    func publishedIdentitiesCapabilityAndModuleMetadataAreExact() throws {
        #expect(MorphologyGridContract.workloadID ==
            "openstar.morphology-grid.v1")
        #expect(MorphologyGridContract.datasetSchemaID ==
            "openstar.dataset.morphology-grid.v1")
        #expect(MorphologyGridContract.payloadSchemaID ==
            "openstar.payload.morphology-grid-shard.v1")
        #expect(MorphologyGridContract.resultSchemaID ==
            "openstar.result.morphology-grid-shard.v1")
        #expect(MorphologyGridContract.morphologyFamilyID ==
            "openstar.microlensing-residual-morphology.v1")
        #expect(MorphologyGridContract.componentTemplateFamilyID ==
            "openstar.curve-family.symmetric-radial-amplification.v1")
        #expect(MorphologyGridContract.executionContractID ==
            "openstar.morphology-grid-execution.v1")
        #expect(MorphologyGridContract.executionContractVersion == "1.0")

        let handler = MorphologyGridWorkloadHandler()
        #expect(handler.workloadIDs == ["openstar.morphology-grid.v1"])
        #expect(handler.capabilities == [WorkloadCapability(
            workloadID: "openstar.morphology-grid.v1",
            executionBackends: [.cpu],
            validatorID: "openstar.morphology-grid.local-double.v1",
            datasetSchemaID: "openstar.dataset.morphology-grid.v1",
            payloadSchemaID: "openstar.payload.morphology-grid-shard.v1",
            resultSchemaID: "openstar.result.morphology-grid-shard.v1"
        )])
        #expect(handler.desiredBatchCount == 8)

        let handlers = try MorphologyGridWorkloadModule.handlers()
        #expect(handlers.count == 1)
        #expect(handlers[0].workloadIDs == [MorphologyGridContract.workloadID])
        #expect(handlers[0].capabilities == handler.capabilities)
    }

    @Test
    func allThreeModelsDecodeWithTopLevelExtensibility() throws {
        for model in MorphologyGridModelClass.allCasesForTests {
            let data = try MorphologyGridFixture.datasetData(
                model: model,
                topLevelAdditions: [
                    "opaqueMetadata": ["generic": "ignored"],
                    "reference": NSNull(),
                ]
            )
            let dataset = try MorphologyGridJSONDatasetDecoder().decode(data)
            #expect(dataset.modelClassID == model)
            #expect(dataset.datasetSchemaID ==
                MorphologyGridContract.datasetSchemaID)
            #expect(dataset.morphologyFamilyID ==
                MorphologyGridContract.morphologyFamilyID)
            #expect(dataset.componentTemplateFamilyID ==
                MorphologyGridContract.componentTemplateFamilyID)
            #expect(dataset.executionContractID ==
                MorphologyGridContract.executionContractID)
            #expect(dataset.executionContractVersion == "1.0")
            let expectedCandidateCount: Int
            switch model {
            case .positivePulseOnly:
                expectedCandidateCount = 27
            case .orderedNegativePositiveDoublet:
                expectedCandidateCount = 2
            case .independentPulses:
                expectedCandidateCount = 10
            }
            #expect(try dataset.morphologyGrid.totalCandidateCount() ==
                expectedCandidateCount)
        }
    }

    @Test
    func datasetPublishedIdentitiesAreRequiredExactly() throws {
        let fields = [
            "datasetSchemaID",
            "morphologyFamilyID",
            "componentTemplateFamilyID",
            "executionContractID",
            "executionContractVersion",
        ]
        for field in fields {
            var wrong = MorphologyGridFixture.positiveObject()
            wrong[field] = "wrong"
            #expect(throws: MorphologyGridError.self) {
                _ = try MorphologyGridJSONDatasetDecoder().decode(
                    MorphologyGridFixture.data(wrong)
                )
            }

            var missing = MorphologyGridFixture.positiveObject()
            missing.removeValue(forKey: field)
            #expect(throws: MorphologyGridError.self) {
                _ = try MorphologyGridJSONDatasetDecoder().decode(
                    MorphologyGridFixture.data(missing)
                )
            }
        }

        var wrongModel = MorphologyGridFixture.positiveObject()
        wrongModel["modelClassID"] = "POSITIVE_ONLY"
        #expect(throws: MorphologyGridError.self) {
            _ = try MorphologyGridJSONDatasetDecoder().decode(
                MorphologyGridFixture.data(wrongModel)
            )
        }
    }

    @Test
    func nestedSeriesGridAndAxesDecodeStrictly() throws {
        var extraSeries = MorphologyGridFixture.positiveObject()
        var series = extraSeries["series"] as! [[String: Any]]
        series[0]["legacyValue"] = 1
        extraSeries["series"] = series

        var extraGrid = MorphologyGridFixture.positiveObject()
        var grid = extraGrid["morphologyGrid"] as! [String: Any]
        grid["legacyAxis"] = MorphologyGridFixture.linearAxis()
        extraGrid["morphologyGrid"] = grid

        var extraAxis = MorphologyGridFixture.positiveObject()
        grid = extraAxis["morphologyGrid"] as! [String: Any]
        var axis = grid["centerAxis"] as! [String: Any]
        axis["end"] = 2.0
        grid["centerAxis"] = axis
        extraAxis["morphologyGrid"] = grid

        for object in [extraSeries, extraGrid, extraAxis] {
            #expect(throws: MorphologyGridError.self) {
                _ = try MorphologyGridJSONDatasetDecoder().decode(
                    MorphologyGridFixture.data(object)
                )
            }
        }
    }

    @Test
    func malformedSeriesAndModelSpecificDatasetsFailClosed() throws {
        var cases: [[String: Any]] = []

        var duplicate = MorphologyGridFixture.positiveObject()
        var series = duplicate["series"] as! [[String: Any]]
        series[1]["genericSeriesID"] = "series-001"
        duplicate["series"] = series
        cases.append(duplicate)

        var unordered = MorphologyGridFixture.positiveObject()
        series = unordered["series"] as! [[String: Any]]
        series.reverse()
        unordered["series"] = series
        cases.append(unordered)

        var unequal = MorphologyGridFixture.positiveObject()
        series = unequal["series"] as! [[String: Any]]
        var values = series[0]["values"] as! [Double]
        values.removeLast()
        series[0]["values"] = values
        unequal["series"] = series
        cases.append(unequal)

        var repeatedCoordinate = MorphologyGridFixture.positiveObject()
        series = repeatedCoordinate["series"] as! [[String: Any]]
        var coordinates = series[0]["coordinates"] as! [Double]
        coordinates[1] = coordinates[0]
        series[0]["coordinates"] = coordinates
        repeatedCoordinate["series"] = series
        cases.append(repeatedCoordinate)

        var negativeWeight = MorphologyGridFixture.positiveObject()
        series = negativeWeight["series"] as! [[String: Any]]
        var weights = series[0]["inverseVariances"] as! [Double]
        weights[0] = -1
        series[0]["inverseVariances"] = weights
        negativeWeight["series"] = series
        cases.append(negativeWeight)

        var zeroSeparation = MorphologyGridFixture.orderedObject()
        var orderedGrid = zeroSeparation["morphologyGrid"]
            as! [String: Any]
        var separation = orderedGrid["separationAxis"] as! [String: Any]
        separation["start"] = 0.0
        orderedGrid["separationAxis"] = separation
        zeroSeparation["morphologyGrid"] = orderedGrid
        cases.append(zeroSeparation)

        var repeatedExplicit = MorphologyGridFixture.positiveObject()
        var grid = repeatedExplicit["morphologyGrid"] as! [String: Any]
        grid["logShapeAxis"] = ["values": [0.0, 0.0]]
        repeatedExplicit["morphologyGrid"] = grid
        cases.append(repeatedExplicit)

        var independentMultiple = MorphologyGridFixture.independentObject()
        series = independentMultiple["series"] as! [[String: Any]]
        var second = series[0]
        second["genericSeriesID"] = "series-002"
        series.append(second)
        independentMultiple["series"] = series
        cases.append(independentMultiple)

        for object in cases {
            #expect(throws: MorphologyGridError.self) {
                _ = try MorphologyGridJSONDatasetDecoder().decode(
                    MorphologyGridFixture.data(object)
                )
            }
        }
    }

    @Test
    func nonfiniteAndUnsafeValuesAreRejectedWithoutLargeAllocations() throws {
        for axis in [
            MorphologyGridAxis(start: .infinity, step: 1, count: 1),
            MorphologyGridAxis(start: 0, step: 0, count: 1),
            MorphologyGridAxis(start: 710, step: 1, count: 1),
            MorphologyGridAxis(values: [0, .nan]),
        ] {
            #expect(throws: MorphologyGridError.self) {
                try axis.validate(
                    fieldName: "axis",
                    exponentiated: true,
                    allowsExplicit: true
                )
            }
        }
        #expect(MorphologyGridEvaluator.componentBasis(
            coordinate: .infinity,
            center: 0,
            logScale: 0,
            logShape: 0
        ) == nil)

        let valid = try MorphologyGridFixture.decode(.positivePulseOnly)
        var nonfiniteSeries = valid.series
        let original = nonfiniteSeries[0]
        var nonfiniteValues = original.values
        nonfiniteValues[0] = .nan
        nonfiniteSeries[0] = MorphologyGridSeries(
            genericSeriesID: original.genericSeriesID,
            coordinates: original.coordinates,
            values: nonfiniteValues,
            inverseVariances: original.inverseVariances
        )
        let nonfiniteDataset = MorphologyGridDataset(
            id: valid.id,
            datasetSchemaID: valid.datasetSchemaID,
            morphologyFamilyID: valid.morphologyFamilyID,
            componentTemplateFamilyID: valid.componentTemplateFamilyID,
            modelClassID: valid.modelClassID,
            series: nonfiniteSeries,
            morphologyGrid: valid.morphologyGrid,
            candidatesPerWorkUnit: valid.candidatesPerWorkUnit,
            executionContractID: valid.executionContractID,
            executionContractVersion: valid.executionContractVersion
        )
        #expect(throws: MorphologyGridError.self) {
            try nonfiniteDataset.validate()
        }

        var unsafe = MorphologyGridFixture.positiveObject()
        var grid = unsafe["morphologyGrid"] as! [String: Any]
        var axis = grid["centerAxis"] as! [String: Any]
        axis["count"] = MorphologyGridContract.maximumJSONSafeInteger
        grid["centerAxis"] = axis
        unsafe["morphologyGrid"] = grid
        #expect(throws: MorphologyGridError.self) {
            _ = try MorphologyGridJSONDatasetDecoder().decode(
                MorphologyGridFixture.data(unsafe)
            )
        }

        #expect(throws: MorphologyGridError.self) {
            _ = try MorphologyGridIndexing.candidateIndex(
                indices: [0, 0],
                counts: [MorphologyGridContract.maximumJSONSafeInteger, 2]
            )
        }
        #expect(throws: MorphologyGridError.self) {
            _ = try MorphologyGridIndexing.independentCenterPairIndex(
                centerCount: 1 << 53,
                negativeCenterIndex: 0,
                positiveCenterIndex: 1
            )
        }
    }

    @Test
    func mixedRadixForwardInverseGoldenVectorsAreRightmostFastest() throws {
        let counts = [3, 2, 4]
        var expectedIndex = 0
        for first in 0..<3 {
            for second in 0..<2 {
                for third in 0..<4 {
                    let indices = [first, second, third]
                    #expect(try MorphologyGridIndexing.candidateIndex(
                        indices: indices,
                        counts: counts
                    ) == expectedIndex)
                    #expect(try MorphologyGridIndexing.candidateIndices(
                        index: expectedIndex,
                        counts: counts
                    ) == indices)
                    expectedIndex += 1
                }
            }
        }
        #expect(try MorphologyGridIndexing.candidateIndices(
            index: 1,
            counts: counts
        ) == [0, 0, 1])
        #expect(try MorphologyGridIndexing.candidateIndices(
            index: 4,
            counts: counts
        ) == [0, 1, 0])
        #expect(try MorphologyGridIndexing.candidateIndices(
            index: 8,
            counts: counts
        ) == [1, 0, 0])
    }

    @Test
    func independentCenterPairForwardInverseGoldenVectorsAreExact() throws {
        let expected = [
            (0, 1), (0, 2), (0, 3), (0, 4),
            (1, 2), (1, 3), (1, 4),
            (2, 3), (2, 4),
            (3, 4),
        ]
        for (pairIndex, pair) in expected.enumerated() {
            #expect(try MorphologyGridIndexing.independentCenterPairIndex(
                centerCount: 5,
                negativeCenterIndex: pair.0,
                positiveCenterIndex: pair.1
            ) == pairIndex)
            let inverse = try MorphologyGridIndexing
                .independentCenterPairIndices(
                    centerCount: 5,
                    pairIndex: pairIndex
                )
            #expect(inverse.negative == pair.0)
            #expect(inverse.positive == pair.1)
        }
        for pair in [(0, 0), (1, 0), (-1, 2), (0, 5)] {
            #expect(throws: MorphologyGridError.self) {
                _ = try MorphologyGridIndexing.independentCenterPairIndex(
                    centerCount: 5,
                    negativeCenterIndex: pair.0,
                    positiveCenterIndex: pair.1
                )
            }
        }
    }

    @Test
    func componentBasisMatchesServerGoldenOperationOrder() throws {
        let vectors = [
            (-1.25, -0.5, -0.2, -1.0),
            (0.0, 0.25, 0.0, 0.0),
            (2.5, 1.0, 0.5, -0.5),
        ]
        for vector in vectors {
            let actual = try #require(MorphologyGridEvaluator.componentBasis(
                coordinate: vector.0,
                center: vector.1,
                logScale: vector.2,
                logShape: vector.3
            ))
            #expect(actual == MorphologyGridFixture.canonicalBasis(
                coordinate: vector.0,
                center: vector.1,
                logScale: vector.2,
                logShape: vector.3
            ))
        }
    }

    @Test
    func allThreeModelsRecoverServerGoldenFitsAndMetrics() throws {
        let positive = try MorphologyGridFixture.decode(.positivePulseOnly)
        let positiveCandidate = try #require(
            try MorphologyGridEvaluator.evaluateCandidate(
                dataset: positive,
                gridIndex: 13
            )
        )
        #expect(positiveCandidate.parameters == .positive(
            center: 0,
            logScale: 0,
            logShape: 0
        ))
        #expect(positiveCandidate.seriesFits.count == 2)
        #expect(abs(positiveCandidate.seriesFits[0].offset - 0.5) < 1e-11)
        #expect(abs(positiveCandidate.seriesFits[0].positiveAmplitude - 2) < 1e-11)
        #expect(abs(positiveCandidate.seriesFits[1].offset - 1.5) < 1e-11)
        #expect(abs(positiveCandidate.seriesFits[1].positiveAmplitude - 3) < 1e-11)
        #expect(positiveCandidate.positiveWeightSampleCount == 8)
        #expect(positiveCandidate.seriesFits.map(
            \.positiveWeightSampleCount
        ) == [4, 4])
        #expect(positiveCandidate.nominalParameterCount == 7)
        #expect(abs(positiveCandidate.bayesianInformationCriterion
            - (positiveCandidate.weightedResidualSumSquares + 7 * log(8)))
            < 1e-12)
        #expect(positiveCandidate.correctedAkaikeInformationCriterion == nil)
        #expect(!positiveCandidate.correctedAkaikeInformationCriterionDefined)

        let ordered = try MorphologyGridFixture.decode(
            .orderedNegativePositiveDoublet
        )
        let orderedCandidate = try #require(
            try MorphologyGridEvaluator.evaluateCandidate(
                dataset: ordered,
                gridIndex: 0
            )
        )
        #expect(orderedCandidate.seriesFits.count == 2)
        let firstOrderedNegative = try #require(
            orderedCandidate.seriesFits[0].negativeAmplitude
        )
        #expect(abs(firstOrderedNegative + 1.25) < 1e-11)
        #expect(abs(orderedCandidate.seriesFits[0].positiveAmplitude - 2.5)
            < 1e-11)
        let secondOrderedNegative = try #require(
            orderedCandidate.seriesFits[1].negativeAmplitude
        )
        #expect(abs(secondOrderedNegative + 2.0) < 1e-11)
        #expect(abs(orderedCandidate.seriesFits[1].positiveAmplitude - 1.5)
            < 1e-11)
        #expect(orderedCandidate.positiveWeightSampleCount == 8)
        #expect(orderedCandidate.nominalParameterCount == 12)

        let independent = try MorphologyGridFixture.decode(.independentPulses)
        let independentCandidate = try #require(
            try MorphologyGridEvaluator.evaluateCandidate(
                dataset: independent,
                gridIndex: 5
            )
        )
        #expect(independentCandidate.parameters == .independentDoublet(
            negativeCenter: -0.5,
            positiveCenter: 0.5,
            negativeLogScale: 0,
            negativeLogShape: 0,
            positiveLogScale: 0,
            positiveLogShape: 0
        ))
        let independentNegative = try #require(
            independentCandidate.seriesFits[0].negativeAmplitude
        )
        #expect(abs(independentNegative + 1.25) < 1e-11)
        #expect(abs(independentCandidate.seriesFits[0].positiveAmplitude - 2.5)
            < 1e-11)
        #expect(independentCandidate.positiveWeightSampleCount == 4)
        #expect(independentCandidate.nominalParameterCount == 9)
    }

    @Test
    func zeroWeightsCountsConstraintsAndExactSignLabelsMatchServer() throws {
        var object = MorphologyGridFixture.positiveObject(seriesCount: 1)
        var series = object["series"] as! [[String: Any]]
        var values = series[0]["values"] as! [Double]
        values[2] = 1e100
        series[0]["values"] = values
        object["series"] = series
        let changed = try MorphologyGridFixture.decode(object)
        let original = try MorphologyGridFixture.decode(.positivePulseOnly,
            seriesCount: 1)
        let changedCandidate = try #require(
            try MorphologyGridEvaluator.evaluateCandidate(
                dataset: changed,
                gridIndex: 13
            )
        )
        let originalCandidate = try #require(
            try MorphologyGridEvaluator.evaluateCandidate(
                dataset: original,
                gridIndex: 13
            )
        )
        #expect(changedCandidate.seriesFits[0].offset ==
            originalCandidate.seriesFits[0].offset)
        #expect(changedCandidate.weightedResidualSumSquares ==
            originalCandidate.weightedResidualSumSquares)
        #expect(changedCandidate.positiveWeightSampleCount == 4)

        object = MorphologyGridFixture.positiveObject(seriesCount: 1)
        series = object["series"] as! [[String: Any]]
        series[0]["values"] = [Double](repeating: 1.5, count: 5)
        object["series"] = series
        let zeroDataset = try MorphologyGridFixture.decode(object)
        let zeroCandidate = try #require(
            try MorphologyGridEvaluator.evaluateCandidate(
                dataset: zeroDataset,
                gridIndex: 13
            )
        )
        #expect(zeroCandidate.seriesFits[0].positiveAmplitude == 0)
        #expect(MorphologyGridEvaluator.amplitudeSign(
            zeroCandidate.seriesFits[0].positiveAmplitude
        ) == "zero")
        #expect(MorphologyGridEvaluator.amplitudeSign(-0.0) == "zero")

        let ordered = try MorphologyGridFixture.decode(
            .orderedNegativePositiveDoublet
        )
        let signed = try #require(
            try MorphologyGridEvaluator.evaluateCandidate(
                dataset: ordered,
                gridIndex: 0
            )
        )
        let negativeAmplitude = try #require(
            signed.seriesFits[0].negativeAmplitude
        )
        #expect(MorphologyGridEvaluator.amplitudeSign(negativeAmplitude) ==
            "negative")
        #expect(MorphologyGridEvaluator.amplitudeSign(
            signed.seriesFits[0].positiveAmplitude
        ) == "positive")
    }

    @Test
    func definedAndUndefinedAICcUseFrozenFormula() throws {
        let undefined = try #require(
            try MorphologyGridEvaluator.evaluateCandidate(
                dataset: MorphologyGridFixture.decode(
                    .positivePulseOnly,
                    seriesCount: 1
                ),
                gridIndex: 13
            )
        )
        #expect(undefined.positiveWeightSampleCount == 4)
        #expect(undefined.nominalParameterCount == 5)
        #expect(undefined.correctedAkaikeInformationCriterion == nil)
        #expect(!undefined.correctedAkaikeInformationCriterionDefined)

        let defined = try #require(
            try MorphologyGridEvaluator.evaluateCandidate(
                dataset: MorphologyGridFixture.decodeDensePositive(),
                gridIndex: 13
            )
        )
        #expect(defined.positiveWeightSampleCount == 8)
        #expect(defined.nominalParameterCount == 5)
        let expected = defined.weightedResidualSumSquares
            + 2.0 * 5.0 + 2.0 * 5.0 * 6.0 / (8.0 - 5.0 - 1.0)
        #expect(defined.correctedAkaikeInformationCriterionDefined)
        let definedAICc = try #require(
            defined.correctedAkaikeInformationCriterion
        )
        #expect(abs(definedAICc - expected) < 1e-12)
    }

    @Test
    func fullShardPartialShardInvalidCountsAndAllInvalidWinnerAreExact() throws {
        let dataset = try MorphologyGridFixture.decode(.positivePulseOnly)
        let full = try MorphologyGridEvaluator.search(
            dataset: dataset,
            payload: MorphologyGridFixture.payload(
                model: .positivePulseOnly,
                start: 0,
                count: 27
            )
        )
        #expect(full.evaluatedCandidateCount == 27)
        #expect(full.invalidCandidateCount == 0)
        #expect(full.bestCandidate?.gridIndex == 13)

        let partial = try MorphologyGridEvaluator.search(
            dataset: dataset,
            payload: MorphologyGridFixture.payload(
                model: .positivePulseOnly,
                start: 10,
                count: 5
            )
        )
        #expect(partial.evaluatedCandidateCount == 5)
        #expect(partial.bestCandidate?.gridIndex == 13)

        let independent = try MorphologyGridFixture.decode(.independentPulses)
        let partialFinal = try MorphologyGridEvaluator.search(
            dataset: independent,
            payload: MorphologyGridFixture.payload(
                model: .independentPulses,
                start: 8,
                count: 2
            )
        )
        #expect(partialFinal.evaluatedCandidateCount == 2)
        #expect(partialFinal.invalidCandidateCount == 0)
        let partialFinalIndex = try #require(
            partialFinal.bestCandidate?.gridIndex
        )
        #expect([8, 9].contains(partialFinalIndex))

        let mixed = try MorphologyGridFixture.decodeMixedValidity()
        let mixedResult = try MorphologyGridEvaluator.search(
            dataset: mixed,
            payload: MorphologyGridFixture.payload(
                model: .positivePulseOnly,
                start: 0,
                count: 2
            )
        )
        #expect(mixedResult.evaluatedCandidateCount == 2)
        #expect(mixedResult.invalidCandidateCount == 1)
        #expect(mixedResult.bestCandidate != nil)

        let allInvalid = try MorphologyGridFixture.decodeAllInvalid()
        let allInvalidResult = try MorphologyGridEvaluator.search(
            dataset: allInvalid,
            payload: MorphologyGridFixture.payload(
                model: .positivePulseOnly,
                start: 0,
                count: 9
            )
        )
        #expect(allInvalidResult.evaluatedCandidateCount == 9)
        #expect(allInvalidResult.invalidCandidateCount == 9)
        #expect(allInvalidResult.bestCandidate == nil)
    }

    @Test
    func deterministicTiesChooseLowestGlobalIndex() throws {
        var object = MorphologyGridFixture.positiveObject(seriesCount: 1)
        var series = object["series"] as! [[String: Any]]
        series[0]["values"] = [Double](repeating: 1.5, count: 5)
        object["series"] = series
        object["morphologyGrid"] = [
            "centerAxis": MorphologyGridFixture.linearAxis(
                start: -0.5,
                step: 0.5,
                count: 3
            ),
            "logScaleAxis": MorphologyGridFixture.linearAxis(),
            "logShapeAxis": ["values": [0.0]],
        ]
        let dataset = try MorphologyGridFixture.decode(object)
        let result = try MorphologyGridEvaluator.search(
            dataset: dataset,
            payload: MorphologyGridFixture.payload(
                model: .positivePulseOnly,
                start: 0,
                count: 3
            )
        )
        #expect(result.bestCandidate?.gridIndex == 0)
        #expect(result.bestCandidate?.weightedResidualSumSquares == 0)
    }

    @Test
    func candidateComparisonUsesCompleteFrozenObjectiveOrder() {
        func candidate(
            gridIndex: Int,
            wrss: Double = 10,
            bic: Double = 20,
            aicc: Double? = 30
        ) -> MorphologyGridCandidate {
            MorphologyGridCandidate(
                gridIndex: gridIndex,
                parameters: .positive(center: 0, logScale: 0, logShape: 0),
                seriesFits: [],
                positiveWeightSampleCount: 10,
                weightedResidualSumSquares: wrss,
                nominalParameterCount: 1,
                bayesianInformationCriterion: bic,
                correctedAkaikeInformationCriterion: aicc,
                correctedAkaikeInformationCriterionDefined: aicc != nil
            )
        }

        #expect(MorphologyGridEvaluator.candidatePrecedes(
            candidate(gridIndex: 9, wrss: 9, bic: 100, aicc: 100),
            candidate(gridIndex: 1)
        ))
        #expect(MorphologyGridEvaluator.candidatePrecedes(
            candidate(gridIndex: 9, wrss: 10 + 1e-10, bic: 19),
            candidate(gridIndex: 1)
        ))
        #expect(MorphologyGridEvaluator.candidatePrecedes(
            candidate(gridIndex: 9, aicc: 29),
            candidate(gridIndex: 1)
        ))
        #expect(MorphologyGridEvaluator.candidatePrecedes(
            candidate(gridIndex: 9),
            candidate(gridIndex: 1, aicc: nil)
        ))
        #expect(MorphologyGridEvaluator.candidatePrecedes(
            candidate(gridIndex: 1),
            candidate(gridIndex: 9)
        ))
        #expect(!MorphologyGridEvaluator.candidatePrecedes(
            candidate(gridIndex: 9),
            candidate(gridIndex: 1)
        ))
    }

    @Test
    func emittedResultPayloadAndEveryNestedShapeAreExact() async throws {
        let handler = MorphologyGridWorkloadHandler()
        let execution = try await handler.execute(
            workUnit: MorphologyGridFixture.workUnit(
                model: .orderedNegativePositiveDoublet,
                start: 0,
                count: 2
            ),
            datasetData: MorphologyGridFixture.datasetData(
                model: .orderedNegativePositiveDoublet
            )
        )
        let payload = try #require(execution.payload.objectValue)
        #expect(Set(payload.keys) == [
            "morphologyFamilyID",
            "modelClassID",
            "gridStartIndex",
            "gridCount",
            "bestCandidate",
            "evaluatedCandidateCount",
            "invalidCandidateCount",
        ])
        #expect(payload["evaluatedCandidateCount"]?.intValue == 2)
        #expect(payload["invalidCandidateCount"]?.intValue == 0)
        let candidate = try #require(
            payload["bestCandidate"]?.objectValue
        )
        #expect(Set(candidate.keys) == [
            "gridIndex",
            "parameters",
            "seriesFits",
            "positiveWeightSampleCount",
            "weightedResidualSumSquares",
            "nominalParameterCount",
            "bayesianInformationCriterion",
            "correctedAkaikeInformationCriterion",
            "correctedAkaikeInformationCriterionDefined",
        ])
        let parameters = try #require(
            candidate["parameters"]?.objectValue
        )
        #expect(Set(parameters.keys) == [
            "negativeCenter",
            "separation",
            "negativeLogScale",
            "negativeLogShape",
            "positiveLogScale",
            "positiveLogShape",
        ])
        let fits = try #require(candidate["seriesFits"]?.arrayValueForTests)
        #expect(fits.count == 2)
        for fitValue in fits {
            let fit = try #require(fitValue.objectValue)
            #expect(Set(fit.keys) == [
                "genericSeriesID",
                "positiveWeightSampleCount",
                "offset",
                "negativeAmplitude",
                "negativeAmplitudeSign",
                "positiveAmplitude",
                "positiveAmplitudeSign",
                "weightedResidualSumSquares",
            ])
        }

        let positive = try #require(
            try MorphologyGridEvaluator.evaluateCandidate(
                dataset: MorphologyGridFixture.decode(.positivePulseOnly),
                gridIndex: 13
            )
        )
        let positivePayload = try #require(
            try positive.jsonValue(
                modelClassID: .positivePulseOnly
            ).objectValue
        )
        let positiveFits = try #require(
            positivePayload["seriesFits"]?.arrayValueForTests
        )
        for fitValue in positiveFits {
            let fit = try #require(fitValue.objectValue)
            #expect(Set(fit.keys) == [
                "genericSeriesID",
                "positiveWeightSampleCount",
                "offset",
                "positiveAmplitude",
                "positiveAmplitudeSign",
                "weightedResidualSumSquares",
            ])
        }

        let allInvalidExecution = try await handler.execute(
            workUnit: MorphologyGridFixture.workUnit(
                model: .positivePulseOnly,
                start: 0,
                count: 9
            ),
            datasetData: MorphologyGridFixture.data(
                MorphologyGridFixture.allInvalidObject()
            )
        )
        let allInvalidPayload = try #require(
            allInvalidExecution.payload.objectValue
        )
        #expect(allInvalidPayload["bestCandidate"] == .null)
        #expect(allInvalidPayload["evaluatedCandidateCount"]?.intValue == 9)
        #expect(allInvalidPayload["invalidCandidateCount"]?.intValue == 9)
        #expect(execution.summary?.title == "Morphology-grid search")
        #expect(execution.legacyResultFields.bestFrequency == nil)
        #expect(execution.legacyResultFields.bestPeriodDays == nil)
        #expect(execution.legacyResultFields.bestPower == nil)
    }

    @Test
    func strictPayloadMalformedIdentitiesAndShardRangesAreRejected() async throws {
        let handler = MorphologyGridWorkloadHandler()
        let data = try MorphologyGridFixture.datasetData(
            model: .positivePulseOnly
        )
        let units = [
            MorphologyGridFixture.workUnit(
                model: .positivePulseOnly,
                workloadID: "wrong"
            ),
            MorphologyGridFixture.workUnit(
                model: .positivePulseOnly,
                datasetSchemaID: "wrong"
            ),
            MorphologyGridFixture.workUnit(
                model: .positivePulseOnly,
                payloadSchemaID: "wrong"
            ),
            MorphologyGridFixture.workUnit(
                model: .positivePulseOnly,
                resultSchemaID: "wrong"
            ),
            MorphologyGridFixture.workUnit(
                model: .positivePulseOnly,
                datasetID: "wrong"
            ),
            MorphologyGridFixture.workUnit(
                model: .positivePulseOnly,
                start: 27,
                count: 1
            ),
            MorphologyGridFixture.workUnit(
                model: .positivePulseOnly,
                start: 25,
                count: 3
            ),
            MorphologyGridFixture.workUnit(
                model: .positivePulseOnly,
                payload: .object([
                    "morphologyFamilyID": .string(
                        MorphologyGridContract.morphologyFamilyID
                    ),
                    "modelClassID": .string("POSITIVE_PULSE_ONLY"),
                    "gridStartIndex": .number(0),
                    "gridCount": .number(1),
                    "legacyGridIndex": .number(0),
                ])
            ),
            MorphologyGridFixture.workUnit(
                model: .positivePulseOnly,
                payload: .object([
                    "morphologyFamilyID": .string(
                        MorphologyGridContract.morphologyFamilyID
                    ),
                    "modelClassID": .string("POSITIVE_PULSE_ONLY"),
                    "gridStartIndex": .number(0),
                    "gridCount": .bool(true),
                ])
            ),
        ]
        for unit in units {
            await expectInvalidInput(handler: handler, unit: unit, data: data)
        }
        await expectInvalidInput(
            handler: handler,
            unit: MorphologyGridFixture.workUnit(model: .positivePulseOnly),
            data: nil
        )
    }

    @Test
    func cancellationIsRecoverable() async throws {
        let handler = MorphologyGridWorkloadHandler()
        let data = try MorphologyGridFixture.datasetData(
            model: .positivePulseOnly
        )
        let unit = MorphologyGridFixture.workUnit(model: .positivePulseOnly)
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await handler.execute(
                workUnit: unit,
                datasetData: data
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancelled morphology-grid execution to fail")
        } catch let error as WorkloadCancellation {
            #expect(error.workFailureKind == .environmentUnavailable)
        } catch {
            Issue.record("Expected WorkloadCancellation, received \(error)")
        }
    }

    @Test
    func repeatedAndConcurrentExecutionsAreIdentical() async throws {
        let handler = MorphologyGridWorkloadHandler()
        let data = try MorphologyGridFixture.datasetData(
            model: .independentPulses
        )
        let unit = MorphologyGridFixture.workUnit(
            model: .independentPulses,
            start: 4,
            count: 4
        )
        let first = try await handler.execute(
            workUnit: unit,
            datasetData: data
        ).payload
        let second = try await handler.execute(
            workUnit: unit,
            datasetData: data
        ).payload
        #expect(first == second)

        let payloads = try await withThrowingTaskGroup(
            of: JSONValue.self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await handler.execute(
                        workUnit: unit,
                        datasetData: data
                    ).payload
                }
            }
            var results: [JSONValue] = []
            for try await payload in group {
                results.append(payload)
            }
            return results
        }
        #expect(payloads.count == 8)
        #expect(payloads.allSatisfy { $0 == first })
    }

    private func expectInvalidInput(
        handler: MorphologyGridWorkloadHandler,
        unit: WorkUnit,
        data: Data?
    ) async {
        do {
            _ = try await handler.execute(workUnit: unit, datasetData: data)
            Issue.record("Expected invalid morphology-grid input to fail")
        } catch let error as MorphologyGridError {
            #expect(error.workFailureKind == .invalidInput)
        } catch {
            Issue.record("Expected MorphologyGridError, received \(error)")
        }
    }
}

private enum MorphologyGridFixture {
    static let coordinates = [-2.0, -1.0, 0.0, 1.0, 2.0]
    static let weights = [1.0, 2.0, 0.0, 3.0, 1.0]

    static func linearAxis(
        start: Double = 0,
        step: Double = 1,
        count: Int = 1
    ) -> [String: Any] {
        ["start": start, "step": step, "count": count]
    }

    static func canonicalBasis(
        coordinate: Double,
        center: Double,
        logScale: Double,
        logShape: Double
    ) -> Double {
        let scale = exp(logScale)
        let shape = exp(logShape)
        let difference = coordinate - center
        let z = difference / scale
        let shapeSquared = shape * shape
        let zSquared = z * z
        let uSquared = shapeSquared + zSquared
        let u = sqrt(uSquared)
        let numerator = uSquared + 2.0
        let rooted = sqrt(uSquared + 4.0)
        let denominator = u * rooted
        return numerator / denominator
    }

    static func genericSeries(
        id: String,
        offset: Double = 0.5,
        positiveAmplitude: Double = 2,
        negativeAmplitude: Double? = nil,
        negativeCenter: Double = -0.5,
        positiveCenter: Double = 0.5,
        coordinates: [Double] = MorphologyGridFixture.coordinates,
        weights: [Double] = MorphologyGridFixture.weights
    ) -> [String: Any] {
        let positive = coordinates.map {
            canonicalBasis(
                coordinate: $0,
                center: positiveCenter,
                logScale: 0,
                logShape: 0
            )
        }
        var values = positive.map { offset + positiveAmplitude * $0 }
        if let negativeAmplitude {
            let negative = coordinates.map {
                canonicalBasis(
                    coordinate: $0,
                    center: negativeCenter,
                    logScale: 0,
                    logShape: 0
                )
            }
            values = zip(values, negative).map {
                $0.0 + negativeAmplitude * $0.1
            }
        }
        return [
            "genericSeriesID": id,
            "coordinates": coordinates,
            "values": values,
            "inverseVariances": weights,
        ]
    }

    static func baseObject(
        id: String,
        model: MorphologyGridModelClass,
        series: [[String: Any]],
        grid: [String: Any],
        candidatesPerWorkUnit: Int
    ) -> [String: Any] {
        [
            "id": id,
            "datasetSchemaID": MorphologyGridContract.datasetSchemaID,
            "morphologyFamilyID": MorphologyGridContract.morphologyFamilyID,
            "componentTemplateFamilyID":
                MorphologyGridContract.componentTemplateFamilyID,
            "modelClassID": model.rawValue,
            "series": series,
            "morphologyGrid": grid,
            "candidatesPerWorkUnit": candidatesPerWorkUnit,
            "executionContractID":
                MorphologyGridContract.executionContractID,
            "executionContractVersion":
                MorphologyGridContract.executionContractVersion,
        ]
    }

    static func positiveObject(seriesCount: Int = 2) -> [String: Any] {
        let series = (0..<seriesCount).map { index in
            genericSeries(
                id: String(format: "series-%03d", index + 1),
                offset: 0.5 + Double(index),
                positiveAmplitude: 2 + Double(index),
                positiveCenter: 0
            )
        }
        return baseObject(
            id: "generic-positive-grid",
            model: .positivePulseOnly,
            series: series,
            grid: [
                "centerAxis": linearAxis(start: -0.5, step: 0.5, count: 3),
                "logScaleAxis": linearAxis(
                    start: -0.5,
                    step: 0.5,
                    count: 3
                ),
                "logShapeAxis": ["values": [-0.5, 0.0, 0.5]],
            ],
            candidatesPerWorkUnit: 5
        )
    }

    static func orderedObject() -> [String: Any] {
        baseObject(
            id: "generic-ordered-grid",
            model: .orderedNegativePositiveDoublet,
            series: [
                genericSeries(
                    id: "series-001",
                    offset: 0.75,
                    positiveAmplitude: 2.5,
                    negativeAmplitude: -1.25
                ),
                genericSeries(
                    id: "series-002",
                    offset: -0.25,
                    positiveAmplitude: 1.5,
                    negativeAmplitude: -2
                ),
            ],
            grid: [
                "negativeCenterAxis": linearAxis(
                    start: -0.5,
                    step: 0.5,
                    count: 2
                ),
                "separationAxis": linearAxis(start: 1, step: 0.5, count: 1),
                "negativeLogScaleAxis": linearAxis(),
                "negativeLogShapeAxis": ["values": [0.0]],
                "positiveLogScaleAxis": linearAxis(),
                "positiveLogShapeAxis": ["values": [0.0]],
            ],
            candidatesPerWorkUnit: 1
        )
    }

    static func independentObject() -> [String: Any] {
        baseObject(
            id: "generic-independent-grid",
            model: .independentPulses,
            series: [genericSeries(
                id: "series-001",
                offset: 0.75,
                positiveAmplitude: 2.5,
                negativeAmplitude: -1.25
            )],
            grid: [
                "centerAxis": linearAxis(start: -1, step: 0.5, count: 5),
                "negativeLogScaleAxis": linearAxis(),
                "negativeLogShapeAxis": ["values": [0.0]],
                "positiveLogScaleAxis": linearAxis(),
                "positiveLogShapeAxis": ["values": [0.0]],
            ],
            candidatesPerWorkUnit: 4
        )
    }

    static func datasetObject(
        model: MorphologyGridModelClass,
        seriesCount: Int = 2
    ) -> [String: Any] {
        switch model {
        case .positivePulseOnly:
            return positiveObject(seriesCount: seriesCount)
        case .orderedNegativePositiveDoublet:
            return orderedObject()
        case .independentPulses:
            return independentObject()
        }
    }

    static func datasetData(
        model: MorphologyGridModelClass,
        seriesCount: Int = 2,
        topLevelAdditions: [String: Any] = [:]
    ) throws -> Data {
        var object = datasetObject(model: model, seriesCount: seriesCount)
        for (key, value) in topLevelAdditions {
            object[key] = value
        }
        return try data(object)
    }

    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode(
        _ model: MorphologyGridModelClass,
        seriesCount: Int = 2
    ) throws -> MorphologyGridDataset {
        try MorphologyGridJSONDatasetDecoder().decode(
            datasetData(model: model, seriesCount: seriesCount)
        )
    }

    static func decode(_ object: [String: Any]) throws -> MorphologyGridDataset {
        try MorphologyGridJSONDatasetDecoder().decode(data(object))
    }

    static func decodeDensePositive() throws -> MorphologyGridDataset {
        var object = positiveObject(seriesCount: 1)
        let denseCoordinates = [-3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 4.0]
        object["series"] = [genericSeries(
            id: "series-001",
            offset: 0.75,
            positiveAmplitude: 1.5,
            positiveCenter: 0,
            coordinates: denseCoordinates,
            weights: [Double](repeating: 1, count: denseCoordinates.count)
        )]
        return try decode(object)
    }

    static func decodeMixedValidity() throws -> MorphologyGridDataset {
        var object = positiveObject(seriesCount: 1)
        object["morphologyGrid"] = [
            "centerAxis": linearAxis(),
            "logScaleAxis": linearAxis(start: -700, step: 700, count: 2),
            "logShapeAxis": ["values": [0.0]],
        ]
        object["candidatesPerWorkUnit"] = 2
        return try decode(object)
    }

    static func allInvalidObject() -> [String: Any] {
        var object = positiveObject(seriesCount: 1)
        var grid = object["morphologyGrid"] as! [String: Any]
        grid["logScaleAxis"] = linearAxis(start: -700, step: 1, count: 1)
        object["morphologyGrid"] = grid
        object["candidatesPerWorkUnit"] = 9
        return object
    }

    static func decodeAllInvalid() throws -> MorphologyGridDataset {
        try decode(allInvalidObject())
    }

    static func payload(
        model: MorphologyGridModelClass,
        start: Int = 0,
        count: Int? = nil
    ) throws -> MorphologyGridPayload {
        let resolvedCount = count ?? {
            switch model {
            case .positivePulseOnly: return 27
            case .orderedNegativePositiveDoublet: return 2
            case .independentPulses: return 10
            }
        }()
        return try MorphologyGridPayload(.object([
            "morphologyFamilyID": .string(
                MorphologyGridContract.morphologyFamilyID
            ),
            "modelClassID": .string(model.rawValue),
            "gridStartIndex": .number(Double(start)),
            "gridCount": .number(Double(resolvedCount)),
        ]))
    }

    static func workUnit(
        model: MorphologyGridModelClass,
        workloadID: String = MorphologyGridContract.workloadID,
        datasetSchemaID: String? = MorphologyGridContract.datasetSchemaID,
        payloadSchemaID: String? = MorphologyGridContract.payloadSchemaID,
        resultSchemaID: String? = MorphologyGridContract.resultSchemaID,
        datasetID: String? = nil,
        payload: JSONValue? = nil,
        start: Int = 0,
        count: Int? = nil
    ) -> WorkUnit {
        let resolvedDatasetID = datasetID ?? {
            switch model {
            case .positivePulseOnly: return "generic-positive-grid"
            case .orderedNegativePositiveDoublet: return "generic-ordered-grid"
            case .independentPulses: return "generic-independent-grid"
            }
        }()
        let resolvedCount = count ?? {
            switch model {
            case .positivePulseOnly: return 27
            case .orderedNegativePositiveDoublet: return 2
            case .independentPulses: return 10
            }
        }()
        return WorkUnit(
            id: UUID(),
            projectID: "morphology-grid-project",
            workloadID: workloadID,
            datasetSchemaID: datasetSchemaID,
            payloadSchemaID: payloadSchemaID,
            resultSchemaID: resultSchemaID,
            datasetID: resolvedDatasetID,
            payload: payload ?? .object([
                "morphologyFamilyID": .string(
                    MorphologyGridContract.morphologyFamilyID
                ),
                "modelClassID": .string(model.rawValue),
                "gridStartIndex": .number(Double(start)),
                "gridCount": .number(Double(resolvedCount)),
            ])
        )
    }
}

private extension MorphologyGridModelClass {
    static let allCasesForTests: [MorphologyGridModelClass] = [
        .positivePulseOnly,
        .orderedNegativePositiveDoublet,
        .independentPulses,
    ]
}

private extension JSONValue {
    var arrayValueForTests: [JSONValue]? {
        guard case .array(let value) = self else {
            return nil
        }
        return value
    }
}
