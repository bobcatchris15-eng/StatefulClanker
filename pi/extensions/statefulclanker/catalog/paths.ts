import { homedir } from "node:os";
import { join } from "node:path";

export function machineDir(): string {
  const o = process.env.SC_MACHINE_DIR;
  if (o) return o;
  if (process.platform === "win32") {
    const base = process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local");
    return join(base, "StatefulClanker");
  }
  return join(homedir(), ".statefulclanker");
}

export function projectProfilesPath(root: string): string {
  return join(root, ".statefulclanker", "profiles.json");
}
