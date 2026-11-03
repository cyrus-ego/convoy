import { distanceM } from '../../lib/geo.js';
import type { EventType, Pos } from '../realtime/protocol.js';

export interface AlertConfig {
  /** Cách người gần nhất trong đoàn quá ngưỡng này thì báo tụt lại */
  lagThresholdM: number;
  /** Đang chia sẻ mà quá lâu không có vị trí mới thì báo mất tín hiệu */
  signalLostMs: number;
  /** Đứng yên (trong bán kính stoppedRadiusM) quá lâu trong khi đoàn đang chạy */
  stoppedMs: number;
  stoppedRadiusM: number;
  /** Tốc độ trung vị của những người còn lại vượt ngưỡng này thì coi là đoàn đang chạy */
  groupMovingSpeedMs: number;
}

export const DEFAULT_ALERT_CONFIG: AlertConfig = {
  lagThresholdM: 3000,
  signalLostMs: 90_000,
  stoppedMs: 5 * 60_000,
  stoppedRadiusM: 50,
  groupMovingSpeedMs: 4,
};

/** Hết tụt lại khi khoảng cách xuống dưới 80% ngưỡng, tránh báo bật/tắt liên tục quanh ngưỡng */
const LAG_CLEAR_RATIO = 0.8;

export interface AlertInput {
  uid: string;
  sharing: boolean;
  pos: Pos | null;
}

export interface AlertEvent {
  type: Extract<EventType, 'lagging' | 'lagging_cleared' | 'stopped' | 'signal_lost' | 'signal_restored'>;
  uid: string;
  data: Record<string, unknown>;
}

interface MemberAlertState {
  lagging: boolean;
  stopped: boolean;
  signalLostAt: number | null;
  anchor: { lat: number; lng: number; ts: number } | null;
}

/**
 * Luật cảnh báo cho một đoàn. Thuần logic, không I/O, để test được.
 * Mỗi cảnh báo chỉ phát một lần cho tới khi điều kiện hết.
 */
export class AlertEngine {
  private readonly states = new Map<string, MemberAlertState>();

  constructor(private config: AlertConfig = DEFAULT_ALERT_CONFIG) {}

  get signalLostMs(): number {
    return this.config.signalLostMs;
  }

  setLagThreshold(meters: number): void {
    this.config = { ...this.config, lagThresholdM: meters };
  }

  forget(uid: string): void {
    this.states.delete(uid);
  }

  /** Khi nạp lại phòng (server khởi động lại): người đã mất sóng từ trước thì không báo lại */
  markSignalLost(uid: string, lastTs: number): void {
    this.state(uid).signalLostAt = lastTs;
  }

  evaluate(members: AlertInput[], now: number): AlertEvent[] {
    const events: AlertEvent[] = [];
    const { signalLostMs } = this.config;
    const fresh = members.filter(
      (m): m is AlertInput & { pos: Pos } => m.sharing && m.pos !== null && now - m.pos.ts <= signalLostMs,
    );

    for (const m of members) {
      const s = this.state(m.uid);

      if (!m.sharing || !m.pos) {
        // Tạm dừng chia sẻ là chủ ý của người dùng, không phải sự cố: xoá trạng thái, không báo
        Object.assign(s, { lagging: false, stopped: false, signalLostAt: null, anchor: null });
        continue;
      }

      const isFresh = now - m.pos.ts <= signalLostMs;
      if (!isFresh) {
        if (s.signalLostAt === null) {
          s.signalLostAt = m.pos.ts;
          events.push({ type: 'signal_lost', uid: m.uid, data: { lastTs: m.pos.ts } });
        }
        continue;
      }
      if (s.signalLostAt !== null) {
        events.push({ type: 'signal_restored', uid: m.uid, data: { gapMs: m.pos.ts - s.signalLostAt } });
        s.signalLostAt = null;
      }

      const others = fresh.filter((o) => o.uid !== m.uid);
      this.checkLagging(m.uid, m.pos, others, s, events);
      this.checkStopped(m.uid, m.pos, others, s, now, events);
    }
    return events;
  }

  private checkLagging(
    uid: string,
    pos: Pos,
    others: { pos: Pos }[],
    s: MemberAlertState,
    events: AlertEvent[],
  ): void {
    if (others.length === 0) return;
    const nearest = Math.min(...others.map((o) => distanceM(pos.lat, pos.lng, o.pos.lat, o.pos.lng)));
    const distance = Math.round(nearest);
    const threshold = this.config.lagThresholdM;
    if (!s.lagging && nearest > threshold) {
      s.lagging = true;
      events.push({ type: 'lagging', uid, data: { distanceM: distance } });
    } else if (s.lagging && nearest < threshold * LAG_CLEAR_RATIO) {
      s.lagging = false;
      events.push({ type: 'lagging_cleared', uid, data: { distanceM: distance } });
    }
  }

  private checkStopped(
    uid: string,
    pos: Pos,
    others: { pos: Pos }[],
    s: MemberAlertState,
    now: number,
    events: AlertEvent[],
  ): void {
    const { stoppedRadiusM, stoppedMs, groupMovingSpeedMs } = this.config;
    if (!s.anchor || distanceM(s.anchor.lat, s.anchor.lng, pos.lat, pos.lng) > stoppedRadiusM) {
      s.anchor = { lat: pos.lat, lng: pos.lng, ts: pos.ts };
      s.stopped = false;
      return;
    }
    if (s.stopped || now - s.anchor.ts < stoppedMs) return;
    if (median(others.map((o) => o.pos.spd ?? 0)) > groupMovingSpeedMs) {
      s.stopped = true;
      events.push({ type: 'stopped', uid, data: { sinceTs: s.anchor.ts } });
    }
  }

  private state(uid: string): MemberAlertState {
    let s = this.states.get(uid);
    if (!s) {
      s = { lagging: false, stopped: false, signalLostAt: null, anchor: null };
      this.states.set(uid, s);
    }
    return s;
  }
}

function median(values: number[]): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
}
