import type { FastifyBaseLogger } from 'fastify';
import { AlertEngine, DEFAULT_ALERT_CONFIG } from '../alert/engine.js';
import { type Notifier, PUSH_EVENT_TYPES } from '../notify/notifier.js';
import type { NewEvent, RoomData } from '../trip/service.js';
import type { Peer } from './peer.js';
import {
  acceptPosition,
  type ClientMsg,
  type MemberState,
  type Pos,
  type Regroup,
  type ServerMsg,
  type TripEvent,
  type TripInfo,
  toPos,
} from './protocol.js';

export interface RoomStore {
  loadRoom(tripId: string): Promise<RoomData | null>;
  saveLastPositions(tripId: string, entries: { uid: string; pos: Pos | null }[]): Promise<void>;
  setSharing(tripId: string, uid: string, on: boolean): Promise<void>;
  recordEvent(tripId: string, e: NewEvent): Promise<TripEvent>;
}

export interface RoomDeps {
  store: RoomStore;
  notifier: Notifier;
  log: FastifyBaseLogger;
  tickMs: number;
  now?: () => number;
}

interface LiveMember extends MemberState {
  /** ts của vị trí đã ghi xuống DB gần nhất */
  persistedTs: number;
}

/** Ghi vị trí cuối xuống DB tối đa mỗi 30 giây cho mỗi người */
const PERSIST_EVERY_MS = 30_000;
/** Ngưỡng hàng đợi gửi của socket: vượt HIGH thì bỏ qua delta, xuống dưới LOW thì gửi lại snapshot */
const BUFFER_HIGH = 64 * 1024;
const BUFFER_LOW = 16 * 1024;

/** Trạng thái trực tiếp của một chuyến đi, chỉ nằm trong RAM */
export class Room {
  private readonly members = new Map<string, LiveMember>();
  private readonly peers = new Map<string, Set<Peer>>();
  private readonly dirty = new Set<string>();
  private readonly alerts: AlertEngine;
  private trip: TripInfo;
  private regroup: Regroup | null;
  private timer: NodeJS.Timeout | null;
  private ticking = false;
  lastActivity: number;

  static async load(tripId: string, deps: RoomDeps): Promise<Room | null> {
    const data = await deps.store.loadRoom(tripId);
    return data ? new Room(data, deps) : null;
  }

  private constructor(
    data: RoomData,
    private readonly deps: RoomDeps,
  ) {
    this.trip = data.trip;
    this.regroup = data.regroup;
    this.alerts = new AlertEngine({ ...DEFAULT_ALERT_CONFIG, lagThresholdM: data.trip.lagThresholdM });
    const now = this.now();
    for (const m of data.members) {
      this.members.set(m.uid, toLive(m, m.sharing ? m.lastPos : null));
      if (m.lastPos && now - m.lastPos.ts > this.alerts.signalLostMs) this.alerts.markSignalLost(m.uid, m.lastPos.ts);
    }
    this.lastActivity = now;
    this.timer = setInterval(() => void this.tick(), deps.tickMs);
    this.timer.unref();
  }

  get id(): string {
    return this.trip.id;
  }

  get peerCount(): number {
    let n = 0;
    for (const set of this.peers.values()) n += set.size;
    return n;
  }

  attach(peer: Peer): boolean {
    const member = this.members.get(peer.uid);
    if (!member) {
      peer.close(4403, 'not a member');
      return false;
    }
    let set = this.peers.get(peer.uid);
    if (!set) this.peers.set(peer.uid, (set = new Set()));
    set.add(peer);
    if (!member.online) {
      member.online = true;
      this.dirty.add(peer.uid);
    }
    peer.send(this.snapshot());
    this.lastActivity = this.now();
    return true;
  }

  detach(peer: Peer): void {
    const set = this.peers.get(peer.uid);
    if (!set?.delete(peer)) return;
    this.lastActivity = this.now();
    if (set.size > 0) return;
    this.peers.delete(peer.uid);
    const member = this.members.get(peer.uid);
    if (member) {
      member.online = false;
      this.dirty.add(peer.uid);
    }
  }

  handleMessage(peer: Peer, msg: ClientMsg): void {
    const m = this.members.get(peer.uid);
    if (!m) return;
    this.lastActivity = this.now();

    switch (msg.t) {
      case 'pos': {
        if (!m.sharing || !acceptPosition(m.pos, msg, this.now())) return;
        m.pos = toPos(msg);
        this.dirty.add(m.uid);
        return;
      }
      case 'sharing': {
        if (m.sharing === msg.on) return;
        m.sharing = msg.on;
        if (!msg.on) {
          // Tạm dừng chia sẻ thì người khác không còn thấy cả vị trí cuối
          m.pos = null;
          m.persistedTs = 0;
        }
        this.dirty.add(m.uid);
        this.deps.store.setSharing(this.id, m.uid, msg.on).catch((err) => this.deps.log.error({ err }, 'setSharing'));
        return;
      }
      case 'sos': {
        if (m.sos === msg.on) return;
        m.sos = msg.on;
        this.dirty.add(m.uid);
        // SOS không chờ nhịp gộp
        this.flush();
        const data = m.pos ? { lat: m.pos.lat, lng: m.pos.lng } : undefined;
        void this.publishEvent({ type: msg.on ? 'sos' : 'sos_cleared', uid: m.uid, ...(data ? { data } : {}) });
        return;
      }
    }
  }

  async tick(): Promise<void> {
    if (this.ticking) return;
    this.ticking = true;
    try {
      const now = this.now();
      for (const e of this.alerts.evaluate([...this.members.values()], now)) await this.publishEvent(e);
      this.flush();
      this.persistPositions(false);
    } catch (err) {
      this.deps.log.error({ err, tripId: this.id }, 'room tick failed');
    } finally {
      this.ticking = false;
    }
  }

  /** Gửi delta những người vừa đổi; client chậm thì nhận snapshot khi đã thông */
  flush(): void {
    const changed = [...this.dirty].flatMap((uid) => {
      const m = this.members.get(uid);
      return m ? [toState(m)] : [];
    });
    this.dirty.clear();
    const delta = changed.length ? JSON.stringify({ t: 'delta', serverTime: this.now(), members: changed }) : null;
    let snapshot: string | null = null;

    for (const peer of this.allPeers()) {
      if (peer.needsSnapshot) {
        if (peer.bufferedAmount > BUFFER_LOW) continue;
        snapshot ??= JSON.stringify(this.snapshot());
        peer.sendRaw(snapshot);
        peer.needsSnapshot = false;
      } else if (delta) {
        if (peer.bufferedAmount > BUFFER_HIGH) peer.needsSnapshot = true;
        else peer.sendRaw(delta);
      }
    }
  }

  async publishEvent(e: NewEvent): Promise<void> {
    let event: TripEvent;
    try {
      event = await this.deps.store.recordEvent(this.id, e);
    } catch (err) {
      this.deps.log.error({ err, tripId: this.id }, 'recordEvent failed');
      event = { id: 0, type: e.type, uid: e.uid, at: this.now(), ...(e.data ? { data: e.data } : {}) };
    }
    this.broadcast({ t: 'event', event });
    if (PUSH_EVENT_TYPES.has(event.type)) {
      const recipients = [...this.members.keys()].filter((uid) => uid !== event.uid);
      this.deps.notifier
        .notifyTripEvent(this.id, event, recipients)
        .catch((err) => this.deps.log.error({ err }, 'notify failed'));
    }
  }

  /** Nạp lại danh sách thành viên sau khi có người vào/rời/đổi vai trò qua REST */
  async reload(): Promise<void> {
    const data = await this.deps.store.loadRoom(this.id);
    if (!data) return;
    this.trip = data.trip;
    this.regroup = data.regroup;
    this.alerts.setLagThreshold(data.trip.lagThresholdM);

    const activeIds = new Set(data.members.map((m) => m.uid));
    for (const uid of [...this.members.keys()]) {
      if (activeIds.has(uid)) continue;
      this.members.delete(uid);
      this.dirty.delete(uid);
      this.alerts.forget(uid);
      for (const peer of this.peers.get(uid) ?? []) peer.close(4403, 'removed from trip');
      this.peers.delete(uid);
    }
    for (const m of data.members) {
      const live = this.members.get(m.uid);
      if (live) Object.assign(live, { name: m.name, role: m.role, color: m.color });
      else this.members.set(m.uid, toLive(m, null));
    }
    // Đổi thành viên hiếm khi xảy ra: gửi lại toàn bộ cho mọi người cho đơn giản
    for (const peer of this.allPeers()) peer.needsSnapshot = true;
    this.flush();
  }

  setRegroup(regroup: Regroup | null): void {
    this.regroup = regroup;
    this.broadcast({ t: 'regroup', regroup });
  }

  /** Chuyến kết thúc: báo cho mọi người rồi đóng phòng */
  end(event: TripEvent): void {
    this.broadcast({ t: 'event', event });
    this.stopTimer();
    for (const peer of this.allPeers()) peer.close(4403, 'trip ended');
    this.peers.clear();
  }

  /** Đóng phòng (server tắt hoặc phòng không ai dùng): ghi nốt vị trí cuối */
  async close(code?: number): Promise<void> {
    this.stopTimer();
    if (code) for (const peer of this.allPeers()) peer.close(code, 'server restarting');
    this.peers.clear();
    await this.persistPositions(true);
  }

  snapshot(): ServerMsg {
    return {
      t: 'snapshot',
      serverTime: this.now(),
      trip: this.trip,
      members: [...this.members.values()].map(toState),
      regroup: this.regroup,
    };
  }

  private persistPositions(all: boolean): Promise<void> {
    const entries: { uid: string; pos: Pos | null }[] = [];
    for (const m of this.members.values()) {
      if (!m.pos) continue;
      if (all ? m.pos.ts > m.persistedTs : m.pos.ts - m.persistedTs >= PERSIST_EVERY_MS) {
        entries.push({ uid: m.uid, pos: m.pos });
        m.persistedTs = m.pos.ts;
      }
    }
    return this.deps.store
      .saveLastPositions(this.id, entries)
      .catch((err) => this.deps.log.error({ err, tripId: this.id }, 'saveLastPositions failed'));
  }

  private broadcast(msg: ServerMsg): void {
    const data = JSON.stringify(msg);
    for (const peer of this.allPeers()) peer.sendRaw(data);
  }

  private *allPeers(): Generator<Peer> {
    for (const set of this.peers.values()) yield* set;
  }

  private stopTimer(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  private now(): number {
    return this.deps.now?.() ?? Date.now();
  }
}

function toLive(m: RoomData['members'][number], pos: Pos | null): LiveMember {
  return {
    uid: m.uid,
    name: m.name,
    role: m.role,
    color: m.color,
    online: false,
    sharing: m.sharing,
    sos: false,
    pos,
    persistedTs: pos?.ts ?? 0,
  };
}

function toState(m: LiveMember): MemberState {
  const { persistedTs: _, ...state } = m;
  return state;
}
