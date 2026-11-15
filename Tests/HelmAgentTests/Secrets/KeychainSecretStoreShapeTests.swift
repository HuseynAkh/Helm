import Security
import XCTest
@testable import HelmAgent

/// What the keychain store asks the keychain for, read from the queries it builds. No keychain function is called:
/// the login keychain belongs to the person, and a question from macOS would take the screen.
final class KeychainSecretStoreShapeTests: XCTestCase {
    private let claude = AgentSecretID(provider: .claude, host: "api.anthropic.com", port: 443)
    private let local = AgentSecretID(provider: .lmStudio, host: "127.0.0.1", port: 1234)

    private var allQueries: [(String, [String: Any])] {
        let secret = AgentTransportTesting.secret()
        return [("item", KeychainSecretStore.itemQuery(claude)), ("presence", KeychainSecretStore.presenceQuery(claude)),
                ("secret", KeychainSecretStore.secretQuery(claude)), ("add", KeychainSecretStore.addQuery(secret, for: claude))]
    }

    func testTheNamesAreFixed() {
        XCTAssertEqual(KeychainSecretStore.service, "com.helm.filemanager.ai-key")
        XCTAssertEqual(KeychainSecretStore.label, "Helm AI key")
        XCTAssertFalse(KeychainSecretStore().isMemoryOnly)
    }

    func testEveryQueryNamesOneGenericPasswordByServiceAndAccount() {
        for (name, query) in allQueries {
            XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String, name)
            XCTAssertEqual(query[kSecAttrService as String] as? String, "com.helm.filemanager.ai-key", name)
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "claude|api.anthropic.com:443", name)
        }
        XCTAssertEqual(KeychainSecretStore.itemQuery(local)[kSecAttrAccount as String] as? String, "lmStudio|127.0.0.1:1234")
    }

    func testNoQueryCarriesTheDataProtectionAccessGroupOrSyncAttributes() {
        let forbidden = [kSecUseDataProtectionKeychain, kSecAttrAccessGroup, kSecAttrSynchronizable, kSecAttrAccessible,
                         kSecAttrAccessControl, kSecUseAuthenticationContext].map { $0 as String }
        for (name, query) in allQueries {
            for key in forbidden {
                XCTAssertNil(query[key], "\(name) holds \(key)")
            }
        }
    }

    func testTheItemQueryHoldsTheThreeKeysAndNothingElse() {
        // Anything else in the query that finds the item would let a delete or a read match more, or less.
        XCTAssertEqual(Set(KeychainSecretStore.itemQuery(claude).keys),
                       [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String])
    }

    func testAskingWhetherAKeyIsSavedAsksForAttributesOnly() {
        let query = KeychainSecretStore.presenceQuery(claude)
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnData as String])
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertNil(query[kSecValueData as String])
    }

    func testReadingAKeyAsksForOneItemsData() {
        let query = KeychainSecretStore.secretQuery(claude)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertNil(query[kSecReturnAttributes as String])
    }

    func testAddingAKeyCarriesTheLabelAndTheKey() {
        let query = KeychainSecretStore.addQuery(AgentTransportTesting.secret(), for: claude)
        XCTAssertEqual(query[kSecAttrLabel as String] as? String, "Helm AI key")
        XCTAssertEqual(query[kSecValueData as String] as? Data, Data(AgentTransportTesting.key.utf8))
        XCTAssertNil(query[kSecReturnData as String])
        XCTAssertNil(query[kSecReturnAttributes as String])
        // The label isn't used to find an item, so one the person renamed is still found.
        XCTAssertNil(KeychainSecretStore.itemQuery(claude)[kSecAttrLabel as String])
        XCTAssertNil(KeychainSecretStore.secretQuery(claude)[kSecAttrLabel as String])
    }

    func testARefusedQuestionIsDeniedAndNeverMissing() {
        XCTAssertEqual(KeychainSecretStore.outcome(of: -128), .denied)
        XCTAssertEqual(KeychainSecretStore.outcome(of: -25293), .denied)
        XCTAssertEqual(KeychainSecretStore.outcome(of: -25308), .denied)
        XCTAssertEqual(KeychainSecretStore.outcome(of: errSecUserCanceled), .denied)
        XCTAssertEqual(KeychainSecretStore.outcome(of: errSecAuthFailed), .denied)
        XCTAssertEqual(KeychainSecretStore.outcome(of: errSecInteractionNotAllowed), .denied)
    }

    func testOnlyNoSuchItemIsMissing() {
        XCTAssertEqual(KeychainSecretStore.outcome(of: 0), .found)
        XCTAssertEqual(KeychainSecretStore.outcome(of: -25300), .missing)
        // A duplicate, a missing entitlement, a broken keychain: none is "no key" and none is a refusal.
        for status: OSStatus in [-25299, -34018, -25291, -25294, -50, -26276] {
            XCTAssertEqual(KeychainSecretStore.outcome(of: status), .failed, "\(status)")
        }
    }

    // MARK: The ChatGPT sign-in

    func testASignInIsKeptInTwoItemsOfItsOwnUnderTheSameService() {
        XCTAssertEqual(KeychainSecretStore.signInLabel, "Helm ChatGPT sign-in")
        XCTAssertEqual(AgentSignInItem.chatGPTRegistration.account, "chatgpt-registration|auth.openai.com:443")
        XCTAssertEqual(AgentSignInItem.chatGPTTokens.account, "chatgpt-sign-in|auth.openai.com:443")
        // No provider's key can have either account: a key's account starts with the provider's identifier.
        for item in AgentSignInItem.allCases {
            XCTAssertFalse(AgentProviderID.allCases.contains { item.account.hasPrefix($0.rawValue + "|") }, item.account)
        }
        let data = Data("record".utf8)
        let add = KeychainSecretStore.signInAddQuery(data, note: "person@example.com", for: .chatGPTTokens)
        XCTAssertEqual(add[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(add[kSecAttrService as String] as? String, "com.helm.filemanager.ai-key")
        XCTAssertEqual(add[kSecAttrAccount as String] as? String, "chatgpt-sign-in|auth.openai.com:443")
        XCTAssertEqual(add[kSecAttrLabel as String] as? String, "Helm ChatGPT sign-in")
        XCTAssertEqual(add[kSecAttrComment as String] as? String, "person@example.com", "Settings reads who without the data")
        XCTAssertEqual(add[kSecValueData as String] as? Data, data)
        XCTAssertNil(KeychainSecretStore.signInAddQuery(data, note: nil, for: .chatGPTRegistration)[kSecAttrComment as String])
        let forbidden = [kSecUseDataProtectionKeychain, kSecAttrAccessGroup, kSecAttrSynchronizable, kSecAttrAccessible,
                         kSecAttrAccessControl].map { $0 as String }
        for key in forbidden { XCTAssertNil(add[key], key) }
        let presence = KeychainSecretStore.presenceQuery(account: AgentSignInItem.chatGPTTokens.account)
        XCTAssertEqual(presence[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(presence[kSecReturnData as String], "whether one is saved, and who, never asks for the tokens")
    }

    func testTheMemoryStoreKeepsASignInApartFromTheKeys() throws {
        let store = MemorySecretStore()
        try store.saveSignIn(Data("tokens".utf8), note: "person@example.com", for: .chatGPTTokens)
        XCTAssertTrue(store.hasSignIn(.chatGPTTokens))
        XCTAssertFalse(store.hasSignIn(.chatGPTRegistration))
        XCTAssertEqual(store.accounts, [], "a sign-in is not a key")
        XCTAssertEqual(store.signInNote(.chatGPTTokens), "person@example.com")
        store.denies = true
        XCTAssertThrowsError(try store.signInData(.chatGPTTokens))
        XCTAssertTrue(store.hasSignIn(.chatGPTTokens), "asking whether one is saved never asks for it")
        store.denies = false
        try store.removeSignIn(.chatGPTTokens)
        XCTAssertNil(try store.signInData(.chatGPTTokens))
        XCTAssertNil(store.signInNote(.chatGPTTokens))
        // A store made for keys alone has no room for a sign-in.
        let keysOnly = AgentCountingSecretStore()
        XCTAssertFalse(keysOnly.hasSignIn(.chatGPTTokens))
        XCTAssertThrowsError(try keysOnly.saveSignIn(Data(), note: nil, for: .chatGPTTokens))
    }
}
