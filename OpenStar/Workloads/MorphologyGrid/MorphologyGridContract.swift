import Foundation

nonisolated
enum MorphologyGridContract {
    static let workloadID = "openstar.morphology-grid.v1"
    static let datasetSchemaID = "openstar.dataset.morphology-grid.v1"
    static let payloadSchemaID = "openstar.payload.morphology-grid-shard.v1"
    static let resultSchemaID = "openstar.result.morphology-grid-shard.v1"
    static let morphologyFamilyID =
        "openstar.microlensing-residual-morphology.v1"
    static let componentTemplateFamilyID =
        "openstar.curve-family.symmetric-radial-amplification.v1"
    static let executionContractID =
        "openstar.morphology-grid-execution.v1"
    static let executionContractVersion = "1.0"
    static let validatorID = "openstar.morphology-grid.local-double.v1"
    static let maximumJSONSafeInteger = 9_007_199_254_740_991
    static let rankRelativeTolerance = 1e-12
    static let resultRelativeTolerance = 1e-9
}

nonisolated
enum MorphologyGridError:
    LocalizedError, WorkFailureClassifyingError, Equatable
{
    case missingDataset
    case invalidDataset(String)
    case invalidWorkUnit(String)
    case invalidGridIndex(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingDataset:
            return "Morphology-grid work requires a dataset."
        case .invalidDataset(let message):
            return "Invalid morphology-grid dataset: \(message)"
        case .invalidWorkUnit(let message):
            return "Invalid morphology-grid work unit: \(message)"
        case .invalidGridIndex(let message):
            return "Invalid morphology-grid index: \(message)"
        case .validationFailed(let message):
            return "Morphology-grid local validation failed: \(message)"
        }
    }

    var workFailureKind: WorkFailureKind {
        switch self {
        case .validationFailed:
            return .workloadValidation
        case .missingDataset,
             .invalidDataset,
             .invalidWorkUnit,
             .invalidGridIndex:
            return .invalidInput
        }
    }
}

nonisolated
enum MorphologyGridModelClass: String, Decodable, Sendable, Equatable {
    case positivePulseOnly = "POSITIVE_PULSE_ONLY"
    case orderedNegativePositiveDoublet =
        "ORDERED_NEGATIVE_POSITIVE_DOUBLET"
    case independentPulses = "INDEPENDENT_PULSES"
}

nonisolated
struct MorphologyGridAxis: Decodable, Sendable, Equatable {
    let start: Double?
    let step: Double?
    let count: Int
    let explicitValues: [Double]?

    init(start: Double, step: Double, count: Int) {
        self.start = start
        self.step = step
        self.count = count
        explicitValues = nil
    }

    init(values: [Double]) {
        start = nil
        step = nil
        count = values.count
        explicitValues = values
    }

    func value(at index: Int) throws -> Double {
        guard index >= 0, index < count else {
            throw MorphologyGridError.invalidGridIndex(
                "axis index is outside the configured axis"
            )
        }
        if let explicitValues {
            return explicitValues[index]
        }
        guard let start, let step else {
            throw MorphologyGridError.invalidGridIndex(
                "axis representation is invalid"
            )
        }
        let value = start + Double(index) * step
        guard value.isFinite else {
            throw MorphologyGridError.invalidGridIndex(
                "axis value is nonfinite"
            )
        }
        return value
    }

    func validate(
        fieldName: String,
        exponentiated: Bool,
        allowsExplicit: Bool = false,
        strictlyPositive: Bool = false
    ) throws {
        guard count > 0,
              count <= MorphologyGridContract.maximumJSONSafeInteger else {
            throw MorphologyGridError.invalidDataset(
                "\(fieldName).count must be a positive JSON-safe integer"
            )
        }

        let valuesToValidate: [Double]
        if let explicitValues {
            guard allowsExplicit else {
                throw MorphologyGridError.invalidDataset(
                    "\(fieldName) does not permit explicit values"
                )
            }
            guard !explicitValues.isEmpty,
                  explicitValues.allSatisfy(\.isFinite) else {
                throw MorphologyGridError.invalidDataset(
                    "\(fieldName).values must be a nonempty finite array"
                )
            }
            for index in 1..<explicitValues.count {
                guard explicitValues[index] > explicitValues[index - 1] else {
                    throw MorphologyGridError.invalidDataset(
                        "\(fieldName).values must be strictly increasing"
                    )
                }
            }
            valuesToValidate = explicitValues
        } else {
            guard let start, let step,
                  start.isFinite, step.isFinite else {
                throw MorphologyGridError.invalidDataset(
                    "\(fieldName) must have finite start and step values"
                )
            }
            guard step > 0 else {
                throw MorphologyGridError.invalidDataset(
                    "\(fieldName).step must be positive"
                )
            }
            let last = start + Double(count - 1) * step
            guard last.isFinite else {
                throw MorphologyGridError.invalidDataset(
                    "\(fieldName) has a nonfinite endpoint"
                )
            }
            valuesToValidate = [start, last]
        }

        for value in valuesToValidate {
            if strictlyPositive, value <= 0 {
                throw MorphologyGridError.invalidDataset(
                    "\(fieldName) values must be strictly positive"
                )
            }
            if exponentiated {
                let expanded = exp(value)
                guard expanded.isFinite, expanded > 0 else {
                    throw MorphologyGridError.invalidDataset(
                        "\(fieldName) has an invalid exponentiated value"
                    )
                }
            }
        }
    }
}

nonisolated
struct MorphologyGridSeries: Decodable, Sendable, Equatable {
    let genericSeriesID: String
    let coordinates: [Double]
    let values: [Double]
    let inverseVariances: [Double]

    var positiveWeightSampleCount: Int {
        inverseVariances.reduce(into: 0) { count, weight in
            if weight > 0 {
                count += 1
            }
        }
    }

    func validate(index: Int) throws {
        let fieldName = "series[\(index)]"
        guard genericSeriesID.contains(where: { !$0.isWhitespace }) else {
            throw MorphologyGridError.invalidDataset(
                "\(fieldName).genericSeriesID must be nonempty"
            )
        }
        guard !coordinates.isEmpty,
              coordinates.count == values.count,
              coordinates.count == inverseVariances.count else {
            throw MorphologyGridError.invalidDataset(
                "\(fieldName) arrays must be nonempty and equal length"
            )
        }
        guard coordinates.allSatisfy(\.isFinite),
              values.allSatisfy(\.isFinite),
              inverseVariances.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw MorphologyGridError.invalidDataset(
                "\(fieldName) samples must be finite with nonnegative weights"
            )
        }
        for sampleIndex in 1..<coordinates.count {
            guard coordinates[sampleIndex] > coordinates[sampleIndex - 1] else {
                throw MorphologyGridError.invalidDataset(
                    "\(fieldName).coordinates must be strictly increasing"
                )
            }
        }
    }
}

nonisolated
struct MorphologyGridDefinition: Sendable, Equatable {
    let modelClassID: MorphologyGridModelClass
    let axes: [MorphologyGridAxis]

    var candidateCounts: [Int] {
        get throws {
            if modelClassID == .independentPulses {
                return [
                    try MorphologyGridIndexing.independentCenterPairCount(
                        centerCount: axes[0].count
                    ),
                    axes[1].count,
                    axes[2].count,
                    axes[3].count,
                    axes[4].count,
                ]
            }
            return axes.map(\.count)
        }
    }

    func totalCandidateCount() throws -> Int {
        try MorphologyGridIndexing.safeProduct(
            try candidateCounts,
            fieldName: "total candidate count"
        )
    }

    func validate() throws {
        switch modelClassID {
        case .positivePulseOnly:
            guard axes.count == 3 else {
                throw MorphologyGridError.invalidDataset(
                    "positive morphologyGrid field set is invalid"
                )
            }
            try axes[0].validate(
                fieldName: "morphologyGrid.centerAxis",
                exponentiated: false
            )
            try axes[1].validate(
                fieldName: "morphologyGrid.logScaleAxis",
                exponentiated: true
            )
            try axes[2].validate(
                fieldName: "morphologyGrid.logShapeAxis",
                exponentiated: true,
                allowsExplicit: true
            )
        case .orderedNegativePositiveDoublet:
            guard axes.count == 6 else {
                throw MorphologyGridError.invalidDataset(
                    "ordered morphologyGrid field set is invalid"
                )
            }
            try axes[0].validate(
                fieldName: "morphologyGrid.negativeCenterAxis",
                exponentiated: false
            )
            try axes[1].validate(
                fieldName: "morphologyGrid.separationAxis",
                exponentiated: false,
                strictlyPositive: true
            )
            try axes[2].validate(
                fieldName: "morphologyGrid.negativeLogScaleAxis",
                exponentiated: true
            )
            try axes[3].validate(
                fieldName: "morphologyGrid.negativeLogShapeAxis",
                exponentiated: true,
                allowsExplicit: true
            )
            try axes[4].validate(
                fieldName: "morphologyGrid.positiveLogScaleAxis",
                exponentiated: true
            )
            try axes[5].validate(
                fieldName: "morphologyGrid.positiveLogShapeAxis",
                exponentiated: true,
                allowsExplicit: true
            )
        case .independentPulses:
            guard axes.count == 5 else {
                throw MorphologyGridError.invalidDataset(
                    "independent morphologyGrid field set is invalid"
                )
            }
            try axes[0].validate(
                fieldName: "morphologyGrid.centerAxis",
                exponentiated: false
            )
            _ = try MorphologyGridIndexing.independentCenterPairCount(
                centerCount: axes[0].count
            )
            try axes[1].validate(
                fieldName: "morphologyGrid.negativeLogScaleAxis",
                exponentiated: true
            )
            try axes[2].validate(
                fieldName: "morphologyGrid.negativeLogShapeAxis",
                exponentiated: true,
                allowsExplicit: true
            )
            try axes[3].validate(
                fieldName: "morphologyGrid.positiveLogScaleAxis",
                exponentiated: true
            )
            try axes[4].validate(
                fieldName: "morphologyGrid.positiveLogShapeAxis",
                exponentiated: true,
                allowsExplicit: true
            )
        }
        _ = try totalCandidateCount()
    }
}

nonisolated
struct MorphologyGridDataset: Decodable, Sendable, Equatable {
    let id: String
    let datasetSchemaID: String
    let morphologyFamilyID: String
    let componentTemplateFamilyID: String
    let modelClassID: MorphologyGridModelClass
    let series: [MorphologyGridSeries]
    let morphologyGrid: MorphologyGridDefinition
    let candidatesPerWorkUnit: Int
    let executionContractID: String
    let executionContractVersion: String

    func validate() throws {
        guard id.contains(where: { !$0.isWhitespace }) else {
            throw MorphologyGridError.invalidDataset("id must be nonempty")
        }
        guard datasetSchemaID == MorphologyGridContract.datasetSchemaID else {
            throw MorphologyGridError.invalidDataset(
                "datasetSchemaID is invalid"
            )
        }
        guard morphologyFamilyID == MorphologyGridContract.morphologyFamilyID else {
            throw MorphologyGridError.invalidDataset(
                "morphologyFamilyID is invalid"
            )
        }
        guard componentTemplateFamilyID
                == MorphologyGridContract.componentTemplateFamilyID else {
            throw MorphologyGridError.invalidDataset(
                "componentTemplateFamilyID is invalid"
            )
        }
        guard executionContractID
                == MorphologyGridContract.executionContractID else {
            throw MorphologyGridError.invalidDataset(
                "executionContractID is invalid"
            )
        }
        guard executionContractVersion
                == MorphologyGridContract.executionContractVersion else {
            throw MorphologyGridError.invalidDataset(
                "executionContractVersion is invalid"
            )
        }
        guard !series.isEmpty else {
            throw MorphologyGridError.invalidDataset(
                "series must be a nonempty array"
            )
        }
        for (index, item) in series.enumerated() {
            try item.validate(index: index)
        }
        let seriesIDs = series.map(\.genericSeriesID)
        let seriesIDScalars = seriesIDs.map {
            $0.unicodeScalars.map(\.value)
        }
        guard Set(seriesIDScalars).count == seriesIDScalars.count else {
            throw MorphologyGridError.invalidDataset(
                "generic series IDs must be unique"
            )
        }
        guard seriesIDScalars == seriesIDScalars.sorted(by: {
            $0.lexicographicallyPrecedes($1)
        }) else {
            throw MorphologyGridError.invalidDataset(
                "series must be in canonical generic-series-ID order"
            )
        }
        guard morphologyGrid.modelClassID == modelClassID else {
            throw MorphologyGridError.invalidDataset(
                "morphologyGrid model class is inconsistent"
            )
        }
        try morphologyGrid.validate()
        if modelClassID == .independentPulses, series.count != 1 {
            throw MorphologyGridError.invalidDataset(
                "INDEPENDENT_PULSES requires exactly one series"
            )
        }
        let requiredRank = modelClassID == .positivePulseOnly ? 2 : 3
        for item in series where item.positiveWeightSampleCount < requiredRank {
            throw MorphologyGridError.invalidDataset(
                "\(item.genericSeriesID) lacks positive-weight rows for rank"
            )
        }
        guard candidatesPerWorkUnit > 0,
              candidatesPerWorkUnit
                <= MorphologyGridContract.maximumJSONSafeInteger else {
            throw MorphologyGridError.invalidDataset(
                "candidatesPerWorkUnit must be a positive JSON-safe integer"
            )
        }
        var totalSampleCount = 0
        for item in series {
            let (nextCount, overflow) = totalSampleCount
                .addingReportingOverflow(item.coordinates.count)
            guard !overflow,
                  nextCount <= MorphologyGridContract.maximumJSONSafeInteger else {
                throw MorphologyGridError.invalidDataset(
                    "total sample count exceeds the JSON-safe integer limit"
                )
            }
            totalSampleCount = nextCount
        }
        _ = try MorphologyGridIndexing.safeProduct(
            [totalSampleCount, try morphologyGrid.totalCandidateCount()],
            fieldName: "sample-candidate evaluation count"
        )
    }
}

nonisolated
struct MorphologyGridPayload: Sendable, Equatable {
    let morphologyFamilyID: String
    let modelClassID: MorphologyGridModelClass
    let gridStartIndex: Int
    let gridCount: Int

    init(_ value: JSONValue?) throws {
        guard let object = value?.objectValue else {
            throw MorphologyGridError.invalidWorkUnit(
                "payload must be an object"
            )
        }
        let expectedKeys: Set<String> = [
            "morphologyFamilyID",
            "modelClassID",
            "gridStartIndex",
            "gridCount",
        ]
        guard Set(object.keys) == expectedKeys else {
            throw MorphologyGridError.invalidWorkUnit(
                "payload fields do not match the published schema"
            )
        }
        guard let morphologyFamilyID =
                object["morphologyFamilyID"]?.stringValue,
              morphologyFamilyID
                == MorphologyGridContract.morphologyFamilyID else {
            throw MorphologyGridError.invalidWorkUnit(
                "morphology family ID does not match"
            )
        }
        guard let rawModelClassID = object["modelClassID"]?.stringValue,
              let modelClassID = MorphologyGridModelClass(
                rawValue: rawModelClassID
              ) else {
            throw MorphologyGridError.invalidWorkUnit(
                "modelClassID is invalid"
            )
        }
        guard let gridStartIndex = object["gridStartIndex"]?.intValue,
              gridStartIndex >= 0,
              gridStartIndex
                <= MorphologyGridContract.maximumJSONSafeInteger else {
            throw MorphologyGridError.invalidWorkUnit(
                "gridStartIndex must be a nonnegative JSON-safe integer"
            )
        }
        guard let gridCount = object["gridCount"]?.intValue,
              gridCount > 0,
              gridCount <= MorphologyGridContract.maximumJSONSafeInteger else {
            throw MorphologyGridError.invalidWorkUnit(
                "gridCount must be a positive JSON-safe integer"
            )
        }
        self.morphologyFamilyID = morphologyFamilyID
        self.modelClassID = modelClassID
        self.gridStartIndex = gridStartIndex
        self.gridCount = gridCount
    }

    func validate(in dataset: MorphologyGridDataset) throws {
        guard modelClassID == dataset.modelClassID else {
            throw MorphologyGridError.invalidWorkUnit(
                "model class does not match the dataset"
            )
        }
        let totalCount = try dataset.morphologyGrid.totalCandidateCount()
        guard gridStartIndex < totalCount,
              gridCount <= totalCount - gridStartIndex else {
            throw MorphologyGridError.invalidWorkUnit(
                "shard is outside the flattened grid"
            )
        }
    }
}

nonisolated
enum MorphologyGridIndexing {
    static func safeProduct(
        _ values: [Int],
        fieldName: String
    ) throws -> Int {
        var product = 1
        for value in values {
            guard value >= 0 else {
                throw MorphologyGridError.invalidDataset(
                    "\(fieldName) contains an invalid count"
                )
            }
            if value != 0,
               product > MorphologyGridContract.maximumJSONSafeInteger / value {
                throw MorphologyGridError.invalidDataset(
                    "\(fieldName) exceeds the JSON-safe integer limit"
                )
            }
            product *= value
        }
        return product
    }

    static func independentCenterPairCount(centerCount: Int) throws -> Int {
        guard centerCount >= 2 else {
            throw MorphologyGridError.invalidGridIndex(
                "center count must be at least two"
            )
        }
        let maximum = MorphologyGridContract.maximumJSONSafeInteger
        guard centerCount <= maximum,
              centerCount <= maximum / (centerCount - 1) else {
            throw MorphologyGridError.invalidGridIndex(
                "center pair count exceeds the JSON-safe integer limit"
            )
        }
        let pairCount = centerCount * (centerCount - 1) / 2
        guard pairCount <= maximum else {
            throw MorphologyGridError.invalidGridIndex(
                "center pair count exceeds the JSON-safe integer limit"
            )
        }
        return pairCount
    }

    static func independentCenterPairIndex(
        centerCount: Int,
        negativeCenterIndex: Int,
        positiveCenterIndex: Int
    ) throws -> Int {
        _ = try independentCenterPairCount(centerCount: centerCount)
        guard negativeCenterIndex >= 0,
              positiveCenterIndex < centerCount,
              negativeCenterIndex < positiveCenterIndex else {
            throw MorphologyGridError.invalidGridIndex(
                "center indices must satisfy 0 <= negative < positive < count"
            )
        }
        return negativeCenterIndex
            * (2 * centerCount - negativeCenterIndex - 1) / 2
            + positiveCenterIndex - negativeCenterIndex - 1
    }

    static func independentCenterPairIndices(
        centerCount: Int,
        pairIndex: Int
    ) throws -> (negative: Int, positive: Int) {
        let pairCount = try independentCenterPairCount(
            centerCount: centerCount
        )
        guard pairIndex >= 0, pairIndex < pairCount else {
            throw MorphologyGridError.invalidGridIndex(
                "center pair index is outside the configured axis"
            )
        }
        var low = 0
        var high = centerCount - 2
        while low <= high {
            let middle = (low + high) / 2
            let rowStart = middle * (2 * centerCount - middle - 1) / 2
            let nextStart: Int
            if middle + 1 < centerCount - 1 {
                nextStart = (middle + 1)
                    * (2 * centerCount - middle - 2) / 2
            } else {
                nextStart = pairCount
            }
            if pairIndex < rowStart {
                high = middle - 1
            } else if pairIndex >= nextStart {
                low = middle + 1
            } else {
                return (
                    negative: middle,
                    positive: middle + 1 + pairIndex - rowStart
                )
            }
        }
        throw MorphologyGridError.invalidGridIndex(
            "center pair index could not be inverted"
        )
    }

    static func candidateIndex(
        indices: [Int],
        counts: [Int]
    ) throws -> Int {
        guard indices.count == counts.count, !counts.isEmpty else {
            throw MorphologyGridError.invalidGridIndex(
                "indices and counts must have equal nonzero length"
            )
        }
        _ = try checkedCounts(counts)
        var result = 0
        for (index, count) in zip(indices, counts) {
            guard index >= 0, index < count else {
                throw MorphologyGridError.invalidGridIndex(
                    "candidate index is outside its axis"
                )
            }
            let maximum = MorphologyGridContract.maximumJSONSafeInteger
            guard result <= (maximum - index) / count else {
                throw MorphologyGridError.invalidGridIndex(
                    "mixed-radix index exceeds the JSON-safe integer limit"
                )
            }
            result = result * count + index
        }
        return result
    }

    static func candidateIndices(
        index: Int,
        counts: [Int]
    ) throws -> [Int] {
        let total = try checkedCounts(counts)
        guard index >= 0, index < total else {
            throw MorphologyGridError.invalidGridIndex(
                "mixed-radix index is outside the configured grid"
            )
        }
        var remaining = index
        var reversedIndices: [Int] = []
        reversedIndices.reserveCapacity(counts.count)
        for count in counts.reversed() {
            reversedIndices.append(remaining % count)
            remaining /= count
        }
        return Array(reversedIndices.reversed())
    }

    private static func checkedCounts(_ counts: [Int]) throws -> Int {
        guard !counts.isEmpty else {
            throw MorphologyGridError.invalidGridIndex(
                "counts must be nonempty"
            )
        }
        var total = 1
        for count in counts {
            guard count > 0,
                  count <= MorphologyGridContract.maximumJSONSafeInteger else {
                throw MorphologyGridError.invalidGridIndex(
                    "axis count is invalid"
                )
            }
            guard total
                    <= MorphologyGridContract.maximumJSONSafeInteger / count else {
                throw MorphologyGridError.invalidGridIndex(
                    "mixed-radix count exceeds the JSON-safe integer limit"
                )
            }
            total *= count
        }
        return total
    }
}

private struct MorphologyGridCodingKey: CodingKey {
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
private func morphologyGridRequireExactKeys(
    _ container: KeyedDecodingContainer<MorphologyGridCodingKey>,
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

extension MorphologyGridAxis {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: MorphologyGridCodingKey.self
        )
        let keys = Set(container.allKeys.map(\.stringValue))
        if keys == ["start", "step", "count"] {
            start = try container.decode(
                Double.self,
                forKey: MorphologyGridCodingKey("start")
            )
            step = try container.decode(
                Double.self,
                forKey: MorphologyGridCodingKey("step")
            )
            count = try container.decode(
                Int.self,
                forKey: MorphologyGridCodingKey("count")
            )
            explicitValues = nil
        } else if keys == ["values"] {
            let values = try container.decode(
                [Double].self,
                forKey: MorphologyGridCodingKey("values")
            )
            start = nil
            step = nil
            count = values.count
            explicitValues = values
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription:
                        "Axis fields do not match the published schema."
                )
            )
        }
    }
}

extension MorphologyGridSeries {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: MorphologyGridCodingKey.self
        )
        try morphologyGridRequireExactKeys(container, [
            "genericSeriesID",
            "coordinates",
            "values",
            "inverseVariances",
        ])
        genericSeriesID = try container.decode(
            String.self,
            forKey: MorphologyGridCodingKey("genericSeriesID")
        )
        coordinates = try container.decode(
            [Double].self,
            forKey: MorphologyGridCodingKey("coordinates")
        )
        values = try container.decode(
            [Double].self,
            forKey: MorphologyGridCodingKey("values")
        )
        inverseVariances = try container.decode(
            [Double].self,
            forKey: MorphologyGridCodingKey("inverseVariances")
        )
    }
}

extension MorphologyGridDefinition {
    nonisolated init(from decoder: Decoder, modelClassID: MorphologyGridModelClass) throws {
        let container = try decoder.container(
            keyedBy: MorphologyGridCodingKey.self
        )
        self.modelClassID = modelClassID
        let axisNames: [String]
        switch modelClassID {
        case .positivePulseOnly:
            axisNames = ["centerAxis", "logScaleAxis", "logShapeAxis"]
        case .orderedNegativePositiveDoublet:
            axisNames = [
                "negativeCenterAxis",
                "separationAxis",
                "negativeLogScaleAxis",
                "negativeLogShapeAxis",
                "positiveLogScaleAxis",
                "positiveLogShapeAxis",
            ]
        case .independentPulses:
            axisNames = [
                "centerAxis",
                "negativeLogScaleAxis",
                "negativeLogShapeAxis",
                "positiveLogScaleAxis",
                "positiveLogShapeAxis",
            ]
        }
        try morphologyGridRequireExactKeys(container, Set(axisNames))
        axes = try axisNames.map { name in
            try container.decode(
                MorphologyGridAxis.self,
                forKey: MorphologyGridCodingKey(name)
            )
        }
    }
}

extension MorphologyGridDataset {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: MorphologyGridCodingKey.self
        )
        id = try container.decode(
            String.self,
            forKey: MorphologyGridCodingKey("id")
        )
        datasetSchemaID = try container.decode(
            String.self,
            forKey: MorphologyGridCodingKey("datasetSchemaID")
        )
        morphologyFamilyID = try container.decode(
            String.self,
            forKey: MorphologyGridCodingKey("morphologyFamilyID")
        )
        componentTemplateFamilyID = try container.decode(
            String.self,
            forKey: MorphologyGridCodingKey("componentTemplateFamilyID")
        )
        modelClassID = try container.decode(
            MorphologyGridModelClass.self,
            forKey: MorphologyGridCodingKey("modelClassID")
        )
        series = try container.decode(
            [MorphologyGridSeries].self,
            forKey: MorphologyGridCodingKey("series")
        )
        let gridDecoder = try container.superDecoder(
            forKey: MorphologyGridCodingKey("morphologyGrid")
        )
        morphologyGrid = try MorphologyGridDefinition(
            from: gridDecoder,
            modelClassID: modelClassID
        )
        candidatesPerWorkUnit = try container.decode(
            Int.self,
            forKey: MorphologyGridCodingKey("candidatesPerWorkUnit")
        )
        executionContractID = try container.decode(
            String.self,
            forKey: MorphologyGridCodingKey("executionContractID")
        )
        executionContractVersion = try container.decode(
            String.self,
            forKey: MorphologyGridCodingKey("executionContractVersion")
        )
    }
}

nonisolated
protocol MorphologyGridDatasetDecoding: Sendable {
    func decode(_ data: Data) throws -> MorphologyGridDataset
}

nonisolated
struct MorphologyGridJSONDatasetDecoder: MorphologyGridDatasetDecoding {
    func decode(_ data: Data) throws -> MorphologyGridDataset {
        do {
            let dataset = try JSONDecoder().decode(
                MorphologyGridDataset.self,
                from: data
            )
            try dataset.validate()
            return dataset
        } catch let error as MorphologyGridError {
            throw error
        } catch {
            throw MorphologyGridError.invalidDataset(error.localizedDescription)
        }
    }
}
