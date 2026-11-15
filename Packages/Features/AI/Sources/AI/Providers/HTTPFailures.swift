import Foundation
import Kit

/// Turns what went wrong with a request into words for the user. Nothing here logs: an error body
/// can quote the request.
nonisolated enum HTTPFailures {
    // MARK: - Anthropic

    /// The failure for an Anthropic response outside 200 to 299. The body is the API's error object,
    /// `{"type":"error","error":{"type":"...","message":"..."}}`, when the API answered at all.
    static func anthropic(status: Int, headers: [String: String], body: String, model: String) -> AIFailure {
        let error = decodeError(body)
        return anthropic(
            errorType: error.type, message: error.message, status: status,
            retryAfter: retryAfterSeconds(headers), model: model)
    }

    /// The failure for an Anthropic error, from an error response or an `error` event mid-stream.
    static func anthropic(errorType: String?, message: String?, status: Int?, retryAfter: Int?, model: String)
        -> AIFailure
    {
        switch errorType {
        case "authentication_error": return Strings.Failures.anthropicKeyRejected
        case "permission_error": return Strings.Failures.permissionDenied
        case "billing_error": return Strings.Failures.anthropicBilling
        case "not_found_error": return Strings.Failures.anthropicModelUnavailable(model)
        case "request_too_large": return Strings.Failures.requestTooLarge
        case "rate_limit_error": return Strings.Failures.rateLimited(after: retryAfter)
        case "overloaded_error": return Strings.Failures.overloaded(Strings.Providers.anthropic)
        case "api_error": return Strings.Failures.serverProblem(Strings.Providers.anthropic)
        case "invalid_request_error": return Strings.Failures.requestRefused(message)
        default: break
        }
        switch status {
        case 401: return Strings.Failures.anthropicKeyRejected
        case 402: return Strings.Failures.anthropicBilling
        case 403: return Strings.Failures.permissionDenied
        case 404: return Strings.Failures.anthropicModelUnavailable(model)
        case 413: return Strings.Failures.requestTooLarge
        case 429: return Strings.Failures.rateLimited(after: retryAfter)
        case 529: return Strings.Failures.overloaded(Strings.Providers.anthropic)
        case let code? where code >= 500: return Strings.Failures.serverProblem(Strings.Providers.anthropic)
        default: return Strings.Failures.requestRefused(message)
        }
    }

    // MARK: - OpenAI-compatible servers

    /// The failure for a server response outside 200 to 299. Servers send
    /// `{"error":{"message":"..."}}`, `{"error":"..."}` or plain text.
    static func compatible(status: Int, headers: [String: String], body: String, host: String) -> AIFailure {
        let message = decodeError(body).message ?? plainMessage(body)
        switch status {
        case 401: return Strings.Failures.serverKeyRejected(host)
        case 403: return Strings.Failures.permissionDenied
        case 404: return Strings.Failures.serverModelNotFound(message)
        case 408: return Strings.Failures.timedOut(host)
        case 413: return Strings.Failures.requestTooLarge
        case 429: return Strings.Failures.rateLimited(after: retryAfterSeconds(headers))
        case 503, 529: return Strings.Failures.overloaded(host)
        case 500...: return Strings.Failures.serverProblem(host, detail: message)
        default: return Strings.Failures.requestRefused(message)
        }
    }

    // MARK: - Transport

    /// The error to report for a request that failed without an HTTP answer. `CancellationError` and
    /// ``AIFailure`` pass through unchanged.
    static func transport(_ error: any Error, host: String) -> any Error {
        if error is CancellationError || error is AIFailure { return error }
        guard let urlError = error as? URLError else { return Strings.Failures.unexpected }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
            .callIsActive:
            return Strings.Failures.noInternet
        case .cannotFindHost, .dnsLookupFailed:
            return Strings.Failures.cannotFindHost(host)
        case .cannotConnectToHost:
            return Strings.Failures.cannotConnect(host)
        case .timedOut:
            return Strings.Failures.timedOut(host)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
            .clientCertificateRequired:
            return Strings.Failures.secureConnection(host)
        case .appTransportSecurityRequiresSecureConnection:
            return Strings.Failures.insecureAddress(host)
        case .badURL, .unsupportedURL:
            return Strings.Failures.badAddress
        default:
            return Strings.Failures.requestFailed(host)
        }
    }

    // MARK: - Parsing

    private struct ErrorEnvelope: Decodable {
        var error: ErrorBody?
    }

    /// `error` is an object for Anthropic and OpenAI, and a plain string for some local servers.
    private enum ErrorBody: Decodable {
        case object(type: String?, message: String?)
        case text(String)

        private enum Keys: String, CodingKey {
            case type
            case message
        }

        init(from decoder: any Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self = .text(text)
                return
            }
            let container = try decoder.container(keyedBy: Keys.self)
            self = .object(
                type: try container.decodeIfPresent(String.self, forKey: .type),
                message: try container.decodeIfPresent(String.self, forKey: .message))
        }
    }

    /// The error type and message in a JSON error body, when it has them.
    static func decodeError(_ body: String) -> (type: String?, message: String?) {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: Data(body.utf8)) else {
            return (nil, nil)
        }
        switch envelope.error {
        case .object(let type, let message): return (type, message.map(oneLine))
        case .text(let text): return (nil, oneLine(text))
        case nil: return (nil, nil)
        }
    }

    /// A short plain-text body as one line, or nil for HTML pages and long or empty bodies.
    private static func plainMessage(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 300, !trimmed.hasPrefix("<") else { return nil }
        return oneLine(trimmed)
    }

    private static func oneLine(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return collapsed.count > 300 ? String(collapsed.prefix(300)) + "…" : collapsed
    }

    /// The `retry-after` header in whole seconds, whatever case the server used.
    static func retryAfterSeconds(_ headers: [String: String]) -> Int? {
        guard let value = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value else { return nil }
        guard let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds >= 0, seconds < 86_400 else {
            return nil
        }
        return Int(seconds.rounded(.up))
    }
}

extension HTTPStream {
    /// At most `limit` bytes of the body as text, for an error answer. Stops reading after that.
    nonisolated func boundedText(limit: Int = 65_536) async throws -> String {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count >= limit { break }
        }
        try Task.checkCancellation()
        return String(decoding: data.prefix(limit), as: UTF8.self)
    }
}
