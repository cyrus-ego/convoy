import type { WebSocket } from 'ws';
import type { NewEvent, TripRealtime } from '../trip/service.js';
import { WsPeer } from './peer.js';
import { type ClientMsg, parseClientMsg, type Regroup, type TripEvent } from './protocol.js';
import { Room, type RoomDeps } from './room.js';

const HEARTBEAT_MS = 25_000;
const GC_EVERY_MS = 60_000;
/** Phòng không còn ai kết nối quá lâu thì giải phóng khỏi RAM (vị trí cuối đã nằm trong DB) */
const ROOM_IDLE_MS = 10 * 60_000;
/** Bản tin đến trong lúc phòng đang nạp: giữ tối đa chừng này */
const MAX_PENDING = 20;

/** Quản lý các phòng đang mở trong tiến trình này */
export class Hub implements TripRealtime {
  private readonly rooms = new Map<string, Room>();
  private readonly loading = new Map<string, Promise<Room | null>>();
  private readonly peers = new Set<WsPeer>();
  private readonly timers: NodeJS.Timeout[];

  constructor(private readonly deps: RoomDeps) {
    this.timers = [
      setInterval(() => {
        for (const peer of this.peers) if (!peer.heartbeat()) this.peers.delete(peer);
      }, HEARTBEAT_MS),
      setInterval(() => void this.collectIdleRooms(), GC_EVERY_MS),
    ];
    for (const t of this.timers) t.unref();
  }

  /**
   * Gắn socket vừa nâng cấp vào phòng. Phải gọi đồng bộ trong handler WebSocket
   * để không lỡ bản tin client gửi ngay khi mở kết nối.
   */
  accept(tripId: string, uid: string, socket: WebSocket): void {
    const peer = new WsPeer(uid, socket);
    this.peers.add(peer);
    let room: Room | null = null;
    const pending: ClientMsg[] = [];

    socket.on('message', (data, isBinary) => {
      if (isBinary) return;
      if (!peer.allowMessage(Date.now())) {
        if (peer.abusive) peer.close(4008, 'too many messages');
        return;
      }
      const msg = parseClientMsg(data.toString());
      if (!msg) return;
      if (room) room.handleMessage(peer, msg);
      else if (pending.length < MAX_PENDING) pending.push(msg);
    });
    socket.on('close', () => {
      this.peers.delete(peer);
      room?.detach(peer);
    });
    socket.on('error', (err) => this.deps.log.warn({ err, uid }, 'websocket error'));

    this.getRoom(tripId)
      .then((r) => {
        if (!r) return peer.close(4403, 'trip not available');
        if (!peer.isOpen || !r.attach(peer)) return;
        room = r;
        for (const msg of pending) r.handleMessage(peer, msg);
      })
      .catch((err) => {
        this.deps.log.error({ err, tripId }, 'load room failed');
        peer.close(1011, 'internal error');
      });
  }

  async getRoom(tripId: string): Promise<Room | null> {
    const existing = this.rooms.get(tripId);
    if (existing) return existing;
    let promise = this.loading.get(tripId);
    if (!promise) {
      promise = Room.load(tripId, this.deps)
        .then((room) => {
          if (room) this.rooms.set(tripId, room);
          return room;
        })
        .finally(() => this.loading.delete(tripId));
      this.loading.set(tripId, promise);
    }
    return promise;
  }

  // ---- TripRealtime: REST báo thay đổi ----

  async membersChanged(tripId: string, event?: NewEvent): Promise<void> {
    const room = this.rooms.get(tripId) ?? (await this.loading.get(tripId)) ?? null;
    if (room) await room.reload();
    if (!event) return;
    if (room) await room.publishEvent(event);
    else await this.deps.store.recordEvent(tripId, event);
  }

  regroupChanged(tripId: string, regroup: Regroup | null): void {
    this.rooms.get(tripId)?.setRegroup(regroup);
  }

  tripEnded(tripId: string, event: TripEvent): void {
    const room = this.rooms.get(tripId);
    if (!room) return;
    this.rooms.delete(tripId);
    room.end(event);
  }

  async close(): Promise<void> {
    for (const t of this.timers) clearInterval(t);
    const rooms = [...this.rooms.values()];
    this.rooms.clear();
    // 1012: server khởi động lại, client nên kết nối lại
    await Promise.all(rooms.map((r) => r.close(1012)));
  }

  private async collectIdleRooms(): Promise<void> {
    const now = Date.now();
    for (const [id, room] of this.rooms) {
      if (room.peerCount > 0 || now - room.lastActivity < ROOM_IDLE_MS) continue;
      this.rooms.delete(id);
      await room.close();
    }
  }
}
