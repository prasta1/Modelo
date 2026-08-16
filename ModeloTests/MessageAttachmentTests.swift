import XCTest
@testable import Modelo

final class MessageAttachmentTests: XCTestCase {

    // MARK: isImage

    func test_isImage_trueForJpeg() {
        let att = MessageAttachment(data: Data(), mimeType: "image/jpeg", fileName: "photo.jpg")
        XCTAssertTrue(att.isImage)
    }

    func test_isImage_trueForPng() {
        let att = MessageAttachment(data: Data(), mimeType: "image/png", fileName: "img.png")
        XCTAssertTrue(att.isImage)
    }

    func test_isImage_falseForText() {
        let att = MessageAttachment(data: Data(), mimeType: "text/plain", fileName: "file.txt")
        XCTAssertFalse(att.isImage)
    }

    func test_isImage_falseForPDF() {
        let att = MessageAttachment(data: Data(), mimeType: "application/pdf", fileName: "doc.pdf")
        XCTAssertFalse(att.isImage)
    }

    // MARK: dataURL

    func test_dataURL_hasCorrectSchemeAndMimeType() {
        let data = Data("hello".utf8)
        let att = MessageAttachment(data: data, mimeType: "image/png", fileName: "img.png")
        XCTAssertTrue(att.dataURL.hasPrefix("data:image/png;base64,"))
    }

    func test_dataURL_base64MatchesData() {
        let data = Data("hello world".utf8)
        let att = MessageAttachment(data: data, mimeType: "image/jpeg", fileName: "x.jpg")
        let expected = "data:image/jpeg;base64,\(data.base64EncodedString())"
        XCTAssertEqual(att.dataURL, expected)
    }

    // MARK: JSON round-trip

    func test_jsonRoundTrip_preservesMimeTypeAndFileName() throws {
        let original = MessageAttachment(data: Data("test".utf8), mimeType: "image/png", fileName: "img.png")
        let json = try XCTUnwrap([original].json)
        let decoded = try XCTUnwrap(MessageAttachment.decodeList(json))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].mimeType, "image/png")
        XCTAssertEqual(decoded[0].fileName, "img.png")
        XCTAssertEqual(decoded[0].data, Data("test".utf8))
    }

    func test_jsonRoundTrip_emptyList() throws {
        let json = try XCTUnwrap([MessageAttachment]().json)
        let decoded = try XCTUnwrap(MessageAttachment.decodeList(json))
        XCTAssertEqual(decoded.count, 0)
    }

    func test_decodeList_malformedJSON_returnsNil() {
        XCTAssertNil(MessageAttachment.decodeList("not json at all"))
    }

    func test_decodeList_emptyString_returnsNil() {
        XCTAssertNil(MessageAttachment.decodeList(""))
    }
}
