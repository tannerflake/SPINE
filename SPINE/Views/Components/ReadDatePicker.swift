import SwiftUI

/// Calendar popover for picking a read date. It stays open while the month/year
/// wheel is scrubbed and closes only on Done or a tap outside. Auto-closing on
/// selection change (the old MarkAsReadDrawer behaviour) fired the moment the
/// year wheel moved, so nobody could change the year and then the month
/// without reopening the picker.
struct ReadDatePickerPopover: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var selection: Date

    func body(content: Content) -> some View {
        content.popover(isPresented: $isPresented) {
            VStack(spacing: 0) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { ReadDate.isLongAgo(selection) ? Date() : selection },
                        set: { selection = $0 }
                    ),
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                // The graphical calendar has no usable intrinsic width inside a
                // popover: without an explicit frame it collapses to a narrow
                // clipped column. Size it to the calendar's natural dimensions.
                .frame(width: 320, height: 360)

                Button {
                    isPresented = false
                } label: {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.spinePrimary)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}

extension View {
    /// Presents the shared read-date calendar popover anchored to this view.
    func readDatePickerPopover(isPresented: Binding<Bool>, selection: Binding<Date>) -> some View {
        modifier(ReadDatePickerPopover(isPresented: isPresented, selection: selection))
    }
}

/// Capsule chip that shows the picked date and opens `ReadDatePickerPopover`
/// on tap. Drop-in replacement for the compact `DatePicker`, whose UIKit
/// popover dismissed itself mid-edit.
struct ReadDateChip: View {
    @Binding var date: Date
    var compact = false
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 7 : 10)
            .background(Capsule().fill(Theme.surfaceElevated))
            .overlay(Capsule().stroke(Theme.chrome.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.springPress)
        .readDatePickerPopover(isPresented: $showPicker, selection: $date)
    }
}
