import SwiftUI
import WidgetKit

/// Home Screen / Lock Screen balance widget. Reads the watch-only App
/// Group snapshot the Messages extension publishes — no keys, no network
/// calls of its own, honest "as of" freshness.
@main
struct WalletWidgetBundle: WidgetBundle {
    var body: some Widget {
        WalletWidget()
    }
}

struct WalletWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OrangeBubblesBalance", provider: SnapshotProvider()) { entry in
            WalletWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Bitcoin Balance")
        .description("Your OrangeBubbles balance and latest activity.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular])
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: SharedSnapshot.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: SharedSnapshot.load())
        // The extension pokes WidgetCenter on every wallet refresh; this
        // interval is just a staleness backstop.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

extension SharedSnapshot {
    static let placeholder = SharedSnapshot(
        balanceSats: 21_000,
        pendingSats: 0,
        recent: [],
        network: "bitcoin",
        upcomingReceiveAddresses: [],
        usdPerBTC: nil,
        updatedAt: Date()
    )
}

struct WalletWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private let orange = Color(red: 0.97, green: 0.58, blue: 0.10)

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryInline:
                Text("₿ \(snapshot.balanceLine)")
                    .privacySensitive()
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text("OrangeBubbles")
                        .font(.caption2.weight(.semibold))
                    Text(snapshot.balanceLine)
                        .font(.headline)
                        .privacySensitive()
                    if snapshot.pendingSats > 0 {
                        Text("\(SharedSnapshot.formatSats(snapshot.pendingSats)) pending")
                            .font(.caption2)
                            .privacySensitive()
                    }
                }
            default:
                homeScreenBody(snapshot)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "bitcoinsign.circle.fill")
                    .font(.title2)
                    .foregroundStyle(orange)
                Text("Open OrangeBubbles in Messages to set up")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private func homeScreenBody(_ snapshot: SharedSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "bitcoinsign.circle.fill")
                    .foregroundStyle(orange)
                Text("Balance")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if snapshot.network != "bitcoin" {
                    Text(snapshot.network.uppercased())
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.purple)
                }
            }

            Text(snapshot.balanceLine)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .minimumScaleFactor(0.6)
                .privacySensitive()

            if let usd = snapshot.usdLine {
                Text("≈ \(usd)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .privacySensitive()
            }

            if family == .systemMedium, !snapshot.recent.isEmpty {
                Divider()
                ForEach(snapshot.recent.prefix(2)) { activity in
                    HStack(spacing: 4) {
                        Image(systemName: activity.incoming ? "arrow.down.left" : "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(activity.incoming ? .green : orange)
                        Text(activity.incoming ? "Received" : "Sent")
                            .font(.caption2)
                        Spacer()
                        Text("\(activity.incoming ? "+" : "−")\(SharedSnapshot.formatSats(activity.amountSats))")
                            .font(.caption2.weight(.semibold))
                            .privacySensitive()
                        if !activity.confirmed {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(orange)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Text("as of \(entry.snapshot?.updatedAt.formatted(date: .omitted, time: .shortened) ?? "—")")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .padding(2)
    }
}
