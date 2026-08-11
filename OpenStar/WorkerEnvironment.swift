//
//  WorkerEnvironment.swift
//  OpenStar
//
//  Generic worker-availability abstraction. Workloads do not know why a node
//  is temporarily unavailable. Platform adapters translate local runtime state
//  into this domain-neutral availability state.
//

import Foundation

#if os(iOS)
import UIKit
#endif

nonisolated
enum WorkerAvailability: String, Sendable {
    case available
    case temporarilyUnavailable = "temporarily-unavailable"
}

nonisolated
enum WorkerRuntimeError: LocalizedError, WorkFailureClassifyingError {
    case environmentUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .environmentUnavailable(let reason):
            return reason
        }
    }

    var workFailureKind: WorkFailureKind {
        .environmentUnavailable
    }
}

enum WorkerEnvironment {
    @MainActor
    static func currentAvailability() -> WorkerAvailability {
#if os(iOS)
        return UIApplication.shared.applicationState == .active
            ? .available
            : .temporarilyUnavailable
#else
        return .available
#endif
    }

    @MainActor
    static func requireAvailable() throws {
        guard currentAvailability() == .available else {
            throw WorkerRuntimeError.environmentUnavailable(
                "The device environment is temporarily unavailable for compute work."
            )
        }
    }
}
