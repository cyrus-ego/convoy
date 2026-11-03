import type { WebSocket } from 'ws';
import type { ServerMsg } from './protocol.js';

export interface Peer {
  readonly uid: string;
  readonly bufferedAmount: number;
  /** Client chậm bị bỏ qua vài delta thì lần sau phải nhận lại toàn bộ trạng thái */
  needsSnapshot: boolean;
  send(msg: ServerMsg): void;
  sendRaw(data: string): void;
  close(code: number, reason: string): void;
}

const OPEN = 1;
/** Tối đa 10 bản tin dồn một lúc, hồi 5 bản tin mỗi giây */
const BUCKET_SIZE = 10;
const REFILL_PER_SEC = 5;
/** Bị chặn quá số lần này trong một phút thì đóng kết nối */
const MAX_DROPPED_PER_MIN = 50;

export class WsPeer implements Peer {
  needsSnapshot = false;
  private alive = true;
  private tokens = BUCKET_SIZE;
  private lastRefill = Date.now();
  private dropped = 0;
  private droppedSince = Date.now();

  constructor(
    readonly uid: string,
    private readonly socket: WebSocket,
  ) {
    socket.on('pong', () => {
      this.alive = true;
    });
  }

  get bufferedAmount(): number {
    return this.socket.bufferedAmount;
  }

  get isOpen(): boolean {
    return this.socket.readyState === OPEN;
  }

  send(msg: ServerMsg): void {
    this.sendRaw(JSON.stringify(msg));
  }

  sendRaw(data: string): void {
    if (this.isOpen) this.socket.send(data);
  }

  close(code: number, reason: string): void {
    this.socket.close(code, reason);
  }

  /** Token bucket. Trả về false nếu client gửi quá nhanh. */
  allowMessage(now: number): boolean {
    this.tokens = Math.min(BUCKET_SIZE, this.tokens + ((now - this.lastRefill) / 1000) * REFILL_PER_SEC);
    this.lastRefill = now;
    if (this.tokens >= 1) {
      this.tokens -= 1;
      return true;
    }
    if (now - this.droppedSince > 60_000) {
      this.dropped = 0;
      this.droppedSince = now;
    }
    this.dropped++;
    return false;
  }

  get abusive(): boolean {
    return this.dropped > MAX_DROPPED_PER_MIN;
  }

  /** Gọi định kỳ. Trả về false (và cắt kết nối) nếu lần ping trước không có pong. */
  heartbeat(): boolean {
    if (!this.alive) {
      this.socket.terminate();
      return false;
    }
    this.alive = false;
    this.socket.ping();
    return true;
  }
}
