import { readFileSync } from 'node:fs';
import { strict as assert } from 'node:assert';

const [providerPath, victimPath] = process.argv.slice(2);
if (!providerPath || !victimPath) {
  throw new Error('usage: node node-zombie.mjs PROVIDER.wasm VICTIM.wasm');
}

const providerModule = new WebAssembly.Module(readFileSync(providerPath));
const provider = new WebAssembly.Instance(providerModule, {});
const victimModule = new WebAssembly.Module(readFileSync(victimPath));

let trapped = false;
try {
  new WebAssembly.Instance(victimModule, {
    'zombie-provider': { table: provider.exports.table },
  });
} catch (error) {
  trapped = error instanceof WebAssembly.RuntimeError;
}

assert.equal(trapped, true, 'victim instantiation did not trap');
const zombieResult = provider.exports.call_slot();
assert.equal(zombieResult, 42, 'failed module function did not remain callable');

console.log(`node=${process.version}`);
console.log(`instantiation_trapped=${trapped}`);
console.log(`zombie_result=${zombieResult}`);
