//
//  TESSPeriodSearchWorker.swift
//  OpenStar
//
//  Domain/workload plugin for Lomb-Scargle period-search work.
//  OpenStar Core routes this workload but does not understand its payload.
//

import Foundation
import Metal

nonisolated
struct TESSPeriodSearchDataset: Codable, Sendable {
    let id: String
    let targetName: String?
    let mission: String?
    let timeUnit: String?
    let fluxUnit: String?
    let times: [Float]
    let flux: [Float]
}

nonisolated
struct LombScargleWorkPayload: Sendable {
    let frequencyStartIndex: Int
    let startFrequency: Float
    let frequencyStep: Float
    let frequencyCount: Int
}

nonisolated
enum PeriodSearchError: LocalizedError {
    case metalUnavailable
    case commandQueueUnavailable
    case libraryUnavailable
    case functionUnavailable
    case pipelineCreationFailed(Error)
    case missingDataset
    case invalidDataset
    case invalidWorkUnit(String)
    case bufferAllocationFailed
    case commandBufferUnavailable
    case encoderUnavailable
    case commandFailed(Error?)
    case noFiniteResult
    case validationFailed(TESSPeriodSearchValidation)

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "Metal is unavailable."

        case .commandQueueUnavailable:
            return "Could not create Metal command queue."

        case .libraryUnavailable:
            return "Could not load Metal shader library."

        case .functionUnavailable:
            return "Could not find openStarLombScargle."

        case .pipelineCreationFailed(let error):
            return "Could not create Metal pipeline: \(error.localizedDescription)"

        case .missingDataset:
            return "The Lomb-Scargle workload requires a dataset."

        case .invalidDataset:
            return "The Lomb-Scargle dataset is invalid."

        case .invalidWorkUnit(let message):
            return "The Lomb-Scargle work unit is invalid: \(message)"

        case .bufferAllocationFailed:
            return "Could not allocate Metal buffers."

        case .commandBufferUnavailable:
            return "Could not create Metal command buffer."

        case .encoderUnavailable:
            return "Could not create Metal compute encoder."

        case .commandFailed(let error):
            return error?.localizedDescription ?? "Metal command failed."

        case .noFiniteResult:
            return "The period search produced no finite result."

        case .validationFailed(let validation):
            return validation.reason
        }
    }
}

nonisolated
final class TESSPeriodSearchWorker: OpenStarWorkloadHandler, @unchecked Sendable {
    // New domain-neutral workload name plus the existing project ID as a
    // compatibility alias. Both route to the same implementation.
    static let workloadID = "openstar.lomb-scargle.v1"
    static let legacyWorkloadID = "openstar.tess-period-search.v1"

    let workloadIDs = [
        TESSPeriodSearchWorker.workloadID,
        TESSPeriodSearchWorker.legacyWorkloadID
    ]

    let capabilities = [
        WorkloadCapability(
            workloadID: TESSPeriodSearchWorker.workloadID,
            executionBackends: [.metal],
            validatorID: TESSPeriodSearchValidation.validatorID
        ),
        WorkloadCapability(
            workloadID: TESSPeriodSearchWorker.legacyWorkloadID,
            executionBackends: [.metal],
            validatorID: TESSPeriodSearchValidation.validatorID
        )
    ]

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PeriodSearchError.metalUnavailable
        }

        guard let commandQueue = device.makeCommandQueue() else {
            throw PeriodSearchError.commandQueueUnavailable
        }

        guard let library = device.makeDefaultLibrary() else {
            throw PeriodSearchError.libraryUnavailable
        }

        guard let function = library.makeFunction(
            name: "openStarLombScargle"
        ) else {
            throw PeriodSearchError.functionUnavailable
        }

        do {
            pipeline = try device.makeComputePipelineState(
                function: function
            )
        } catch {
            throw PeriodSearchError.pipelineCreationFailed(error)
        }

        self.device = device
        self.commandQueue = commandQueue
    }

    @concurrent
    func execute(
        workUnit: WorkUnit,
        datasetData: Data?
    ) async throws -> WorkloadExecution {
        try Task.checkCancellation()

        guard let datasetData else {
            throw PeriodSearchError.missingDataset
        }

        let dataset = try JSONDecoder().decode(
            TESSPeriodSearchDataset.self,
            from: datasetData
        )

        let payload = try workPayload(
            from: workUnit
        )

        let totalStarted = ProcessInfo.processInfo.systemUptime

        let metalResult = try runMetalSynchronously(
            payload: payload,
            dataset: dataset
        )

        try Task.checkCancellation()

        let validationStarted = ProcessInfo.processInfo.systemUptime

        let validation = try TESSPeriodSearchCPUValidator.validate(
            times: dataset.times,
            flux: dataset.flux,
            metalBestIndex: metalResult.bestIndex,
            metalBestPower: metalResult.bestPower,
            startFrequency: payload.startFrequency,
            frequencyStep: payload.frequencyStep,
            frequencyCount: payload.frequencyCount
        )

        let validationDuration =
            ProcessInfo.processInfo.systemUptime - validationStarted

        guard validation.passed else {
            throw PeriodSearchError.validationFailed(
                validation
            )
        }

        let totalDuration =
            ProcessInfo.processInfo.systemUptime - totalStarted

        let resultPayload: JSONValue = .object([
            "bestFrequency": .number(metalResult.bestFrequency),
            "bestPeriodDays": .number(metalResult.bestPeriodDays),
            "bestPower": .number(metalResult.bestPower),
            "bestFrequencyIndex": .number(Double(metalResult.bestIndex)),
            "metalDurationSeconds": .number(metalResult.metalDuration),
            "validation": .object([
                "validatorID": .string(
                    TESSPeriodSearchValidation.validatorID
                ),
                "passed": .bool(true),
                "cpuBestLocalIndex": .number(
                    Double(validation.cpuBestLocalIndex)
                ),
                "cpuPowerAtMetalWinner": .number(
                    validation.cpuPowerAtMetalWinner
                ),
                "absolutePowerError": .number(
                    validation.absolutePowerError
                ),
                "allowedPowerError": .number(
                    validation.allowedPowerError
                ),
                "durationSeconds": .number(validationDuration)
            ])
        ])

        return WorkloadExecution(
            duration: totalDuration,
            payload: resultPayload,
            summary: WorkloadResultSummary(
                title: "Lomb-Scargle Result",
                fields: [
                    WorkloadResultField(
                        id: "period",
                        label: "Period",
                        value: String(
                            format: "%.6f days",
                            metalResult.bestPeriodDays
                        )
                    ),
                    WorkloadResultField(
                        id: "frequency",
                        label: "Frequency",
                        value: String(
                            format: "%.6f cycles/day",
                            metalResult.bestFrequency
                        )
                    ),
                    WorkloadResultField(
                        id: "power",
                        label: "Power",
                        value: String(
                            format: "%.6f",
                            metalResult.bestPower
                        )
                    ),
                    WorkloadResultField(
                        id: "validator",
                        label: "Local Validation",
                        value: "Passed"
                    )
                ]
            ),
            legacyResultFields: LegacyResultFields(
                bestFrequency: metalResult.bestFrequency,
                bestPeriodDays: metalResult.bestPeriodDays,
                bestPower: metalResult.bestPower
            )
        )
    }

    private func workPayload(
        from workUnit: WorkUnit
    ) throws -> LombScargleWorkPayload {
        if let payloadObject = workUnit.payload?.objectValue {
            guard let startFrequency = payloadObject["startFrequency"]?.doubleValue,
                  let frequencyStep = payloadObject["frequencyStep"]?.doubleValue,
                  let frequencyCount = payloadObject["frequencyCount"]?.intValue else {
                throw PeriodSearchError.invalidWorkUnit(
                    "generic payload is missing startFrequency, frequencyStep, or frequencyCount"
                )
            }

            let startIndex =
                payloadObject["frequencyStartIndex"]?.intValue ?? 0

            return try validatedPayload(
                frequencyStartIndex: startIndex,
                startFrequency: startFrequency,
                frequencyStep: frequencyStep,
                frequencyCount: frequencyCount
            )
        }

        // v18 compatibility path. This goes away after all coordinators emit
        // workload parameters only inside WorkUnit.payload.
        guard let startFrequency = workUnit.startFrequency,
              let frequencyStep = workUnit.frequencyStep,
              let frequencyCount = workUnit.frequencyCount else {
            throw PeriodSearchError.invalidWorkUnit(
                "no generic payload or legacy frequency fields were supplied"
            )
        }

        return try validatedPayload(
            frequencyStartIndex: workUnit.frequencyStartIndex ?? 0,
            startFrequency: startFrequency,
            frequencyStep: frequencyStep,
            frequencyCount: frequencyCount
        )
    }

    private func validatedPayload(
        frequencyStartIndex: Int,
        startFrequency: Double,
        frequencyStep: Double,
        frequencyCount: Int
    ) throws -> LombScargleWorkPayload {
        guard startFrequency.isFinite,
              frequencyStep.isFinite,
              startFrequency > 0,
              frequencyStep > 0,
              frequencyCount > 0 else {
            throw PeriodSearchError.invalidWorkUnit(
                "frequency grid is invalid"
            )
        }

        let startFrequencyFloat = Float(startFrequency)
        let frequencyStepFloat = Float(frequencyStep)

        guard startFrequencyFloat.isFinite,
              frequencyStepFloat.isFinite,
              startFrequencyFloat > 0,
              frequencyStepFloat > 0 else {
            throw PeriodSearchError.invalidWorkUnit(
                "frequency grid cannot be represented by the Metal Float32 workload"
            )
        }

        return LombScargleWorkPayload(
            frequencyStartIndex: frequencyStartIndex,
            startFrequency: startFrequencyFloat,
            frequencyStep: frequencyStepFloat,
            frequencyCount: frequencyCount
        )
    }

    private struct MetalResult {
        let metalDuration: Double
        let bestIndex: Int
        let bestFrequency: Double
        let bestPeriodDays: Double
        let bestPower: Double
    }

    private func runMetalSynchronously(
        payload: LombScargleWorkPayload,
        dataset: TESSPeriodSearchDataset
    ) throws -> MetalResult {
        guard !dataset.times.isEmpty,
              dataset.times.count == dataset.flux.count,
              dataset.times.allSatisfy(\.isFinite),
              dataset.flux.allSatisfy(\.isFinite) else {
            throw PeriodSearchError.invalidDataset
        }

        let sampleCount = dataset.times.count

        let timeByteCount =
            sampleCount * MemoryLayout<Float>.stride

        let outputByteCount =
            payload.frequencyCount * MemoryLayout<Float>.stride

        guard let timeBuffer = device.makeBuffer(
            bytes: dataset.times,
            length: timeByteCount,
            options: .storageModeShared
        ),
        let fluxBuffer = device.makeBuffer(
            bytes: dataset.flux,
            length: timeByteCount,
            options: .storageModeShared
        ),
        let powerBuffer = device.makeBuffer(
            length: outputByteCount,
            options: .storageModeShared
        ) else {
            throw PeriodSearchError.bufferAllocationFailed
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PeriodSearchError.commandBufferUnavailable
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PeriodSearchError.encoderUnavailable
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(timeBuffer, offset: 0, index: 0)
        encoder.setBuffer(fluxBuffer, offset: 0, index: 1)
        encoder.setBuffer(powerBuffer, offset: 0, index: 2)

        var gpuSampleCount = UInt32(sampleCount)
        var startFrequency = payload.startFrequency
        var frequencyStep = payload.frequencyStep

        encoder.setBytes(
            &gpuSampleCount,
            length: MemoryLayout<UInt32>.stride,
            index: 3
        )

        encoder.setBytes(
            &startFrequency,
            length: MemoryLayout<Float>.stride,
            index: 4
        )

        encoder.setBytes(
            &frequencyStep,
            length: MemoryLayout<Float>.stride,
            index: 5
        )

        let executionWidth = pipeline.threadExecutionWidth

        let threadgroupWidth = min(
            pipeline.maxTotalThreadsPerThreadgroup,
            executionWidth * 4
        )

        encoder.dispatchThreads(
            MTLSize(
                width: payload.frequencyCount,
                height: 1,
                depth: 1
            ),
            threadsPerThreadgroup: MTLSize(
                width: threadgroupWidth,
                height: 1,
                depth: 1
            )
        )

        encoder.endEncoding()

        let started = ProcessInfo.processInfo.systemUptime

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let metalDuration =
            ProcessInfo.processInfo.systemUptime - started

        guard commandBuffer.status == .completed else {
            throw PeriodSearchError.commandFailed(
                commandBuffer.error
            )
        }

        let powers = powerBuffer.contents().bindMemory(
            to: Float.self,
            capacity: payload.frequencyCount
        )

        var bestIndex: Int?
        var bestPower = -Float.infinity

        for index in 0..<payload.frequencyCount {
            let power = powers[index]

            if power.isFinite && power > bestPower {
                bestPower = power
                bestIndex = index
            }
        }

        guard let bestIndex,
              bestPower.isFinite else {
            throw PeriodSearchError.noFiniteResult
        }

        let bestFrequency =
            Double(payload.startFrequency) +
            Double(bestIndex) *
            Double(payload.frequencyStep)

        guard bestFrequency.isFinite,
              bestFrequency > 0 else {
            throw PeriodSearchError.noFiniteResult
        }

        return MetalResult(
            metalDuration: metalDuration,
            bestIndex: bestIndex,
            bestFrequency: bestFrequency,
            bestPeriodDays: 1.0 / bestFrequency,
            bestPower: Double(bestPower)
        )
    }
}
