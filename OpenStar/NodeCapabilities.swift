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
//  Created by Cody Peter on 8/9/26.
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
    let elementCount: Int
    let iterationsPerElement: Int
    let seed: Int
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
    let estimatedGFLOPS: Double?
    let checksum: Double?
    let verificationValue: Float?

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
    let totalWorkUnits: Int
    let pendingWorkUnits: Int
    let assignedWorkUnits: Int
    let completedWorkUnits: Int
    let retryCount: Int

    var isComplete: Bool {
        totalWorkUnits > 0 &&
        completedWorkUnits == totalWorkUnits
    }

    var progress: Double {
        guard totalWorkUnits > 0 else {
            return 0
        }

        return Double(completedWorkUnits) /
            Double(totalWorkUnits)
    }
}