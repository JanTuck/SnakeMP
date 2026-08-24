/** Protocol constants shared by the Bun implementation modules. */

// Board: 120 x 60 cells of 16px (1920 x 960 logical units).
export const GRID_SIZE = 16;
export const GRID_WIDTH = 1920;
export const GRID_HEIGHT = 960;

// Game tick: 15fps.
export const TICK_MS = 1000 / 15;

// Player caps.
export const MAX_PLAYERS_GLOBAL = 100;   // concurrent players across all lobbies
export const MAX_PLAYERS_PER_LOBBY = 16; // keeps a single arena playable
export const LOBBY_IDLE_DELETE_MS = 60000;
export const DEFAULT_LOBBY_ID = '12345';

// Bonus world constants.
export const BONUS_CAP = 12;
export const DROP_TTL = 25000;           // crates despawn 25s after landing
export const GOLDEN_TTL = 12000;         // golden apple lasts 12s
export const DROP_POINTS = 2;
export const DROP_GROWTH = 2;
export const DROP_APPLES = 4;
export const GOLDEN_POINTS = 3;

// Spawn schedules: drops every 12-20s, golden every 25-40s.
export const DROP_SCHEDULE_MIN = 12000;
export const DROP_SCHEDULE_SPAN = 8000;
export const GOLDEN_SCHEDULE_MIN = 25000;
export const GOLDEN_SCHEDULE_SPAN = 15000;

export const ERRORS: Record<string, string> = {
  INVALID_USERNAME: 'Invalid username',
  UNKNOWN_GAME: 'That game does not exist any more',
  SERVER_FULL: 'Server is full, try again later',
  LOBBY_FULL: 'This game is full',
};

// engine.io v3 heartbeat contract.
export const PING_INTERVAL = 20000;
export const PING_TIMEOUT = 15000;
