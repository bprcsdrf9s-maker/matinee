import Foundation

enum StremioError: LocalizedError {
    case api(String, code: Int)
    case badResponse
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case let .api(message, _): return message
        case .badResponse: return "Stremio sent an unexpected response."
        case .notSignedIn: return "You're signed out."
        }
    }

    /// Stremio's API answers a dead session with code 1 ("Session does not exist").
    var isSessionExpired: Bool {
        if case let .api(message, code) = self {
            return code == 1 || message.localizedCaseInsensitiveContains("session")
        }
        return false
    }
}

/// Stremio's account API, matching stremio-core (types/api/request.rs):
/// every call is a POST to https://api.strem.io/api/<method> and answers {"result": …} or {"error": {message, code}}.
enum StremioAPI {
    static let apiBase = URL(string: "https://api.strem.io/api/")!
    static let linkBase = URL(string: "https://link.stremio.com/api/v2/")!

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // MARK: Transport

    private static func call(_ method: String, _ body: [String: Any]) async throws -> Any {
        var request = URLRequest(url: apiBase.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        return try unwrap(data)
    }

    private static func unwrap(_ data: Data) throws -> Any {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StremioError.badResponse
        }
        if let err = root["error"] as? [String: Any] {
            let message = err["message"] as? String ?? "Stremio returned an error."
            let code = (err["code"] as? NSNumber)?.intValue ?? 0
            throw StremioError.api(message, code: code)
        }
        if let err = root["error"] as? String {
            throw StremioError.api(err, code: 0)
        }
        guard let result = root["result"] else { throw StremioError.badResponse }
        return result
    }

    // MARK: Auth

    struct Account {
        let authKey: String
        let email: String?
    }

    private static func account(from result: Any) throws -> Account {
        guard let dict = result as? [String: Any], let key = dict["authKey"] as? String else {
            throw StremioError.badResponse
        }
        let user = dict["user"] as? [String: Any]
        return Account(authKey: key, email: user?["email"] as? String)
    }

    static func login(email: String, password: String) async throws -> Account {
        let result = try await call("login", ["type": "Login", "email": email, "password": password, "facebook": false])
        return try account(from: result)
    }

    static func loginWithToken(_ token: String) async throws -> Account {
        let result = try await call("loginWithToken", ["type": "LoginWithToken", "token": token])
        return try account(from: result)
    }

    static func getUserEmail(authKey: String) async throws -> String? {
        let result = try await call("getUser", ["type": "GetUser", "authKey": authKey])
        return (result as? [String: Any])?["email"] as? String
    }

    static func logout(authKey: String) async {
        _ = try? await call("logout", ["type": "Logout", "authKey": authKey])
    }

    // MARK: Sign in with a code (link.stremio.com)

    struct LinkCode {
        let code: String
        let link: URL?
    }

    static func createLinkCode() async throws -> LinkCode {
        var comps = URLComponents(url: linkBase.appendingPathComponent("create"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "type", value: "Create")]
        let (data, _) = try await session.data(from: comps.url!)
        guard let dict = try unwrap(data) as? [String: Any], let code = dict["code"] as? String else {
            throw StremioError.badResponse
        }
        return LinkCode(code: code, link: (dict["link"] as? String).flatMap(URL.init(string:)))
    }

    /// Returns the auth key once the code has been approved, or nil while it's still waiting.
    static func readLinkCode(_ code: String) async throws -> String? {
        var comps = URLComponents(url: linkBase.appendingPathComponent("read"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "type", value: "Read"), URLQueryItem(name: "code", value: code)]
        let (data, _) = try await session.data(from: comps.url!)
        do {
            let result = try unwrap(data)
            return (result as? [String: Any])?["authKey"] as? String
        } catch is StremioError {
            // "not approved yet" comes back as an API error; keep polling.
            return nil
        }
    }

    // MARK: Addons

    /// Returns the raw JSON of the addon collection plus the decoded addons.
    static func addonCollection(authKey: String) async throws -> (raw: Data, addons: [AddonDescriptor]) {
        let result = try await call("addonCollectionGet", ["type": "AddonCollectionGet", "authKey": authKey, "update": true])
        let raw = try JSONSerialization.data(withJSONObject: result)
        return (raw, decodeAddons(raw))
    }

    static func decodeAddons(_ raw: Data) -> [AddonDescriptor] {
        struct AddonCollection: Decodable {
            let addons: [AddonDescriptor]
            enum CodingKeys: String, CodingKey { case addons }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                addons = c.lossyArray(AddonDescriptor.self, .addons)
            }
        }
        return (try? JSONDecoder().decode(AddonCollection.self, from: raw))?.addons ?? []
    }

    // MARK: Library (datastore, collection "libraryItem")

    static func libraryItems(authKey: String, ids: [String] = []) async throws -> [[String: Any]] {
        let result = try await call("datastoreGet", [
            "authKey": authKey,
            "collection": "libraryItem",
            "ids": ids,
            "all": ids.isEmpty,
        ])
        return result as? [[String: Any]] ?? []
    }

    static func putLibraryItems(authKey: String, _ items: [[String: Any]]) async throws {
        _ = try await call("datastorePut", [
            "authKey": authKey,
            "collection": "libraryItem",
            "changes": items,
        ])
    }
}
