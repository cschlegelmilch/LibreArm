@preconcurrency import CoreBluetooth
import Foundation

enum ScaleState: Equatable {
    case unknown, configMode, weighing, resultReady
}

@MainActor
final class QardioBaseClient: NSObject, ObservableObject {
    @Published private(set) var connectionState: ConnectionState = .searching
    @Published private(set) var scaleState: ScaleState = .unknown
    @Published private(set) var lastReading: WeightReading?

    /// Fired every time `lastReading` is set to a freshly parsed result, in addition to
    /// (not instead of) the `@Published` update. `lastReading` only notifies views that are
    /// actually mounted (e.g. `WeightView`), but `startConnect()` is invoked unconditionally
    /// from the root `ContentView` launch task for both tabs, so a weigh-in can complete
    /// before the user has ever opened the Weight tab. This callback lets the root view wire
    /// up the save gate independent of whether `WeightView` exists yet — mirroring how
    /// `BPClient.onFinalReading` already solves the same problem for blood pressure.
    var onNewReading: ((WeightReading) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var stateChar: CBCharacteristic?
    private var resultChar: CBCharacteristic?
    private var engineeringChar: CBCharacteristic?
    private var stateNotifyReady = false
    private var engineeringNotifyReady = false
    private var awaitingRetryResult = false

    private let qardioBaseService = CBUUID(string: "C8219E89-93E0-4169-A3DC-EA7959E866AF")
    private let state = CBUUID(string: "A78AF805-8F3F-4E8F-A964-318B768BC38C")
    private let result = CBUUID(string: "B24F98BE-9CD4-4F82-B935-01F18F104EDE")
    private let engineering = CBUUID(string: "9F3F4E1B-37D7-4F95-B374-CF585D808BEB")

    private var connectionID = UUID()
    private var connectTask: DispatchWorkItem?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startConnect(timeout: TimeInterval = 30) {
        guard central.state == .poweredOn else { connectionState = .unavailable; return }
        let previousPeripheral = peripheral
        if let previousPeripheral {
            central.cancelPeripheralConnection(previousPeripheral)
        }
        clearDevice()
        connectionID = UUID()
        let id = connectionID
        connectionState = .searching
        central.scanForPeripherals(withServices: [qardioBaseService])
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.connectionID == id, self.connectionState != .ready else { return }
            self.central.stopScan()
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.clearDevice()
            self.connectionState = .failed("Connection timed out. Check the scale is awake and nearby.")
        }
        connectTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: task)
    }

    private func write(_ data: Data, characteristic: CBCharacteristic, peripheral: CBPeripheral) {
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    private func timestampPayload(date: Date = Date()) -> Data {
        var payload = Data([0x00, 0x00, 0x0C])
        let epochSeconds = UInt32(date.timeIntervalSince1970)
        withUnsafeBytes(of: epochSeconds.littleEndian) { payload.append(contentsOf: $0) }
        return payload
    }

    private func beginHandshake() {
        guard let peripheral, let engineeringChar, let stateChar else { return }
        write(timestampPayload(), characteristic: engineeringChar, peripheral: peripheral)
        peripheral.readValue(for: stateChar)
    }

    private func updateReadiness() {
        guard stateChar != nil, resultChar != nil, engineeringChar != nil,
              stateNotifyReady, engineeringNotifyReady,
              connectionState != .ready else { return }
        connectTask?.cancel(); connectTask = nil
        connectionState = .ready
        beginHandshake()
    }

    private func handleStateByte(_ byte: UInt8) {
        scaleState = Self.scaleState(fromStateByte: byte)
        if scaleState == .resultReady {
            readResult()
        }
    }

    private func readResult(isRetry: Bool = false) {
        guard let peripheral, let resultChar else { return }
        awaitingRetryResult = isRetry
        peripheral.readValue(for: resultChar)
    }

    private func handleResultData(_ data: Data) {
        let wasRetry = awaitingRetryResult
        let id = connectionID
        do {
            let reading = try QardioBaseResultParser.parse(data)
            lastReading = reading
            onNewReading?(reading)
        } catch QardioBaseParseError.emptyPayload {
            guard !wasRetry else {
                connectionState = .failed("The scale result was empty. Step on the scale again, then reconnect.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.connectionID == id else { return }
                self.readResult(isRetry: true)
            }
        } catch {
            connectionState = .failed("The scale sent an unreadable result. Please try again.")
        }
    }

    private func clearDevice() {
        connectTask?.cancel(); connectTask = nil
        stateChar = nil; resultChar = nil; engineeringChar = nil
        stateNotifyReady = false; engineeringNotifyReady = false
        awaitingRetryResult = false
        peripheral = nil
        scaleState = .unknown
    }

    private func recoveryMessage(_ error: Error) -> String {
        if Self.isPairingATTError(error) {
            return "Pairing needs attention. Reset the scale, forget QardioBase in iPhone Bluetooth settings if listed, then reconnect here."
        }
        return "Scale command failed: \(error.localizedDescription)"
    }

    static func isPairingATTError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let pairingCodes: Set<Int> = [0x05, 0x08, 0x0C, 0x0F]
        return nsError.domain == CBATTErrorDomain && pairingCodes.contains(nsError.code)
    }

    static func scaleState(fromStateByte byte: UInt8) -> ScaleState {
        switch byte {
        case 1: return .configMode
        case 3: return .weighing
        case 6: return .resultReady
        default: return .unknown
        }
    }

    nonisolated static func shouldSave(_ reading: WeightReading, ownerUserID: String?, lastSavedID: String?) -> Bool {
        guard reading.resultID != lastSavedID else { return false }
        guard let ownerUserID else { return true }
        return reading.userID == ownerUserID
    }

    /// Pure decision for the weight-save gate: resolves the first-seen-becomes-owner
    /// assignment (if no owner is assigned yet, this reading's profile becomes the owner)
    /// *before* evaluating `shouldSave` — the same ordering that used to live inline in
    /// `WeightView`'s `.onChange`, now kept side-effect-free and unit-testable without
    /// `UserDefaults`/`@AppStorage`.
    nonisolated static func weightSaveGateDecision(
        for reading: WeightReading,
        ownerUserID: String?,
        lastSavedID: String?
    ) -> (resolvedOwnerUserID: String?, shouldSave: Bool) {
        let resolvedOwnerUserID = ownerUserID ?? reading.userID
        let shouldSave = Self.shouldSave(reading, ownerUserID: resolvedOwnerUserID, lastSavedID: lastSavedID)
        return (resolvedOwnerUserID, shouldSave)
    }
}

/// Runs the full weight-save gate outside of any View: first-seen owner assignment,
/// `QardioBaseClient.shouldSave`, `Health.record`, and the `lastSavedScaleResultID` update.
/// Used by the root-level `QardioBaseClient.onNewReading` callback (wired in
/// `ContentView.configure()`, so saving no longer depends on `WeightView` being mounted) and
/// by `WeightView`'s "Use this profile instead" reassignment action (so reassigning the owner
/// immediately saves the reading it was shown for).
@MainActor
enum WeightSaveGate {
    /// Matches the exact `@AppStorage` keys `WeightView` uses, so both stay in sync.
    static let ownerDefaultsKey = "scaleOwnerUserID"
    static let lastSavedDefaultsKey = "lastSavedScaleResultID"

    static func run(
        _ reading: WeightReading,
        health: Health,
        autoSaveEnabled: Bool,
        defaults: UserDefaults = .standard
    ) async {
        let ownerUserID = defaults.string(forKey: ownerDefaultsKey)
        let lastSavedID = defaults.string(forKey: lastSavedDefaultsKey)

        let decision = QardioBaseClient.weightSaveGateDecision(
            for: reading,
            ownerUserID: ownerUserID,
            lastSavedID: lastSavedID
        )

        if decision.resolvedOwnerUserID != ownerUserID {
            defaults.set(decision.resolvedOwnerUserID, forKey: ownerDefaultsKey)
        }

        guard decision.shouldSave else { return }

        let outcome = await health.record(reading, enabled: autoSaveEnabled)
        if outcome.weightSaved {
            defaults.set(reading.resultID, forKey: lastSavedDefaultsKey)
        }
    }
}

extension QardioBaseClient: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            clearDevice()
            connectionState = .unavailable
            return
        }
        if connectionState == .unavailable { startConnect() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard connectionState == .searching else { return }
        central.stopScan(); connectionState = .connecting
        peripheral = p; p.delegate = self; central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p == peripheral else { return }
        connectionState = .preparing
        p.discoverServices([qardioBaseService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p == peripheral else { return }
        clearDevice()
        connectionState = .failed(error.map { "Connection failed: \($0.localizedDescription)" } ?? "Connection failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p == peripheral else { return }
        clearDevice()
        connectionState = .disconnected
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p == peripheral else { return }
        if let error { connectionState = .failed("Service discovery failed: \(error.localizedDescription)"); return }
        for service in p.services ?? [] where service.uuid == qardioBaseService {
            p.discoverCharacteristics([state, result, engineering], for: service)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p == peripheral else { return }
        if let error { connectionState = .failed("Device setup failed: \(error.localizedDescription)"); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == state {
                stateChar = characteristic; p.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == result {
                resultChar = characteristic
            } else if characteristic.uuid == engineering {
                engineeringChar = characteristic; p.setNotifyValue(true, for: characteristic)
            }
        }
        updateReadiness()
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard p == peripheral, characteristic.uuid == state || characteristic.uuid == engineering else { return }
        if let error {
            central.cancelPeripheralConnection(p)
            clearDevice()
            connectionState = .failed(recoveryMessage(error))
            return
        }
        if characteristic.uuid == state {
            stateNotifyReady = characteristic.isNotifying
        } else {
            engineeringNotifyReady = characteristic.isNotifying
        }
        updateReadiness()
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard p == peripheral, characteristic.uuid == engineering, let error else { return }
        connectionState = .failed(recoveryMessage(error))
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard p == peripheral else { return }
        if let error {
            if characteristic.uuid == state || characteristic.uuid == result {
                connectionState = .failed(recoveryMessage(error))
            }
            return
        }
        guard let data = characteristic.value else { return }
        if characteristic.uuid == state, let byte = data.first {
            handleStateByte(byte)
        } else if characteristic.uuid == result {
            handleResultData(data)
        }
    }
}
