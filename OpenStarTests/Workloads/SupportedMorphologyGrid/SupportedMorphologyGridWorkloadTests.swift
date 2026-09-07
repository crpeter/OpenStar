import Foundation
import Testing
@testable import OpenStar

struct SupportedMorphologyGridWorkloadTests {
    private typealias Fixture = SupportedMorphologyGridFixture

    @Test func documentedPortableDatasetHasExpectedRejections() throws {
        var object = Fixture.object()
        var series = object["series"] as! [[String: Any]]
        series[0]["values"] = [0.0, 1, 2, 3, 2, 1, 0, 1]
        object["series"] = series
        let full = try Fixture.search(object)
        expectCounts(full, evaluated: 2, invalid: 0, rejected: 1, eligible: 1)
        #expect(full.bestCandidate?.gridIndex == 1)
        let first = try Fixture.search(object, count: 1)
        expectCounts(first, evaluated: 1, invalid: 0, rejected: 1, eligible: 0)
        #expect(first.bestCandidate == nil)
    }

    @Test func unsupportedNumericalWinnerLosesToSupportedCandidate() throws {
        let object = Fixture.object(positiveCenter: 0)
        let numerical = try Fixture.numericalDataset(object)
        let rejected = try #require(MorphologyGridEvaluator.evaluateCandidate(dataset: numerical, gridIndex: 0))
        let admitted = try #require(MorphologyGridEvaluator.evaluateCandidate(dataset: numerical, gridIndex: 1))
        #expect(rejected.weightedResidualSumSquares < admitted.weightedResidualSumSquares - 1e-9)
        #expect(MorphologyGridEvaluator.candidatePrecedes(rejected, admitted))

        let result = try Fixture.search(object)
        #expect(result.bestCandidate == admitted)
        expectCounts(result, evaluated: 2, invalid: 0, rejected: 1, eligible: 1)
    }

    @Test func fullPartialAndEmptyEligibleShardsHaveExactAccounting() throws {
        let object = Fixture.object()
        let full = try Fixture.search(object)
        let first = try Fixture.search(object, count: 1)
        let last = try Fixture.search(object, start: 1, count: 1)
        expectCounts(full, evaluated: 2, invalid: 0, rejected: 1, eligible: 1)
        expectCounts(first, evaluated: 1, invalid: 0, rejected: 1, eligible: 0)
        expectCounts(last, evaluated: 1, invalid: 0, rejected: 0, eligible: 1)
        #expect(first.bestCandidate == nil)
        #expect(full.bestCandidate == last.bestCandidate)
        #expect(last.bestCandidate?.gridIndex == 1)

        let mixed = Fixture.object(mixedValidity: true)
        let mixedFull = try Fixture.search(mixed, count: 4)
        expectCounts(mixedFull, evaluated: 4, invalid: 2, rejected: 1, eligible: 1)
        #expect(mixedFull.bestCandidate?.gridIndex == 3)
        let noEligible = try Fixture.search(mixed, count: 3)
        expectCounts(noEligible, evaluated: 3, invalid: 2, rejected: 1, eligible: 0)
        #expect(noEligible.bestCandidate == nil)
        let invalidOnly = try Fixture.search(mixed, count: 1)
        expectCounts(invalidOnly, evaluated: 1, invalid: 1, rejected: 0, eligible: 0)
        #expect(invalidOnly.bestCandidate == nil)

        let allRejected = try Fixture.search(Fixture.object(coordinates: [7, 8, 9, 10, 11, 12]))
        expectCounts(allRejected, evaluated: 2, invalid: 0, rejected: 2, eligible: 0)
        #expect(allRejected.bestCandidate == nil)
    }

    @Test func allSupportedModelsPreserveV1WinnersFitsAndMetrics() throws {
        for model in Fixture.models {
            let object = Fixture.object(model: model, coordinates: [-2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
            let count = model == .independentPulses ? 3 : 2
            let numerical = try Fixture.numericalDataset(object)
            var payload = try #require(Fixture.payload(model: model, count: count).objectValue)
            payload.removeValue(forKey: "supportPolicyID")
            let expected = try MorphologyGridEvaluator.search(
                dataset: numerical, payload: MorphologyGridPayload(.object(payload))
            )
            let actual = try Fixture.search(object, model: model, count: count)
            expectCounts(actual, evaluated: count, invalid: 0, rejected: 0, eligible: count)
            #expect(actual.bestCandidate == expected.bestCandidate)
            let best = try #require(actual.bestCandidate)
            #expect(best.gridIndex == (model == .positivePulseOnly ? 1 : 0))
            #expect(best.weightedResidualSumSquares < 1e-9)
            #expect(best.seriesFits[0].positiveAmplitude > 0.1)
            if model != .positivePulseOnly {
                #expect(try #require(best.seriesFits[0].negativeAmplitude) < -0.1)
            }
            #expect(best.correctedAkaikeInformationCriterionDefined)
        }
    }

    @Test func inclusiveBoundariesZeroWeightsAndSeparateExponentials() throws {
        let parameters = MorphologyGridParameters.positive(center: 0, logScale: 0, logShape: 0)
        for coordinate in [-2.0, 2.0] {
            #expect(try supported(parameters, coordinates: [coordinate]))
            #expect(try !supported(parameters, coordinates: [coordinate], weights: [0]))
        }
        #expect(try !supported(parameters, coordinates: [(-2.0).nextDown]))
        #expect(try !supported(parameters, coordinates: [2.0.nextUp]))
        #expect(try !supported(parameters, coordinates: [0, 3], weights: [0, 1]))
        #expect(try supported(parameters, coordinates: [0], weights: [Double.leastNonzeroMagnitude]))

        let logScale = 0.7
        let logShape = -0.3
        let width = exp(logScale) * exp(logShape)
        let radius = 2.0 * width
        let scaled = MorphologyGridParameters.positive(center: 0, logScale: logScale, logShape: logShape)
        #expect(try supported(scaled, coordinates: [radius]))
        #expect(try !supported(scaled, coordinates: [radius.nextUp]))
        for (scale, shape) in [(700.0, 700.0), (-700.0, -700.0), (1000.0, -1000.0)] {
            #expect(try !supported(.positive(center: 0, logScale: scale, logShape: shape), coordinates: [0]))
        }
        // exp(700) and exp(-700) are separately finite; their product is near one.
        #expect(try supported(.positive(center: 0, logScale: 700, logShape: -700), coordinates: [0]))

        var boundary = Fixture.object(coordinates: [2, 3, 4, 5, 6, 7, 8], positiveCenter: 0)
        let admitted = try Fixture.search(boundary, count: 1)
        expectCounts(admitted, evaluated: 1, invalid: 0, rejected: 0, eligible: 1)
        #expect(admitted.bestCandidate?.gridIndex == 0)
        boundary["series"] = [Fixture.series([2, 3, 4, 5, 6, 7, 8], positiveCenter: 0, weights: [0, 1, 1, 1, 1, 1, 1])]
        let excluded = try Fixture.search(boundary, count: 1)
        expectCounts(excluded, evaluated: 1, invalid: 0, rejected: 1, eligible: 0)
        #expect(excluded.bestCandidate == nil)
    }

    @Test func orderedCenterDerivationAndEveryComponentInEverySeries() throws {
        let parameters = MorphologyGridParameters.orderedDoublet(
            negativeCenter: 10, separation: 4, negativeLogScale: 0, negativeLogShape: 0,
            positiveLogScale: 0, positiveLogShape: 0
        )
        #expect(try supported(parameters, coordinates: [10, 14]))
        #expect(try !supported(parameters, coordinates: [4, 10]))
        #expect(try !supported(parameters, coordinates: [10]))
        #expect(try !supported(parameters, coordinates: [14]))
        #expect(try supported(parameters, coordinates: [12])) // Both inclusive boundaries.

        var ordered = Fixture.object(
            model: .orderedNegativePositiveDoublet, coordinates: [8, 9, 10, 11, 12, 13, 14, 15],
            positiveCenter: 14, negativeCenter: 10
        )
        var orderedGrid = ordered["morphologyGrid"] as! [String: Any]
        orderedGrid["negativeCenterAxis"] = Fixture.axis(10)
        ordered["morphologyGrid"] = orderedGrid
        let orderedResult = try Fixture.search(ordered, model: .orderedNegativePositiveDoublet)
        expectCounts(orderedResult, evaluated: 2, invalid: 0, rejected: 1, eligible: 1)
        #expect(orderedResult.bestCandidate?.gridIndex == 0)
        let orderedPartial = try Fixture.search(ordered, model: .orderedNegativePositiveDoublet, start: 1, count: 1)
        expectCounts(orderedPartial, evaluated: 1, invalid: 0, rejected: 1, eligible: 0)
        #expect(orderedPartial.bestCandidate == nil)

        let first = supportSeries([10, 14])
        let missingPositive = supportSeries([10], id: "series-002")
        #expect(try !SupportedMorphologyGridSupport.isSupported(parameters: parameters, series: [first, missingPositive]))
        #expect(try !SupportedMorphologyGridSupport.isSupported(parameters: parameters, series: [missingPositive, first]))

        for model in [MorphologyGridModelClass.positivePulseOnly, .orderedNegativePositiveDoublet] {
            var object = Fixture.object(model: model, coordinates: [-2, 0, 2, 4, 6, 8, 10])
            var series = object["series"] as! [[String: Any]]
            series.append(Fixture.series([20, 21, 22, 23], id: "series-002"))
            object["series"] = series
            let result = try Fixture.search(object, model: model)
            expectCounts(result, evaluated: 2, invalid: 0, rejected: 2, eligible: 0)
            #expect(result.bestCandidate == nil)
        }
    }

    @Test func independentScopeAndStrictCenterPairOrderingArePreserved() throws {
        let object = Fixture.object(model: .independentPulses, positiveCenter: 8, negativeCenter: 4)
        let result = try Fixture.search(object, model: .independentPulses, count: 3)
        expectCounts(result, evaluated: 3, invalid: 0, rejected: 2, eligible: 1)
        let best = try #require(result.bestCandidate)
        #expect(best.gridIndex == 2)
        #expect(best.parameters == .independentDoublet(
            negativeCenter: 4, positiveCenter: 8, negativeLogScale: 0, negativeLogShape: 0,
            positiveLogScale: 0, positiveLogShape: 0
        ))
        #expect(best.weightedResidualSumSquares < 1e-9)
        #expect(best.nominalParameterCount == 9)
        let partial = try Fixture.search(object, model: .independentPulses, start: 1, count: 2)
        expectCounts(partial, evaluated: 2, invalid: 0, rejected: 1, eligible: 1)
        #expect(partial.bestCandidate == best)

        var multiple = object
        var series = object["series"] as! [[String: Any]]
        var second = series[0]
        second["genericSeriesID"] = "series-002"
        series.append(second)
        multiple["series"] = series
        #expect(throws: MorphologyGridError.self) { try Fixture.decode(multiple) }
    }

    @Test func zeroAmplitudeStillRequiresSupportAndTiesUseLowestEligibleIndex() throws {
        for model in Fixture.models {
            var object = Fixture.object(model: model)
            var series = object["series"] as! [[String: Any]]
            series[0]["values"] = Array(repeating: 0.0, count: 8)
            object["series"] = series
            let count = model == .independentPulses ? 3 : 2
            let result = try Fixture.search(object, model: model, count: count)
            #expect(result.supportRejectedCandidateCount == (model == .positivePulseOnly ? 1 : 2))
            if model == .orderedNegativePositiveDoublet {
                #expect(result.bestCandidate == nil)
            } else {
                #expect(result.bestCandidate?.gridIndex == (model == .positivePulseOnly ? 1 : 2))
                #expect(result.bestCandidate?.seriesFits[0].positiveAmplitude == 0)
            }

            object["series"] = [[
                "genericSeriesID": "series-001", "coordinates": [-2.0, 0, 2, 4, 6, 8, 10],
                "values": Array(repeating: 0.0, count: 7), "inverseVariances": Array(repeating: 1.0, count: 7),
            ]]
            let tied = try Fixture.search(object, model: model, count: count)
            #expect(tied.bestCandidate?.gridIndex == 0)
            let partial = try Fixture.search(object, model: model, start: 1, count: count - 1)
            #expect(partial.bestCandidate?.gridIndex == 1)
        }
    }

    @Test func exactEmittedFieldsAndNullWinnersAreSuccessfulWork() async throws {
        let handler = SupportedMorphologyGridWorkloadHandler()
        for model in Fixture.models {
            let object = Fixture.object(model: model, coordinates: [-2, 0, 2, 4, 6, 8, 10])
            let count = model == .independentPulses ? 3 : 2
            let result = try await handler.execute(workUnit: Fixture.unit(model: model, count: count), datasetData: Fixture.data(object))
            let payload = try #require(result.payload.objectValue)
            #expect(Set(payload.keys) == [
                "morphologyFamilyID", "modelClassID", "supportPolicyID", "gridStartIndex", "gridCount",
                "bestCandidate", "evaluatedCandidateCount", "invalidCandidateCount", "supportRejectedCandidateCount",
            ])
            #expect(payload["supportPolicyID"] == .string("openstar.morphology-support.two-effective-widths.v1"))
            #expect(payload["morphologyFamilyID"] == .string("openstar.microlensing-residual-morphology.v1"))
            #expect(payload["modelClassID"] == .string(model.rawValue))
            #expect(payload["gridStartIndex"] == .number(0))
            #expect(payload["gridCount"] == .number(Double(count)))
            #expect(payload["evaluatedCandidateCount"] == .number(Double(count)))
            #expect(payload["invalidCandidateCount"] == .number(0))
            #expect(payload["supportRejectedCandidateCount"] == .number(0))
            let best = try #require(payload["bestCandidate"]?.objectValue)
            #expect(Set(best.keys) == [
                "gridIndex", "parameters", "seriesFits", "positiveWeightSampleCount", "weightedResidualSumSquares",
                "nominalParameterCount", "bayesianInformationCriterion", "correctedAkaikeInformationCriterion",
                "correctedAkaikeInformationCriterionDefined",
            ])
            let parameters = try #require(best["parameters"]?.objectValue)
            let parameterKeys: Set<String>
            switch model {
            case .positivePulseOnly:
                parameterKeys = ["center", "logScale", "logShape"]
            case .orderedNegativePositiveDoublet:
                parameterKeys = ["negativeCenter", "separation", "negativeLogScale", "negativeLogShape",
                                 "positiveLogScale", "positiveLogShape"]
            case .independentPulses:
                parameterKeys = ["negativeCenter", "positiveCenter", "negativeLogScale", "negativeLogShape",
                                 "positiveLogScale", "positiveLogShape"]
            }
            #expect(Set(parameters.keys) == parameterKeys)
            let seriesFits = try #require(best["seriesFits"])
            guard case .array(let fits) = seriesFits else {
                Issue.record("Expected seriesFits array")
                continue
            }
            var fitKeys: Set<String> = ["genericSeriesID", "positiveWeightSampleCount", "offset", "positiveAmplitude",
                                        "positiveAmplitudeSign", "weightedResidualSumSquares"]
            if model != .positivePulseOnly { fitKeys.formUnion(["negativeAmplitude", "negativeAmplitudeSign"]) }
            #expect(fits.count == 1)
            for fit in fits { #expect(Set(try #require(fit.objectValue).keys) == fitKeys) }
            let expected = try #require(Fixture.search(object, model: model, count: count).bestCandidate)
            #expect(payload["bestCandidate"] == (try expected.jsonValue(modelClassID: model)))
            let encoded = try JSONEncoder().encode(result.payload)
            #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == result.payload)
        }
        for count in [1, 3] {
            let result = try await handler.execute(
                workUnit: Fixture.unit(count: count), datasetData: Fixture.data(Fixture.object(mixedValidity: true))
            )
            #expect(result.payload.objectValue?["bestCandidate"] == .null)
            #expect(result.payload.objectValue?["evaluatedCandidateCount"] == .number(Double(count)))
            #expect(result.payload.objectValue?["invalidCandidateCount"] == .number(count == 1 ? 1 : 2))
            #expect(result.payload.objectValue?["supportRejectedCandidateCount"] == .number(count == 1 ? 0 : 1))
        }
        let rejected = try await handler.execute(workUnit: Fixture.unit(count: 1), datasetData: Fixture.data(Fixture.object()))
        #expect(rejected.payload.objectValue?["bestCandidate"] == .null)
        #expect(rejected.payload.objectValue?["invalidCandidateCount"] == .number(0))
        #expect(rejected.payload.objectValue?["supportRejectedCandidateCount"] == .number(1))
    }

    @Test func repeatedConcurrentAndBatchedExecutionsAgree() async throws {
        let handler = SupportedMorphologyGridWorkloadHandler()
        let data = try Fixture.data(Fixture.object(mixedValidity: true))
        let unit = Fixture.unit(count: 4)
        let first = try await handler.execute(workUnit: unit, datasetData: data).payload
        #expect(try await handler.execute(workUnit: unit, datasetData: data).payload == first)
        let results = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            for _ in 0..<8 {
                group.addTask { try await handler.execute(workUnit: unit, datasetData: data).payload }
            }
            var payloads: [JSONValue] = []
            for try await payload in group { payloads.append(payload) }
            return payloads
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == first })
        let units = [unit, Fixture.unit(start: 3, count: 1), Fixture.unit(count: 0), Fixture.unit(count: 3)]
        let batch = try await handler.executeBatch(workUnits: units, datasetData: data)
        #expect(batch.map(\.workUnit.id) == units.map(\.id))
        #expect(try batch[0].result.get().payload == first)
        #expect(try batch[1].result.get().payload.objectValue?["bestCandidate"] == first.objectValue?["bestCandidate"])
        #expect(throws: MorphologyGridError.self) { try batch[2].result.get() }
        #expect(try batch[3].result.get().payload.objectValue?["bestCandidate"] == .null)
    }

    @Test func cancellationIsRecoverableForEligibleRejectedAndInvalidShards() async throws {
        let handler = SupportedMorphologyGridWorkloadHandler()
        for (object, count) in [(Fixture.object(), 1), (Fixture.object(), 2), (Fixture.object(mixedValidity: true), 1)] {
            let data = try Fixture.data(object)
            let unit = Fixture.unit(count: count)
            let task = Task {
                while !Task.isCancelled { await Task.yield() }
                return try await handler.execute(workUnit: unit, datasetData: data)
            }
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("Expected recoverable cancellation")
            } catch let error as WorkloadCancellation {
                #expect(error.workFailureKind == .environmentUnavailable)
            }
            let batchTask = Task {
                while !Task.isCancelled { await Task.yield() }
                return try await handler.executeBatch(workUnits: [unit, unit], datasetData: data)
            }
            batchTask.cancel()
            for member in try await batchTask.value {
                #expect(throws: WorkloadCancellation.self) { try member.result.get() }
            }
        }
    }

    private func expectCounts(
        _ result: SupportedMorphologyGridSearchResult, evaluated: Int, invalid: Int, rejected: Int, eligible: Int
    ) {
        #expect(result.evaluatedCandidateCount == evaluated)
        #expect(result.invalidCandidateCount == invalid)
        #expect(result.supportRejectedCandidateCount == rejected)
        #expect(result.evaluatedCandidateCount - result.invalidCandidateCount - result.supportRejectedCandidateCount == eligible)
    }

    private func supportSeries(_ coordinates: [Double], weights: [Double]? = nil, id: String = "series-001") -> MorphologyGridSeries {
        MorphologyGridSeries(
            genericSeriesID: id, coordinates: coordinates, values: Array(repeating: 0, count: coordinates.count),
            inverseVariances: weights ?? Array(repeating: 1, count: coordinates.count)
        )
    }

    private func supported(_ parameters: MorphologyGridParameters, coordinates: [Double], weights: [Double]? = nil) throws -> Bool {
        try SupportedMorphologyGridSupport.isSupported(parameters: parameters, series: [supportSeries(coordinates, weights: weights)])
    }
}
