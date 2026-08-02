#if DEBUG

    import Foundation
    import SwiftUI

    /// The last scan's report, as raw JSON.
    ///
    /// Deliberately unstyled. This is a debug affordance for an audience of one,
    /// and the report is already close to English — a formatted list with
    /// hand-written explanations would be a day of SwiftUI that goes stale every
    /// time a field changes. Read it here, or share the file out and let Claude
    /// read it.
    ///
    /// DEBUG-only in its entirety, so there is nothing to hide behind a gesture
    /// and nothing to strip before release.
    /// The button plus its sheet, as one child view.
    ///
    /// It owns the presentation state so the flow view needs a single `#if
    /// DEBUG` around a child rather than one around a `@State` property and
    /// another around a view modifier — which the formatter and SwiftLint
    /// disagree about how to indent.
    struct ScanDiagnosticsButton: View {
        let report: ScanReport
        @State private var isPresented = false

        var body: some View {
            Button("Scan Report") { isPresented = true }
                .buttonStyle(.formeSecondary)
                .sheet(isPresented: $isPresented) {
                    ScanDiagnosticsView(report: report)
                }
        }
    }

    struct ScanDiagnosticsView: View {
        let report: ScanReport
        @Environment(\.dismiss) private var dismiss

        private var fileURL: URL? {
            DiagnosticsStore().latestURL()
        }

        var body: some View {
            NavigationStack {
                ScrollView([.horizontal, .vertical]) {
                    Text(json)
                        .formeText(.caption)
                        .monospaced()
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle("Scan Report")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    if let fileURL {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: fileURL)
                        }
                    }
                }
            }
        }

        private var json: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard
                let data = try? encoder.encode(report),
                let text = String(data: data, encoding: .utf8)
            else {
                return "Could not encode the report."
            }
            return text
        }
    }

    private func previewReport() -> ScanReport {
        var builder = ScanReportBuilder(
            policy: ScanPolicy(),
            fetched: 2500,
            identityActive: true,
            startedAt: Date(timeIntervalSinceNow: -90),
            runID: "preview"
        )
        // Shaped like the failure this whole screen exists to make obvious:
        // faces found on every candidate, none of them big enough to embed.
        for index in 0 ..< 40 {
            var trace = PhotoTrace()
            trace.didLoad = true
            trace.didAnalyze = true
            trace.clothingConfidence = index.isMultiple(of: 3) ? 0.35 : 0.82
            trace.faceSidesPx = [34]
            builder.record(trace, wasCandidate: true, ownerStatus: .unknown)
        }
        builder.recordReview(groups: 12, groupsWithYou: 3, shown: 40)
        return builder.report(wasCancelled: false)
    }

    #Preview("Report") {
        ScanDiagnosticsView(report: previewReport())
    }

    #Preview("Button") {
        ScanDiagnosticsButton(report: previewReport())
            .padding()
    }

#endif
