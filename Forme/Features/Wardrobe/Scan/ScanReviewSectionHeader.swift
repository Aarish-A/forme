import SwiftUI

/// The heading above each block of the review grid.
///
/// It exists to make the middle case sayable. The scan divides what it found
/// into what it recognised as the user, what it could not read a face in, and
/// what it recognised as somebody else — and until these headings existed the
/// second case was silently mixed into the first and pre-selected with it.
struct ScanReviewSectionHeader: View {
    let confidence: ScanStore.GroupConfidence
    let groups: [ScanStore.CandidateGroup]
    let onKeepAll: () -> Void

    var body: some View {
        let unselected = groups.allSatisfy { group in
            !([group.representative] + group.others).contains(where: \.isSelected)
        }
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(Self.title(confidence))
                    .formeText(.sectionTitle)
                if let note = Self.note(confidence) {
                    Text(note)
                        .formeText(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            // Only offered while nothing in the section is kept: once the user
            // has started picking, a bulk button would undo their choices.
            if confidence == .unsure, unselected {
                Button("Keep These", action: onKeepAll)
                    .buttonStyle(.formeSecondary)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func title(_ confidence: ScanStore.GroupConfidence) -> String {
        switch confidence {
        case .you: "Looks like you"
        case .unsure: "Not sure"
        case .notYou: "Set aside"
        }
    }

    private static func note(_ confidence: ScanStore.GroupConfidence) -> String? {
        switch confidence {
        case .you: nil
        case .unsure: "Forme couldn't see a face clearly enough to tell. Tap any you want to keep."
        case .notYou: "These look like other people."
        }
    }
}

#Preview("Sections") {
    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
        ForEach([ScanStore.GroupConfidence.you, .unsure, .notYou], id: \.self) { confidence in
            ScanReviewSectionHeader(confidence: confidence, groups: [], onKeepAll: {})
        }
    }
    .formeScreenPadding()
}
