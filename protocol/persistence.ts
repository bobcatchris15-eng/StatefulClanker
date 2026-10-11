import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { dirname } from 'node:path';

const pause = new Int32Array(new SharedArrayBuffer(4));
/** Replace without deleting the destination; tolerate brief Windows sharing violations. */
export function replaceFileAtomic(source: string, destination: string, rename = renameSync): void {
  for (let attempt = 0; ; attempt++) {
    try { rename(source, destination); return; }
    catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (!['EPERM', 'EACCES', 'EBUSY'].includes(code ?? '') || attempt >= 6) throw error;
      Atomics.wait(pause, 0, 0, 10 * 2 ** attempt);
    }
  }
}

export function writeJsonAtomic(file: string, value: unknown): void {
  mkdirSync(dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n', 'utf8');
    replaceFileAtomic(tmp, file);
  } finally { rmSync(tmp, { force: true }); }
}

export function readJson<T>(file: string, dflt: T): T {
  try {
    return JSON.parse(readFileSync(file, 'utf8')) as T;
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === 'ENOENT') return dflt;
    throw e;
  }
}
