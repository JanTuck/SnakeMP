/**
 * Snek game simulation: players, lobbies, tick loop.
 * Matches the Node reference per docs/SPEC.md. Transport-agnostic:
 * the network layer injects emit callbacks so this module never touches sockets.
 */
import * as C from './config.ts';
import { isValidUsername, uniqueGameId, rcolor, randomCell, rssBytes } from './util.ts';
import { Player, type Cell } from './player.ts';

interface Drop { id: string; x: number; y: number; expiresAt: number }

export interface Lobby {
  id: string;
  sockets: Map<string, boolean>;        // sid set, insertion ordered
  players: Map<string, Player>;         // sid -> Player
  food: Cell;
  bonusFoods: Cell[];
  drops: Drop[];
  golden: ({ x: number; y: number; expiresAt: number }) | null;
  nextDropAt: number;
  nextGoldenAt: number;
  dropSeq: number;
  lastEmptyAt: number;
  stats: { lastTickMs: number; avgTickMs: number; maxTickMs: number; ticks: number };
}

// Per-connection state mirrors the Node reference lifecycle.
interface Conn { player: Player | null; lobbyId: string | null }

export class GameHost {
  lobbies = new Map<string, Lobby>();
  private conns = new Map<string, Conn>();
  private loop: ReturnType<typeof setInterval> | null = null;
  private emitTo: (sid: string, frame: string) => void;
  private emitToMany: (sids: Iterable<string>, frame: string) => void;

  constructor(
    emitTo: (sid: string, frame: string) => void,
    emitToMany: (sids: Iterable<string>, frame: string) => void,
  ) {
    this.emitTo = emitTo;
    this.emitToMany = emitToMany;
    this.createLobby(C.DEFAULT_LOBBY_ID); // always-available public lobby
  }

  // ---- transport lifecycle -------------------------------------------------

  addConnection(sid: string): void {
    this.conns.set(sid, { player: null, lobbyId: null });
  }

  /** Socket closed: remove the player and announce feed death (SPEC). */
  dropConnection(sid: string): void {
    const conn = this.conns.get(sid);
    this.conns.delete(sid);
    if (!conn) return;
    const lobby = conn.lobbyId ? this.lobbies.get(conn.lobbyId) : null;
    if (lobby !== undefined && conn.player !== null) {
      this.roomEmit(lobby, 'feed', { type: 'death', who: conn.player.displayName, score: conn.player.score });
      this.removePlayer(lobby, conn.player);
      if (lobby.players.size === 0 && lobby.id !== C.DEFAULT_LOBBY_ID) {
        lobby.lastEmptyAt = Date.now();
      }
    }
  }

  // ---- events --------------------------------------------------------------

  clientReady(sid: string, username: unknown, lobbyId: unknown): void {
    const conn = this.conns.get(sid);
    if (!conn || conn.player !== null) return; // already playing (rejoin after death clears it)

    if (!isValidUsername(username)) {
      this.directEmit(sid, 'game_error', C.ERRORS.INVALID_USERNAME);
      return;
    }
    const target = (typeof lobbyId === 'string' && this.lobbies.has(lobbyId))
      ? this.lobbies.get(lobbyId)!
      : null;
    if (target === null) {
      this.directEmit(sid, 'game_error', C.ERRORS.UNKNOWN_GAME);
      return;
    }
    if (this.totalPlayers() >= C.MAX_PLAYERS_GLOBAL) {
      this.directEmit(sid, 'game_error', C.ERRORS.SERVER_FULL);
      return;
    }
    if (target.players.size >= C.MAX_PLAYERS_PER_LOBBY) {
      this.directEmit(sid, 'game_error', C.ERRORS.LOBBY_FULL);
      return;
    }

    this.directEmit(sid, 'init', { scale: C.GRID_SIZE, food: { x: target.food.x, y: target.food.y } });

    // Spawn away from other players AND from the current food item.
    let pos: Cell = { x: 0, y: 0 };
    for (let attempt = 0; attempt < 100; attempt++) {
      pos = startPosition(this.activePlayers(target));
      if (pos.x !== target.food.x || pos.y !== target.food.y) break;
    }
    const player = new Player(sid, (username as string).trim(), pos.x, pos.y, rcolor());
    conn.player = player;
    conn.lobbyId = target.id;
    target.sockets.set(sid, true);
    target.players.set(sid, player);
    this.roomEmit(target, 'feed', { type: 'join', who: player.displayName });
    this.ensureGameLoopRunning();
  }

  keyPress(sid: string, data: unknown): void {
    const conn = this.conns.get(sid);
    if (!conn || conn.player === null) return; // cannot steer before joining
    conn.player.setDirection(data);
  }

  // ---- lobbies -------------------------------------------------------------

  createLobby(id?: string): Lobby {
    let lobbyId = id;
    if (lobbyId === undefined) {
      do {
        lobbyId = uniqueGameId();
      } while (this.lobbies.has(lobbyId));
    }
    const lobby: Lobby = {
      id: lobbyId,
      sockets: new Map(),
      players: new Map(),
      food: randomCell(),
      bonusFoods: [],
      drops: [],
      golden: null,
      nextDropAt: 0,
      nextGoldenAt: 0,
      dropSeq: 1,
      lastEmptyAt: 0,
      stats: { lastTickMs: 0, avgTickMs: 0, maxTickMs: 0, ticks: 0 },
    };
    this.lobbies.set(lobbyId, lobby);
    return lobby;
  }

  totalPlayers(): number {
    let n = 0;
    for (const lobby of this.lobbies.values()) n += lobby.players.size;
    return n;
  }

  activePlayers(lobby: Lobby): Player[] {
    return [...lobby.players.values()];
  }

  statsPayload(): Record<string, unknown> {
    const lobbies = [...this.lobbies.values()].map((l) => ({
      id: l.id,
      players: l.players.size,
      drops: l.drops.length,
      bonus: l.bonusFoods.length,
      golden: l.golden !== null,
      lastTickMs: l.stats.lastTickMs,
      avgTickMs: Math.round(l.stats.avgTickMs * 10) / 10,
      maxTickMs: l.stats.maxTickMs,
    }));
    return {
      rss: rssBytes(),
      uptime: process.uptime(),
      totalPlayers: this.totalPlayers(),
      lobbies,
    };
  }

  stop(): void {
    if (this.loop !== null) {
      clearInterval(this.loop);
      this.loop = null;
    }
  }

  private ensureGameLoopRunning(): void {
    if (this.loop === null) {
      this.loop = setInterval(() => this.tickAll(), C.TICK_MS);
    }
  }

  private removePlayer(lobby: Lobby, player: Player): boolean {
    // Clear the connection state so the same socket may rejoin (Retry without reload).
    const conn = this.conns.get(player.id);
    if (conn) {
      conn.player = null;
      conn.lobbyId = null;
    }
    lobby.sockets.delete(player.id);
    return lobby.players.delete(player.id);
  }

  // ---- emits ----------------------------------------------------------------

  private directEmit(sid: string, event: string, ...args: unknown[]): void {
    this.emitTo(sid, encodeEvent(event, ...args));
  }

  private roomEmit(lobby: Lobby, event: string, ...args: unknown[]): void {
    this.emitToMany(lobby.sockets.keys(), encodeEvent(event, ...args));
  }

  // ---- pickups --------------------------------------------------------------

  /** Random cell free of snakes and every pickup kind (200 attempts). */
  private randomFreeCell(lobby: Lobby): Cell | null {
    for (let attempt = 0; attempt < 200; attempt++) {
      const cell = randomCell();
      const taken =
        this.activePlayers(lobby).some((p) => p.snake.some((s) => s.x === cell.x && s.y === cell.y)) ||
        (lobby.food.x === cell.x && lobby.food.y === cell.y) ||
        lobby.bonusFoods.some((b) => b.x === cell.x && b.y === cell.y) ||
        lobby.drops.some((d) => d.x === cell.x && d.y === cell.y) ||
        (lobby.golden !== null && lobby.golden.x === cell.x && lobby.golden.y === cell.y);
      if (!taken) return cell;
    }
    return null;
  }

  private spawnDrop(lobby: Lobby, now: number): void {
    const cell = this.randomFreeCell(lobby);
    if (cell === null) return;
    lobby.drops.push({ id: 'drop-' + lobby.dropSeq++, x: cell.x, y: cell.y, expiresAt: now + C.DROP_TTL });
    this.roomEmit(lobby, 'feed', { type: 'drop-incoming' });
  }

  private spawnGolden(lobby: Lobby, now: number): void {
    const cell = this.randomFreeCell(lobby);
    if (cell === null) return;
    lobby.golden = { x: cell.x, y: cell.y, expiresAt: now + C.GOLDEN_TTL };
  }

  private openDrop(lobby: Lobby, player: Player): void {
    player.eat(C.DROP_POINTS, C.DROP_GROWTH);
    let spawned = 0;
    for (let i = 0; i < C.DROP_APPLES; i++) {
      if (lobby.bonusFoods.length >= C.BONUS_CAP) break;
      const cell = this.randomFreeCell(lobby);
      if (cell === null) break;
      lobby.bonusFoods.push(cell);
      spawned++;
    }
    this.roomEmit(lobby, 'feed', { type: 'drop-open', who: player.displayName, apples: spawned });
  }

  private respawnFood(lobby: Lobby): void {
    for (let attempt = 0; attempt < 100; attempt++) {
      lobby.food = randomCell();
      const occupied = this.activePlayers(lobby).some((p) =>
        p.snake.some((part) => part.x === lobby.food.x && part.y === lobby.food.y));
      if (!occupied) return;
    }
  }

  // ---- tick loop --------------------------------------------------------------

  private tickAll(): void {
    const now = Date.now();

    // Stamp idle-start for empty non-default lobbies.
    for (const lobby of this.lobbies.values()) {
      if (lobby.players.size === 0 && lobby.id !== C.DEFAULT_LOBBY_ID && lobby.lastEmptyAt === 0) {
        lobby.lastEmptyAt = now;
      }
    }

    // Delete idle non-default lobbies.
    for (const [id, lobby] of [...this.lobbies.entries()]) {
      if (lobby.id !== C.DEFAULT_LOBBY_ID && lobby.players.size === 0 &&
          lobby.lastEmptyAt !== 0 && now - lobby.lastEmptyAt > C.LOBBY_IDLE_DELETE_MS) {
        this.lobbies.delete(id);
      }
    }

    // Disconnected sockets are removed synchronously by the transport's close
    // handler (dropConnection), which also announces feed death — the reap
    // pass below is therefore a structural no-op kept for reference parity.

    for (const lobby of [...this.lobbies.values()]) {
      if (lobby.players.size > 0) this.tickLobby(lobby, now);
    }

    // Stop ticking entirely while nobody is playing (like the reference).
    if (this.loop !== null && this.totalPlayers() === 0) {
      clearInterval(this.loop);
      this.loop = null;
    }
  }

  private tickLobby(lobby: Lobby, now: number): void {
    const t0 = performance.now();

    // 1+2. Expire stale pickups and schedule the next drop / golden apple.
    lobby.drops = lobby.drops.filter((d) => d.expiresAt > now);
    if (lobby.golden !== null && lobby.golden.expiresAt <= now) lobby.golden = null;
    if (lobby.nextDropAt === 0) lobby.nextDropAt = now + 8000;
    if (lobby.nextGoldenAt === 0) lobby.nextGoldenAt = now + 20000;
    if (now >= lobby.nextDropAt && lobby.drops.length < 2) {
      this.spawnDrop(lobby, now);
      lobby.nextDropAt = now + C.DROP_SCHEDULE_MIN + Math.floor(Math.random() * C.DROP_SCHEDULE_SPAN);
    }
    if (now >= lobby.nextGoldenAt && lobby.golden === null) {
      this.spawnGolden(lobby, now);
      lobby.nextGoldenAt = now + C.GOLDEN_SCHEDULE_MIN + Math.floor(Math.random() * C.GOLDEN_SCHEDULE_SPAN);
    }

    // 4. Snapshot: players that die mid-tick must not keep acting this tick.
    const sids = [...lobby.sockets.keys()];

    for (const sid of sids) {
      // Skip players already killed earlier in this same tick.
      if (!lobby.sockets.has(sid)) continue;
      const player = lobby.players.get(sid);
      if (player === undefined) continue;

      // a. wall / self collision.
      if (player.collided()) {
        this.directEmit(sid, 'death', player.score);
        this.roomEmit(lobby, 'feed', { type: 'death', who: player.displayName, score: player.score });
        this.removePlayer(lobby, player);
        continue;
      }

      // b. head vs any other snake: both die.
      const collided = player.collidedOther(this.activePlayers(lobby));
      if (collided !== null) {
        this.directEmit(sid, 'death', player.score);
        const otherSid = collided.id;
        const otherConn = this.conns.get(otherSid);
        if (otherConn && otherConn.player === collided) {
          this.directEmit(otherSid, 'death', collided.score);
        }
        this.roomEmit(lobby, 'feed', { type: 'death', who: player.displayName, score: player.score });
        this.roomEmit(lobby, 'feed', { type: 'death', who: collided.displayName, score: collided.score });
        this.removePlayer(lobby, player);
        this.removePlayer(lobby, collided);
        continue;
      }

      // c. main food.
      if (player.snake[0].x === lobby.food.x && player.snake[0].y === lobby.food.y) {
        player.eat();
        this.respawnFood(lobby);
        this.roomEmit(lobby, 'updateFood', { x: lobby.food.x, y: lobby.food.y });
      }

      // d. bonus apples from opened supply crates.
      for (let i = lobby.bonusFoods.length - 1; i >= 0; i--) {
        if (player.snake[0].x === lobby.bonusFoods[i].x && player.snake[0].y === lobby.bonusFoods[i].y) {
          lobby.bonusFoods.splice(i, 1);
          player.eat();
        }
      }

      // e. golden apple: rare, timed, worth extra.
      if (lobby.golden !== null && player.snake[0].x === lobby.golden.x && player.snake[0].y === lobby.golden.y) {
        lobby.golden = null;
        player.eat(C.GOLDEN_POINTS);
        this.roomEmit(lobby, 'feed', { type: 'golden', who: player.displayName, points: C.GOLDEN_POINTS });
      }

      // f. supply crates.
      for (let i = lobby.drops.length - 1; i >= 0; i--) {
        if (player.snake[0].x === lobby.drops[i].x && player.snake[0].y === lobby.drops[i].y) {
          lobby.drops.splice(i, 1);
          this.openDrop(lobby, player);
        }
      }

      // g. apply one queued turn, then move.
      player.updatePosition();
    }

    // 5. One broadcast of plain data objects.
    this.roomEmit(lobby, 'gameTick', {
      players: this.activePlayers(lobby).map((p) => ({
        id: p.id,
        displayName: p.displayName,
        color: p.color,
        snake: p.snake,
        score: p.score,
        bodyLength: p.bodyLength,
      })),
      bonus: lobby.bonusFoods,
      drops: lobby.drops.map((d) => ({ id: d.id, x: d.x, y: d.y, ttl: Math.max(0, d.expiresAt - now) })),
      golden: lobby.golden === null ? null : { x: lobby.golden.x, y: lobby.golden.y, ttl: Math.max(0, lobby.golden.expiresAt - now) },
    });

    const durMs = performance.now() - t0;
    lobby.stats.lastTickMs = durMs;
    lobby.stats.ticks++;
    lobby.stats.avgTickMs = lobby.stats.avgTickMs + (durMs - lobby.stats.avgTickMs) / Math.min(lobby.stats.ticks, 200);
    lobby.stats.maxTickMs = Math.max(lobby.stats.maxTickMs, durMs);
  }
}

/** Random start position that no current player occupies (1000 attempts). */
function startPosition(players: Player[]): Cell {
  const MAX_ATTEMPTS = 1000;
  let location = randomCell();
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    let overlaps = false;
    for (const player of players) {
      for (const part of player.snake) {
        if (location.x === part.x && location.y === part.y) {
          overlaps = true;
          break;
        }
      }
      if (overlaps) break;
    }
    if (!overlaps) return { x: location.x, y: location.y };
    location = randomCell();
  }
  // Board is effectively saturated; any spot will do (matches the reference).
  return { x: location.x, y: location.y };
}

/** Encode one socket.io v2 event frame: 42 + JSON array. */
export function encodeEvent(event: string, ...args: unknown[]): string {
  return '42' + JSON.stringify([event, ...args]);
}
