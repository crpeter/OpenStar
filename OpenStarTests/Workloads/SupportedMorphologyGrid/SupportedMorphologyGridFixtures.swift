import Foundation
@testable import OpenStar

nonisolated
enum SupportedMorphologyGridFixture {
    static let models: [MorphologyGridModelClass] = [
        .positivePulseOnly, .orderedNegativePositiveDoublet, .independentPulses,
    ]

    static func axis(_ start: Double = 0, step: Double = 1, count: Int = 1) -> [String: Any] {
        ["start": start, "step": step, "count": count]
    }

    // Independent expression of the frozen basis for small portable fixtures.
    static func basis(_ coordinate: Double, center: Double) -> Double {
        let z = coordinate - center
        let uSquared = 1.0 + z * z
        return (uSquared + 2.0) / (sqrt(uSquared) * sqrt(uSquared + 4.0))
    }

    static func series(
        _ coordinates: [Double], id: String = "series-001",
        positiveCenter: Double = 4, negativeCenter: Double? = nil,
        weights: [Double]? = nil
    ) -> [String: Any] {
        let values = coordinates.map { coordinate in
            var value = 0.75
            if let negativeCenter { value += -1.5 * basis(coordinate, center: negativeCenter) }
            value += 2.5 * basis(coordinate, center: positiveCenter)
            return value
        }
        return [
            "genericSeriesID": id, "coordinates": coordinates, "values": values,
            "inverseVariances": weights ?? Array(repeating: 1.0, count: coordinates.count),
        ]
    }

    static func object(
        model: MorphologyGridModelClass = .positivePulseOnly,
        coordinates: [Double] = [3, 4, 5, 6, 7, 8, 9, 10],
        positiveCenter: Double = 4, negativeCenter: Double = 0,
        mixedValidity: Bool = false
    ) -> [String: Any] {
        let grid: [String: Any]
        switch model {
        case .positivePulseOnly:
            grid = [
                "centerAxis": axis(0, step: 4, count: 2),
                "logScaleAxis": mixedValidity ? axis(-700, step: 700, count: 2) : axis(),
                "logShapeAxis": ["values": [0.0]],
            ]
        case .orderedNegativePositiveDoublet:
            grid = [
                "negativeCenterAxis": axis(), "separationAxis": axis(4, step: 4, count: 2),
                "negativeLogScaleAxis": axis(), "negativeLogShapeAxis": ["values": [0.0]],
                "positiveLogScaleAxis": axis(), "positiveLogShapeAxis": ["values": [0.0]],
            ]
        case .independentPulses:
            grid = [
                "centerAxis": axis(0, step: 4, count: 3),
                "negativeLogScaleAxis": axis(), "negativeLogShapeAxis": ["values": [0.0]],
                "positiveLogScaleAxis": axis(), "positiveLogShapeAxis": ["values": [0.0]],
            ]
        }
        return [
            "id": "generic-supported-grid",
            "datasetSchemaID": "openstar.dataset.supported-morphology-grid.v1",
            "morphologyFamilyID": "openstar.microlensing-residual-morphology.v1",
            "componentTemplateFamilyID": "openstar.curve-family.symmetric-radial-amplification.v1",
            "executionContractID": "openstar.supported-morphology-grid-execution.v1",
            "executionContractVersion": "1.0",
            "supportPolicyID": "openstar.morphology-support.two-effective-widths.v1",
            "modelClassID": model.rawValue, "morphologyGrid": grid,
            "candidatesPerWorkUnit": mixedValidity ? 4 : (model == .independentPulses ? 3 : 2),
            "series": [series(coordinates, positiveCenter: positiveCenter,
                              negativeCenter: model == .positivePulseOnly ? nil : negativeCenter)],
        ]
    }

    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode(_ object: [String: Any]) throws -> SupportedMorphologyGridDataset {
        try SupportedMorphologyGridJSONDatasetDecoder().decode(data(object))
    }

    static func payload(
        model: MorphologyGridModelClass = .positivePulseOnly, start: Int = 0, count: Int = 2
    ) -> JSONValue {
        .object([
            "morphologyFamilyID": .string("openstar.microlensing-residual-morphology.v1"),
            "modelClassID": .string(model.rawValue),
            "supportPolicyID": .string("openstar.morphology-support.two-effective-widths.v1"),
            "gridStartIndex": .number(Double(start)), "gridCount": .number(Double(count)),
        ])
    }

    static func unit(
        model: MorphologyGridModelClass = .positivePulseOnly, start: Int = 0, count: Int = 2,
        workloadID: String = "openstar.supported-morphology-grid.v1",
        datasetSchemaID: String? = "openstar.dataset.supported-morphology-grid.v1",
        payloadSchemaID: String? = "openstar.payload.supported-morphology-grid-shard.v1",
        resultSchemaID: String? = "openstar.result.supported-morphology-grid-shard.v1",
        datasetID: String? = "generic-supported-grid", payload: JSONValue? = nil
    ) -> WorkUnit {
        WorkUnit(
            id: UUID(), projectID: "generic-grid-project", workloadID: workloadID,
            datasetSchemaID: datasetSchemaID, payloadSchemaID: payloadSchemaID,
            resultSchemaID: resultSchemaID, datasetID: datasetID,
            payload: payload ?? self.payload(model: model, start: start, count: count)
        )
    }

    static func search(
        _ object: [String: Any], model: MorphologyGridModelClass = .positivePulseOnly,
        start: Int = 0, count: Int = 2
    ) throws -> SupportedMorphologyGridSearchResult {
        try SupportedMorphologyGridEvaluator.search(
            dataset: decode(object),
            payload: SupportedMorphologyGridPayload(payload(model: model, start: start, count: count))
        )
    }

    static func numericalDataset(_ object: [String: Any]) throws -> MorphologyGridDataset {
        var numerical = object
        numerical["datasetSchemaID"] = MorphologyGridContract.datasetSchemaID
        numerical["executionContractID"] = MorphologyGridContract.executionContractID
        numerical.removeValue(forKey: "supportPolicyID")
        return try MorphologyGridJSONDatasetDecoder().decode(data(numerical))
    }
}
