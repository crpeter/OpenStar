//
//  NodeCapabilities.swift
//  OpenStar
//
//  Generic network contracts shared by the OpenStar worker runtime.
//  Workload-specific parameters and results live in JSON payloads.
//

import Foundation

nonisolated
enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }

        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }

        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }

        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }

        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value."
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    var doubleValue: Double? {
        guard case .number(let value) = self else {
            return nil
        }
        return value
    }

    var intValue: Int? {
        guard let doubleValue,
              doubleValue.isFinite,
              doubleValue.rounded() == doubleValue else {
            return nil
        }
        return Int(doubleValue)
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else {
            return nil
        }
        return value
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

nonisolated
struct ComputeBackend: Codable, Sendable, Hashable {
    let id: String

    init(_ id: String) {
        self.id = id
    }

    static let cpu = ComputeBackend("cpu")
    static let metal = ComputeBackend("metal")
    static let cuda = ComputeBackend("cuda")
}

nonisolated
struct WorkloadCapability: Codable, Sendable, Hashable {
    let workloadID: String
    let executionBackends: [ComputeBackend]
    let validatorID: String?
}

nonisolated
struct NodeCapabilities: Codable, Sendable {
    let platform: String
    let hardwareIdentifier: String
    let gpuName: String
    let processorCount: Int
    let memoryGB: Double

    let computeBackends: [ComputeBackend]
    let workloads: [WorkloadCapability]
}

nonisolated
struct NodeRegistrationRequest: Codable, Sendable {
    let nodeID: UUID
    let capabilities: NodeCapabilities
}

nonisolated
struct NodeRegistrationResponse: Codable, Sendable {
    let accepted: Bool
    let message: String
}

nonisolated
struct WorkClaimRequest: Codable, Sendable {
    let nodeID: UUID
}

nonisolated
struct WorkUnit: Codable, Identifiable, Sendable {
    let id: UUID
    let projectID: String
    let workloadID: String

    // Dataset identity is a generic OpenStar concept. The coordinator and
    // worker runtime do not interpret the dataset contents.
    let datasetID: String?

    // New generic workload contract.
    let payload: JSONValue?

    // Transitional compatibility with the existing v18 TESS coordinator.
    // New projects should put these values inside payload instead.
    let frequencyStartIndex: Int?
    let startFrequency: Double?
    let frequencyStep: Double?
    let frequencyCount: Int?
}


nonisolated
enum WorkFailureKind: String, Codable, Sendable {
    /// The workload could not execute successfully on the node.
    /// Examples: Metal command failure, buffer allocation failure, runtime fault.
    case execution = "execution"

    /// The workload executed, but its workload-owned integrity validator
    /// rejected the output.
    case workloadValidation = "workload-validation"

    /// The claimed work or dataset could not be interpreted as valid input
    /// for the workload.
    case invalidInput = "invalid-input"

    /// The worker's environment temporarily cannot execute this work.
    /// Examples: iOS background GPU restrictions, temporary platform policy,
    /// or another transient environment condition. This is not a broken node.
    case environmentUnavailable = "environment-unavailable"

    /// The worker temporarily cannot communicate with the coordinator.
    /// Examples: connection lost, request timeout, offline network, DNS/host
    /// reachability failure. This is not a workload or compute-node failure.
    case transportUnavailable = "transport-unavailable"

    /// The worker received a workload it does not implement.
    case unsupportedWorkload = "unsupported-workload"

    /// The worker could not classify the error more specifically.
    case unknown = "unknown"
}

nonisolated
protocol WorkFailureClassifyingError: Error {
    var workFailureKind: WorkFailureKind { get }
}

nonisolated
enum WorkResultStatus: String, Codable, Sendable {
    case completed
    case failed
}

nonisolated
struct WorkResult: Codable, Sendable {
    let workUnitID: UUID
    let nodeID: UUID
    let status: WorkResultStatus
    let duration: Double?

    // Generic workload-defined result.
    let payload: JSONValue?

    let errorMessage: String?

    // Generic failure provenance. Nil for completed work.
    let failureKind: WorkFailureKind?

    // Transitional flattened TESS fields retained only so the existing v18
    // coordinator can continue its current period reduction while the server
    // is migrated to generic result payloads.
    let bestFrequency: Double?
    let bestPeriodDays: Double?
    let bestPower: Double?
}

nonisolated
struct ResultReceipt: Codable, Sendable {
    let accepted: Bool
    let message: String
}

nonisolated
struct ProjectStatus: Codable, Sendable {
    let projectID: String
    let workloadID: String

    // Optional display metadata. Core scheduling does not depend on it.
    let targetName: String?

    let totalWorkUnits: Int
    let pendingWorkUnits: Int
    let assignedWorkUnits: Int
    let completedWorkUnits: Int
    let retryCount: Int
    let failedWorkUnits: Int?

    var isComplete: Bool {
        guard totalWorkUnits > 0 else {
            return false
        }

        return completedWorkUnits + (failedWorkUnits ?? 0) >= totalWorkUnits
    }

    var progress: Double {
        guard totalWorkUnits > 0 else {
            return 0
        }

        return Double(
            completedWorkUnits + (failedWorkUnits ?? 0)
        ) / Double(totalWorkUnits)
    }
}
