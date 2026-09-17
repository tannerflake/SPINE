//
//  RootViewController.swift
//  SPINE
//
//  Helper to get the topmost UIViewController for presenting (e.g. Google Sign-In).
//

import UIKit

enum RootViewController {
    /// Returns the topmost view controller suitable for presenting modals (e.g. Google Sign-In).
    static func topMost(in window: UIWindow? = nil) -> UIViewController? {
        let window = window ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard var root = window?.rootViewController else { return nil }
        while let presented = root.presentedViewController {
            root = presented
        }
        return root
    }
}
