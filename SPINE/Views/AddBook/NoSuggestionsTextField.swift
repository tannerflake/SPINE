//
//  NoSuggestionsTextField.swift
//  Spine
//
//  A UITextField-backed field with the keyboard's predictive / QuickType
//  suggestions bar disabled. SwiftUI's `TextField` keeps that bar even with
//  `.autocorrectionDisabled()`, and it eats a lot of vertical space above the
//  keyboard. Setting the UIKit text-input traits directly removes it.
//

import SwiftUI
import UIKit

struct NoSuggestionsTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var font: UIFont
    var textColor: UIColor
    var placeholderColor: UIColor
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.delegate = context.coordinator
        tf.font = font
        tf.textColor = textColor
        tf.tintColor = textColor
        tf.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: placeholderColor, .font: font]
        )
        tf.returnKeyType = .search
        tf.enablesReturnKeyAutomatically = false
        tf.clearButtonMode = .never
        // Turn off the predictive/QuickType bar and the other keyboard assists.
        tf.autocorrectionType = .no
        tf.spellCheckingType = .no
        tf.smartQuotesType = .no
        tf.smartDashesType = .no
        tf.smartInsertDeleteType = .no
        tf.autocapitalizationType = .none
        if #available(iOS 17.0, *) { tf.inlinePredictionType = .no }
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        // Let the field stretch to fill its container instead of hugging its text.
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text { uiView.text = text }
        // Placeholder is dynamic (the search drawer swaps it per scope), so keep it in sync.
        if uiView.attributedPlaceholder?.string != placeholder {
            uiView.attributedPlaceholder = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: placeholderColor, .font: font]
            )
        }
        // Keep UIKit focus in sync with SwiftUI's `isFocused` (autofocus on open,
        // resign when a search is submitted).
        if isFocused, !uiView.isFirstResponder {
            if uiView.window != nil {
                uiView.becomeFirstResponder()
            } else {
                // Focus requested before the field is attached (autofocus on the
                // first layout pass) — becomeFirstResponder would silently fail.
                DispatchQueue.main.async {
                    if context.coordinator.parent.isFocused, !uiView.isFirstResponder {
                        uiView.becomeFirstResponder()
                    }
                }
            }
        } else if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NoSuggestionsTextField
        init(_ parent: NoSuggestionsTextField) { self.parent = parent }

        @objc func editingChanged(_ tf: UITextField) {
            parent.text = tf.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }
    }
}
