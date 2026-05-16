//
//  ReportProblemSheet.swift
//  WorkHaven
//

import SwiftUI

struct ReportProblemSheet: View {
    let spotName: String
    let allowsWebResearch: Bool
    let onResearch: (() async throws -> Void)?
    let onSubmit: (SpotProblemCategory, String) async throws -> Void
    let onCancel: () -> Void

    @State private var selectedCategory: SpotProblemCategory = .outletsListedButNone
    @State private var customDetails = ""
    @State private var isSubmitting = false
    @State private var isResearching = false
    @State private var researchSuccessMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if allowsWebResearch {
                    Section {
                        Text(
                            "Something look off? You can refresh WiFi, noise, outlets, and the spot summary from web sources before you submit a report."
                        )
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)

                        Button {
                            Task { await runResearch() }
                        } label: {
                            HStack(spacing: ThemeManager.Spacing.sm) {
                                if isResearching {
                                    ProgressView()
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(isResearching ? "Researching…" : "Update from web (AI)")
                                    .font(ThemeManager.SwiftUIFonts.body)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(ThemeManager.SwiftUIColors.coral)
                        .disabled(isResearching || isSubmitting || onResearch == nil)

                        if let researchSuccessMessage {
                            Label(researchSuccessMessage, systemImage: "checkmark.circle.fill")
                                .font(ThemeManager.SwiftUIFonts.caption)
                                .foregroundColor(ThemeManager.SwiftUIColors.coral)
                        }
                    } header: {
                        Text("Before you report")
                    } footer: {
                        Text("Web research updates amenities on this listing. Star ratings always come from community reviews.")
                    }
                }

                Section {
                    Text("Tell us what is still incorrect for \(spotName) after you have checked the listing.")
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                }

                Section("What's wrong?") {
                    Picker("Problem type", selection: $selectedCategory) {
                        ForEach(SpotProblemCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section(selectedCategory == .other ? "Describe the problem" : "Additional details (optional)") {
                    TextField(
                        selectedCategory == .other ? "Describe the issue…" : "Add more context…",
                        text: $customDetails,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(ThemeManager.SwiftUIFonts.caption)
                    }
                }
            }
            .navigationTitle("Report a Problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSubmitting || isResearching)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || isResearching || !canSubmit)
                }
            }
        }
    }

    private var canSubmit: Bool {
        if selectedCategory == .other {
            return !customDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    @MainActor
    private func runResearch() async {
        guard let onResearch else { return }
        isResearching = true
        errorMessage = nil
        researchSuccessMessage = nil
        defer { isResearching = false }

        do {
            try await onResearch()
            researchSuccessMessage = "Listing updated from web sources. Close this sheet to see changes, or submit a report if something is still wrong."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let details = customDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await onSubmit(selectedCategory, details)
            onCancel()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
