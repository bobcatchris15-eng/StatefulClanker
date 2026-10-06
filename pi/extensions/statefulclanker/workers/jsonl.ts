import { StringDecoder } from 'node:string_decoder';
import type { Readable } from 'node:stream';

/** LF-only JSONL line splitter. NOT node:readline (it splits on U+2028/2029). Strips trailing \r. */
export function attachJsonlReader(stream: Readable, onLine: (line: string) => void): void {
  const decoder = new StringDecoder('utf8');
  let buf = '';
  const strip = (l: string) => (l.endsWith('\r') ? l.slice(0, -1) : l);
  stream.on('data', (chunk: Buffer | string) => {
    buf += typeof chunk === 'string' ? chunk : decoder.write(chunk);
    for (;;) {
      const i = buf.indexOf('\n');
      if (i === -1) break;
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      onLine(strip(line));
    }
  });
  stream.on('end', () => {
    buf += decoder.end();
    if (buf.length > 0) onLine(strip(buf));
    buf = '';
  });
}
