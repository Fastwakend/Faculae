import XCTest
@testable import SeekCore

final class DocumentTextTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
    }
    func testCompressedWordAndOpenDocumentText() throws {
        XCTAssertTrue(try DocumentText.extract(fixture("sample.docx"), filename: "sample.docx").contains("中文文档"))
        XCTAssertTrue(try DocumentText.extract(fixture("sample.odt"), filename: "sample.odt").contains("OpenDocument"))
    }
    func testWorkbookSharedStringsInlineAndNumericCells() throws {
        let text = try DocumentText.extract(fixture("sample.xlsx"), filename: "sample.xlsx")
        XCTAssertTrue(text.contains("姓名\t金额")); XCTAssertTrue(text.contains("张三\t12.50"))
        XCTAssertTrue(text.contains("inline"))
        XCTAssertTrue(text.contains("1\t\tTRUE"), "Sparse Excel cells must keep empty columns and boolean meaning")
    }
    func testPresentationNaturalPageOrder() throws {
        let text = try DocumentText.extract(fixture("sample.pptx"), filename: "sample.pptx")
        XCTAssertLessThan(text.range(of: "Second")!.lowerBound, text.range(of: "Tenth")!.lowerBound)
    }
    func testUTF16BOMAndHTMLWithoutScripts() throws {
        var bytes = Data([0xff, 0xfe]); bytes.append("中文 CSV,金额\n示例,12".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try DocumentText.extract(bytes, filename: "table.csv"), "中文 CSV,金额\n示例,12")
        let html = Data("<p>Hello &amp; 中文</p><script>secret()</script><p>Next</p>".utf8)
        let text = try DocumentText.extract(html, filename: "page.html")
        XCTAssertTrue(text.contains("Hello & 中文")); XCTAssertFalse(text.contains("secret"))
    }
    func testInvalidBinaryOversizeAndCorruptArchiveRejected() throws {
        XCTAssertThrowsError(try DocumentText.extract(Data([0,1,2,3]), filename: "binary.dat"))
        XCTAssertThrowsError(try DocumentText.extract(Data(repeating: 65, count: 1024 * 1024 + 1), filename: "large.txt"))
        XCTAssertThrowsError(try DocumentText.extract(Data("not a zip".utf8), filename: "bad.docx"))
        XCTAssertThrowsError(try DocumentText.extract(Data("old format".utf8), filename: "legacy.xls"))
        var corrupt = try fixture("sample.docx"); corrupt[55] ^= 255
        XCTAssertThrowsError(try DocumentText.extract(corrupt, filename: "broken.docx"))
    }
}
