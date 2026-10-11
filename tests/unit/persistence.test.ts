import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { replaceFileAtomic, writeJsonAtomic } from '../../protocol/persistence.ts';

test('replacement retries transient sharing violations without deleting the existing destination', () => {
  const root = mkdtempSync(join(tmpdir(), 'sc-persist-')), source = join(root, 'new'), destination = join(root, 'state');
  writeFileSync(source, 'new'); writeFileSync(destination, 'old');
  let attempts = 0;
  replaceFileAtomic(source, destination, (a, b) => {
    attempts++;
    assert.equal(readFileSync(destination, 'utf8'), 'old');
    if (attempts < 3) throw Object.assign(new Error('reader holds file'), { code: 'EPERM' });
    renameSync(a, b);
  });
  assert.equal(attempts, 3); assert.equal(readFileSync(destination, 'utf8'), 'new');
});

test('replacement stops on permanent errors and bounds retries for persistent locks', () => {
  let attempts = 0;
  assert.throws(() => replaceFileAtomic('a', 'b', () => {
    attempts++; throw Object.assign(new Error('missing'), { code: 'ENOENT' });
  }), /missing/);
  assert.equal(attempts, 1);
  attempts = 0;
  assert.throws(() => replaceFileAtomic('a', 'b', () => {
    attempts++; throw Object.assign(new Error('locked'), { code: 'EBUSY' });
  }), /locked/);
  assert.equal(attempts, 7);
});

test('JSON write failure removes its temporary file and preserves the old destination', () => {
  const root = mkdtempSync(join(tmpdir(), 'sc-persist-')), destination = join(root, 'state');
  mkdirSync(destination); writeFileSync(join(destination, 'keep'), 'evidence');
  assert.throws(() => writeJsonAtomic(destination, { changed: true }));
  assert.deepEqual(readdirSync(root), ['state']);
  assert.equal(readFileSync(join(destination, 'keep'), 'utf8'), 'evidence');
});
