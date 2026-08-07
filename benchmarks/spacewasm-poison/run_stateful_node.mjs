import { readFile } from "node:fs/promises";

if (process.argv.length !== 3) {
  throw new Error(`usage: ${process.argv[1]} MODULE.wasm`);
}

const bytes = await readFile(process.argv[2]);
const { instance } = await WebAssembly.instantiate(bytes, {});
const {
  spacewasm_init,
  spacewasm_event,
  spacewasm_bad,
  spacewasm_observed,
} = instance.exports;

const init = spacewasm_init();
const a = spacewasm_event(0);
const f = spacewasm_event(1);
const c = spacewasm_event(2);
const observed = spacewasm_observed();
const bad = spacewasm_bad();

console.log(`init=${init}`);
console.log(`attack=${a}`);
console.log(`future=${f}`);
console.log(`call=${c}`);
console.log(`observed=${observed}`);
console.log(`bad=${bad}`);

if (init !== 0 || a !== 0 || f !== 0 || c !== 0) {
  throw new Error("stateful harness event failed");
}
if (observed !== 31337 || bad !== 1) {
  throw new Error("A-F-C did not reproduce the hijack");
}
