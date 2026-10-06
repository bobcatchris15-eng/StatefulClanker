import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { activeCount, claim, release, releaseByWorker, reapDead } from "../../catalog/leases.ts";

const tmp = () => mkdtempSync(join(tmpdir(), "sc-lease-"));
const owner = (w: string, pid = process.pid) => ({ worker_id: w, parent_pid: pid });

test("capacity, release, releaseByWorker, ttl expiry", () => {
  const d = tmp();
  const a = claim("p/m", owner("w1"), 2, 60_000, d)!;
  const b = claim("p/m", owner("w2"), 2, 60_000, d)!;
  assert.ok(a && b);
  assert.equal(claim("p/m", owner("w3"), 2, 60_000, d), null);
  assert.equal(activeCount("p/m", d), 2);
  assert.ok(claim("p/other", owner("w3"), 1, 60_000, d));
  assert.equal(release(a.lease_id, d), true);
  assert.ok(claim("p/m", owner("w3"), 2, 60_000, d));
  assert.equal(releaseByWorker("w2", d), 1);
  assert.equal(activeCount("p/m", d), 1);
  assert.ok(claim("p/unl", owner("w1"), null, 60_000, d));
  assert.ok(claim("p/unl", owner("w2"), null, 60_000, d));
  const t0 = Date.now();
  assert.ok(claim("p/ttl", owner("w1"), 1, 10, d, t0));
  assert.equal(claim("p/ttl", owner("w2"), 1, 10, d, t0 + 5), null);
  assert.ok(claim("p/ttl", owner("w2"), 1, 10, d, t0 + 50));
});

test("reapDead removes dead parent pids and expired leases", () => {
  const d = tmp();
  claim("p/m", owner("live", 111), 5, 60_000, d);
  claim("p/m", owner("dead", 222), 5, 60_000, d);
  assert.equal(reapDead((pid) => pid === 111, d), 1);
  assert.equal(activeCount("p/m", d), 1);
  assert.equal(reapDead(() => true, d, Date.now() + 120_000), 1);
  assert.equal(activeCount("p/m", d), 0);
});

test("stale lockfile is removed", () => {
  const d = tmp();
  const lock = join(d, "leases.lock");
  writeFileSync(lock, "");
  const old = new Date(Date.now() - 60_000);
  // utimes via fs
  return import("node:fs").then(({ utimesSync }) => {
    utimesSync(lock, old, old);
    assert.ok(claim("p/m", owner("w"), 1, 1000, d));
  });
});

test("concurrent claims from two node processes never exceed capacity", async () => {
  const d = tmp();
  const url = pathToFileURL(join(import.meta.dirname, "../../catalog/leases.ts")).href;
  const script = `
    import { claim } from ${JSON.stringify(url)};
    let ok = 0;
    for (let i = 0; i < 20; i++) {
      if (claim("p/m", { worker_id: "w" + process.pid + "-" + i, parent_pid: process.pid }, 5, 60000, process.argv[1])) ok++;
    }
    console.log(ok);
  `;
  const run = () => new Promise<number>((resolve, reject) => {
    const c = spawn(process.execPath, ["--input-type=module", "-e", script, d], { stdio: ["ignore", "pipe", "pipe"] });
    let out = "", err = "";
    c.stdout.on("data", (b) => (out += b)); c.stderr.on("data", (b) => (err += b));
    c.on("exit", (code) => (code === 0 ? resolve(Number(out.trim())) : reject(new Error(err))));
  });
  const [x, y] = await Promise.all([run(), run()]);
  assert.equal(x + y, 5);
  assert.equal(activeCount("p/m", d), 5);
  assert.equal(JSON.parse(readFileSync(join(d, "leases.json"), "utf8")).length, 5);
});
