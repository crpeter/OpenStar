//
//  NodeCapabilities 2.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//


//
//  NetworkModels.swift
//  OpenStar
//

import Foundation

nonisolated
struct NodeCapabilities: Codable, Sendable {
    let platform: String
    let hardwareIdentifier: String
    let gpuName: String
    let processorCount: Int
    let memoryGB: Double
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
    let datasetID: String
    let frequencyStartIndex: Int
    let startFrequency: Float
    let frequencyStep: Float
    let frequencyCount: Int
}

nonisolated
struct AstronomyDataset: Codable, Sendable {
    let id: String
    let targetName: String
    let mission: String
    let timeUnit: String
    let fluxUnit: String
    let times: [Float]
    let flux: [Float]
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
    let bestFrequency: Double?
    let bestPeriodDays: Double?
    let bestPower: Double?

    let errorMessage: String?
}

nonisolated
struct ResultReceipt: Codable, Sendable {
    let accepted: Bool
    let message: String
}

nonisolated
struct ProjectStatus: Codable, Sendable {
    let projectID: String
    let targetName: String
    let workloadID: String

    let totalWorkUnits: Int
    let pendingWorkUnits: Int
    let assignedWorkUnits: Int
    let completedWorkUnits: Int
    let retryCount: Int

    var isComplete: Bool {
        totalWorkUnits > 0 && completedWorkUnits == totalWorkUnits
    }

    var progress: Double {
        guard totalWorkUnits > 0 else {
            return 0
        }

        return Double(completedWorkUnits) / Double(totalWorkUnits)
    }
}
