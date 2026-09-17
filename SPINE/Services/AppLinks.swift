//
//  AppLinks.swift
//  SPINE
//
//  Public links for Spine and invite copy shared by the contact-invite flows.
//

import Foundation

enum AppLinks {
    /// Spine on the App Store (SPINE [Reading Tracker]).
    static let appStore = "https://apps.apple.com/us/app/spine-reading-tracker/id6759875368"

    /// Prefilled SMS body for inviting a contact. Mentions the book when the
    /// invite starts from a recommendation.
    static func inviteMessage(bookTitle: String? = nil) -> String {
        if let title = bookTitle, !title.isEmpty {
            return "I want to suggest a book to you: \u{201C}\(title)\u{201D}. Get SPINE so I can send it over: \(appStore)"
        }
        return "I want to suggest a book to you. Get SPINE and I'll send it over: \(appStore)"
    }

    /// Prefilled SMS body for the onboarding wizard's invite step, where no
    /// book context exists yet.
    static func onboardingInviteMessage() -> String {
        "Share your reading with me on SPINE! \(appStore)"
    }
}
