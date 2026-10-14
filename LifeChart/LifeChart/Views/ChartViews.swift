import Charts
import SwiftData
import SwiftUI

enum ChartRange: String, CaseIterable, Identifiable {
    case month = "1M", quarter = "3M", half = "6M", year = "1Y"

    var id: String { rawValue }

    var days: Int {
        switch self {
        case .month: 30
        case .quarter: 91
        case .half: 182
        case .year: 365
        }
    }

    var domain: ClosedRange<Date> {
        let end = Date.now.startOfDay.adding(days: 1)
        return end.adding(days: -days) ... end
    }

    var stride: Calendar.Component { self == .month ? .weekOfYear : .month }
}

/// Plain values for the chart, so it can also be rendered for PDF export.
struct ChartData {
    struct Mood: Identifiable {
        var id: Date { day }
        let day: Date
        let level: Int
        let mixed: Bool
    }

    struct Value: Identifiable {
        let id = UUID()
        let day: Date
        let series: String
        let value: Double
    }

    struct Lane: Identifiable {
        let id = UUID()
        let day: Date
        let name: String
        let color: Color
    }

    struct Event: Identifiable {
        let id = UUID()
        let day: Date
        let title: String
        let impact: Int
    }

    var domain: ClosedRange<Date>
    var mood: [Mood] = []
    var sleep: [Value] = []
    var strain: [Value] = []
    var hrv: [Value] = []
    var lanes: [Lane] = []
    var events: [Event] = []
    var notes: [Date: String] = [:]

    init(range: ChartRange, entries: [DayEntry], wearables: [WearableDay], medications: [Medication], events: [LifeEvent]) {
        let domain = range.domain
        self.domain = domain
        func inRange(_ date: Date) -> Bool { domain.contains(date) }
        let medsById = Dictionary(medications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for entry in entries where !entry.isRemoved && inRange(entry.date) {
            if let level = entry.moodLevel {
                mood.append(Mood(day: entry.date, level: level, mixed: entry.mixed))
            }
            if let hours = entry.sleepHours {
                sleep.append(Value(day: entry.date, series: "Self-reported", value: hours))
            }
            for dose in entry.doses {
                if let medication = medsById[dose.medicationId], !medication.isRemoved {
                    lanes.append(Lane(day: entry.date, name: medication.name, color: Palette.medication(medication.colorIndex)))
                }
            }
            if !entry.notes.isEmpty { notes[entry.date] = entry.notes }
        }
        for day in wearables where inRange(day.date) {
            if let hours = day.sleepHours { sleep.append(Value(day: day.date, series: "Watch", value: hours)) }
            if let stress = day.stressAvg { strain.append(Value(day: day.date, series: "Stress", value: Double(stress))) }
            if let battery = day.bodyBatteryHigh {
                strain.append(Value(day: day.date, series: "Body Battery peak", value: Double(battery)))
            }
            if let value = day.hrv { hrv.append(Value(day: day.date, series: "HRV", value: Double(value))) }
        }
        for event in events where !event.isRemoved && inRange(event.date) {
            self.events.append(Event(day: event.date, title: event.title, impact: event.impact))
        }
    }
}

struct ChartScreen: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var sync: SyncService
    @Query(sort: \DayEntry.dayKey) private var entries: [DayEntry]
    @Query(sort: \WearableDay.dayKey) private var wearables: [WearableDay]
    @Query(sort: \Medication.name) private var medications: [Medication]
    @Query(sort: \LifeEvent.dateKey) private var events: [LifeEvent]
    @AppStorage("chartRange") private var range: ChartRange = .quarter
    @State private var export: ExportFile?

    private var data: ChartData {
        ChartData(range: range, entries: entries, wearables: wearables, medications: medications, events: events)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Range", selection: $range) {
                        ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    SummaryTiles(data: data)
                    LifeChartView(data: data, range: range, interactive: true)
                }
                .padding()
            }
            .refreshable { await sync.sync(context) }
            .navigationTitle("Life Chart")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Export PDF", systemImage: "doc.richtext") {
                            export = ExportService.pdf(data: data, range: range).map(ExportFile.init)
                        }
                        Button("Export CSV", systemImage: "tablecells") {
                            export = ExportService.csv(entries: entries, wearables: wearables,
                                                       medications: medications, events: events).map(ExportFile.init)
                        }
                        NavigationLink {
                            MoodGalleryView()
                        } label: {
                            Label("Mood impressions", systemImage: "photo.stack")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(item: $export, onDismiss: ExportService.cleanUp) { file in
                ShareSheet(items: [file.url])
            }
        }
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SummaryTiles: View {
    let data: ChartData

    var body: some View {
        let rated = data.mood.count
        let low = data.mood.filter { $0.level < 0 }.count
        let high = data.mood.filter { $0.level > 0 }.count
        let watchSleep = data.sleep.filter { $0.series == "Watch" }.map(\.value)
        let ownSleep = data.sleep.filter { $0.series == "Self-reported" }.map(\.value)
        let sleep = watchSleep.isEmpty ? ownSleep : watchSleep

        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                tile("Days rated", "\(rated)")
                tile("Low days", rated == 0 ? "—" : "\(low)")
                tile("Elevated days", rated == 0 ? "—" : "\(high)")
                tile("Avg sleep", sleep.isEmpty ? "—" : String(format: "%.1f h", sleep.reduce(0, +) / Double(sleep.count)))
            }
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct LifeChartView: View {
    let data: ChartData
    let range: ChartRange
    var interactive = false
    @State private var selected: Date?

    private var xAxis: some AxisContent {
        AxisMarks(values: .stride(by: range.stride)) { _ in
            AxisGridLine().foregroundStyle(.quaternary)
            AxisValueLabel(format: range == .month ? .dateTime.day().month(.abbreviated) : .dateTime.month(.abbreviated))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            moodChart
            if !data.sleep.isEmpty { sleepChart }
            if !data.strain.isEmpty { strainChart }
            if !data.hrv.isEmpty { hrvChart }
            if !data.lanes.isEmpty { medicationChart }
        }
    }

    // MARK: Mood

    private var moodChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mood").font(.headline)
            Text("▲ elevated · ▼ depressed · height = impact on functioning")
                .font(.caption).foregroundStyle(.secondary)
            Chart {
                RuleMark(y: .value("Balanced", 0)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(data.mood) { point in
                    if point.level == 0 {
                        PointMark(x: .value("Day", point.day, unit: .day), y: .value("Level", 0))
                            .foregroundStyle(MoodLevel.balanced.color)
                            .symbolSize(18)
                    } else {
                        BarMark(x: .value("Day", point.day, unit: .day), y: .value("Level", point.level))
                            .foregroundStyle(MoodLevel(rawValue: point.level)?.color ?? .gray)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    if point.mixed {
                        PointMark(x: .value("Day", point.day, unit: .day), y: .value("Level", point.level > 0 ? point.level : 0))
                            .symbol(.diamond)
                            .symbolSize(30)
                            .foregroundStyle(.primary)
                    }
                }
                ForEach(data.events) { event in
                    RuleMark(x: .value("Event", event.day, unit: .day))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading, spacing: 2,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Label(event.title, systemImage: "flag.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                }
                if let selected, let point = data.mood.first(where: { Calendar.current.isDate($0.day, inSameDayAs: selected) }) {
                    RuleMark(x: .value("Selected", point.day, unit: .day))
                        .foregroundStyle(.primary.opacity(0.3))
                        .annotation(position: .bottom, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            tooltip(for: point)
                        }
                }
            }
            .chartXScale(domain: data.domain)
            .chartYScale(domain: -4 ... 4)
            .chartYAxis {
                AxisMarks(position: .leading, values: [-4, -2, 0, 2, 4]) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let level = value.as(Int.self) { Text(level > 0 ? "+\(level)" : "\(level)") }
                    }
                }
            }
            .chartXAxis { xAxis }
            .chartXSelection(value: interactive ? $selected : .constant(nil))
            .frame(height: 240)
            .padding(.top, data.events.isEmpty ? 0 : 14)
        }
    }

    private func tooltip(for point: ChartData.Mood) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(point.day.formatted(.dateTime.weekday().day().month())).font(.caption.bold())
            Text(MoodLevel(rawValue: point.level)?.title ?? "").font(.caption)
            if point.mixed { Text("Mixed state").font(.caption) }
            if let note = data.notes[point.day] {
                Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(8)
        .frame(maxWidth: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Body signals (one unit per chart, never two y-axes)

    private var sleepChart: some View {
        lineChart(title: "Sleep (hours)", values: data.sleep, yDomain: 0 ... 12,
                  styles: [("Self-reported", .indigo), ("Watch", .teal)])
    }

    private var strainChart: some View {
        lineChart(title: "Stress & Body Battery (0–100)", values: data.strain, yDomain: 0 ... 100,
                  styles: [("Stress", .orange), ("Body Battery peak", .blue)])
    }

    private var hrvChart: some View {
        lineChart(title: "Overnight HRV (ms)", values: data.hrv, yDomain: nil, styles: [("HRV", .purple)])
    }

    private func lineChart(
        title: String, values: [ChartData.Value], yDomain: ClosedRange<Double>?, styles: [(String, Color)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Chart(values) { value in
                LineMark(x: .value("Day", value.day, unit: .day), y: .value(title, value.value))
                    .foregroundStyle(by: .value("Series", value.series))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Day", value.day, unit: .day), y: .value(title, value.value))
                    .foregroundStyle(by: .value("Series", value.series))
                    .symbolSize(range.days <= 31 ? 16 : 0)
            }
            .chartForegroundStyleScale(domain: styles.map { $0.0 }, range: styles.map { $0.1 })
            .chartLegend(styles.count > 1 ? .visible : .hidden)
            .chartXScale(domain: data.domain)
            .chartYScale(domain: yDomain ?? autoDomain(values))
            .chartXAxis { xAxis }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
            .frame(height: 140)
        }
    }

    private func autoDomain(_ values: [ChartData.Value]) -> ClosedRange<Double> {
        let numbers = values.map(\.value)
        let low = (numbers.min() ?? 0) - 5
        let high = (numbers.max() ?? 100) + 5
        return max(0, low) ... max(low + 1, high)
    }

    // MARK: Medication

    private var medicationChart: some View {
        let names = Array(Set(data.lanes.map(\.name))).sorted()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Medication taken").font(.headline)
            Chart(data.lanes) { lane in
                RectangleMark(x: .value("Day", lane.day, unit: .day), y: .value("Medication", lane.name), height: 12)
                    .foregroundStyle(lane.color)
            }
            .chartXScale(domain: data.domain)
            .chartXAxis { xAxis }
            .frame(height: CGFloat(names.count) * 28 + 30)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
