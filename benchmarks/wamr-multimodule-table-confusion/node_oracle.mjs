import { readFileSync } from 'node:fs';
import { strict as assert } from 'node:assert';

const [providerPath, consumerPath] = process.argv.slice(2);
if (!providerPath || !consumerPath) {
  throw new Error('usage: node node_oracle.mjs PROVIDER.wasm CONSUMER.wasm');
}

const providerModule = new WebAssembly.Module(readFileSync(providerPath));
const provider = new WebAssembly.Instance(providerModule, {});
const consumerModule = new WebAssembly.Module(readFileSync(consumerPath));
const consumer = new WebAssembly.Instance(consumerModule, {
  provider: {
    table: provider.exports.table,
    call_slot: provider.exports.call_slot,
  },
});

let trapped = false;
let message = '<none>';
try {
  consumer.exports.trigger();
} catch (error) {
  trapped = error instanceof WebAssembly.RuntimeError;
  message = String(error.message);
}

assert.equal(trapped, true, 'correct WebAssembly semantics must trap');
assert.match(message, /indirect call|signature|type mismatch/i);

console.log(`node=${process.version}`);
console.log(`trapped=${trapped}`);
console.log(`message=${message}`);
