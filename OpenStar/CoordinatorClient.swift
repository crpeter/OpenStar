//
//  CoordinatorClientError.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//


//
//  CoordinatorClient.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
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

    func register(
        nodeID: UUID,
        capabilities: NodeCapabilities
    ) async throws -> NodeRegistrationResponse {
        let requestBody = NodeRegistrationRequest(
            nodeID: nodeID,
            capabilities: capabilities
        )

        return try await post(
            path: "v1/nodes/register",
            body: requestBody,
            responseType: NodeRegistrationResponse.self
        )
    }

    func claimWork(
        nodeID: UUID
    ) async throws -> WorkUnit? {
        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("work")
            .appendingPathComponent("claim")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        request.httpBody = try JSONEncoder().encode(
            WorkClaimRequest(nodeID: nodeID)
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoordinatorClientError.invalidResponse
        }

        if httpResponse.statusCode == 204 {
            return nil
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CoordinatorClientError.serverError(
                statusCode: httpResponse.statusCode,
                message: String(decoding: data, as: UTF8.self)
            )
        }

        return try JSONDecoder().decode(
            WorkUnit.self,
            from: data
        )
    }

    func submit(
        result: WorkResult
    ) async throws -> ResultReceipt {
        let path =
            "v1/work/\(result.workUnitID.uuidString)/result"

        return try await post(
            path: path,
            body: result,
            responseType: ResultReceipt.self
        )
    }

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        responseType: Response.Type
    ) async throws -> Response {
        let url = path
            .split(separator: "/")
            .reduce(baseURL) {
                $0.appendingPathComponent(String($1))
            }

        var request = URLRequest(url: url)

        request.httpMethod = "POST"

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoordinatorClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CoordinatorClientError.serverError(
                statusCode: httpResponse.statusCode,
                message: String(decoding: data, as: UTF8.self)
            )
        }

        return try JSONDecoder().decode(
            Response.self,
            from: data
        )
    }
}
