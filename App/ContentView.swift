import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var bp: BPClient
    @EnvironmentObject private var health: Health
    @EnvironmentObject private var coffee: CoffeeSupport
    @EnvironmentObject private var scale: QardioBaseClient
    @State private var showsCoffeeSupport = {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--screenshot-state=coffee")
#else
        false
#endif
    }()
    @AppStorage("autoSaveToHealth") private var autoSaveToHealth = true
    @AppStorage("autoSaveWeightToHealth") private var autoSaveWeightToHealth = true
    @AppStorage("readingCount") private var readingCount = 1
    @AppStorage("delayBetweenRuns") private var delayBetweenRuns = 30.0
    @State private var nextMeasurementIsGuest = {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--screenshot-state=guest")
#else
        false
#endif
    }()

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                BloodPressureView(nextMeasurementIsGuest: $nextMeasurementIsGuest)
                    .tabItem {
                        Label("Blood Pressure", systemImage: "heart.fill")
                    }
                WeightView()
                    .tabItem {
                        Label("Weight", systemImage: "scalemass")
                    }
            }
            footer
        }
        .task { await configure() }
        .sheet(isPresented: $showsCoffeeSupport) {
            CoffeeSupportView(coffee: coffee)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Button {
                showsCoffeeSupport = true
            } label: {
                HStack(spacing: 6) {
                    Text("🫘")
                        .accessibilityHidden(true)
                    Text("Buy LibreArm a coffee")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .accessibilityLabel("Buy LibreArm a coffee")
            .accessibilityHint("Shows an optional one-time Apple purchase")

            HStack(alignment: .center, spacing: 6) {
                Text("Paul Taylor")
                Text("•")
                Link("GitHub: ptylr/LibreArm", destination: URL(string: "https://github.com/ptylr/LibreArm")!)
                    .foregroundStyle(.blue)
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("• v\(version)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func configure() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--screenshot-state=") }) {
            readingCount = 3
            delayBetweenRuns = 30
        }
#endif
        readingCount = min(max(readingCount, 1), 3)
        delayBetweenRuns = min(max(delayBetweenRuns, 15), 60)
        bp.readingCount = readingCount
        bp.delayBetweenRuns = delayBetweenRuns
        await health.requestAuth()
        bp.onFinalReading = { reading, wasGuest in
            Task { @MainActor in
                _ = await health.record(reading, guest: wasGuest, enabled: autoSaveToHealth)
                if wasGuest {
                    nextMeasurementIsGuest = false
                }
            }
        }
        scale.onNewReading = { reading in
            Task { @MainActor in
                await WeightSaveGate.run(
                    reading,
                    health: health,
                    autoSaveEnabled: autoSaveWeightToHealth
                )
            }
        }
        bp.startConnect(timeout: 30)
        scale.startConnect(timeout: 30)
    }
}
