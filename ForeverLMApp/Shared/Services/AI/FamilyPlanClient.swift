import CryptoKit
import Foundation

/// The app's half of family plans (docs/family-design.md; the proxy's half is
/// docs/managed-ai-billing.md → Family plans). A parent's plan covers the
/// children in a family team, and each child's AI runs on an OpenRouter key
/// the parent connected for them.
///
/// The key never travels in the clear. Each account has an X25519 device key
/// in its Keychain (`FamilyDeviceKey`); a child's app publishes the public
/// half when it joins, the parent's Mac seals the child's key to it with HPKE
/// (`FamilyKeySealing`), and the proxy only ever stores the ciphertext.
enum FamilyPlanClient {
    struct Status: Decodable, Equatable, Sendable {
        let maxMembers: Int
        let families: [Family]
        let membership: Membership?

        enum CodingKeys: String, CodingKey {
            case maxMembers = "max_members"
            case families, membership
        }

        func family(teamID: String) -> Family? {
            families.first { $0.teamID == teamID }
        }
    }

    /// A team this account pays for, with the children who joined it.
    struct Family: Decodable, Equatable, Sendable {
        let teamID: String
        let familyPlan: Bool
        let members: [Member]

        enum CodingKeys: String, CodingKey {
            case teamID = "team_id"
            case familyPlan = "family_plan"
            case members
        }
    }

    struct Member: Decodable, Equatable, Sendable, Identifiable {
        let memberID: String
        let displayName: String
        let cloudKitUserRecordName: String?
        let devicePublicKey: String
        let hasKey: Bool
        let keyLabel: String?
        let keyUpdatedAt: String?
        let joinedAt: String?

        var id: String { memberID }

        enum CodingKeys: String, CodingKey {
            case memberID = "member_id"
            case displayName = "display_name"
            case cloudKitUserRecordName = "cloudkit_user_record_name"
            case devicePublicKey = "device_public_key"
            case hasKey = "has_key"
            case keyLabel = "key_label"
            case keyUpdatedAt = "key_updated_at"
            case joinedAt = "joined_at"
        }
    }

    /// The family this account is a child in.
    struct Membership: Decodable, Equatable, Sendable {
        let teamID: String
        let memberID: String
        let covered: Bool
        let devicePublicKey: String
        let key: SealedKey?

        enum CodingKeys: String, CodingKey {
            case teamID = "team_id"
            case memberID = "member_id"
            case covered
            case devicePublicKey = "device_public_key"
            case key
        }
    }

    struct SealedKey: Codable, Equatable, Sendable {
        let sealedKey: String
        let encapsulation: String
        let label: String?
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case sealedKey = "sealed_key"
            case encapsulation, label
            case updatedAt = "updated_at"
        }
    }

    struct JoinResult: Decodable, Equatable, Sendable {
        let teamID: String
        let memberID: String
        let covered: Bool

        enum CodingKeys: String, CodingKey {
            case teamID = "team_id"
            case memberID = "member_id"
            case covered
        }
    }

    // MARK: - Calls

    static func status() async throws -> Status {
        try await send("GET", "/v1/family")
    }

    /// Turns the family plan on for a team, or renews its code. Needs a live
    /// plan of the caller's own (`plan_required` otherwise).
    static func enable(teamID: String) async throws -> String {
        struct Response: Decodable { let code: String }
        let response: Response = try await send("POST", "/v1/family/invite", body: ["team_id": teamID])
        return response.code
    }

    /// Turns the family plan off for a team: every child who joined through it
    /// leaves, sealed keys included.
    static func disable(teamID: String) async throws {
        let _: Empty = try await send("DELETE", "/v1/family/invite", body: ["team_id": teamID])
    }

    static func join(code: String, displayName: String, cloudKitUserRecordName: String?) async throws -> JoinResult {
        let publicKey = try FamilyDeviceKey.publicKeyBase64()
        var body = ["code": code, "device_public_key": publicKey, "display_name": displayName]
        if let cloudKitUserRecordName { body["cloudkit_user_record_name"] = cloudKitUserRecordName }
        return try await send("POST", "/v1/family/join", body: body)
    }

    static func leave() async throws {
        let _: Empty = try await send("DELETE", "/v1/family/membership")
    }

    /// Seals `openRouterKey` to the child's device key and stores the
    /// ciphertext for them.
    static func giveKey(_ openRouterKey: String, to member: Member, label: String) async throws {
        let sealed = try FamilyKeySealing.seal(openRouterKey, toPublicKeyBase64: member.devicePublicKey)
        let body = ["sealed_key": sealed.sealedKey, "encapsulation": sealed.encapsulation, "label": label]
        let _: Empty = try await send("PUT", "/v1/family/members/\(member.memberID)/key", body: body)
    }

    // MARK: - Transport

    private struct Empty: Decodable {}

    private static func send<T: Decodable>(
        _ method: String,
        _ path: String,
        body: [String: String]? = nil
    ) async throws -> T {
        guard let token = ManagedAI.sessionToken else {
            throw ManagedAI.ServiceError(code: "invalid_session", message: "Sign in with Apple to use a family plan.")
        }
        var request = URLRequest(url: ManagedAI.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ManagedAI.serviceError(from: data)
                ?? ManagedAI.ServiceError(code: "http_\(status)", message: "The family plan service answered \(status).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Device key

/// This account's X25519 key pair for family plans. The private half lives in
/// the Keychain (synced, so a child's Macs share it) and is made on first use.
enum FamilyDeviceKey {
    struct KeychainError: LocalizedError {
        var errorDescription: String? { "The family device key could not be read from the Keychain." }
    }

    private static let lock = NSLock()

    static func privateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try lock.withLock {
            if let stored = KeychainService.load(.familyDeviceKey),
               let data = Data(base64Encoded: stored) {
                return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
            }
            let key = Curve25519.KeyAgreement.PrivateKey()
            KeychainService.save(key.rawRepresentation.base64EncodedString(), for: .familyDeviceKey)
            guard KeychainService.load(.familyDeviceKey) != nil else { throw KeychainError() }
            return key
        }
    }

    static func publicKeyBase64() throws -> String {
        try privateKey().publicKey.rawRepresentation.base64EncodedString()
    }
}

// MARK: - Sealing

/// HPKE (RFC 9180, X25519 / HKDF-SHA256 / ChaCha20-Poly1305) around one
/// OpenRouter key. `info` binds the ciphertext to this use, so a sealed key
/// cannot be replayed into another HPKE context.
enum FamilyKeySealing {
    struct Sealed: Equatable, Sendable {
        let sealedKey: String
        let encapsulation: String
    }

    struct OpenError: LocalizedError {
        var errorDescription: String? {
            "The key your family sent could not be opened on this Mac. Ask them to connect it again."
        }
    }

    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    static let info = Data("ForeverLM family key v1".utf8)

    static func seal(_ plaintext: String, toPublicKeyBase64 publicKeyBase64: String) throws -> Sealed {
        guard let raw = Data(base64Encoded: publicKeyBase64) else { throw OpenError() }
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info)
        let ciphertext = try sender.seal(Data(plaintext.utf8))
        return Sealed(
            sealedKey: ciphertext.base64EncodedString(),
            encapsulation: sender.encapsulatedKey.base64EncodedString()
        )
    }

    static func open(
        _ sealed: FamilyPlanClient.SealedKey,
        with privateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> String {
        guard let ciphertext = Data(base64Encoded: sealed.sealedKey),
              let encapsulated = Data(base64Encoded: sealed.encapsulation) else { throw OpenError() }
        var recipient = try HPKE.Recipient(
            privateKey: privateKey,
            ciphersuite: suite,
            info: info,
            encapsulatedKey: encapsulated
        )
        let plaintext = try recipient.open(ciphertext)
        guard let key = String(data: plaintext, encoding: .utf8), !key.isEmpty else { throw OpenError() }
        return key
    }
}
