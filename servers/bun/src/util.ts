/** Small framework-free helpers: ids, colors, validation, RSS sampling. */
import { readFileSync } from 'node:fs';
import { GRID_SIZE, GRID_WIDTH, GRID_HEIGHT } from './config.ts';

// Usernames may contain unicode letters, numbers, spaces, underscores and
// hyphens, and must be 4-16 characters long after trimming.
const USERNAME_PATTERN = /^[\p{L}\p{N}_\- ]+$/u;

export function isValidUsername(username: unknown): boolean {
  if (typeof username !== 'string') return false;
  const trimmed = username.trim();
  return trimmed.length >= 4 && trimmed.length <= 16 && USERNAME_PATTERN.test(trimmed);
}

/** Lobby ids created by POST /generateid (id-<base36 rand><base36 time>). */
export function uniqueGameId(): string {
  return 'id-' + Math.random().toString(36).substring(2, 10) + Date.now().toString(36);
}

/** Random #rrggbb (rcolor-style; any hex color is fine per SPEC). */
export function rcolor(): string {
  let out = '#';
  for (let i = 0; i < 6; i++) out += Math.floor(Math.random() * 16).toString(16);
  return out;
}

/** Random grid-aligned cell (multiples of 16) within the board. */
export function randomCell(): { x: number; y: number } {
  return {
    x: Math.floor((Math.random() * GRID_WIDTH) / GRID_SIZE) * GRID_SIZE,
    y: Math.floor((Math.random() * GRID_HEIGHT) / GRID_SIZE) * GRID_SIZE,
  };
}

const PAGE_SIZE = 4096;

/** Resident set size in bytes, read from /proc like the benchmark expects. */
export function rssBytes(): number {
  try {
    const parts = readFileSync('/proc/self/statm', 'utf8').trim().split(/\s+/);
    const pages = Number.parseInt(parts[1], 10);
    if (Number.isFinite(pages) && pages > 0) return pages * PAGE_SIZE;
  } catch { /* fall through */ }
  try {
    const status = readFileSync('/proc/self/status', 'utf8');
    const m = /VmRSS:\s+(\d+)\s+kB/.exec(status);
    if (m) return Number.parseInt(m[1], 10) * 1024;
  } catch { /* fall through */ }
  try { return process.memoryUsage().rss; } catch { return 0; }
}
