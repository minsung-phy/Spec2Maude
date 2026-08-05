import { readFile } from "node:fs/promises";

if (process.argv.length !== 3) {
  throw new Error(`usage: ${process.argv[1]} MODULE.wasm`);
}

const bytes = await readFile(process.argv[2]);
const { instance } = await WebAssembly.instantiate(bytes, {});
const { bitnet_dot_lane0, bitnet_mismatch, fixed_mismatch } = instance.exports;

let mismatchCount = 0;
let firstMismatch = -1;
for (let b = 0; b < 256; ++b) {
  if (bitnet_mismatch(b) !== 0) {
    mismatchCount += 1;
    if (firstMismatch < 0) firstMismatch = b;
  }
  if (fixed_mismatch(b) !== 0) {
    throw new Error(`deterministic repair mismatched at byte ${b}`);
  }
}

console.log(`node=${process.version}`);
console.log(`mismatch_count=${mismatchCount}`);
console.log(`first_mismatch=${firstMismatch}`);
console.log(`lane0_x127=${bitnet_dot_lane0(127)}`);
console.log(`lane0_x128=${bitnet_dot_lane0(128)}`);
console.log(`lane0_x255=${bitnet_dot_lane0(255)}`);
