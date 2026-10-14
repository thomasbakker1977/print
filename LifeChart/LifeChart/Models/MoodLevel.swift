import SwiftUI

/// The nine levels of the NIMH Life Chart Method, rated by how much the mood
/// interferes with daily functioning.
enum MoodLevel: Int, CaseIterable, Identifiable {
    case severeHighDepression = -4
    case severeLowDepression = -3
    case moderateDepression = -2
    case mildDepression = -1
    case balanced = 0
    case mildElevation = 1
    case moderateMania = 2
    case severeLowMania = 3
    case severeHighMania = 4

    var id: Int { rawValue }

    /// Top of the chart first.
    static var descending: [MoodLevel] { allCases.reversed() }

    var title: String {
        switch self {
        case .severeHighDepression: "Severe depression (high)"
        case .severeLowDepression: "Severe depression (low)"
        case .moderateDepression: "Moderate depression"
        case .mildDepression: "Mild depression"
        case .balanced: "Balanced"
        case .mildElevation: "Mild elevation"
        case .moderateMania: "Moderate mania"
        case .severeLowMania: "Severe mania (low)"
        case .severeHighMania: "Severe mania (high)"
        }
    }

    var impairment: String {
        switch abs(rawValue) {
        case 0: "Mood within your normal range."
        case 1: "Noticeable mood change, little or no impact on functioning."
        case 2: "Functioning with some difficulty in work, home or social roles."
        case 3: "Great difficulty functioning; usual roles are hard to keep up."
        default: "Unable to function in usual roles; may need intensive care."
        }
    }

    var color: Color {
        switch self {
        case .severeHighDepression: Color(red: 0.12, green: 0.24, blue: 0.60)
        case .severeLowDepression: Color(red: 0.22, green: 0.42, blue: 0.80)
        case .moderateDepression: Color(red: 0.40, green: 0.60, blue: 0.90)
        case .mildDepression: Color(red: 0.62, green: 0.78, blue: 0.95)
        case .balanced: Color(red: 0.60, green: 0.63, blue: 0.65)
        case .mildElevation: Color(red: 1.00, green: 0.78, blue: 0.45)
        case .moderateMania: Color(red: 0.98, green: 0.60, blue: 0.25)
        case .severeLowMania: Color(red: 0.92, green: 0.38, blue: 0.18)
        case .severeHighMania: Color(red: 0.78, green: 0.15, blue: 0.12)
        }
    }
}

enum Severity {
    static let labels = ["None", "Mild", "Moderate", "Severe"]
}

enum Palette {
    static let medication: [Color] = [.purple, .teal, .pink, .indigo, .brown, .mint, .orange, .cyan]

    static func medication(_ index: Int) -> Color {
        medication[((index % medication.count) + medication.count) % medication.count]
    }
}
