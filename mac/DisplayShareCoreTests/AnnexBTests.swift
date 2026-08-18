import XCTest

@testable import DisplayShareCore

/// Task 8.2. The Windows Media Foundation encoder mixes 3- and 4-byte start
/// codes inside a single access unit, which the Mac-as-sender path never
/// produced — so these cases were previously unreachable and untested.
final class AnnexBTests: XCTestCase {

    /// Builds a payload from (startCodeLength, nalType) pairs.
    private func payload(_ parts: [(Int, UInt8)], bodyBytes: Int = 2) -> Data {
        var data = Data()
        for (prefix, type) in parts {
            data.append(contentsOf: prefix == 4 ? [0, 0, 0, 1] : [0, 0, 1])
            data.append(type & 0x1F)
            data.append(contentsOf: [UInt8](repeating: 0xAA, count: bodyBytes))
        }
        return data
    }

    func testMixedStartCodeLengthsAreAllFound() {
        let data = payload([(4, 9), (4, 7), (3, 8), (3, 6), (4, 5)])
        XCTAssertEqual(AnnexB.nalUnits(data).map(\.type), [9, 7, 8, 6, 5])
    }

    func testNalBoundariesStopBeforeTheNextStartCode() {
        // Three-byte start code following a 4-byte one: the first NAL must not
        // swallow the next start code's leading zeros.
        let data = payload([(4, 7), (3, 5)], bodyBytes: 3)
        let units = AnnexB.nalUnits(data)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].data.count, 4, "header byte + 3 body bytes")
        XCTAssertEqual(units[1].data.count, 4)
    }

    func testParameterSetsAreExtracted() {
        let sets = AnnexB.parameterSets(payload([(4, 7), (3, 8), (4, 5)]))
        XCTAssertEqual(sets.sps.count, 1)
        XCTAssertEqual(sets.pps.count, 1)
        XCTAssertEqual(sets.sps.first?.first.map { $0 & 0x1F }, 7)
        XCTAssertEqual(sets.pps.first?.first.map { $0 & 0x1F }, 8)
    }

    func testAvccDropsParameterSetsAndDelimiters() {
        // SPS and PPS belong in the format description; an AUD in sample data is
        // redundant. Only the IDR should survive.
        let data = payload([(4, 9), (4, 7), (3, 8), (4, 5)])
        let avcc = AnnexB.avcc(data)
        XCTAssertEqual(avcc.count, 4 + 3, "one 4-byte length plus one 3-byte NAL")
        let length = avcc.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(length, 3)
        XCTAssertEqual(avcc[4] & 0x1F, 5, "the surviving NAL must be the IDR")
    }

    func testAvccLengthPrefixIsBigEndian() {
        let data = payload([(4, 5)], bodyBytes: 300)
        let avcc = AnnexB.avcc(data)
        XCTAssertEqual([UInt8](avcc.prefix(4)), [0, 0, 0x01, 0x2D], "301 big-endian")
    }

    func testStartableRequiresAnSps() {
        XCTAssertTrue(AnnexB.isStartable(payload([(4, 7), (4, 8), (4, 5)])))
        // An IDR with no SPS does not raise an error in any decoder — it just
        // never shows a picture, so it has to be caught here.
        XCTAssertFalse(AnnexB.isStartable(payload([(4, 5)])))
    }

    func testEmptyAndTruncatedInputDoNotCrash() {
        XCTAssertTrue(AnnexB.nalUnits(Data()).isEmpty)
        XCTAssertTrue(AnnexB.nalUnits(Data([0, 0])).isEmpty)
        XCTAssertTrue(AnnexB.nalUnits(Data([0, 0, 1])).isEmpty, "start code with no payload")
        XCTAssertTrue(AnnexB.nalUnits(Data([0, 0, 0, 1])).isEmpty)
    }

    func testCodecStringReadsThreeByteStartCodes() {
        // WireProtocol.codecString only scanned 4-byte start codes, which was
        // invisible while VideoToolbox — which always emits 4 — was the only
        // sender.
        var data = Data([0, 0, 1, 0x67, 0x42, 0xC0, 0x1E])
        XCTAssertEqual(WireProtocol.codecString(fromAnnexB: data), "avc1.42C01E")
        data = Data([0, 0, 0, 1, 0x67, 0x64, 0x00, 0x28])
        XCTAssertEqual(WireProtocol.codecString(fromAnnexB: data), "avc1.640028")
    }
}
