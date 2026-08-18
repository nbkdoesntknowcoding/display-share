import Foundation

/// Annex-B bitstream inspection and conversion to AVCC (Task 8.2).
///
/// VideoToolbox cannot decode Annex-B directly. It needs parameter sets handed
/// over separately, as a `CMVideoFormatDescription`, and sample data in AVCC
/// form with 4-byte length prefixes instead of start codes.
///
/// **Both start-code lengths are handled here on purpose.** VideoToolbox emits
/// 4-byte start codes everywhere, so the Mac-as-sender path never exercised the
/// 3-byte form — but the Windows Media Foundation encoder mixes them freely
/// within one access unit. A scanner that only knows `00 00 00 01` silently
/// misses NAL units rather than failing, which shows up as a picture that never
/// appears.
public enum AnnexB {

    public struct NALUnit: Equatable {
        /// Low 5 bits of the header byte. The upper bits are `nal_ref_idc`.
        public let type: UInt8
        /// Payload including the header byte, excluding the start code.
        public let data: Data
    }

    public static let sps: UInt8 = 7
    public static let pps: UInt8 = 8
    public static let idr: UInt8 = 5
    public static let accessUnitDelimiter: UInt8 = 9

    /// Splits a payload into NAL units, accepting 3- and 4-byte start codes.
    public static func nalUnits(_ payload: Data) -> [NALUnit] {
        let bytes = [UInt8](payload)
        var starts: [(offset: Int, prefix: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index + 3, 3))
                    index += 3
                    continue
                }
                if index + 4 <= bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index + 4, 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }

        var units: [NALUnit] = []
        for (position, start) in starts.enumerated() {
            // A NAL runs until the next start code, or to the end of the buffer.
            let end = position + 1 < starts.count
                ? starts[position + 1].offset - starts[position + 1].prefix
                : bytes.count
            guard start.offset < end else { continue }
            let slice = Data(bytes[start.offset..<end])
            units.append(NALUnit(type: bytes[start.offset] & 0x1F, data: slice))
        }
        return units
    }

    /// SPS and PPS from a payload, in the order they appear.
    public static func parameterSets(_ payload: Data) -> (sps: [Data], pps: [Data]) {
        var spsList: [Data] = []
        var ppsList: [Data] = []
        for unit in nalUnits(payload) {
            if unit.type == sps { spsList.append(unit.data) }
            if unit.type == pps { ppsList.append(unit.data) }
        }
        return (spsList, ppsList)
    }

    /// Converts to AVCC: each NAL prefixed with its big-endian 4-byte length.
    ///
    /// Parameter sets and access unit delimiters are dropped by default. SPS and
    /// PPS travel in the format description instead, and an AUD inside sample
    /// data is at best redundant.
    public static func avcc(_ payload: Data) -> Data {
        var out = Data()
        for unit in nalUnits(payload) {
            if unit.type == sps || unit.type == pps || unit.type == accessUnitDelimiter {
                continue
            }
            var length = UInt32(unit.data.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(unit.data)
        }
        return out
    }

    /// True when the payload can start a decode, i.e. it carries an SPS.
    public static func isStartable(_ payload: Data) -> Bool {
        nalUnits(payload).contains { $0.type == sps }
    }
}
