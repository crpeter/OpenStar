import Foundation

nonisolated
enum MorphologyGridParameters: Sendable, Equatable {
    case positive(
        center: Double,
        logScale: Double,
        logShape: Double
    )
    case orderedDoublet(
        negativeCenter: Double,
        separation: Double,
        negativeLogScale: Double,
        negativeLogShape: Double,
        positiveLogScale: Double,
        positiveLogShape: Double
    )
    case independentDoublet(
        negativeCenter: Double,
        positiveCenter: Double,
        negativeLogScale: Double,
        negativeLogShape: Double,
        positiveLogScale: Double,
        positiveLogShape: Double
    )

    var jsonValue: JSONValue {
        switch self {
        case .positive(let center, let logScale, let logShape):
            return .object([
                "center": .number(center),
                "logScale": .number(logScale),
                "logShape": .number(logShape),
            ])
        case .orderedDoublet(
            let negativeCenter,
            let separation,
            let negativeLogScale,
            let negativeLogShape,
            let positiveLogScale,
            let positiveLogShape
        ):
            return .object([
                "negativeCenter": .number(negativeCenter),
                "separation": .number(separation),
                "negativeLogScale": .number(negativeLogScale),
                "negativeLogShape": .number(negativeLogShape),
                "positiveLogScale": .number(positiveLogScale),
                "positiveLogShape": .number(positiveLogShape),
            ])
        case .independentDoublet(
            let negativeCenter,
            let positiveCenter,
            let negativeLogScale,
            let negativeLogShape,
            let positiveLogScale,
            let positiveLogShape
        ):
            return .object([
                "negativeCenter": .number(negativeCenter),
                "positiveCenter": .number(positiveCenter),
                "negativeLogScale": .number(negativeLogScale),
                "negativeLogShape": .number(negativeLogShape),
                "positiveLogScale": .number(positiveLogScale),
                "positiveLogShape": .number(positiveLogShape),
            ])
        }
    }

    var geometries: [MorphologyGridGeometry]? {
        switch self {
        case .positive(let center, let logScale, let logShape):
            return [MorphologyGridGeometry(
                center: center,
                logScale: logScale,
                logShape: logShape
            )]
        case .orderedDoublet(
            let negativeCenter,
            let separation,
            let negativeLogScale,
            let negativeLogShape,
            let positiveLogScale,
            let positiveLogShape
        ):
            let positiveCenter = negativeCenter + separation
            guard positiveCenter.isFinite,
                  positiveCenter > negativeCenter else {
                return nil
            }
            return [
                MorphologyGridGeometry(
                    center: negativeCenter,
                    logScale: negativeLogScale,
                    logShape: negativeLogShape
                ),
                MorphologyGridGeometry(
                    center: positiveCenter,
                    logScale: positiveLogScale,
                    logShape: positiveLogShape
                ),
            ]
        case .independentDoublet(
            let negativeCenter,
            let positiveCenter,
            let negativeLogScale,
            let negativeLogShape,
            let positiveLogScale,
            let positiveLogShape
        ):
            guard positiveCenter.isFinite,
                  positiveCenter > negativeCenter else {
                return nil
            }
            return [
                MorphologyGridGeometry(
                    center: negativeCenter,
                    logScale: negativeLogScale,
                    logShape: negativeLogShape
                ),
                MorphologyGridGeometry(
                    center: positiveCenter,
                    logScale: positiveLogScale,
                    logShape: positiveLogShape
                ),
            ]
        }
    }
}

nonisolated
struct MorphologyGridGeometry: Sendable, Equatable {
    let center: Double
    let logScale: Double
    let logShape: Double
}

nonisolated
struct MorphologyGridSeriesFit: Sendable, Equatable {
    let genericSeriesID: String
    let positiveWeightSampleCount: Int
    let offset: Double
    let negativeAmplitude: Double?
    let positiveAmplitude: Double
    let weightedResidualSumSquares: Double

    func jsonValue(modelClassID: MorphologyGridModelClass) throws -> JSONValue {
        var object: [String: JSONValue] = [
            "genericSeriesID": .string(genericSeriesID),
            "positiveWeightSampleCount": try MorphologyGridResultEncoding
                .jsonSafeNumber(positiveWeightSampleCount),
            "offset": .number(offset),
            "positiveAmplitude": .number(positiveAmplitude),
            "positiveAmplitudeSign": .string(
                MorphologyGridEvaluator.amplitudeSign(positiveAmplitude)
            ),
            "weightedResidualSumSquares": .number(
                weightedResidualSumSquares
            ),
        ]
        if modelClassID != .positivePulseOnly {
            guard let negativeAmplitude else {
                throw MorphologyGridError.validationFailed(
                    "doublet fit lacks a negative amplitude"
                )
            }
            object["negativeAmplitude"] = .number(negativeAmplitude)
            object["negativeAmplitudeSign"] = .string(
                MorphologyGridEvaluator.amplitudeSign(negativeAmplitude)
            )
        }
        return .object(object)
    }
}

nonisolated
struct MorphologyGridCandidate: Sendable, Equatable {
    let gridIndex: Int
    let parameters: MorphologyGridParameters
    let seriesFits: [MorphologyGridSeriesFit]
    let positiveWeightSampleCount: Int
    let weightedResidualSumSquares: Double
    let nominalParameterCount: Int
    let bayesianInformationCriterion: Double
    let correctedAkaikeInformationCriterion: Double?
    let correctedAkaikeInformationCriterionDefined: Bool

    func jsonValue(modelClassID: MorphologyGridModelClass) throws -> JSONValue {
        let aiccValue: JSONValue
        if let correctedAkaikeInformationCriterion {
            aiccValue = .number(correctedAkaikeInformationCriterion)
        } else {
            aiccValue = .null
        }
        return .object([
            "gridIndex": try MorphologyGridResultEncoding.jsonSafeNumber(
                gridIndex
            ),
            "parameters": parameters.jsonValue,
            "seriesFits": .array(try seriesFits.map {
                try $0.jsonValue(modelClassID: modelClassID)
            }),
            "positiveWeightSampleCount": try MorphologyGridResultEncoding
                .jsonSafeNumber(positiveWeightSampleCount),
            "weightedResidualSumSquares": .number(
                weightedResidualSumSquares
            ),
            "nominalParameterCount": try MorphologyGridResultEncoding
                .jsonSafeNumber(nominalParameterCount),
            "bayesianInformationCriterion": .number(
                bayesianInformationCriterion
            ),
            "correctedAkaikeInformationCriterion": aiccValue,
            "correctedAkaikeInformationCriterionDefined": .bool(
                correctedAkaikeInformationCriterionDefined
            ),
        ])
    }
}

nonisolated
struct MorphologyGridSearchResult: Sendable, Equatable {
    let bestCandidate: MorphologyGridCandidate?
    let evaluatedCandidateCount: Int
    let invalidCandidateCount: Int
}

nonisolated
enum MorphologyGridEvaluator {
    static func search(
        dataset: MorphologyGridDataset,
        payload: MorphologyGridPayload
    ) throws -> MorphologyGridSearchResult {
        try dataset.validate()
        try payload.validate(in: dataset)

        var bestCandidate: MorphologyGridCandidate?
        var invalidCandidateCount = 0
        for localIndex in 0..<payload.gridCount {
            if (localIndex & 63) == 0, Task.isCancelled {
                throw WorkloadCancellation()
            }
            let (gridIndex, overflow) = payload.gridStartIndex
                .addingReportingOverflow(localIndex)
            guard !overflow else {
                throw MorphologyGridError.invalidWorkUnit(
                    "shard index overflows"
                )
            }
            guard let candidate = try evaluateCandidate(
                dataset: dataset,
                gridIndex: gridIndex
            ) else {
                invalidCandidateCount += 1
                continue
            }
            if let current = bestCandidate {
                if candidatePrecedes(candidate, current) {
                    bestCandidate = candidate
                }
            } else {
                bestCandidate = candidate
            }
        }
        return MorphologyGridSearchResult(
            bestCandidate: bestCandidate,
            evaluatedCandidateCount: payload.gridCount,
            invalidCandidateCount: invalidCandidateCount
        )
    }

    static func evaluateCandidate(
        dataset: MorphologyGridDataset,
        gridIndex: Int
    ) throws -> MorphologyGridCandidate? {
        let parameters: MorphologyGridParameters
        do {
            parameters = try candidateParameters(
                grid: dataset.morphologyGrid,
                gridIndex: gridIndex
            )
        } catch is WorkloadCancellation {
            throw WorkloadCancellation()
        } catch {
            return nil
        }
        guard let geometries = parameters.geometries else {
            return nil
        }
        let signs = geometries.count == 1 ? [1] : [-1, 1]

        var fits: [MorphologyGridSeriesFit] = []
        fits.reserveCapacity(dataset.series.count)
        var totalObjective = 0.0
        for (seriesIndex, series) in dataset.series.enumerated() {
            if (seriesIndex & 31) == 0, Task.isCancelled {
                throw WorkloadCancellation()
            }
            var componentBases: [[Double]] = []
            componentBases.reserveCapacity(geometries.count)
            for geometry in geometries {
                var bases: [Double] = []
                bases.reserveCapacity(series.coordinates.count)
                for sampleIndex in series.coordinates.indices {
                    if (sampleIndex & 1023) == 0, Task.isCancelled {
                        throw WorkloadCancellation()
                    }
                    if series.inverseVariances[sampleIndex] == 0 {
                        bases.append(0)
                        continue
                    }
                    guard let basis = componentBasis(
                        coordinate: series.coordinates[sampleIndex],
                        center: geometry.center,
                        logScale: geometry.logScale,
                        logShape: geometry.logShape
                    ) else {
                        return nil
                    }
                    bases.append(basis)
                }
                componentBases.append(bases)
            }
            guard let fitted = try fitSeries(
                series,
                componentBases: componentBases,
                signs: signs
            ) else {
                return nil
            }
            fits.append(MorphologyGridSeriesFit(
                genericSeriesID: series.genericSeriesID,
                positiveWeightSampleCount: series.positiveWeightSampleCount,
                offset: fitted.offset,
                negativeAmplitude: fitted.amplitudes.count == 2
                    ? fitted.amplitudes[0]
                    : nil,
                positiveAmplitude: fitted.amplitudes.count == 2
                    ? fitted.amplitudes[1]
                    : fitted.amplitudes[0],
                weightedResidualSumSquares: fitted.objective
            ))
            totalObjective += fitted.objective
            guard totalObjective.isFinite else {
                return nil
            }
        }

        let positiveWeightSampleCount = fits.reduce(0) {
            $0 + $1.positiveWeightSampleCount
        }
        let nominalParameterCount = try nominalParameterCount(
            modelClassID: dataset.modelClassID,
            seriesCount: fits.count
        )
        let bayesianInformationCriterion = totalObjective
            + Double(nominalParameterCount)
                * log(Double(positiveWeightSampleCount))
        let correctedAkaikeInformationCriterion: Double?
        let correctedAkaikeInformationCriterionDefined: Bool
        if positiveWeightSampleCount > nominalParameterCount + 1 {
            correctedAkaikeInformationCriterion = totalObjective
                + 2.0 * Double(nominalParameterCount)
                + 2.0 * Double(nominalParameterCount)
                    * Double(nominalParameterCount + 1)
                    / Double(
                        positiveWeightSampleCount
                            - nominalParameterCount - 1
                    )
            correctedAkaikeInformationCriterionDefined = true
        } else {
            correctedAkaikeInformationCriterion = nil
            correctedAkaikeInformationCriterionDefined = false
        }
        guard totalObjective.isFinite,
              bayesianInformationCriterion.isFinite,
              correctedAkaikeInformationCriterion?.isFinite != false else {
            return nil
        }
        return MorphologyGridCandidate(
            gridIndex: gridIndex,
            parameters: parameters,
            seriesFits: fits,
            positiveWeightSampleCount: positiveWeightSampleCount,
            weightedResidualSumSquares: totalObjective,
            nominalParameterCount: nominalParameterCount,
            bayesianInformationCriterion: bayesianInformationCriterion,
            correctedAkaikeInformationCriterion:
                correctedAkaikeInformationCriterion,
            correctedAkaikeInformationCriterionDefined:
                correctedAkaikeInformationCriterionDefined
        )
    }

    static func componentBasis(
        coordinate: Double,
        center: Double,
        logScale: Double,
        logShape: Double
    ) -> Double? {
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
        let basis = numerator / denominator
        guard scale.isFinite, scale > 0,
              shape.isFinite, shape > 0,
              difference.isFinite,
              z.isFinite,
              shapeSquared.isFinite,
              zSquared.isFinite,
              uSquared.isFinite,
              u.isFinite,
              numerator.isFinite,
              rooted.isFinite,
              denominator.isFinite,
              basis.isFinite else {
            return nil
        }
        return basis
    }

    static func amplitudeSign(_ value: Double) -> String {
        if value < 0 {
            return "negative"
        }
        if value > 0 {
            return "positive"
        }
        return "zero"
    }

    static func candidatePrecedes(
        _ left: MorphologyGridCandidate,
        _ right: MorphologyGridCandidate
    ) -> Bool {
        for (leftValue, rightValue) in [
            (
                left.weightedResidualSumSquares,
                right.weightedResidualSumSquares
            ),
            (
                left.bayesianInformationCriterion,
                right.bayesianInformationCriterion
            ),
        ] {
            let limit = objectiveLimit(leftValue, rightValue)
            if leftValue < rightValue - limit {
                return true
            }
            if rightValue < leftValue - limit {
                return false
            }
        }

        if left.correctedAkaikeInformationCriterionDefined,
           right.correctedAkaikeInformationCriterionDefined {
            guard let leftAICc = left.correctedAkaikeInformationCriterion,
                  let rightAICc = right.correctedAkaikeInformationCriterion else {
                return false
            }
            let limit = objectiveLimit(leftAICc, rightAICc)
            if leftAICc < rightAICc - limit {
                return true
            }
            if rightAICc < leftAICc - limit {
                return false
            }
        } else if left.correctedAkaikeInformationCriterionDefined
                    != right.correctedAkaikeInformationCriterionDefined {
            return left.correctedAkaikeInformationCriterionDefined
        }
        return left.gridIndex < right.gridIndex
    }

    static func nominalParameterCount(
        modelClassID: MorphologyGridModelClass,
        seriesCount: Int
    ) throws -> Int {
        switch modelClassID {
        case .positivePulseOnly:
            return 2 * seriesCount + 3
        case .orderedNegativePositiveDoublet:
            return 3 * seriesCount + 6
        case .independentPulses where seriesCount == 1:
            return 9
        case .independentPulses:
            throw MorphologyGridError.validationFailed(
                "model class and series count are inconsistent"
            )
        }
    }

    private struct FittedSeries {
        let offset: Double
        let amplitudes: [Double]
        let objective: Double
        let stateOrdinal: Int
    }

    private static func fitSeries(
        _ series: MorphologyGridSeries,
        componentBases: [[Double]],
        signs: [Int]
    ) throws -> FittedSeries? {
        let componentCount = componentBases.count
        guard componentCount == signs.count,
              componentCount == 1 || componentCount == 2,
              componentBases.allSatisfy({
                $0.count == series.coordinates.count
              }) else {
            return nil
        }
        let activeStates: [[Bool]] = componentCount == 1
            ? [[true], [false]]
            : [
                [true, true],
                [false, true],
                [true, false],
                [false, false],
            ]
        var accepted: FittedSeries?
        for (stateOrdinal, state) in activeStates.enumerated() {
            let freeComponents = state.indices.filter { state[$0] }
            let columnCount = 1 + freeComponents.count
            if series.positiveWeightSampleCount < columnCount {
                continue
            }
            var gram = Array(
                repeating: Array(repeating: 0.0, count: columnCount),
                count: columnCount
            )
            var right = Array(repeating: 0.0, count: columnCount)
            var valid = true
            for sampleIndex in series.values.indices {
                if (sampleIndex & 1023) == 0, Task.isCancelled {
                    throw WorkloadCancellation()
                }
                let value = series.values[sampleIndex]
                let weight = series.inverseVariances[sampleIndex]
                if weight == 0 {
                    continue
                }
                var columns = [1.0]
                columns.append(contentsOf: freeComponents.map {
                    componentBases[$0][sampleIndex]
                })
                for left in 0..<columnCount {
                    for rightIndex in left..<columnCount {
                        let term = weight * columns[left]
                            * columns[rightIndex]
                        gram[left][rightIndex] += term
                    }
                    right[left] += weight * columns[left] * value
                }
                if !right.allSatisfy(\.isFinite)
                    || !gram.joined().allSatisfy(\.isFinite) {
                    valid = false
                    break
                }
            }
            if !valid {
                continue
            }
            for left in 0..<columnCount {
                for rightIndex in (left + 1)..<columnCount {
                    gram[rightIndex][left] = gram[left][rightIndex]
                }
            }
            guard let solved = solveNormalEquations(
                matrix: gram,
                rightHandSide: right
            ) else {
                continue
            }
            let offset = solved[0]
            var amplitudes = Array(repeating: 0.0, count: componentCount)
            for (solutionIndex, componentIndex) in freeComponents.enumerated() {
                amplitudes[componentIndex] = solved[solutionIndex + 1]
            }
            var satisfiesConstraints = true
            for (sign, amplitude) in zip(signs, amplitudes) {
                if (sign < 0 && amplitude > 0)
                    || (sign > 0 && amplitude < 0) {
                    satisfiesConstraints = false
                    break
                }
            }
            if !satisfiesConstraints {
                continue
            }

            var objective = 0.0
            for sampleIndex in series.values.indices {
                if (sampleIndex & 1023) == 0, Task.isCancelled {
                    throw WorkloadCancellation()
                }
                let value = series.values[sampleIndex]
                let weight = series.inverseVariances[sampleIndex]
                if weight == 0 {
                    continue
                }
                var prediction = offset
                for componentIndex in amplitudes.indices {
                    prediction = prediction
                        + amplitudes[componentIndex]
                            * componentBases[componentIndex][sampleIndex]
                }
                let residual = value - prediction
                let term = weight * residual * residual
                guard prediction.isFinite,
                      residual.isFinite,
                      term.isFinite else {
                    valid = false
                    break
                }
                objective += term
                guard objective.isFinite else {
                    valid = false
                    break
                }
            }
            if !valid {
                continue
            }
            let candidate = FittedSeries(
                offset: offset,
                amplitudes: amplitudes,
                objective: objective,
                stateOrdinal: stateOrdinal
            )
            if let current = accepted {
                let limit = objectiveLimit(
                    candidate.objective,
                    current.objective
                )
                if candidate.objective < current.objective - limit
                    || (abs(candidate.objective - current.objective) <= limit
                        && candidate.stateOrdinal < current.stateOrdinal) {
                    accepted = candidate
                }
            } else {
                accepted = candidate
            }
        }
        return accepted
    }

    private static func solveNormalEquations(
        matrix: [[Double]],
        rightHandSide: [Double]
    ) -> [Double]? {
        let size = matrix.count
        guard size > 0,
              rightHandSide.count == size,
              matrix.allSatisfy({ $0.count == size }) else {
            return nil
        }
        var working = matrix
        var right = rightHandSide
        guard working.joined().allSatisfy(\.isFinite),
              right.allSatisfy(\.isFinite),
              let originalMaximum = working.joined()
                .map({ abs($0) }).max() else {
            return nil
        }
        let rankLimit = MorphologyGridContract.rankRelativeTolerance
            * max(1.0, originalMaximum)
        guard originalMaximum.isFinite, rankLimit.isFinite else {
            return nil
        }

        for pivot in 0..<size {
            var pivotRow = pivot
            var pivotAbsolute = abs(working[pivot][pivot])
            if pivot + 1 < size {
                for row in (pivot + 1)..<size {
                    let candidateAbsolute = abs(working[row][pivot])
                    if candidateAbsolute > pivotAbsolute {
                        pivotRow = row
                        pivotAbsolute = candidateAbsolute
                    }
                }
            }
            guard pivotAbsolute.isFinite, pivotAbsolute > rankLimit else {
                return nil
            }
            if pivotRow != pivot {
                working.swapAt(pivot, pivotRow)
                right.swapAt(pivot, pivotRow)
            }
            if pivot + 1 < size {
                for row in (pivot + 1)..<size {
                    let factor = working[row][pivot]
                        / working[pivot][pivot]
                    working[row][pivot] = 0.0
                    if pivot + 1 < size {
                        for column in (pivot + 1)..<size {
                            working[row][column] = working[row][column]
                                - factor * working[pivot][column]
                        }
                    }
                    right[row] = right[row] - factor * right[pivot]
                    guard working[row].allSatisfy(\.isFinite),
                          right[row].isFinite else {
                        return nil
                    }
                }
            }
        }

        var solution = Array(repeating: 0.0, count: size)
        for row in stride(from: size - 1, through: 0, by: -1) {
            var numerator = right[row]
            if row + 1 < size {
                for column in (row + 1)..<size {
                    numerator = numerator
                        - working[row][column] * solution[column]
                }
            }
            let diagonal = working[row][row]
            guard numerator.isFinite,
                  diagonal.isFinite,
                  abs(diagonal) > rankLimit else {
                return nil
            }
            solution[row] = numerator / diagonal
            guard solution[row].isFinite else {
                return nil
            }
        }
        return solution
    }

    private static func candidateParameters(
        grid: MorphologyGridDefinition,
        gridIndex: Int
    ) throws -> MorphologyGridParameters {
        let indices = try MorphologyGridIndexing.candidateIndices(
            index: gridIndex,
            counts: try grid.candidateCounts
        )
        switch grid.modelClassID {
        case .positivePulseOnly:
            return .positive(
                center: try grid.axes[0].value(at: indices[0]),
                logScale: try grid.axes[1].value(at: indices[1]),
                logShape: try grid.axes[2].value(at: indices[2])
            )
        case .orderedNegativePositiveDoublet:
            let negativeCenter = try grid.axes[0].value(at: indices[0])
            let separation = try grid.axes[1].value(at: indices[1])
            let positiveCenter = negativeCenter + separation
            guard positiveCenter.isFinite,
                  positiveCenter > negativeCenter else {
                throw MorphologyGridError.invalidGridIndex(
                    "ordered candidate centers are invalid"
                )
            }
            return .orderedDoublet(
                negativeCenter: negativeCenter,
                separation: separation,
                negativeLogScale: try grid.axes[2].value(at: indices[2]),
                negativeLogShape: try grid.axes[3].value(at: indices[3]),
                positiveLogScale: try grid.axes[4].value(at: indices[4]),
                positiveLogShape: try grid.axes[5].value(at: indices[5])
            )
        case .independentPulses:
            let centerPair = try MorphologyGridIndexing
                .independentCenterPairIndices(
                    centerCount: grid.axes[0].count,
                    pairIndex: indices[0]
                )
            return .independentDoublet(
                negativeCenter: try grid.axes[0].value(
                    at: centerPair.negative
                ),
                positiveCenter: try grid.axes[0].value(
                    at: centerPair.positive
                ),
                negativeLogScale: try grid.axes[1].value(at: indices[1]),
                negativeLogShape: try grid.axes[2].value(at: indices[2]),
                positiveLogScale: try grid.axes[3].value(at: indices[3]),
                positiveLogShape: try grid.axes[4].value(at: indices[4])
            )
        }
    }

    private static func objectiveLimit(_ left: Double, _ right: Double) -> Double {
        MorphologyGridContract.resultRelativeTolerance
            * max(1.0, max(abs(left), abs(right)))
    }
}

nonisolated
enum MorphologyGridResultEncoding {
    static func jsonSafeNumber(_ value: Int) throws -> JSONValue {
        guard value >= 0,
              value <= MorphologyGridContract.maximumJSONSafeInteger else {
            throw MorphologyGridError.validationFailed(
                "result integer exceeds the JSON-safe integer limit"
            )
        }
        return .number(Double(value))
    }
}
