//
//  TESSPeriodSearchFailureClassification.swift
//  OpenStar
//
//  Workload-specific mapping from Lomb-Scargle/TESS errors into the generic
//  OpenStar WorkFailureKind taxonomy.
//
//  OpenStar Core only understands WorkFailureKind. It does not need to know
//  about Metal, Lomb-Scargle, TESS, or the local Float64 validator.
//

import Foundation

extension PeriodSearchError: WorkFailureClassifyingError {
    nonisolated
    var workFailureKind: WorkFailureKind {
        switch self {
        case .validationFailed:
            return .workloadValidation

        case .missingDataset,
             .invalidDataset,
             .invalidWorkUnit:
            return .invalidInput

        case .commandFailed(let error):
            if Self.isEnvironmentUnavailableMetalError(error) {
                return .environmentUnavailable
            }
            return .execution

        case .metalUnavailable,
             .commandQueueUnavailable,
             .libraryUnavailable,
             .functionUnavailable,
             .pipelineCreationFailed,
             .bufferAllocationFailed,
             .commandBufferUnavailable,
             .encoderUnavailable,
             .noFiniteResult:
            return .execution
        }
    }

    private nonisolated
    static func isEnvironmentUnavailableMetalError(
        _ error: Error?
    ) -> Bool {
        guard let error else {
            return false
        }

        let message = error.localizedDescription.lowercased()

        return message.contains(
            "backgroundexecutionnotpermitted"
        ) || message.contains(
            "submit gpu work from background"
        )
    }
}

extension TESSPeriodSearchValidationError: WorkFailureClassifyingError {
    nonisolated
    var workFailureKind: WorkFailureKind {
        switch self {
        case .invalidInput:
            return .invalidInput

        case .failed:
            return .workloadValidation
        }
    }
}
