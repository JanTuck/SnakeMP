/**
 * Shared static assets are read once at startup into memory and served from
 * RAM. Source and bundled entry points both resolve the repository client/.
 */
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export interface Asset { body: Uint8Array; type: string }

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.md': 'text/markdown; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
};

function mimeFor(name: string): string {
  const dot = name.lastIndexOf('.');
  const ext = dot === -1 ? '' : name.slice(dot).toLowerCase();
  return MIME[ext] || 'application/octet-stream';
}

function walk(absDir: string, urlBase: string, out: Map<string, Asset>): void {
  for (const entry of readdirSync(absDir, { withFileTypes: true })) {
    const abs = join(absDir, entry.name);
    const urlPath = urlBase + '/' + entry.name;
    if (entry.isDirectory()) {
      walk(abs, urlPath, out);
    } else if (entry.isFile()) {
      out.set(urlPath, { body: readFileSync(abs), type: mimeFor(entry.name) });
    }
  }
}

/** Load the shared client into memory. Source and bundled entry points resolve
 *  from different folders but remain at the same depth below the repository. */
export function loadAssets(here: string): Map<string, Asset> {
  const candidates = [join(here, '..', '..', '..', 'client')];
  const root = candidates.find((c) => existsSync(join(c, 'index.html')));
  if (!root) throw new Error('shared client/ directory not found from ' + here);
  const out = new Map<string, Asset>();
  walk(root, '', out);
  return out;
}
