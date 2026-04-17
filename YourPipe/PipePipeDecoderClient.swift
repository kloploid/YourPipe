import Foundation

/// Batch n-param and signatureCipher decoder backed by the PipePipe remote
/// decoder service (`api.pipepipe.dev/decoder`). Mirrors the contract used by
/// `YoutubeApiDecoder` in the PipePipe Android client:
///
///   GET /decoder/decode?player=<8-char playerId>&n=<csv>&sig=<csv>
///
///   {
///     "type": "result",
///     "responses": [
///       { "type": "result", "data": { "<input>": "<decoded>", ... } }
///     ]
///   }
///
/// The `responses` array preserves the request order: when both `n` and `sig`
/// are present, the n-group comes first. This actor caches decoded values in
/// memory keyed by `playerId|kind|input` to keep repeat segments free.
actor PipePipeDecoderClient {
    static let shared = PipePipeDecoderClient()

    enum Kind: String {
        case n
        case sig
    }

    enum DecoderError: LocalizedError {
        case invalidURL
        case httpStatus(Int)
        case invalidResponse
        case unexpectedType(String)
        case missingValues

        var errorDescription: String? {
            switch self {
            case .invalidURL:           return "Bad decoder URL"
            case .httpStatus(let code): return "Decoder HTTP \(code)"
            case .invalidResponse:      return "Decoder returned non-JSON payload"
            case .unexpectedType(let t): return "Decoder returned type=\(t)"
            case .missingValues:        return "Decoder response missing expected values"
            }
        }
    }

    struct DecodeResult {
        var n: [String: String]
        var sig: [String: String]
    }

    private let session: URLSession
    private let endpoint = URL(string: "https://api.pipepipe.dev/decoder/decode")!
    private let userAgent = "PipePipe/4.9.0"
    private let requestTimeout: TimeInterval = 10

    /// Keyed by `playerId|kind|input` — never expires; player.js is versioned
    /// by `playerId` so stale values never conflict across deploys.
    private var cache: [String: String] = [:]

    /// Deduplicate in-flight batches by playerId + sorted inputs, so many
    /// segments arriving simultaneously collapse into one network request.
    private var inflight: [String: Task<DecodeResult, Error>] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    func decodeN(playerId: String, value: String) async throws -> String {
        if let hit = cache[cacheKey(playerId: playerId, kind: .n, input: value)] {
            return hit
        }
        let result = try await decode(playerId: playerId, nParams: [value], sigs: [])
        guard let out = result.n[value] else { throw DecoderError.missingValues }
        return out
    }

    func decodeSig(playerId: String, value: String) async throws -> String {
        if let hit = cache[cacheKey(playerId: playerId, kind: .sig, input: value)] {
            return hit
        }
        let result = try await decode(playerId: playerId, nParams: [], sigs: [value])
        guard let out = result.sig[value] else { throw DecoderError.missingValues }
        return out
    }

    /// Batch decode. Empty arrays are allowed for either group.
    func decode(
        playerId: String,
        nParams: [String],
        sigs: [String]
    ) async throws -> DecodeResult {
        let trimmedPlayerId = String(playerId.prefix(8))
        guard !trimmedPlayerId.isEmpty else { throw DecoderError.invalidURL }

        // Serve from cache first; only request the missing pieces.
        var result = DecodeResult(n: [:], sig: [:])
        var missingN: [String] = []
        var missingSig: [String] = []

        for v in nParams {
            if let hit = cache[cacheKey(playerId: trimmedPlayerId, kind: .n, input: v)] {
                result.n[v] = hit
            } else {
                missingN.append(v)
            }
        }
        for v in sigs {
            if let hit = cache[cacheKey(playerId: trimmedPlayerId, kind: .sig, input: v)] {
                result.sig[v] = hit
            } else {
                missingSig.append(v)
            }
        }

        if missingN.isEmpty && missingSig.isEmpty {
            return result
        }

        let key = inflightKey(playerId: trimmedPlayerId, nParams: missingN, sigs: missingSig)
        if let task = inflight[key] {
            let partial = try await task.value
            result.n.merge(partial.n) { _, new in new }
            result.sig.merge(partial.sig) { _, new in new }
            return result
        }

        let task = Task<DecodeResult, Error> {
            try await self.performRequest(
                playerId: trimmedPlayerId,
                nParams: missingN,
                sigs: missingSig
            )
        }
        inflight[key] = task

        do {
            let fetched = try await task.value
            inflight[key] = nil
            for (k, v) in fetched.n {
                cache[cacheKey(playerId: trimmedPlayerId, kind: .n, input: k)] = v
                result.n[k] = v
            }
            for (k, v) in fetched.sig {
                cache[cacheKey(playerId: trimmedPlayerId, kind: .sig, input: k)] = v
                result.sig[k] = v
            }
            return result
        } catch {
            inflight[key] = nil
            throw error
        }
    }

    // MARK: - Network

    private func performRequest(
        playerId: String,
        nParams: [String],
        sigs: [String]
    ) async throws -> DecodeResult {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [URLQueryItem(name: "player", value: playerId)]
        if !nParams.isEmpty {
            items.append(URLQueryItem(name: "n", value: nParams.joined(separator: ",")))
        }
        if !sigs.isEmpty {
            items.append(URLQueryItem(name: "sig", value: sigs.joined(separator: ",")))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw DecoderError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DecoderError.httpStatus(http.statusCode)
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecoderError.invalidResponse
        }
        let topType = (obj["type"] as? String) ?? ""
        guard topType == "result" else { throw DecoderError.unexpectedType(topType) }
        guard let responses = obj["responses"] as? [[String: Any]] else {
            throw DecoderError.invalidResponse
        }

        var result = DecodeResult(n: [:], sig: [:])
        var cursor = 0

        if !nParams.isEmpty {
            guard cursor < responses.count else { throw DecoderError.missingValues }
            let group = responses[cursor]; cursor += 1
            let groupType = (group["type"] as? String) ?? ""
            guard groupType == "result" else { throw DecoderError.unexpectedType(groupType) }
            let data = (group["data"] as? [String: Any]) ?? [:]
            for key in nParams {
                guard let decoded = data[key] as? String else { throw DecoderError.missingValues }
                result.n[key] = decoded
            }
        }

        if !sigs.isEmpty {
            guard cursor < responses.count else { throw DecoderError.missingValues }
            let group = responses[cursor]
            let groupType = (group["type"] as? String) ?? ""
            guard groupType == "result" else { throw DecoderError.unexpectedType(groupType) }
            let data = (group["data"] as? [String: Any]) ?? [:]
            for key in sigs {
                guard let decoded = data[key] as? String else { throw DecoderError.missingValues }
                result.sig[key] = decoded
            }
        }

        return result
    }

    // MARK: - Helpers

    private func cacheKey(playerId: String, kind: Kind, input: String) -> String {
        "\(playerId)|\(kind.rawValue)|\(input)"
    }

    private func inflightKey(playerId: String, nParams: [String], sigs: [String]) -> String {
        let n = nParams.sorted().joined(separator: ",")
        let s = sigs.sorted().joined(separator: ",")
        return "\(playerId)|n=\(n)|s=\(s)"
    }
}
