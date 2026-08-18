/**
 * Task 8.1 acceptance: connect to the Windows sender as a scripted WebSocket
 * client, validate the framing against protocol/SPEC.md §3, and write the
 * payloads out for ffprobe.
 *
 * This checks the thing the encoder self-test cannot: that what arrives ON THE
 * WIRE is a decodable stream. An encoder can be perfect and the framing still
 * wrong — a length field that includes itself, or a first frame that is not a
 * keyframe — and neither shows up until a real client tries to decode.
 *
 *   node scripts/ws-acceptance.mjs <url> <out.h264> [frames]
 */
import { writeFileSync } from "node:fs";

const [url, outPath, countArg] = process.argv.slice(2);
const want = Number(countArg ?? 40);

const TYPE_VIDEO = 1;
const FLAG_KEYFRAME = 0x01;

const fail = (message) => {
  console.error(`FAIL: ${message}`);
  process.exit(1);
};

const socket = new WebSocket(url);
socket.binaryType = "arraybuffer";

const payloads = [];
let keyframes = 0;
let lastTimestamp = -1;

const timer = setTimeout(
  () => fail(`only ${payloads.length}/${want} frames arrived within 30s`),
  30_000
);

socket.addEventListener("error", () => fail(`could not connect to ${url}`));

socket.addEventListener("message", (event) => {
  if (!(event.data instanceof ArrayBuffer)) fail("message was not binary");
  const view = new DataView(event.data);
  const bytes = new Uint8Array(event.data);

  if (bytes.length < 16) fail(`message shorter than the 16-byte header: ${bytes.length}`);

  // SPEC §3: length counts the bytes AFTER the length field.
  const length = view.getUint32(0, false);
  if (length !== bytes.length - 4) {
    fail(`length ${length} does not equal size-4 (${bytes.length - 4})`);
  }
  if (view.getUint8(4) !== TYPE_VIDEO) fail(`unexpected message type ${view.getUint8(4)}`);

  const flags = view.getUint8(5);
  if (flags & ~FLAG_KEYFRAME) fail(`reserved flag bits set: 0x${flags.toString(16)}`);
  if (view.getUint16(6, false) !== 0) fail("reserved field is not zero");

  const timestamp = Number(view.getBigUint64(8, false));
  if (timestamp < lastTimestamp) {
    fail(`timestamps went backwards: ${timestamp} after ${lastTimestamp}`);
  }
  lastTimestamp = timestamp;

  const payload = bytes.subarray(16);
  const keyframe = Boolean(flags & FLAG_KEYFRAME);

  if (payloads.length === 0 && !keyframe) {
    fail("first frame was not a keyframe — a client cannot start decoding here");
  }
  if (keyframe) {
    keyframes += 1;
    // Annex-B, parameter sets in band. Scan by NAL type: the low 5 bits of the
    // header byte, since nal_ref_idc occupies the upper bits.
    const types = [];
    for (let i = 0; i + 3 < payload.length; i += 1) {
      if (payload[i] === 0 && payload[i + 1] === 0) {
        if (payload[i + 2] === 1) types.push(payload[i + 3] & 0x1f);
        else if (payload[i + 2] === 0 && payload[i + 3] === 1 && i + 4 < payload.length) {
          types.push(payload[i + 4] & 0x1f);
        }
      }
    }
    if (!types.includes(7)) fail("keyframe arrived without an in-band SPS");
  }

  payloads.push(payload);
  if (payloads.length >= want) {
    clearTimeout(timer);
    socket.close();
    const total = payloads.reduce((n, p) => n + p.length, 0);
    const joined = new Uint8Array(total);
    let at = 0;
    for (const p of payloads) {
      joined.set(p, at);
      at += p.length;
    }
    writeFileSync(outPath, joined);
    console.log(
      `ok: ${payloads.length} frames, ${keyframes} keyframes, ${total} bytes -> ${outPath}`
    );
    process.exit(0);
  }
});
