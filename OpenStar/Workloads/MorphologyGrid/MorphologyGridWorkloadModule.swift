import Foundation

nonisolated
final class MorphologyGridWorkloadHandler:
    OpenStarBatchWorkloadHandler, @unchecked Sendable
{
    static let workloadID = MorphologyGridContract.workloadID
    static let datasetSchemaID = MorphologyGridContract.datasetSchemaID
    static let payloadSchemaID = MorphologyGridContract.payloadSchemaID
    static let resultSchemaID = MorphologyGridContract.resultSchemaID
    static let morphologyFamilyID =
        MorphologyGridContract.morphologyFamilyID
    static let componentTemplateFamilyID =
        MorphologyGridContract.componentTemplateFamilyID
    static let executionContractID =
        MorphologyGridContract.executionContractID
    static let executionContractVersion =
        MorphologyGridContract.executionContractVersion
    static let validatorID = MorphologyGridContract.validatorID

    let workloadIDs = [MorphologyGridContract.workloadID]
    let capabilities = [WorkloadCapability(
        workloadID: MorphologyGridContract.workloadID,
        executionBackends: [.cpu],
        validatorID: MorphologyGridContract.validatorID,
        datasetSchemaID: MorphologyGridContract.datasetSchemaID,
        payloadSchemaID: MorphologyGridContract.payloadSchemaID,
        resultSchemaID: MorphologyGridContract.resultSchemaID
    )]
    let desiredBatchCount = 8

    private let datasetDecoder: any MorphologyGridDatasetDecoding

    init(
        datasetDecoder: any MorphologyGridDatasetDecoding =
            MorphologyGridJSONDatasetDecoder()
    ) {
        self.datasetDecoder = datasetDecoder
    }

    func execute(
        workUnit: WorkUnit,
        datasetData: Data?
    ) async throws -> WorkloadExecution {
        guard let datasetData else {
            throw MorphologyGridError.missingDataset
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
                    result: .failure(MorphologyGridError.missingDataset)
                )
            }
        }

        let dataset: MorphologyGridDataset
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
        dataset: MorphologyGridDataset
    ) throws -> WorkloadExecution {
        try validate(workUnit: workUnit, dataset: dataset)
        let payload = try MorphologyGridPayload(workUnit.payload)
        let started = Date()
        let result = try MorphologyGridEvaluator.search(
            dataset: dataset,
            payload: payload
        )
        let duration = Date().timeIntervalSince(started)
        let bestCandidate = try result.bestCandidate?.jsonValue(
            modelClassID: dataset.modelClassID
        ) ?? .null
        let summaryFields: [WorkloadResultField]
        if let best = result.bestCandidate {
            summaryFields = [
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
        } else {
            summaryFields = [WorkloadResultField(
                id: "validCandidateCount",
                label: "Valid candidates",
                value: "0"
            )]
        }
        return WorkloadExecution(
            duration: duration,
            payload: .object([
                "morphologyFamilyID": .string(
                    MorphologyGridContract.morphologyFamilyID
                ),
                "modelClassID": .string(dataset.modelClassID.rawValue),
                "gridStartIndex": try MorphologyGridResultEncoding
                    .jsonSafeNumber(payload.gridStartIndex),
                "gridCount": try MorphologyGridResultEncoding
                    .jsonSafeNumber(payload.gridCount),
                "bestCandidate": bestCandidate,
                "evaluatedCandidateCount": try MorphologyGridResultEncoding
                    .jsonSafeNumber(result.evaluatedCandidateCount),
                "invalidCandidateCount": try MorphologyGridResultEncoding
                    .jsonSafeNumber(result.invalidCandidateCount),
            ]),
            summary: WorkloadResultSummary(
                title: "Morphology-grid search",
                fields: summaryFields
            ),
            legacyResultFields: .none
        )
    }

    private func validate(
        workUnit: WorkUnit,
        dataset: MorphologyGridDataset
    ) throws {
        guard workUnit.workloadID == MorphologyGridContract.workloadID else {
            throw MorphologyGridError.invalidWorkUnit(
                "workload ID does not match"
            )
        }
        guard workUnit.datasetSchemaID
                == MorphologyGridContract.datasetSchemaID else {
            throw MorphologyGridError.invalidWorkUnit(
                "dataset schema ID does not match"
            )
        }
        guard workUnit.payloadSchemaID
                == MorphologyGridContract.payloadSchemaID else {
            throw MorphologyGridError.invalidWorkUnit(
                "payload schema ID does not match"
            )
        }
        guard workUnit.resultSchemaID
                == MorphologyGridContract.resultSchemaID else {
            throw MorphologyGridError.invalidWorkUnit(
                "result schema ID does not match"
            )
        }
        guard workUnit.datasetID == dataset.id else {
            throw MorphologyGridError.invalidWorkUnit(
                "dataset ID does not match"
            )
        }
    }
}

nonisolated
enum MorphologyGridWorkloadModule {
    static func handlers() throws -> [any OpenStarWorkloadHandler] {
        [MorphologyGridWorkloadHandler()]
    }
}
