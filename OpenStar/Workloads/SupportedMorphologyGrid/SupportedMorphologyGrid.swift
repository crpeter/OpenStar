import Foundation

nonisolated
enum SupportedMorphologyGridContract {
    static let workloadID = "openstar.supported-morphology-grid.v1"
    static let datasetSchemaID = "openstar.dataset.supported-morphology-grid.v1"
    static let payloadSchemaID = "openstar.payload.supported-morphology-grid-shard.v1"
    static let resultSchemaID = "openstar.result.supported-morphology-grid-shard.v1"
    static let executionContractID = "openstar.supported-morphology-grid-execution.v1"
    static let executionContractVersion = "1.0"
    static let validatorID = "openstar.supported-morphology-grid.local-double.v1"
    static let supportPolicyID = "openstar.morphology-support.two-effective-widths.v1"
    static let morphologyFamilyID = MorphologyGridContract.morphologyFamilyID
    static let componentTemplateFamilyID = MorphologyGridContract.componentTemplateFamilyID
}

nonisolated
struct SupportedMorphologyGridDataset: Decodable, Sendable {
    fileprivate let numericalView: MorphologyGridDataset

    var id: String { numericalView.id }
    var modelClassID: MorphologyGridModelClass { numericalView.modelClassID }

    init(from decoder: Decoder) throws {
        numericalView = try SupportedMorphologyGridNumericalAdapter.decodeDataset(from: decoder)
    }
}

nonisolated
protocol SupportedMorphologyGridDatasetDecoding: Sendable {
    func decode(_ data: Data) throws -> SupportedMorphologyGridDataset
}

nonisolated
struct SupportedMorphologyGridJSONDatasetDecoder: SupportedMorphologyGridDatasetDecoding {
    func decode(_ data: Data) throws -> SupportedMorphologyGridDataset {
        do {
            return try JSONDecoder().decode(SupportedMorphologyGridDataset.self, from: data)
        } catch let error as MorphologyGridError {
            throw error
        } catch {
            throw MorphologyGridError.invalidDataset(error.localizedDescription)
        }
    }
}

nonisolated
struct SupportedMorphologyGridPayload: Sendable {
    fileprivate let numericalView: MorphologyGridPayload

    var gridStartIndex: Int { numericalView.gridStartIndex }
    var gridCount: Int { numericalView.gridCount }

    init(_ value: JSONValue?) throws {
        numericalView = try SupportedMorphologyGridNumericalAdapter.decodePayload(value)
    }
}

nonisolated
struct SupportedMorphologyGridSearchResult: Sendable, Equatable {
    let bestCandidate: MorphologyGridCandidate?
    let evaluatedCandidateCount: Int
    let invalidCandidateCount: Int
    let supportRejectedCandidateCount: Int
}

nonisolated
enum SupportedMorphologyGridEvaluator {
    static func search(
        dataset: SupportedMorphologyGridDataset,
        payload: SupportedMorphologyGridPayload
    ) throws -> SupportedMorphologyGridSearchResult {
        let numericalDataset = dataset.numericalView
        try payload.numericalView.validate(in: numericalDataset)
        var bestCandidate: MorphologyGridCandidate?
        var invalidCandidateCount = 0
        var supportRejectedCandidateCount = 0

        for localIndex in 0..<payload.gridCount {
            // Check before every candidate, including candidates rejected by either rule.
            if Task.isCancelled { throw WorkloadCancellation() }
            let (gridIndex, overflow) = payload.gridStartIndex.addingReportingOverflow(localIndex)
            guard !overflow else {
                throw MorphologyGridError.invalidWorkUnit("shard index overflows")
            }
            guard let candidate = try SupportedMorphologyGridNumericalAdapter.evaluate(
                dataset: numericalDataset, gridIndex: gridIndex
            ) else {
                invalidCandidateCount += 1
                continue
            }
            guard try SupportedMorphologyGridSupport.isSupported(
                parameters: candidate.parameters, series: numericalDataset.series
            ) else {
                supportRejectedCandidateCount += 1
                continue
            }
            if let current = bestCandidate {
                if SupportedMorphologyGridNumericalAdapter.precedes(candidate, current) {
                    bestCandidate = candidate
                }
            } else {
                bestCandidate = candidate
            }
        }
        if Task.isCancelled { throw WorkloadCancellation() }
        return SupportedMorphologyGridSearchResult(
            bestCandidate: bestCandidate,
            evaluatedCandidateCount: payload.gridCount,
            invalidCandidateCount: invalidCandidateCount,
            supportRejectedCandidateCount: supportRejectedCandidateCount
        )
    }
}

nonisolated
enum SupportedMorphologyGridSupport {
    static func isSupported(
        parameters: MorphologyGridParameters,
        series: [MorphologyGridSeries]
    ) throws -> Bool {
        guard let geometries = parameters.geometries else { return false }
        for geometry in geometries {
            let scale = exp(geometry.logScale)
            let shape = exp(geometry.logShape)
            let effectiveWidth = scale * shape
            let radius = 2.0 * effectiveWidth
            guard geometry.center.isFinite,
                  scale.isFinite, scale > 0,
                  shape.isFinite, shape > 0,
                  effectiveWidth.isFinite, effectiveWidth > 0,
                  radius.isFinite, radius > 0 else { return false }

            // INDEPENDENT_PULSES datasets are validated to contain exactly one series.
            for item in series {
                if Task.isCancelled { throw WorkloadCancellation() }
                var supported = false
                for index in item.coordinates.indices {
                    if (index & 1023) == 0, Task.isCancelled { throw WorkloadCancellation() }
                    if item.inverseVariances[index] > 0,
                       abs(item.coordinates[index] - geometry.center) <= radius {
                        supported = true
                        break
                    }
                }
                if !supported { return false }
            }
        }
        return true
    }
}

// This is the only bridge to v1 numerical views. Public identities are checked
// before creating those views; neither handler accepts the other's work units.
nonisolated
private enum SupportedMorphologyGridNumericalAdapter {
    private enum IdentityKey: String, CodingKey {
        case datasetSchemaID, morphologyFamilyID, componentTemplateFamilyID
        case executionContractID, executionContractVersion, supportPolicyID
        case workloadID, payloadSchemaID, resultSchemaID
    }

    static func decodeDataset(from decoder: Decoder) throws -> MorphologyGridDataset {
        let identities = try decoder.container(keyedBy: IdentityKey.self)
        let required: [(IdentityKey, String)] = [
            (.datasetSchemaID, SupportedMorphologyGridContract.datasetSchemaID),
            (.morphologyFamilyID, SupportedMorphologyGridContract.morphologyFamilyID),
            (.componentTemplateFamilyID, SupportedMorphologyGridContract.componentTemplateFamilyID),
            (.executionContractID, SupportedMorphologyGridContract.executionContractID),
            (.executionContractVersion, SupportedMorphologyGridContract.executionContractVersion),
            (.supportPolicyID, SupportedMorphologyGridContract.supportPolicyID),
        ]
        for (key, expected) in required {
            guard try identities.decode(String.self, forKey: key) == expected else {
                throw MorphologyGridError.invalidDataset("\(key.rawValue) is invalid")
            }
        }
        let optional: [(IdentityKey, String)] = [
            (.workloadID, SupportedMorphologyGridContract.workloadID),
            (.payloadSchemaID, SupportedMorphologyGridContract.payloadSchemaID),
            (.resultSchemaID, SupportedMorphologyGridContract.resultSchemaID),
        ]
        for (key, expected) in optional where identities.contains(key) {
            guard try identities.decode(String.self, forKey: key) == expected else {
                throw MorphologyGridError.invalidDataset("\(key.rawValue) is invalid")
            }
        }
        // Reuse strict nested decoding and top-level extensibility without a JSON
        // round trip, which could change integer or floating-point representation.
        let decoded = try MorphologyGridDataset(from: decoder)
        let numericalView = MorphologyGridDataset(
            id: decoded.id,
            datasetSchemaID: MorphologyGridContract.datasetSchemaID,
            morphologyFamilyID: decoded.morphologyFamilyID,
            componentTemplateFamilyID: decoded.componentTemplateFamilyID,
            modelClassID: decoded.modelClassID,
            series: decoded.series,
            morphologyGrid: decoded.morphologyGrid,
            candidatesPerWorkUnit: decoded.candidatesPerWorkUnit,
            executionContractID: MorphologyGridContract.executionContractID,
            executionContractVersion: decoded.executionContractVersion
        )
        try numericalView.validate()
        return numericalView
    }

    static func decodePayload(_ value: JSONValue?) throws -> MorphologyGridPayload {
        guard var object = value?.objectValue,
              Set(object.keys) == [
                "morphologyFamilyID", "modelClassID", "supportPolicyID",
                "gridStartIndex", "gridCount",
              ] else {
            throw MorphologyGridError.invalidWorkUnit("payload fields do not match the published schema")
        }
        guard object["supportPolicyID"]?.stringValue == SupportedMorphologyGridContract.supportPolicyID else {
            throw MorphologyGridError.invalidWorkUnit("supportPolicyID is invalid")
        }
        object.removeValue(forKey: "supportPolicyID")
        return try MorphologyGridPayload(.object(object))
    }

    static func evaluate(dataset: MorphologyGridDataset, gridIndex: Int) throws -> MorphologyGridCandidate? {
        try MorphologyGridEvaluator.evaluateCandidate(dataset: dataset, gridIndex: gridIndex)
    }

    static func precedes(_ left: MorphologyGridCandidate, _ right: MorphologyGridCandidate) -> Bool {
        MorphologyGridEvaluator.candidatePrecedes(left, right)
    }
}
