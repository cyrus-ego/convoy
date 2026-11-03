import Type from 'typebox';
import Schema from 'typebox/schema';
import { distanceM } from '../../lib/geo.js';

// Xem docs/protocol.md

export type Role = 'leader' | 'sweeper' | 'member';

export interface Pos {
  ts: number;
  lat: number;
  lng: number;
  acc: number;
  spd?: number;
  hdg?: number;
  bat?: number;
}

export interface MemberState {
  uid: string;
  name: string;
  role: Role;
  color: string;
  online: boolean;
  sharing: boolean;
  sos: boolean;
  pos: Pos | null;
}

export interface TripInfo {
  id: string;
  name: string;
  status: 'active' | 'ended';
  inviteCode: string;
  lagThresholdM: number;
}

export interface Regroup {
  lat: number;
  lng: number;
  title: string;
  setBy: string;
  setAt: number;
}

export type EventType =
  | 'member_joined'
  | 'member_left'
  | 'role_changed'
  | 'sos'
  | 'sos_cleared'
  | 'lagging'
  | 'lagging_cleared'
  | 'stopped'
  | 'signal_lost'
  | 'signal_restored'
  | 'trip_ended';

export interface TripEvent {
  id: number;
  type: EventType;
  uid: string | null;
  at: number;
  data?: Record<string, unknown>;
}

export type ServerMsg =
  | { t: 'snapshot'; serverTime: number; trip: TripInfo; members: MemberState[]; regroup: Regroup | null }
  | { t: 'delta'; serverTime: number; members: MemberState[] }
  | { t: 'regroup'; regroup: Regroup | null }
  | { t: 'event'; event: TripEvent };

const PosMsg = Type.Object(
  {
    t: Type.Literal('pos'),
    ts: Type.Integer({ minimum: 0 }),
    lat: Type.Number({ minimum: -90, maximum: 90 }),
    lng: Type.Number({ minimum: -180, maximum: 180 }),
    acc: Type.Number({ minimum: 0 }),
    spd: Type.Optional(Type.Number({ minimum: 0, maximum: 150 })),
    hdg: Type.Optional(Type.Number({ minimum: 0, maximum: 360 })),
    bat: Type.Optional(Type.Integer({ minimum: 0, maximum: 100 })),
  },
  { additionalProperties: false },
);
const SharingMsg = Type.Object({ t: Type.Literal('sharing'), on: Type.Boolean() }, { additionalProperties: false });
const SosMsg = Type.Object({ t: Type.Literal('sos'), on: Type.Boolean() }, { additionalProperties: false });
const ClientMsg = Type.Union([PosMsg, SharingMsg, SosMsg]);

export type ClientMsg = Type.Static<typeof ClientMsg>;
export type PosMsg = Type.Static<typeof PosMsg>;

const clientMsgValidator = Schema.Compile(ClientMsg);
const MAX_MSG_BYTES = 1024;

export function parseClientMsg(raw: string): ClientMsg | null {
  if (raw.length > MAX_MSG_BYTES) return null;
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  return clientMsgValidator.Check(value) ? (value as ClientMsg) : null;
}

export const MAX_ACCURACY_M = 1000;
/** ~250 km/h: nhanh hơn thế trong vòng 1 phút thì coi là nhiễu GPS */
export const MAX_PLAUSIBLE_SPEED_MS = 70;
const GLITCH_WINDOW_MS = 60_000;
const MAX_FUTURE_SKEW_MS = 60_000;

/** Quyết định có nhận bản tin vị trí mới hay không (xem docs/protocol.md) */
export function acceptPosition(prev: Pos | null, next: PosMsg, now: number): boolean {
  if (next.acc > MAX_ACCURACY_M) return false;
  if (next.ts > now + MAX_FUTURE_SKEW_MS) return false;
  if (!prev) return true;
  if (next.ts <= prev.ts) return false;
  const dtMs = next.ts - prev.ts;
  if (dtMs < GLITCH_WINDOW_MS) {
    const speed = distanceM(prev.lat, prev.lng, next.lat, next.lng) / Math.max(dtMs / 1000, 1);
    if (speed > MAX_PLAUSIBLE_SPEED_MS) return false;
  }
  return true;
}

const round = (v: number, digits: number) => {
  const f = 10 ** digits;
  return Math.round(v * f) / f;
};

/** Làm tròn để gói tin gọn: 6 chữ số thập phân ≈ 0,1 m */
export function toPos(msg: PosMsg): Pos {
  const pos: Pos = { ts: msg.ts, lat: round(msg.lat, 6), lng: round(msg.lng, 6), acc: round(msg.acc, 1) };
  if (msg.spd !== undefined) pos.spd = round(msg.spd, 1);
  if (msg.hdg !== undefined) pos.hdg = Math.round(msg.hdg) % 360;
  if (msg.bat !== undefined) pos.bat = msg.bat;
  return pos;
}
