import * as C from './config.ts';

export type Cell = { x: number; y: number };

const DIRECTIONS = ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'] as const;
const OPPOSITE: Record<string, string> = {
  ArrowUp: 'ArrowDown',
  ArrowDown: 'ArrowUp',
  ArrowLeft: 'ArrowRight',
  ArrowRight: 'ArrowLeft',
};

export class Player {
  bodyLength = 1;
  score = 0;
  direction: string | null = null;
  directionQueue: string[] = [];
  pendingGrowth = 0;
  snake: Cell[];

  constructor(
    readonly id: string,
    readonly displayName: string,
    x: number,
    y: number,
    readonly color: string,
  ) {
    this.snake = [{ x, y }];
  }

  collided(): boolean {
    return this.collidedSelf() || this.collidedWall();
  }

  private collidedWall(): boolean {
    const head = this.snake[0];
    return head.x > C.GRID_WIDTH - C.GRID_SIZE || head.x < 0 ||
      head.y > C.GRID_HEIGHT - C.GRID_SIZE || head.y < 0;
  }

  private collidedSelf(): boolean {
    const head = this.snake[0];
    return this.snake.slice(1).some((part) => part.x === head.x && part.y === head.y);
  }

  collidedOther(players: Player[]): Player | null {
    const head = this.snake[0];
    return players.find((other) => other.id !== this.id &&
      other.snake.some((part) => part.x === head.x && part.y === head.y)) ?? null;
  }

  setDirection(direction: unknown): boolean {
    if (typeof direction !== 'string' || !DIRECTIONS.includes(direction as typeof DIRECTIONS[number])) return false;
    const last = this.directionQueue.at(-1) ?? this.direction;
    if (direction === last || (last !== null && direction === OPPOSITE[last]) || this.directionQueue.length >= 2) {
      return false;
    }
    this.directionQueue.push(direction);
    return true;
  }

  updatePosition(): void {
    this.direction = this.directionQueue.shift() ?? this.direction;
    if (this.direction === null) return;

    const head = { ...this.snake[0] };
    if (this.direction === 'ArrowRight') head.x += C.GRID_SIZE;
    if (this.direction === 'ArrowLeft') head.x -= C.GRID_SIZE;
    if (this.direction === 'ArrowUp') head.y -= C.GRID_SIZE;
    if (this.direction === 'ArrowDown') head.y += C.GRID_SIZE;

    if (this.pendingGrowth > 0) this.pendingGrowth--;
    else this.snake.pop();
    this.snake.unshift(head);
    this.bodyLength = this.snake.length;
  }

  eat(points = 1, growth = 1): void {
    this.score += points;
    this.pendingGrowth += growth;
    this.bodyLength = this.snake.length + this.pendingGrowth;
  }
}
