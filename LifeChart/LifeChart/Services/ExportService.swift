import SwiftUI

/// Exports for the user's psychiatrist, GP or care team.
@MainActor
enum ExportService {
    static func pdf(data: ChartData, range: ChartRange) -> URL? {
        let page = VStack(alignment: .leading, spacing: 16) {
            Text("Life Chart").font(.largeTitle.bold())
            Text("\(data.domain.lowerBound.formatted(date: .long, time: .omitted)) – \(Date.now.formatted(date: .long, time: .omitted))")
                .foregroundStyle(.secondary)
            SummaryTiles(data: data)
            LifeChartView(data: data, range: range)
            MoodLegend()
            Text("Mood rated with the NIMH Life Chart Method (−4 severe depression … +4 severe mania). Watch data from Garmin.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 842)
        .background(.white)
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: page)
        renderer.proposedSize = .init(width: 842, height: nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LifeChart.pdf")
        var succeeded = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            draw(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
            succeeded = true
        }
        return succeeded ? url : nil
    }

    static func csv(entries: [DayEntry], wearables: [WearableDay], medications: [Medication], events: [LifeEvent]) -> URL? {
        let names = Dictionary(medications.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let watch = Dictionary(wearables.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
        var eventsByDay: [String: [String]] = [:]
        for event in events where !event.isRemoved { eventsByDay[event.dateKey, default: []].append(event.title) }
        let byDay = Dictionary(entries.filter { !$0.isRemoved }.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
        let days = Set(byDay.keys).union(watch.keys).union(eventsByDay.keys).sorted()

        var rows = [[
            "date", "mood_level", "self_rating", "mixed", "mood_switches", "sleep_hours", "anxiety",
            "irritability", "menstruating", "weight", "medications", "life_events", "watch_sleep_hours",
            "sleep_score", "resting_hr", "hrv", "stress_avg", "body_battery_high", "steps", "notes",
        ]]
        for day in days {
            let entry = byDay[day]
            let wearable = watch[day]
            let doses = entry?.doses.map { "\(names[$0.medicationId] ?? "?") \($0.amount.formatted())" }
                .joined(separator: "; ") ?? ""
            rows.append([
                day,
                entry?.moodLevel.map(String.init) ?? "",
                entry?.moodRating.map { String(Int($0)) } ?? "",
                entry.map { $0.mixed ? "yes" : "" } ?? "",
                entry.map { String($0.moodSwitches) } ?? "",
                entry?.sleepHours.map { String($0) } ?? "",
                entry.map { String($0.anxiety) } ?? "",
                entry.map { String($0.irritability) } ?? "",
                entry.map { $0.menstruating ? "yes" : "" } ?? "",
                entry?.weight.map { String($0) } ?? "",
                doses,
                eventsByDay[day]?.joined(separator: "; ") ?? "",
                wearable?.sleepHours.map { String($0) } ?? "",
                wearable?.sleepScore.map(String.init) ?? "",
                wearable?.restingHeartRate.map(String.init) ?? "",
                wearable?.hrv.map(String.init) ?? "",
                wearable?.stressAvg.map(String.init) ?? "",
                wearable?.bodyBatteryHigh.map(String.init) ?? "",
                wearable?.steps.map(String.init) ?? "",
                entry?.notes ?? "",
            ])
        }
        let text = rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LifeChart.csv")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Quotes a CSV field and neutralises spreadsheet formulas.
    private static func field(_ value: String) -> String {
        var value = value
        if let first = value.first, "=+-@\t\r".contains(first), Double(value) == nil {
            value = "'" + value
        }
        if value.contains(where: { ",\"\n\r".contains($0) }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

struct MoodLegend: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(MoodLevel.descending) { level in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(level.color).frame(width: 14, height: 14)
                    Text("\(level.rawValue > 0 ? "+" : "")\(level.rawValue) \(level.title)").font(.caption)
                }
            }
        }
    }
}
