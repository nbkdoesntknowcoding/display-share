/**
 * TypeScript implementation of protocol/SPEC.md v1.
 *
 * Mirrors mac/Shared/WireProtocol.swift. Both ends are tested against the same
 * golden vectors in protocol/vectors/, so the two implementations are verified
 * independently rather than against each other.
 */
export const PROTOCOL_VERSION = 1;
export const HEADER_SIZE = 16;
export const LENGTH_PREFIX_SIZE = 4;
export function decodeVideoMessage(bytes) {
    if (bytes.length < HEADER_SIZE) {
        return { ok: false, error: { kind: "tooShort", size: bytes.length } };
    }
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const declared = view.getUint32(0);
    const actual = bytes.length - LENGTH_PREFIX_SIZE;
    if (declared !== actual) {
        return { ok: false, error: { kind: "lengthMismatch", declared, actual } };
    }
    const type = bytes[4];
    if (type !== 1) {
        return { ok: false, error: { kind: "unknownType", type } };
    }
    const isKeyframe = (bytes[5] & 0x01) === 1;
    const timestampMicros = view.getBigUint64(8);
    const payload = bytes.subarray(HEADER_SIZE);
    if (payload.length === 0) {
        return { ok: false, error: { kind: "emptyPayload" } };
    }
    return { ok: true, message: { isKeyframe, timestampMicros, payload } };
}
/** Encodes a message. Used by the vector round-trip test. */
export function encodeVideoMessage(message) {
    const out = new Uint8Array(HEADER_SIZE + message.payload.length);
    const view = new DataView(out.buffer);
    view.setUint32(0, HEADER_SIZE - LENGTH_PREFIX_SIZE + message.payload.length);
    out[4] = 1;
    out[5] = message.isKeyframe ? 1 : 0;
    view.setUint16(6, 0);
    view.setBigUint64(8, message.timestampMicros);
    out.set(message.payload, HEADER_SIZE);
    return out;
}
/**
 * Derives the WebCodecs codec string from the SPS (SPEC §3.3).
 *
 * The NALU type is the LOW 5 BITS of the header byte; the upper bits are
 * nal_ref_idc. An SPS is therefore 0x67 *or* 0x27 — VideoToolbox on macOS 26
 * emits 0x27. Matching the whole byte is a reliable way to miss it.
 */
export function codecStringFromAnnexB(payload) {
    for (let i = 0; i + 8 < payload.length; i++) {
        if (payload[i] === 0 &&
            payload[i + 1] === 0 &&
            payload[i + 2] === 0 &&
            payload[i + 3] === 1) {
            if ((payload[i + 4] & 0x1f) === 7) {
                const hex = (n) => n.toString(16).padStart(2, "0");
                return `avc1.${hex(payload[i + 5])}${hex(payload[i + 6])}${hex(payload[i + 7])}`;
            }
        }
    }
    return null;
}
