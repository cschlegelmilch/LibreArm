import SwiftUI

struct WeightView: View {
    @EnvironmentObject private var scale: QardioBaseClient
    @EnvironmentObject private var health: Health
    @AppStorage("autoSaveWeightToHealth") private var autoSaveWeightToHealth = true

    // `scaleOwnerUserID` / `lastSavedScaleResultID` use SwiftUI's Optional<String>-backed
    // `@AppStorage` support: `nil` means "unset" (no owner assigned yet / nothing saved yet),
    // rather than an empty-string sentinel.
    @AppStorage("scaleOwnerUserID") private var scaleOwnerUserID: String?
    @AppStorage("lastSavedScaleResultID") private var lastSavedScaleResultID: String?

    var body: some View {
        NavigationStack {
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .toolbar(.hidden, for: .navigationBar)
            // No .onChange(of: scale.lastReading) here: the save attempt (owner
            // assignment, QardioBaseClient.shouldSave, health.record, updating
            // lastSavedScaleResultID) now runs unconditionally from the root-level
            // QardioBaseClient.onNewReading callback wired in ContentView.configure(),
            // via WeightSaveGate.run — so it fires even if this view is never mounted.
            // Everything this view still needs (the owner-mismatch notice and the
            // reassign control) is purely computed from `scale.lastReading` and the
            // same @AppStorage-backed `scaleOwnerUserID`/`lastSavedScaleResultID`, so it
            // stays in sync with what the root callback just decided without any
            // imperative hook here.
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            header
            status
            readingCard
            settings
            healthAuthorizationStatus
            healthStatus
            recovery
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        Text("LibreArm: Weight")
            .font(.title2.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isConnected: Bool {
        scale.connectionState == .preparing || scale.connectionState == .ready
    }

    private var statusLine: String {
        switch scale.connectionState {
        case .unavailable: return "Bluetooth unavailable"
        case .searching: return "Searching for scale…"
        case .connecting: return "Connecting…"
        case .preparing: return "Connected — preparing…"
        case .disconnected: return "Disconnected"
        case let .failed(message): return message
        case .ready:
            switch scale.scaleState {
            case .unknown: return "Connected — step on the scale"
            case .configMode: return "Scale is in configuration mode"
            case .weighing: return "Weighing…"
            case .resultReady: return "Reading result…"
            }
        }
    }

    private var status: some View {
        Text(statusLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(2)
    }

    /// True only when the last reading belongs to a profile other than the assigned
    /// owner — distinct from a dedup skip (an already-saved reading from the owner),
    /// which `shouldSave` also rejects but which should show no mismatch notice.
    private var isOwnerMismatch: Bool {
        guard let reading = scale.lastReading, let owner = scaleOwnerUserID else { return false }
        return reading.userID != owner
    }

    private var readingCard: some View {
        let reading = scale.lastReading
        return VStack(spacing: 7) {
            Text(reading.map { "\($0.weightKg.formatted(.number.precision(.fractionLength(1)))) kg" } ?? "— kg")
                .font(.title2.bold())

            if let reading, hasComposition(reading) {
                compositionRows(reading)
            }

            if isOwnerMismatch, let reading {
                ownerMismatchNotice(reading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func hasComposition(_ reading: WeightReading) -> Bool {
        reading.bmi != nil || reading.fatPercent != nil || reading.tbwPercent != nil || reading.bmcKg != nil || reading.smPercent != nil
    }

    private func compositionRows(_ reading: WeightReading) -> some View {
        VStack(spacing: 4) {
            if let bmi = reading.bmi {
                compositionRow("BMI", String(format: "%.1f", bmi))
            }
            if let fatPercent = reading.fatPercent {
                compositionRow("Body Fat", String(format: "%.1f%%", fatPercent))
            }
            if let leanBodyMassKg = reading.leanBodyMassKg {
                compositionRow("Lean Mass", String(format: "%.1f kg", leanBodyMassKg))
            }
            if let tbwPercent = reading.tbwPercent {
                compositionRow("Body Water", String(format: "%.1f%%", tbwPercent))
            }
            if let bmcKg = reading.bmcKg {
                compositionRow("Bone Mass", String(format: "%.1f kg", bmcKg))
            }
            if let smPercent = reading.smPercent {
                compositionRow("Skeletal Muscle", String(format: "%.1f%%", smPercent))
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func compositionRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
        }
    }

    private func ownerMismatchNotice(_ reading: WeightReading) -> some View {
        VStack(spacing: 6) {
            Label("Weigh-in from a different scale profile — not saved", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
            // Reassigning to `nil` as "owner" would mean "accept everyone", which isn't
            // the intent, so the control is hidden whenever the reading itself carries no
            // profile id.
            if reading.userID != nil {
                Button("Use this profile instead") {
                    scaleOwnerUserID = reading.userID
                    Task { @MainActor in
                        await WeightSaveGate.run(
                            reading,
                            health: health,
                            autoSaveEnabled: autoSaveWeightToHealth
                        )
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var settings: some View {
        GroupBox("Weight settings") {
            Toggle("Save to Apple Health", isOn: $autoSaveWeightToHealth)
        }
        .font(.subheadline)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var healthAuthorizationStatus: some View {
        switch health.authorizationState {
        case .notRequested, .ready:
            EmptyView()
        case .requesting:
            Label("Requesting Apple Health access…", systemImage: "heart.text.square")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var healthStatus: some View {
        switch health.weightSaveState {
        case .idle: EmptyView()
        case .saving: Label("Saving to Apple Health…", systemImage: "arrow.triangle.2.circlepath").font(.caption)
        case .saved: Label("Saved to Apple Health", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case let .partiallySaved(message), let .failed(message), let .skipped(message):
            Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var recovery: some View {
        if !isConnected {
            Button("Retry Connection") { scale.startConnect(timeout: 30) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
