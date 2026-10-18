import XCTest
@testable import HouseholdCore

final class HouseholdCoreTests: XCTestCase {
    func testMoneyUsesExactCentsAndRejectsPartialParses() {
        let locale = Locale(identifier:"en_CA")
        XCTAssertEqual(MoneyAmount.cents("89.99",locale:locale),8999)
        XCTAssertEqual(MoneyAmount.cents("0.01",locale:locale),1)
        XCTAssertEqual(MoneyAmount.cents("12",locale:locale),1200)
        XCTAssertNil(MoneyAmount.cents("12abc",locale:locale))
        XCTAssertNil(MoneyAmount.cents("1e3",locale:locale))
        XCTAssertNil(MoneyAmount.cents("12.999",locale:locale))
        XCTAssertNil(MoneyAmount.cents("0",locale:locale))
        XCTAssertNil(MoneyAmount.cents("-1",locale:locale))
        XCTAssertNil(MoneyAmount.cents("1000000.01",locale:locale))
        XCTAssertEqual(MoneyAmount.cents("12,50",locale:Locale(identifier:"fr_CA")),1250)
    }
    func testSparsePayloadsDecodeWithoutLosingDefaults() throws {
        let fields = try SharedCoding.decoder().decode(SharedFields.self,from:Data(#"{"title":"Milk"}"#.utf8))
        XCTAssertEqual(fields.title,"Milk")
        XCTAssertFalse(fields.completed)
        XCTAssertEqual(fields.repeatRule,.none)
        XCTAssertTrue(fields.shares.isEmpty)
    }
    func testSharedRecordsRoundTripExactAmountsAndDates() throws {
        let date = Date(timeIntervalSince1970:1_800_000_000)
        var fields = SharedFields(title:"Rent")
        fields.amountCents = 123_456
        fields.dueAt = date
        fields.repeatRule = .monthly
        let record = SharedRecord(id:UUID(),householdID:UUID(),kind:.bill,payload:fields,version:8,deleted:false,updatedBy:nil,updatedAt:date)
        let bytes = try SharedCoding.encoder().encode(record)
        let decoded = try SharedCoding.decoder().decode(SharedRecord.self,from:bytes)
        XCTAssertEqual(decoded,record)
    }
    func testFractionalPostgresDatesDecode() throws {
        let data = Data(#"{"title":"Filter","dueAt":"2026-10-18T09:30:00.123456+00:00"}"#.utf8)
        let fields = try SharedCoding.decoder().decode(SharedFields.self,from:data)
        XCTAssertNotNil(fields.dueAt)
    }
    func testCalendarExportEscapesInjectedLinesAndFoldsUnicode() {
        var fields = SharedFields(title:"A task; with commas, and a newline\nEND:VEVENT")
        fields.dueAt = Date(timeIntervalSince1970:1_800_000_000)
        fields.notes = String(repeating:"é",count:100)
        let record = SharedRecord(id:UUID(),householdID:UUID(),kind:.task,payload:fields,version:1,deleted:false,updatedBy:nil,updatedAt:Date())
        let text = String(decoding:CalendarSnapshot.data(records:[record]),as:UTF8.self)
        XCTAssertTrue(text.contains("\\nEND:VEVENT"))
        XCTAssertEqual(text.components(separatedBy:"\r\n").filter { $0 == "END:VEVENT" }.count,1)
        XCTAssertTrue(text.components(separatedBy:"\r\n").allSatisfy { $0.utf8.count<=75 })
    }
}
