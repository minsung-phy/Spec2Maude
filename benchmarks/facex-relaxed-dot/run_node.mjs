import { readFile } from "node:fs/promises";

const bytes = await readFile(process.argv[2]);
const { instance } = await WebAssembly.instantiate(bytes, {});
const {
  facex_current_result,
  facex_current_mismatch,
  facex_swap_mismatch,
  facex_portable_mismatch,
} = instance.exports;

let currentMismatches = 0;
let swapMismatches = 0;
for (let a = 0; a < 256; ++a) {
  currentMismatches += facex_current_mismatch(a) !== 0;
  swapMismatches += facex_swap_mismatch(a) !== 0;
  if (facex_portable_mismatch(a) !== 0) {
    throw new Error(`portable repair mismatched at ${a}`);
  }
}
console.log(`node=${process.version}`);
console.log(`current_result_a0=${facex_current_result(0)}`);
console.log(`current_mismatch_count=${currentMismatches}`);
console.log(`swap_mismatch_count=${swapMismatches}`);
