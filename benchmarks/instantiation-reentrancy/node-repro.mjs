import { readFileSync } from 'node:fs';
import { strict as assert } from 'node:assert';

const [providerPath, victimPath] = process.argv.slice(2);
if (!providerPath || !victimPath) {
  throw new Error('usage: node node-repro.mjs PROVIDER.wasm VICTIM.wasm');
}

const providerModule = new WebAssembly.Module(readFileSync(providerPath));
const provider = new WebAssembly.Instance(providerModule, {});

const victimModule = new WebAssembly.Module(readFileSync(victimPath));
const victim = new WebAssembly.Instance(victimModule, {
  provider: {
    table: provider.exports.table,
    hook: provider.exports.hook,
  },
});

const duringStart = provider.exports.get_observed();
const afterStart = provider.exports.call_slot();

assert.equal(duringStart, 0, 'reentrant call did not observe partial initialization');
assert.equal(afterStart, 1, 'post-start call did not observe completed initialization');

console.log(`node=${process.version}`);
console.log(`during_start=${duringStart}`);
console.log(`after_start=${afterStart}`);
console.log(`victim_exports=${Object.keys(victim.exports).length}`);
