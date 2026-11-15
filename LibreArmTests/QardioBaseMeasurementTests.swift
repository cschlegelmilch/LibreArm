import XCTest
import HealthKit
@testable import LibreArm

final class QardioBaseMeasurementTests: XCTestCase {
    func testParsesFullPayloadWithComposition() throws {
        let json = #"{"weight":"82.4","bmi":"26.1","fat":"24.3","tbw":"55.0","bmc":"3.1","sm":"44.2","mt":"1","userid":"7","id":"00001763212800"}"#
        let reading = try QardioBaseResultParser.parse(Data((json + "\0\0\0").utf8))
        XCTAssertEqual(reading.weightKg, 82.4)
        XCTAssertEqual(reading.fatPercent, 24.3)
        XCTAssertEqual(reading.userID, "7")
        XCTAssertEqual(reading.resultID, "00001763212800")
        XCTAssertEqual(reading.date, Date(timeIntervalSince1970: 1763212800))
    }

    func testLeanBodyMassDerivesFromFatPercent() throws {
        let json = #"{"weight":"80","fat":"25","id":"1763212800"}"#
        let reading = try QardioBaseResultParser.parse(Data(json.utf8))
        XCTAssertEqual(try XCTUnwrap(reading.leanBodyMassKg), 60, accuracy: 0.01)
    }

    func testParsesWeightOnlyPayloadWithoutComposition() throws {
        let json = #"{"weight":"80.0","id":"1763212800"}"#
        let reading = try QardioBaseResultParser.parse(Data(json.utf8))
        XCTAssertNil(reading.fatPercent)
        XCTAssertNil(reading.leanBodyMassKg)
    }

    func testRejectsEmptyPayload() {
        XCTAssertThrowsError(try QardioBaseResultParser.parse(Data("\0\0\0".utf8))) { error in
            XCTAssertEqual(error as? QardioBaseParseError, .emptyPayload)
        }
    }

    func testRejectsNonJSONPayload() {
        XCTAssertThrowsError(try QardioBaseResultParser.parse(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? QardioBaseParseError, .invalidJSON)
        }
    }

    func testRejectsMissingWeight() {
        XCTAssertThrowsError(try QardioBaseResultParser.parse(Data(#"{"id":"1763212800"}"#.utf8))) { error in
            XCTAssertEqual(error as? QardioBaseParseError, .missingWeight)
        }
    }

    func testRejectsMissingID() {
        XCTAssertThrowsError(try QardioBaseResultParser.parse(Data(#"{"weight":"80"}"#.utf8))) { error in
            XCTAssertEqual(error as? QardioBaseParseError, .missingID)
        }
    }

    func testShouldSaveOwnerFirstResult() {
        let reading = WeightReading(weightKg: 80, bmi: nil, fatPercent: nil, tbwPercent: nil, bmcKg: nil, smPercent: nil, mt: nil, userID: "7", resultID: "A", date: .now)
        XCTAssertTrue(QardioBaseClient.shouldSave(reading, ownerUserID: nil, lastSavedID: nil))
    }

    func testShouldSaveRejectsNonOwnerProfile() {
        let reading = WeightReading(weightKg: 80, bmi: nil, fatPercent: nil, tbwPercent: nil, bmcKg: nil, smPercent: nil, mt: nil, userID: "9", resultID: "A", date: .now)
        XCTAssertFalse(QardioBaseClient.shouldSave(reading, ownerUserID: "7", lastSavedID: nil))
    }

    func testShouldSaveRejectsAlreadySavedResultAcrossRelaunch() {
        let reading = WeightReading(weightKg: 80, bmi: nil, fatPercent: nil, tbwPercent: nil, bmcKg: nil, smPercent: nil, mt: nil, userID: "7", resultID: "A", date: .now)
        XCTAssertFalse(QardioBaseClient.shouldSave(reading, ownerUserID: "7", lastSavedID: "A"))
    }

    func testShouldSaveAcceptsOwnersNewResult() {
        let reading = WeightReading(weightKg: 80, bmi: nil, fatPercent: nil, tbwPercent: nil, bmcKg: nil, smPercent: nil, mt: nil, userID: "7", resultID: "B", date: .now)
        XCTAssertTrue(QardioBaseClient.shouldSave(reading, ownerUserID: "7", lastSavedID: "A"))
    }
}

@MainActor
final class HealthWeightTests: XCTestCase {
    func testSavesWeightOnlyWhenNoComposition() async {
        let reading = WeightReading(weightKg: 80, bmi: nil, fatPercent: nil, tbwPercent: nil, bmcKg: nil, smPercent: nil, mt: nil, userID: "7", resultID: "A", date: .now)
        let store = FakeHealthStore()
        let health = Health(store: store)
        let outcome = await health.save(reading)
        XCTAssertTrue(outcome.message.contains("Saved"))
        XCTAssertTrue(outcome.weightSaved)
        XCTAssertNil(outcome.compositionSaved)
        XCTAssertEqual(store.savedObjects.count, 1)
        XCTAssertEqual((store.savedObjects[0] as? HKSample)?.sampleType, HKQuantityType.quantityType(forIdentifier: .bodyMass))
    }

    func testSavesCompositionWhenPresent() async {
        let reading = WeightReading(weightKg: 80, bmi: 26.1, fatPercent: 25, tbwPercent: nil, bmcKg: nil, smPercent: nil, mt: nil, userID: "7", resultID: "A", date: .now)
        let store = FakeHealthStore()
        let health = Health(store: store)
        let outcome = await health.save(reading)
        XCTAssertTrue(outcome.weightSaved)
        XCTAssertEqual(outcome.compositionSaved, true)
        let savedTypes = Set(store.savedObjects.compactMap { ($0 as? HKSample)?.sampleType })
        XCTAssertTrue(savedTypes.contains(HKQuantityType.quantityType(forIdentifier: .bodyMass)!))
        XCTAssertTrue(savedTypes.contains(HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage)!))
        XCTAssertTrue(savedTypes.contains(HKQuantityType.quantityType(forIdentifier: .leanBodyMass)!))
        XCTAssertTrue(savedTypes.contains(HKQuantityType.quantityType(forIdentifier: .bodyMassIndex)!))
        XCTAssertEqual(store.savedObjects.count, 4)
    }

    func testPartialFailureKeepsWeightSaved() async {
        let reading = WeightReading(weightKg: 80, bmi: 26.1, fatPercent: 25, tbwPercent: nil, bmcKg: nil, smPercent: nil, mt: nil, userID: "7", resultID: "A", date: .now)
        let store = FakeHealthStore(failingSampleTypes: [HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage)!])
        let health = Health(store: store)
        let outcome = await health.save(reading)
        XCTAssertTrue(outcome.weightSaved)
        XCTAssertEqual(outcome.compositionSaved, false)
        XCTAssertFalse(outcome.message.contains("Weight was not saved"))
        switch health.weightSaveState {
        case .partiallySaved:
            break
        default:
            XCTFail("Expected partiallySaved, got \(health.weightSaveState)")
        }
        XCTAssertTrue(store.savedObjects.contains { ($0 as? HKSample)?.sampleType == HKQuantityType.quantityType(forIdentifier: .bodyMass) })
    }

    func testDisabledToggleNeverCallsHealthStore() async {
        let reading = WeightReading(weightKg: 80, bmi: nil, fatPercent: nil, tbwPercent: nil, bmcKg: nil, smPercent: nil, mt: nil, userID: "7", resultID: "A", date: .now)
        let store = FakeHealthStore()
        let health = Health(store: store)
        let outcome = await health.record(reading, enabled: false)
        XCTAssertFalse(outcome.weightSaved)
        XCTAssertEqual(store.savedObjects.count, 0)
    }

    func testBodyMassFailureIsFailed() async {
        let reading = WeightReading(weightKg: 80, bmi: nil, fatPercent: nil, tbwPercent: nil, bmcKg: nil, smPercent: nil, mt: nil, userID: "7", resultID: "A", date: .now)
        let store = FakeHealthStore(failingSampleTypes: [HKQuantityType.quantityType(forIdentifier: .bodyMass)!])
        let health = Health(store: store)
        let outcome = await health.save(reading)
        XCTAssertFalse(outcome.weightSaved)
        XCTAssertNil(outcome.compositionSaved)
        switch health.weightSaveState {
        case .failed:
            break
        default:
            XCTFail("Expected failed, got \(health.weightSaveState)")
        }
    }
}
