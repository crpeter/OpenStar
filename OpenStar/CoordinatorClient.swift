//
//  CoordinatorClient.swift
//  OpenStar
//

import Foundation

nonisolated
enum CoordinatorClientError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The coordinator returned an invalid response."

        case .serverError(let statusCode, let message):
            return "Coordinator error \(statusCode): \(message)"
        }
    }
}

nonisolated
final class CoordinatorClient: @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    init(
        baseURL: URL = CoordinatorConfiguration.baseURL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Node Registration

    func register(
        nodeID: UUID,
        capabilities: NodeCapabilities
    ) async throws -> NodeRegistrationResponse {
        try await post(
            path: "v1/nodes/register",
            body: NodeRegistrationRequest(
                nodeID: nodeID,
                capabilities: capabilities
            ),
            responseType: NodeRegistrationResponse.self
        )
    }

    // MARK: - Work

    func claimWork(
        nodeID: UUID
    ) async throws -> WorkUnit? {
        let url = makeURL(
            path: "v1/work/claim"
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        request.httpBody = try JSONEncoder().encode(
            WorkClaimRequest(
                nodeID: nodeID
            )
        )

        let (data, response) =
            try await session.data(
                for: request
            )

        guard let httpResponse =
            response as? HTTPURLResponse
        else {
            throw CoordinatorClientError.invalidResponse
        }

        if httpResponse.statusCode == 204 {
            return nil
        }

        guard
            (200..<300).contains(
                httpResponse.statusCode
            )
        else {
            throw CoordinatorClientError.serverError(
                statusCode: httpResponse.statusCode,
                message: String(
                    decoding: data,
                    as: UTF8.self
                )
            )
        }

        return try JSONDecoder().decode(
            WorkUnit.self,
            from: data
        )
    }

    // MARK: - Dataset

    /// Generic OpenStar Core dataset access.
    ///
    /// Core treats dataset contents as opaque bytes.
    /// The workload plugin is responsible for decoding
    /// those bytes into its domain-specific model.
    func datasetData(
        id: String
    ) async throws -> Data {
        let url = makeURL(
            path: "v1/datasets/\(id)"
        )

        let (data, response) =
            try await session.data(
                from: url
            )

        guard let httpResponse =
            response as? HTTPURLResponse
        else {
            throw CoordinatorClientError.invalidResponse
        }

        guard
            (200..<300).contains(
                httpResponse.statusCode
            )
        else {
            throw CoordinatorClientError.serverError(
                statusCode: httpResponse.statusCode,
                message: String(
                    decoding: data,
                    as: UTF8.self
                )
            )
        }

        return data
    }

    /// Compatibility API for the existing astronomy/TESS code.
    ///
    /// This intentionally sits on top of the generic raw-data API.
    /// New OpenStar Core code should use datasetData(id:).
    func dataset(
        id: String
    ) async throws -> AstronomyDataset {
        let data = try await datasetData(
            id: id
        )

        return try JSONDecoder().decode(
            AstronomyDataset.self,
            from: data
        )
    }

    // MARK: - Results

    func submit(
        result: WorkResult
    ) async throws -> ResultReceipt {
        try await post(
            path:
                "v1/work/"
                + result.workUnitID.uuidString
                + "/result",
            body: result,
            responseType: ResultReceipt.self
        )
    }

    // MARK: - Project Status

    func projectStatus() async throws -> ProjectStatus {
        let url = makeURL(
            path: "v1/projects/current/status"
        )

        let (data, response) =
            try await session.data(
                from: url
            )

        guard let httpResponse =
            response as? HTTPURLResponse
        else {
            throw CoordinatorClientError.invalidResponse
        }

        guard
            (200..<300).contains(
                httpResponse.statusCode
            )
        else {
            throw CoordinatorClientError.serverError(
                statusCode: httpResponse.statusCode,
                message: String(
                    decoding: data,
                    as: UTF8.self
                )
            )
        }

        return try JSONDecoder().decode(
            ProjectStatus.self,
            from: data
        )
    }

    // MARK: - HTTP

    private func post<
        Request: Encodable,
        Response: Decodable
    >(
        path: String,
        body: Request,
        responseType: Response.Type
    ) async throws -> Response {
        let url = makeURL(
            path: path
        )

        var request =
            URLRequest(
                url: url
            )

        request.httpMethod = "POST"

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        request.httpBody =
            try JSONEncoder().encode(
                body
            )

        let (data, response) =
            try await session.data(
                for: request
            )

        guard let httpResponse =
            response as? HTTPURLResponse
        else {
            throw CoordinatorClientError.invalidResponse
        }

        guard
            (200..<300).contains(
                httpResponse.statusCode
            )
        else {
            throw CoordinatorClientError.serverError(
                statusCode: httpResponse.statusCode,
                message: String(
                    decoding: data,
                    as: UTF8.self
                )
            )
        }

        return try JSONDecoder().decode(
            Response.self,
            from: data
        )
    }

    private func makeURL(
        path: String
    ) -> URL {
        path
            .split(separator: "/")
            .reduce(baseURL) {
                $0.appendingPathComponent(
                    String($1)
                )
            }
    }
}
