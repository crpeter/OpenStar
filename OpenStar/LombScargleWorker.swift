//
//  LombScargleWorker.swift
//  OpenStar
//
//  Domain/workload plugin for Lomb-Scargle period-search work.
//  OpenStar Core routes this workload but does not understand its payload.
//

import Foundation
import Metal

nonisolated
struct LombScargleDataset: Codable, Sendable {
    let id: String?
    let coordinates: [Float]
    let values: [Float]

    private enum CodingKeys: String, CodingKey {
        case id, coordinates, values, times, flux
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(String.self, forKey: .id)
        coordinates = try Self.decodeArray(
            from: container,
            genericKey: .coordinates,
            legacyKey: .times
        )
        values = try Self.decodeArray(
            from: container,
            genericKey: .values,
            legacyKey: .flux
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(coordinates, forKey: .coordinates)
        try container.encode(values, forKey: .values)
    }

    private static func decodeArray(
        from container: KeyedDecodingContainer<CodingKeys>,
        genericKey: CodingKeys,
        legacyKey: CodingKeys
    ) throws -> [Float] {
        if container.contains(genericKey) {
            return try container.decode([Float].self, forKey: genericKey)
        }

        return try container.decode([Float].self, forKey: legacyKey)
    }
}

nonisolated
struct LombScargleWorkPayload: Sendable {
    let frequencyStartIndex: Int
    let startFrequency: Float
    let frequencyStep: Float
    let frequencyCount: Int
}

nonisolated
enum LombScargleError: LocalizedError {
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
    case validationFailed(LombScargleValidation)

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
final class LombScargleWorker: OpenStarWorkloadHandler, @unchecked Sendable {
    // New domain-neutral workload name plus the existing project ID as a
    // compatibility alias. Both route to the same implementation.
    static let workloadID = "openstar.lomb-scargle.v1"
    static let legacyWorkloadID = "openstar.tess-period-search.v1"

    let workloadIDs = [
        LombScargleWorker.workloadID,
        LombScargleWorker.legacyWorkloadID
    ]

    let capabilities = [
        WorkloadCapability(
            workloadID: LombScargleWorker.workloadID,
            executionBackends: [.metal],
            validatorID: LombScargleValidation.validatorID
        ),
        WorkloadCapability(
            workloadID: LombScargleWorker.legacyWorkloadID,
            executionBackends: [.metal],
            validatorID: LombScargleValidation.validatorID
        )
    ]

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw LombScargleError.metalUnavailable
        }

        guard let commandQueue = device.makeCommandQueue() else {
            throw LombScargleError.commandQueueUnavailable
        }

        guard let library = device.makeDefaultLibrary() else {
            throw LombScargleError.libraryUnavailable
        }

        guard let function = library.makeFunction(
            name: "openStarLombScargle"
        ) else {
            throw LombScargleError.functionUnavailable
        }

        do {
            pipeline = try device.makeComputePipelineState(
                function: function
            )
        } catch {
            throw LombScargleError.pipelineCreationFailed(error)
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
            throw LombScargleError.missingDataset
        }

        let dataset = try JSONDecoder().decode(
            LombScargleDataset.self,
            from: datasetData
        )

        let payload = try Self.workPayload(
            from: workUnit
        )

        let totalStarted = ProcessInfo.processInfo.systemUptime

        let metalResult = try runMetalSynchronously(
            payload: payload,
            dataset: dataset
        )

        try Task.checkCancellation()

        let validationStarted = ProcessInfo.processInfo.systemUptime

        let validation = try LombScargleCPUValidator.validate(
            coordinates: dataset.coordinates,
            values: dataset.values,
            metalBestIndex: metalResult.bestIndex,
            metalBestPower: metalResult.bestPower,
            startFrequency: payload.startFrequency,
            frequencyStep: payload.frequencyStep,
            frequencyCount: payload.frequencyCount
        )

        let validationDuration =
            ProcessInfo.processInfo.systemUptime - validationStarted

        guard validation.passed else {
            throw LombScargleError.validationFailed(
                validation
            )
        }

        let totalDuration =
            ProcessInfo.processInfo.systemUptime - totalStarted

        let resultPayload: JSONValue = .object([
            "bestFrequency": .number(metalResult.bestFrequency),
            // Retained for the existing astronomy-oriented wire contract.
            // Generic presentation treats this as reciprocal frequency.
            "bestPeriodDays": .number(metalResult.reciprocalFrequency),
            "bestPower": .number(metalResult.bestPower),
            "bestFrequencyIndex": .number(
                Double(payload.frequencyStartIndex + metalResult.bestIndex)
            ),
            "metalDurationSeconds": .number(metalResult.metalDuration),
            "validation": .object([
                "validatorID": .string(
                    LombScargleValidation.validatorID
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
                        id: "reciprocal-frequency",
                        label: "Reciprocal Frequency",
                        value: String(
                            format: "%.6f",
                            metalResult.reciprocalFrequency
                        )
                    ),
                    WorkloadResultField(
                        id: "frequency",
                        label: "Frequency",
                        value: String(
                            format: "%.6f",
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
                bestPeriodDays: metalResult.reciprocalFrequency,
                bestPower: metalResult.bestPower
            )
        )
    }

    static func workPayload(
        from workUnit: WorkUnit
    ) throws -> LombScargleWorkPayload {
        if let payload = workUnit.payload {
            guard let payloadObject = payload.objectValue else {
                throw LombScargleError.invalidWorkUnit(
                    "generic payload must be a JSON object"
                )
            }

            guard let startFrequency = payloadObject["startFrequency"]?.doubleValue,
                  let frequencyStep = payloadObject["frequencyStep"]?.doubleValue,
                  let frequencyCount = payloadObject["frequencyCount"]?.intValue else {
                throw LombScargleError.invalidWorkUnit(
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
            throw LombScargleError.invalidWorkUnit(
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

    private static func validatedPayload(
        frequencyStartIndex: Int,
        startFrequency: Double,
        frequencyStep: Double,
        frequencyCount: Int
    ) throws -> LombScargleWorkPayload {
        guard frequencyStartIndex >= 0,
              startFrequency.isFinite,
              frequencyStep.isFinite,
              startFrequency > 0,
              frequencyStep > 0,
              frequencyCount > 0 else {
            throw LombScargleError.invalidWorkUnit(
                "frequency grid is invalid"
            )
        }

        let startFrequencyFloat = Float(startFrequency)
        let frequencyStepFloat = Float(frequencyStep)
        let lastFrequency = startFrequency +
            Double(frequencyCount - 1) * frequencyStep

        guard startFrequencyFloat.isFinite,
              frequencyStepFloat.isFinite,
              lastFrequency.isFinite,
              Float(lastFrequency).isFinite,
              startFrequencyFloat > 0,
              frequencyStepFloat > 0 else {
            throw LombScargleError.invalidWorkUnit(
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

    private struct NumericalResult {
        let metalDuration: Double
        let bestIndex: Int
        let bestFrequency: Double
        let reciprocalFrequency: Double
        let bestPower: Double
    }

    private func runMetalSynchronously(
        payload: LombScargleWorkPayload,
        dataset: LombScargleDataset
    ) throws -> NumericalResult {
        guard !dataset.coordinates.isEmpty,
              dataset.coordinates.count == dataset.values.count,
              dataset.coordinates.allSatisfy(\.isFinite),
              dataset.values.allSatisfy(\.isFinite) else {
            throw LombScargleError.invalidDataset
        }

        let sampleCount = dataset.coordinates.count

        guard sampleCount <= Int(UInt32.max),
              payload.frequencyStartIndex <= Int.max - payload.frequencyCount,
              payload.frequencyCount <= Int.max / MemoryLayout<Float>.stride,
              sampleCount <= Int.max / MemoryLayout<Float>.stride else {
            throw LombScargleError.invalidWorkUnit(
                "input dimensions exceed the Metal workload limits"
            )
        }

        let sampleByteCount =
            sampleCount * MemoryLayout<Float>.stride

        let outputByteCount =
            payload.frequencyCount * MemoryLayout<Float>.stride

        guard let coordinateBuffer = device.makeBuffer(
            bytes: dataset.coordinates,
            length: sampleByteCount,
            options: .storageModeShared
        ),
        let valueBuffer = device.makeBuffer(
            bytes: dataset.values,
            length: sampleByteCount,
            options: .storageModeShared
        ),
        let powerBuffer = device.makeBuffer(
            length: outputByteCount,
            options: .storageModeShared
        ) else {
            throw LombScargleError.bufferAllocationFailed
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw LombScargleError.commandBufferUnavailable
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw LombScargleError.encoderUnavailable
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(coordinateBuffer, offset: 0, index: 0)
        encoder.setBuffer(valueBuffer, offset: 0, index: 1)
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
            throw LombScargleError.commandFailed(
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
            throw LombScargleError.noFiniteResult
        }

        let bestFrequency =
            Double(payload.startFrequency) +
            Double(bestIndex) *
            Double(payload.frequencyStep)

        guard bestFrequency.isFinite,
              bestFrequency > 0 else {
            throw LombScargleError.noFiniteResult
        }

        return NumericalResult(
            metalDuration: metalDuration,
            bestIndex: bestIndex,
            bestFrequency: bestFrequency,
            reciprocalFrequency: 1.0 / bestFrequency,
            bestPower: Double(bestPower)
        )
    }
}
