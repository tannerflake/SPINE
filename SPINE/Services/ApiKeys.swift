//
//  ApiKeys.swift
//  SPINE
//
//  Reads API keys from Secrets.plist (gitignored) or Info.plist. Do not commit real keys.
//

import Foundation

enum ApiKeys {
    /// Claude (Anthropic) API key for AI features. From Secrets.plist "CLAUDE_API_KEY" or "ANTHROPIC_API_KEY", or Info.plist.
    static var claude: String? {
        if let key = keyFromPlist(named: "Secrets", key: "CLAUDE_API_KEY"), !key.isEmpty { return key }
        if let key = keyFromPlist(named: "Secrets", key: "ANTHROPIC_API_KEY"), !key.isEmpty { return key }
        if let key = keyFromPlist(named: "Info", key: "CLAUDE_API_KEY"), !key.isEmpty { return key }
        return nil
    }

    /// Gemini (Google AI) API key for the cheap model tier. From Secrets.plist / Info.plist "GEMINI_API_KEY".
    static var gemini: String? {
        if let key = keyFromPlist(named: "Secrets", key: "GEMINI_API_KEY"), !key.isEmpty { return key }
        if let key = keyFromPlist(named: "Info", key: "GEMINI_API_KEY"), !key.isEmpty { return key }
        return nil
    }

    /// Amplitude ingestion key for product analytics. From Secrets.plist / Info.plist "AMPLITUDE_API_KEY".
    static var amplitude: String? {
        if let key = keyFromPlist(named: "Secrets", key: "AMPLITUDE_API_KEY"), !key.isEmpty { return key }
        if let key = keyFromPlist(named: "Info", key: "AMPLITUDE_API_KEY"), !key.isEmpty { return key }
        return nil
    }

    /// Meta app ID for the Instagram story share (Sharing to Stories needs a
    /// Facebook app ID as its source_application). From Secrets.plist /
    /// Info.plist "META_APP_ID". Optional: the share falls back to the bundle
    /// id when unset.
    static var metaAppID: String? {
        if let key = keyFromPlist(named: "Secrets", key: "META_APP_ID"), !key.isEmpty { return key }
        if let key = keyFromPlist(named: "Info", key: "META_APP_ID"), !key.isEmpty { return key }
        return nil
    }

    /// Email/password for hidden test login (tap the welcome book icon 5×). Add `TEST_ACCOUNT_EMAIL` and `TEST_ACCOUNT_PASSWORD` to Secrets.plist; create the same user in Firebase Authentication (Email/Password).
    static var testAccountCredentials: (email: String, password: String)? {
        guard let email = keyFromPlist(named: "Secrets", key: "TEST_ACCOUNT_EMAIL"), !email.isEmpty,
              let password = keyFromPlist(named: "Secrets", key: "TEST_ACCOUNT_PASSWORD"), !password.isEmpty else {
            return nil
        }
        return (email, password)
    }

    private static func keyFromPlist(named name: String, key: String) -> String? {
        guard let path = Bundle.main.path(forResource: name, ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path),
              let value = plist[key] as? String else { return nil }
        return value
    }
}
