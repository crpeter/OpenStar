import Foundation

nonisolated
enum CurveGridContract {
    static let workloadID = "openstar.curve-grid.v1"
    static let datasetSchemaID = "openstar.dataset.curve-grid.v1"
    static let payloadSchemaID = "openstar.payload.curve-grid-shard.v1"
    static let resultSchemaID = "openstar.result.curve-grid-shard.v1"
    static let familyID =
        "openstar.curve-family.symmetric-radial-amplification.v1"
    static let validatorID = "openstar.curve-grid.local-double.v1"
    static let maximumJSONSafeInteger = 9_007_199_254_740_991
}

nonisolated
enum CurveGridError: LocalizedError, WorkFailureClassifyingError, Equatable {
    case missingDataset
    case invalidDataset(String)
    case invalidWorkUnit(String)
    case invalidGridIndex(String)
    case noValidCandidate
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingDataset:
            return "Curve-grid work requires a dataset."
        case .invalidDataset(let message):
            return "Invalid curve-grid dataset: \(message)"
        case .invalidWorkUnit(let message):
            return "Invalid curve-grid work unit: \(message)"
        case .invalidGridIndex(let message):
            return "Invalid curve-grid index: \(message)"
        case .noValidCandidate:
            return "The curve-grid shard contains no valid candidate."
        case .validationFailed(let message):
            return "Curve-grid local validation failed: \(message)"
        }
    }

    var workFailureKind: WorkFailureKind {
        switch self {
        case .validationFailed:
            return .workloadValidation
        case .missingDataset,
             .invalidDataset,
             .invalidWorkUnit,
             .invalidGridIndex,
             .noValidCandidate:
            return .invalidInput
        }
    }
}

nonisolated
struct CurveGridAxis: Decodable, Sendable, Equatable {
    let start: Double
    let step: Double
    let count: Int

    init(start: Double, step: Double, count: Int) {
        self.start = start
        self.step = step
        self.count = count
    }
}

nonisolated
struct CurveGridDefinition: Decodable, Sendable, Equatable {
    let familyID: String
    let centerAxis: CurveGridAxis
    let logScaleAxis: CurveGridAxis
    let logShapeAxis: CurveGridAxis
    let candidatesPerWorkUnit: Int

    init(
        familyID: String,
        centerAxis: CurveGridAxis,
        logScaleAxis: CurveGridAxis,
        logShapeAxis: CurveGridAxis,
        candidatesPerWorkUnit: Int
    ) {
        self.familyID = familyID
        self.centerAxis = centerAxis
        self.logScaleAxis = logScaleAxis
        self.logShapeAxis = logShapeAxis
        self.candidatesPerWorkUnit = candidatesPerWorkUnit
    }

    func totalCandidateCount() throws -> Int {
        guard centerAxis.count > 0,
              logScaleAxis.count > 0,
              logShapeAxis.count > 0 else {
            throw CurveGridError.invalidDataset(
                "axis counts must be positive integers"
            )
        }
        guard centerAxis.count <= CurveGridContract.maximumJSONSafeInteger,
              logScaleAxis.count <= CurveGridContract.maximumJSONSafeInteger,
              logShapeAxis.count
                <= CurveGridContract.maximumJSONSafeInteger else {
            throw CurveGridError.invalidDataset(
                "axis counts exceed the JSON-safe integer limit"
            )
        }
        let (centerScaleCount, firstOverflow) = centerAxis.count
            .multipliedReportingOverflow(by: logScaleAxis.count)
        guard !firstOverflow else {
            throw CurveGridError.invalidDataset("grid size overflows")
        }
        let (totalCount, secondOverflow) = centerScaleCount
            .multipliedReportingOverflow(by: logShapeAxis.count)
        guard !secondOverflow, totalCount > 0 else {
            throw CurveGridError.invalidDataset("grid size overflows")
        }
        guard totalCount <= CurveGridContract.maximumJSONSafeInteger else {
            throw CurveGridError.invalidDataset(
                "grid size exceeds the JSON-safe integer limit"
            )
        }
        return totalCount
    }
}

nonisolated
struct CurveGridDataset: Decodable, Sendable, Equatable {
    let id: String
    let datasetSchemaID: String
    let coordinates: [Double]
    let values: [Double]
    let inverseVariances: [Double]
    let curveGrid: CurveGridDefinition

    init(
        id: String,
        datasetSchemaID: String,
        coordinates: [Double],
        values: [Double],
        inverseVariances: [Double],
        curveGrid: CurveGridDefinition
    ) {
        self.id = id
        self.datasetSchemaID = datasetSchemaID
        self.coordinates = coordinates
        self.values = values
        self.inverseVariances = inverseVariances
        self.curveGrid = curveGrid
    }

    func validate() throws {
        guard datasetSchemaID == CurveGridContract.datasetSchemaID else {
            throw CurveGridError.invalidDataset("dataset schema ID does not match")
        }
        guard curveGrid.familyID == CurveGridContract.familyID else {
            throw CurveGridError.invalidDataset("family ID does not match")
        }
        guard coordinates.count >= 3,
              coordinates.count == values.count,
              coordinates.count == inverseVariances.count else {
            throw CurveGridError.invalidDataset(
                "arrays must have equal length and at least three samples"
            )
        }
        guard coordinates.allSatisfy(\.isFinite),
              values.allSatisfy(\.isFinite),
              inverseVariances.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw CurveGridError.invalidDataset(
                "samples and strictly positive inverse variances must be finite"
            )
        }
        try Self.validateAxis(curveGrid.centerAxis, exponentiated: false)
        try Self.validateAxis(curveGrid.logScaleAxis, exponentiated: true)
        try Self.validateAxis(curveGrid.logShapeAxis, exponentiated: true)
        guard curveGrid.candidatesPerWorkUnit > 0,
              curveGrid.candidatesPerWorkUnit
                <= CurveGridContract.maximumJSONSafeInteger else {
            throw CurveGridError.invalidDataset(
                "candidatesPerWorkUnit must be a positive JSON-safe integer"
            )
        }
        let totalCandidateCount = try curveGrid.totalCandidateCount()
        let (sampleCandidateCount, overflow) = coordinates.count
            .multipliedReportingOverflow(by: totalCandidateCount)
        guard !overflow,
              sampleCandidateCount
                <= CurveGridContract.maximumJSONSafeInteger else {
            throw CurveGridError.invalidDataset(
                "sample and candidate count product exceeds the "
                    + "JSON-safe integer limit"
            )
        }
    }

    private static func validateAxis(
        _ axis: CurveGridAxis,
        exponentiated: Bool
    ) throws {
        guard axis.count > 0,
              axis.count <= CurveGridContract.maximumJSONSafeInteger else {
            throw CurveGridError.invalidDataset(
                "axis count must be a positive JSON-safe integer"
            )
        }
        guard axis.start.isFinite, axis.step.isFinite else {
            throw CurveGridError.invalidDataset("axis values must be finite")
        }
        guard axis.count == 1 || axis.step != 0 else {
            throw CurveGridError.invalidDataset(
                "an axis with multiple values must have a nonzero step"
            )
        }
        let last = axis.start + Double(axis.count - 1) * axis.step
        guard last.isFinite else {
            throw CurveGridError.invalidDataset("reachable axis value is nonfinite")
        }
        if exponentiated {
            let firstValue = exp(axis.start)
            let lastValue = exp(last)
            guard firstValue.isFinite, firstValue > 0,
                  lastValue.isFinite, lastValue > 0 else {
                throw CurveGridError.invalidDataset(
                    "reachable exponentiated axis value must be finite and positive"
                )
            }
        }
    }
}

nonisolated
struct CurveGridPayload: Sendable, Equatable {
    let familyID: String
    let gridStartIndex: Int
    let gridCount: Int

    init(_ value: JSONValue?) throws {
        guard let object = value?.objectValue else {
            throw CurveGridError.invalidWorkUnit("payload must be an object")
        }
        let expectedKeys: Set<String> = [
            "familyID", "gridStartIndex", "gridCount",
        ]
        guard Set(object.keys) == expectedKeys else {
            throw CurveGridError.invalidWorkUnit(
                "payload fields do not match the published schema"
            )
        }
        guard let familyID = object["familyID"]?.stringValue else {
            throw CurveGridError.invalidWorkUnit("familyID must be a string")
        }
        guard let gridStartIndex = object["gridStartIndex"]?.intValue,
              gridStartIndex >= 0,
              gridStartIndex
                <= CurveGridContract.maximumJSONSafeInteger else {
            throw CurveGridError.invalidWorkUnit(
                "gridStartIndex must be a nonnegative JSON-safe integer"
            )
        }
        guard let gridCount = object["gridCount"]?.intValue,
              gridCount > 0,
              gridCount <= CurveGridContract.maximumJSONSafeInteger else {
            throw CurveGridError.invalidWorkUnit(
                "gridCount must be a positive JSON-safe integer"
            )
        }
        guard familyID == CurveGridContract.familyID else {
            throw CurveGridError.invalidWorkUnit("family ID does not match")
        }
        self.familyID = familyID
        self.gridStartIndex = gridStartIndex
        self.gridCount = gridCount
    }

    func validate(in grid: CurveGridDefinition) throws {
        let totalCount = try grid.totalCandidateCount()
        guard gridStartIndex < totalCount,
              gridCount <= totalCount - gridStartIndex else {
            throw CurveGridError.invalidWorkUnit(
                "shard is outside the flattened grid"
            )
        }
    }
}

nonisolated
struct CurveGridIndices: Sendable, Equatable {
    let centerIndex: Int
    let scaleIndex: Int
    let shapeIndex: Int
}

nonisolated
enum CurveGridIndexing {
    static func flatten(
        _ indices: CurveGridIndices,
        in grid: CurveGridDefinition
    ) throws -> Int {
        guard indices.centerIndex >= 0,
              indices.centerIndex < grid.centerAxis.count,
              indices.scaleIndex >= 0,
              indices.scaleIndex < grid.logScaleAxis.count,
              indices.shapeIndex >= 0,
              indices.shapeIndex < grid.logShapeAxis.count else {
            throw CurveGridError.invalidGridIndex("component is out of range")
        }
        let (centerScale, firstOverflow) = indices.centerIndex
            .multipliedReportingOverflow(by: grid.logScaleAxis.count)
        let (centerAndScale, secondOverflow) = centerScale
            .addingReportingOverflow(indices.scaleIndex)
        let (withoutShape, thirdOverflow) = centerAndScale
            .multipliedReportingOverflow(by: grid.logShapeAxis.count)
        let (gridIndex, fourthOverflow) = withoutShape
            .addingReportingOverflow(indices.shapeIndex)
        guard !firstOverflow, !secondOverflow, !thirdOverflow, !fourthOverflow else {
            throw CurveGridError.invalidGridIndex("flattening overflows")
        }
        return gridIndex
    }

    static func inverse(
        _ gridIndex: Int,
        in grid: CurveGridDefinition
    ) throws -> CurveGridIndices {
        let totalCount = try grid.totalCandidateCount()
        guard gridIndex >= 0, gridIndex < totalCount else {
            throw CurveGridError.invalidGridIndex("global index is out of range")
        }
        let shapeIndex = gridIndex % grid.logShapeAxis.count
        let withoutShape = gridIndex / grid.logShapeAxis.count
        let scaleIndex = withoutShape % grid.logScaleAxis.count
        let centerIndex = withoutShape / grid.logScaleAxis.count
        return CurveGridIndices(
            centerIndex: centerIndex,
            scaleIndex: scaleIndex,
            shapeIndex: shapeIndex
        )
    }
}

nonisolated
struct CurveGridCandidate: Sendable, Equatable {
    let gridIndex: Int
    let center: Double
    let logScale: Double
    let logShape: Double
    let offset: Double
    let amplitude: Double
    let weightedResidualSumSquares: Double
}

nonisolated
struct CurveGridSearchResult: Sendable, Equatable {
    let best: CurveGridCandidate
    let evaluatedCandidateCount: Int
    let invalidCandidateCount: Int
}

nonisolated
enum CurveGridEvaluator {
    static func search(
        dataset: CurveGridDataset,
        payload: CurveGridPayload
    ) throws -> CurveGridSearchResult {
        try dataset.validate()
        try payload.validate(in: dataset.curveGrid)

        var best: CurveGridCandidate?
        var invalidCandidateCount = 0

        for localIndex in 0..<payload.gridCount {
            if (localIndex & 63) == 0, Task.isCancelled {
                throw WorkloadCancellation()
            }
            let (gridIndex, overflow) = payload.gridStartIndex
                .addingReportingOverflow(localIndex)
            guard !overflow else {
                throw CurveGridError.invalidWorkUnit("shard index overflows")
            }
            guard let candidate = try evaluateCandidate(
                gridIndex: gridIndex,
                dataset: dataset
            ) else {
                invalidCandidateCount += 1
                continue
            }
            if let current = best {
                if candidate.weightedResidualSumSquares
                    < current.weightedResidualSumSquares
                    || (candidate.weightedResidualSumSquares
                        == current.weightedResidualSumSquares
                        && candidate.gridIndex < current.gridIndex) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }

        guard let best else {
            throw CurveGridError.noValidCandidate
        }
        try CurveGridLocalValidator.validate(best, dataset: dataset)
        return CurveGridSearchResult(
            best: best,
            evaluatedCandidateCount: payload.gridCount,
            invalidCandidateCount: invalidCandidateCount
        )
    }

    private static func evaluateCandidate(
        gridIndex: Int,
        dataset: CurveGridDataset
    ) throws -> CurveGridCandidate? {
        let indices = try CurveGridIndexing.inverse(
            gridIndex,
            in: dataset.curveGrid
        )
        let center = dataset.curveGrid.centerAxis.start
            + Double(indices.centerIndex) * dataset.curveGrid.centerAxis.step
        let logScale = dataset.curveGrid.logScaleAxis.start
            + Double(indices.scaleIndex) * dataset.curveGrid.logScaleAxis.step
        let logShape = dataset.curveGrid.logShapeAxis.start
            + Double(indices.shapeIndex) * dataset.curveGrid.logShapeAxis.step
        let scale = exp(logScale)
        let shape = exp(logShape)
        guard center.isFinite, logScale.isFinite, logShape.isFinite,
              scale.isFinite, scale > 0, shape.isFinite, shape > 0 else {
            return nil
        }

        var sumWeight = 0.0
        var sumWeightedBasis = 0.0
        var sumWeightedBasisSquared = 0.0
        var sumWeightedValue = 0.0
        var sumWeightedBasisValue = 0.0

        for sampleIndex in dataset.coordinates.indices {
            if (sampleIndex & 1023) == 0, Task.isCancelled {
                throw WorkloadCancellation()
            }
            let coordinate = dataset.coordinates[sampleIndex]
            let value = dataset.values[sampleIndex]
            let weight = dataset.inverseVariances[sampleIndex]
            let z = (coordinate - center) / scale
            let shapeSquared = shape * shape
            let zSquared = z * z
            let uSquared = shapeSquared + zSquared
            let u = sqrt(uSquared)
            let basisNumerator = uSquared + 2
            let basisDenominator = u * sqrt(uSquared + 4)
            let basis = basisNumerator / basisDenominator
            let weightedBasis = weight * basis
            let weightedBasisSquared = weightedBasis * basis
            let weightedValue = weight * value
            let weightedBasisValue = weightedBasis * value
            guard z.isFinite, shapeSquared.isFinite, zSquared.isFinite,
                  uSquared.isFinite, u.isFinite, basisNumerator.isFinite,
                  basisDenominator.isFinite, basisDenominator > 0,
                  basis.isFinite, weightedBasis.isFinite,
                  weightedBasisSquared.isFinite, weightedValue.isFinite,
                  weightedBasisValue.isFinite else {
                return nil
            }
            sumWeight += weight
            sumWeightedBasis += weightedBasis
            sumWeightedBasisSquared += weightedBasisSquared
            sumWeightedValue += weightedValue
            sumWeightedBasisValue += weightedBasisValue
            guard sumWeight.isFinite, sumWeightedBasis.isFinite,
                  sumWeightedBasisSquared.isFinite,
                  sumWeightedValue.isFinite,
                  sumWeightedBasisValue.isFinite else {
                return nil
            }
        }

        let weightBasisProduct = sumWeight * sumWeightedBasisSquared
        let basisProduct = sumWeightedBasis * sumWeightedBasis
        let determinant = weightBasisProduct - basisProduct
        let determinantScale = max(
            max(abs(weightBasisProduct), abs(basisProduct)),
            1.0
        )
        let determinantThreshold = 1e-12 * determinantScale
        guard weightBasisProduct.isFinite, basisProduct.isFinite,
              determinant.isFinite, determinantScale.isFinite,
              determinantThreshold.isFinite,
              determinant > determinantThreshold else {
            return nil
        }

        let offsetNumerator = sumWeightedValue * sumWeightedBasisSquared
            - sumWeightedBasisValue * sumWeightedBasis
        let amplitudeNumerator = sumWeight * sumWeightedBasisValue
            - sumWeightedBasis * sumWeightedValue
        let offset = offsetNumerator / determinant
        let amplitude = amplitudeNumerator / determinant
        guard offsetNumerator.isFinite, amplitudeNumerator.isFinite,
              offset.isFinite, amplitude.isFinite else {
            return nil
        }

        var weightedResidualSumSquares = 0.0
        for sampleIndex in dataset.coordinates.indices {
            if (sampleIndex & 1023) == 0, Task.isCancelled {
                throw WorkloadCancellation()
            }
            let coordinate = dataset.coordinates[sampleIndex]
            let value = dataset.values[sampleIndex]
            let weight = dataset.inverseVariances[sampleIndex]
            let z = (coordinate - center) / scale
            let uSquared = shape * shape + z * z
            let u = sqrt(uSquared)
            let basis = (uSquared + 2) / (u * sqrt(uSquared + 4))
            let predicted = offset + amplitude * basis
            let residual = value - predicted
            let residualSquared = residual * residual
            let weightedResidual = weight * residualSquared
            guard z.isFinite, uSquared.isFinite, u.isFinite, basis.isFinite,
                  predicted.isFinite, residual.isFinite,
                  residualSquared.isFinite, weightedResidual.isFinite else {
                return nil
            }
            weightedResidualSumSquares += weightedResidual
            guard weightedResidualSumSquares.isFinite else {
                return nil
            }
        }

        return CurveGridCandidate(
            gridIndex: gridIndex,
            center: center,
            logScale: logScale,
            logShape: logShape,
            offset: offset,
            amplitude: amplitude,
            weightedResidualSumSquares: weightedResidualSumSquares
        )
    }
}

nonisolated
enum CurveGridLocalValidator {
    static func validate(
        _ claimed: CurveGridCandidate,
        dataset: CurveGridDataset
    ) throws {
        if Task.isCancelled {
            throw WorkloadCancellation()
        }
        let indices: CurveGridIndices
        do {
            indices = try CurveGridIndexing.inverse(
                claimed.gridIndex,
                in: dataset.curveGrid
            )
        } catch is WorkloadCancellation {
            throw WorkloadCancellation()
        } catch {
            throw CurveGridError.validationFailed(
                "winning grid index is invalid"
            )
        }
        let center = dataset.curveGrid.centerAxis.start
            + Double(indices.centerIndex) * dataset.curveGrid.centerAxis.step
        let logScale = dataset.curveGrid.logScaleAxis.start
            + Double(indices.scaleIndex) * dataset.curveGrid.logScaleAxis.step
        let logShape = dataset.curveGrid.logShapeAxis.start
            + Double(indices.shapeIndex) * dataset.curveGrid.logShapeAxis.step
        let scale = exp(logScale)
        let shape = exp(logShape)
        guard center.isFinite, logScale.isFinite, logShape.isFinite,
              scale.isFinite, scale > 0, shape.isFinite, shape > 0 else {
            throw CurveGridError.validationFailed(
                "winning parameters are nonfinite"
            )
        }

        var sumWeight = 0.0
        var sumWeightedBasis = 0.0
        var sumWeightedBasisSquared = 0.0
        var sumWeightedValue = 0.0
        var sumWeightedBasisValue = 0.0

        for sampleIndex in dataset.coordinates.indices {
            if (sampleIndex & 1023) == 0, Task.isCancelled {
                throw WorkloadCancellation()
            }
            let coordinate = dataset.coordinates[sampleIndex]
            let value = dataset.values[sampleIndex]
            let weight = dataset.inverseVariances[sampleIndex]
            let z = (coordinate - center) / scale
            let shapeSquared = shape * shape
            let zSquared = z * z
            let uSquared = shapeSquared + zSquared
            let u = sqrt(uSquared)
            let basisNumerator = uSquared + 2
            let basisDenominator = u * sqrt(uSquared + 4)
            let basis = basisNumerator / basisDenominator
            let weightedBasis = weight * basis
            let weightedBasisSquared = weightedBasis * basis
            let weightedValue = weight * value
            let weightedBasisValue = weightedBasis * value
            guard z.isFinite, shapeSquared.isFinite, zSquared.isFinite,
                  uSquared.isFinite, u.isFinite, basisNumerator.isFinite,
                  basisDenominator.isFinite, basisDenominator > 0,
                  basis.isFinite, weightedBasis.isFinite,
                  weightedBasisSquared.isFinite, weightedValue.isFinite,
                  weightedBasisValue.isFinite else {
                throw CurveGridError.validationFailed(
                    "winning basis evaluation is nonfinite"
                )
            }
            sumWeight += weight
            sumWeightedBasis += weightedBasis
            sumWeightedBasisSquared += weightedBasisSquared
            sumWeightedValue += weightedValue
            sumWeightedBasisValue += weightedBasisValue
            guard sumWeight.isFinite, sumWeightedBasis.isFinite,
                  sumWeightedBasisSquared.isFinite,
                  sumWeightedValue.isFinite,
                  sumWeightedBasisValue.isFinite else {
                throw CurveGridError.validationFailed(
                    "winning fit accumulation is nonfinite"
                )
            }
        }

        let weightBasisProduct = sumWeight * sumWeightedBasisSquared
        let basisProduct = sumWeightedBasis * sumWeightedBasis
        let determinant = weightBasisProduct - basisProduct
        let determinantScale = max(
            max(abs(weightBasisProduct), abs(basisProduct)),
            1.0
        )
        let determinantThreshold = 1e-12 * determinantScale
        guard weightBasisProduct.isFinite, basisProduct.isFinite,
              determinant.isFinite, determinantScale.isFinite,
              determinantThreshold.isFinite,
              determinant > determinantThreshold else {
            throw CurveGridError.validationFailed(
                "winning fit determinant is invalid"
            )
        }

        let offsetNumerator = sumWeightedValue * sumWeightedBasisSquared
            - sumWeightedBasisValue * sumWeightedBasis
        let amplitudeNumerator = sumWeight * sumWeightedBasisValue
            - sumWeightedBasis * sumWeightedValue
        let offset = offsetNumerator / determinant
        let amplitude = amplitudeNumerator / determinant
        guard offsetNumerator.isFinite, amplitudeNumerator.isFinite,
              offset.isFinite, amplitude.isFinite else {
            throw CurveGridError.validationFailed(
                "winning coefficients are nonfinite"
            )
        }

        var weightedResidualSumSquares = 0.0
        for sampleIndex in dataset.coordinates.indices {
            if (sampleIndex & 1023) == 0, Task.isCancelled {
                throw WorkloadCancellation()
            }
            let coordinate = dataset.coordinates[sampleIndex]
            let value = dataset.values[sampleIndex]
            let weight = dataset.inverseVariances[sampleIndex]
            let z = (coordinate - center) / scale
            let uSquared = shape * shape + z * z
            let u = sqrt(uSquared)
            let basis = (uSquared + 2) / (u * sqrt(uSquared + 4))
            let predicted = offset + amplitude * basis
            let residual = value - predicted
            let residualSquared = residual * residual
            let weightedResidual = weight * residualSquared
            guard z.isFinite, uSquared.isFinite, u.isFinite, basis.isFinite,
                  predicted.isFinite, residual.isFinite,
                  residualSquared.isFinite, weightedResidual.isFinite else {
                throw CurveGridError.validationFailed(
                    "winning residual evaluation is nonfinite"
                )
            }
            weightedResidualSumSquares += weightedResidual
            guard weightedResidualSumSquares.isFinite else {
                throw CurveGridError.validationFailed(
                    "winning residual accumulation is nonfinite"
                )
            }
        }

        let recomputed = CurveGridCandidate(
            gridIndex: claimed.gridIndex,
            center: center,
            logScale: logScale,
            logShape: logShape,
            offset: offset,
            amplitude: amplitude,
            weightedResidualSumSquares: weightedResidualSumSquares
        )
        guard recomputed == claimed else {
            throw CurveGridError.validationFailed(
                "winning result is inconsistent with local recomputation"
            )
        }
    }
}

nonisolated
protocol CurveGridDatasetDecoding: Sendable {
    func decode(_ data: Data) throws -> CurveGridDataset
}

nonisolated
struct CurveGridJSONDatasetDecoder: CurveGridDatasetDecoding {
    func decode(_ data: Data) throws -> CurveGridDataset {
        do {
            let dataset = try JSONDecoder().decode(
                CurveGridDataset.self,
                from: data
            )
            try dataset.validate()
            return dataset
        } catch let error as CurveGridError {
            throw error
        } catch {
            throw CurveGridError.invalidDataset(error.localizedDescription)
        }
    }
}

nonisolated
final class CurveGridWorkloadHandler:
    OpenStarBatchWorkloadHandler, @unchecked Sendable
{
    static let workloadID = CurveGridContract.workloadID
    static let datasetSchemaID = CurveGridContract.datasetSchemaID
    static let payloadSchemaID = CurveGridContract.payloadSchemaID
    static let resultSchemaID = CurveGridContract.resultSchemaID
    static let familyID = CurveGridContract.familyID
    static let validatorID = CurveGridContract.validatorID

    let workloadIDs = [CurveGridContract.workloadID]
    let capabilities = [WorkloadCapability(
        workloadID: CurveGridContract.workloadID,
        executionBackends: [.cpu],
        validatorID: CurveGridContract.validatorID,
        datasetSchemaID: CurveGridContract.datasetSchemaID,
        payloadSchemaID: CurveGridContract.payloadSchemaID,
        resultSchemaID: CurveGridContract.resultSchemaID
    )]
    let desiredBatchCount = 8

    private let datasetDecoder: any CurveGridDatasetDecoding

    init(
        datasetDecoder: any CurveGridDatasetDecoding =
            CurveGridJSONDatasetDecoder()
    ) {
        self.datasetDecoder = datasetDecoder
    }

    func execute(
        workUnit: WorkUnit,
        datasetData: Data?
    ) async throws -> WorkloadExecution {
        guard let datasetData else {
            throw CurveGridError.missingDataset
        }
        do {
            let dataset = try datasetDecoder.decode(datasetData)
            return try executePrepared(workUnit: workUnit, dataset: dataset)
        } catch is CancellationError {
            throw WorkloadCancellation()
        }
    }

    func executeBatch(
        workUnits: [WorkUnit],
        datasetData: Data?
    ) async throws -> [WorkloadBatchMember] {
        guard let datasetData else {
            return workUnits.map {
                WorkloadBatchMember(
                    workUnit: $0,
                    result: .failure(CurveGridError.missingDataset)
                )
            }
        }

        let dataset: CurveGridDataset
        do {
            dataset = try datasetDecoder.decode(datasetData)
        } catch is CancellationError {
            return workUnits.map {
                WorkloadBatchMember(
                    workUnit: $0,
                    result: .failure(WorkloadCancellation())
                )
            }
        } catch {
            return workUnits.map {
                WorkloadBatchMember(workUnit: $0, result: .failure(error))
            }
        }

        return workUnits.map { workUnit in
            do {
                return WorkloadBatchMember(
                    workUnit: workUnit,
                    result: .success(
                        try executePrepared(workUnit: workUnit, dataset: dataset)
                    )
                )
            } catch is CancellationError {
                return WorkloadBatchMember(
                    workUnit: workUnit,
                    result: .failure(WorkloadCancellation())
                )
            } catch {
                return WorkloadBatchMember(
                    workUnit: workUnit,
                    result: .failure(error)
                )
            }
        }
    }

    private func executePrepared(
        workUnit: WorkUnit,
        dataset: CurveGridDataset
    ) throws -> WorkloadExecution {
        try validate(workUnit: workUnit, dataset: dataset)
        let payload = try CurveGridPayload(workUnit.payload)
        let started = Date()
        let result = try CurveGridEvaluator.search(
            dataset: dataset,
            payload: payload
        )
        let duration = Date().timeIntervalSince(started)
        let best = result.best
        return WorkloadExecution(
            duration: duration,
            payload: .object([
                "familyID": .string(CurveGridContract.familyID),
                "gridStartIndex": try Self.jsonSafeNumber(
                    payload.gridStartIndex
                ),
                "gridCount": try Self.jsonSafeNumber(payload.gridCount),
                "bestGridIndex": try Self.jsonSafeNumber(best.gridIndex),
                "bestCenter": .number(best.center),
                "bestLogScale": .number(best.logScale),
                "bestLogShape": .number(best.logShape),
                "bestOffset": .number(best.offset),
                "bestAmplitude": .number(best.amplitude),
                "bestWeightedResidualSumSquares": .number(
                    best.weightedResidualSumSquares
                ),
                "evaluatedCandidateCount": try Self.jsonSafeNumber(
                    result.evaluatedCandidateCount
                ),
                "invalidCandidateCount": try Self.jsonSafeNumber(
                    result.invalidCandidateCount
                ),
            ]),
            summary: WorkloadResultSummary(
                title: "Curve-grid search",
                fields: [
                    WorkloadResultField(
                        id: "bestGridIndex",
                        label: "Best grid index",
                        value: String(best.gridIndex)
                    ),
                    WorkloadResultField(
                        id: "weightedResidualSumSquares",
                        label: "Weighted residual sum of squares",
                        value: String(
                            format: "%.12g",
                            best.weightedResidualSumSquares
                        )
                    ),
                ]
            ),
            legacyResultFields: .none
        )
    }

    private static func jsonSafeNumber(_ value: Int) throws -> JSONValue {
        guard value >= 0,
              value <= CurveGridContract.maximumJSONSafeInteger else {
            throw CurveGridError.validationFailed(
                "result integer exceeds the JSON-safe integer limit"
            )
        }
        return .number(Double(value))
    }

    private func validate(
        workUnit: WorkUnit,
        dataset: CurveGridDataset
    ) throws {
        guard workUnit.workloadID == CurveGridContract.workloadID else {
            throw CurveGridError.invalidWorkUnit("workload ID does not match")
        }
        guard workUnit.datasetSchemaID == CurveGridContract.datasetSchemaID else {
            throw CurveGridError.invalidWorkUnit(
                "dataset schema ID does not match"
            )
        }
        guard workUnit.payloadSchemaID == CurveGridContract.payloadSchemaID else {
            throw CurveGridError.invalidWorkUnit(
                "payload schema ID does not match"
            )
        }
        guard workUnit.resultSchemaID == CurveGridContract.resultSchemaID else {
            throw CurveGridError.invalidWorkUnit(
                "result schema ID does not match"
            )
        }
        guard workUnit.datasetID == dataset.id else {
            throw CurveGridError.invalidWorkUnit("dataset ID does not match")
        }
    }
}

private struct CurveGridCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

nonisolated
private func curveGridRequireExactKeys(
    _ container: KeyedDecodingContainer<CurveGridCodingKey>,
    _ expected: Set<String>
) throws {
    let actual = Set(container.allKeys.map(\.stringValue))
    guard actual == expected else {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Fields do not match the published schema."
            )
        )
    }
}

extension CurveGridAxis {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CurveGridCodingKey.self)
        try curveGridRequireExactKeys(container, ["start", "step", "count"])
        start = try container.decode(Double.self, forKey: CurveGridCodingKey("start"))
        step = try container.decode(Double.self, forKey: CurveGridCodingKey("step"))
        count = try container.decode(Int.self, forKey: CurveGridCodingKey("count"))
    }
}

extension CurveGridDefinition {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CurveGridCodingKey.self)
        try curveGridRequireExactKeys(container, [
            "familyID",
            "centerAxis",
            "logScaleAxis",
            "logShapeAxis",
            "candidatesPerWorkUnit",
        ])
        familyID = try container.decode(
            String.self,
            forKey: CurveGridCodingKey("familyID")
        )
        centerAxis = try container.decode(
            CurveGridAxis.self,
            forKey: CurveGridCodingKey("centerAxis")
        )
        logScaleAxis = try container.decode(
            CurveGridAxis.self,
            forKey: CurveGridCodingKey("logScaleAxis")
        )
        logShapeAxis = try container.decode(
            CurveGridAxis.self,
            forKey: CurveGridCodingKey("logShapeAxis")
        )
        candidatesPerWorkUnit = try container.decode(
            Int.self,
            forKey: CurveGridCodingKey("candidatesPerWorkUnit")
        )
    }
}

extension CurveGridDataset {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CurveGridCodingKey.self)
        id = try container.decode(String.self, forKey: CurveGridCodingKey("id"))
        datasetSchemaID = try container.decode(
            String.self,
            forKey: CurveGridCodingKey("datasetSchemaID")
        )
        coordinates = try container.decode(
            [Double].self,
            forKey: CurveGridCodingKey("coordinates")
        )
        values = try container.decode(
            [Double].self,
            forKey: CurveGridCodingKey("values")
        )
        inverseVariances = try container.decode(
            [Double].self,
            forKey: CurveGridCodingKey("inverseVariances")
        )
        curveGrid = try container.decode(
            CurveGridDefinition.self,
            forKey: CurveGridCodingKey("curveGrid")
        )
    }
}

nonisolated
enum CurveGridWorkloadModule {
    static func handlers() throws -> [any OpenStarWorkloadHandler] {
        [CurveGridWorkloadHandler()]
    }
}
