//
//  ContactSyncService.swift
//  SPINE
//
//  Reads the device address book (with permission) and matches contacts
//  against Spine members by phone number, so users can find friends already
//  on the app and invite the rest by text.
//

import Contacts
import FirebaseFunctions
import Foundation

/// One address-book entry relevant to friend discovery/invites.
struct SyncedContact: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Raw numbers as entered in the address book (used for the SMS recipient).
    let phoneNumbers: [String]
    /// Last-10-digit match keys derived from `phoneNumbers`.
    let matchKeys: Set<String>
}

/// A contact matched to an existing Spine member.
struct MatchedMember: Identifiable, Equatable {
    var id: String { uid }
    let uid: String
    let user: User
    let contact: SyncedContact
}

enum ContactSyncService {

    /// Digits only. "+1 (512) 555-0199" → "15125550199".
    static func normalizePhoneNumber(_ raw: String) -> String {
        raw.filter(\.isNumber)
    }

    /// Progressive US-style display formatting for a phone entry field.
    /// "5125550199" -> "(512) 555-0199". A leading country "1" is kept as a
    /// "+1" prefix; anything that isn't a plausible US number (more than 11
    /// digits, or 11 not starting with 1) is handed back as bare digits so
    /// international users aren't fighting the formatter.
    static func formatPhoneNumberForDisplay(_ raw: String) -> String {
        var digits = normalizePhoneNumber(raw)
        var prefix = ""
        if digits.count == 11, digits.hasPrefix("1") {
            prefix = "+1 "
            digits = String(digits.dropFirst())
        }
        guard digits.count <= 10 else { return normalizePhoneNumber(raw) }
        let d = Array(digits)
        switch d.count {
        case 0:
            return ""
        case 1...3:
            return prefix + String(d)
        case 4...6:
            return prefix + "(\(String(d[0..<3]))) \(String(d[3...]))"
        default:
            return prefix + "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6...]))"
        }
    }

    /// Numbers match when their last 10 digits agree (folds "+1"/leading
    /// country codes into one key); shorter numbers must match exactly.
    static func matchKey(_ raw: String) -> String? {
        let digits = normalizePhoneNumber(raw)
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(10))
    }

    static var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    static func requestAccess() async -> Bool {
        let store = CNContactStore()
        return (try? await store.requestAccess(for: .contacts)) ?? false
    }

    /// All contacts that have at least one phone number, sorted by name.
    /// Call only after access is granted.
    static func fetchContacts() async -> [SyncedContact] {
        await Task.detached(priority: .userInitiated) { () -> [SyncedContact] in
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.sortOrder = .givenName
            var contacts: [SyncedContact] = []
            try? store.enumerateContacts(with: request) { contact, _ in
                let numbers = contact.phoneNumbers.map { $0.value.stringValue }
                guard !numbers.isEmpty else { return }
                let name = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let displayName = name.isEmpty
                    ? (contact.organizationName.isEmpty ? numbers[0] : contact.organizationName)
                    : name
                contacts.append(SyncedContact(
                    id: contact.identifier,
                    displayName: displayName,
                    phoneNumbers: numbers,
                    matchKeys: Set(numbers.compactMap { matchKey($0) })
                ))
            }
            return contacts
        }.value
    }

    /// Splits contacts into members already on Spine (matched by phone) and
    /// everyone else (invite candidates). `readers` come from
    /// UserRepository.fetchAllReaderProfiles.
    static func match(
        contacts: [SyncedContact],
        readers: [(uid: String, user: User)]
    ) -> (onSpine: [MatchedMember], toInvite: [SyncedContact]) {
        var keyToReader: [String: (uid: String, user: User)] = [:]
        for reader in readers {
            guard let phone = reader.user.phoneNumber, let key = matchKey(phone) else { continue }
            keyToReader[key] = reader
        }
        var onSpine: [MatchedMember] = []
        var matchedUids = Set<String>()
        var toInvite: [SyncedContact] = []
        for contact in contacts {
            if let reader = contact.matchKeys.compactMap({ keyToReader[$0] }).first {
                if matchedUids.insert(reader.uid).inserted {
                    onSpine.append(MatchedMember(uid: reader.uid, user: reader.user, contact: contact))
                }
            } else {
                toInvite.append(contact)
            }
        }
        return (onSpine, toInvite)
    }

    /// Tracks which match sets have already been announced this launch, so the
    /// onboarding wizard and Find Friends can both call this freely without
    /// double-firing. The server is the real guard (one alert per pair, ever);
    /// this just avoids the pointless round trip.
    private static var announcedContactUids = Set<String>()

    /// Tells matched members that someone they know just joined. Only the
    /// matched SPINE uids are sent: the address book never leaves the device.
    ///
    /// Safe to call from anywhere a match runs. The server drops the call
    /// unless the caller genuinely joined recently, has not already alerted
    /// that person, and that person isn't already following them, so callers
    /// don't need to reason about any of that.
    static func announceJoinToMatchedContacts(_ matches: [MatchedMember]) {
        let uids = matches.map(\.uid).filter { !announcedContactUids.contains($0) }
        guard !uids.isEmpty else { return }
        announcedContactUids.formUnion(uids)
        Task {
            _ = try? await Functions.functions(region: "us-central1")
                .httpsCallable("notifyContactsOfJoin")
                .call(["uids": uids])
        }
    }
}
