import { and, asc, eq, isNull, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { tripEvents, tripMembers, trips, users } from '../../db/schema.js';
import { conflict, forbidden, notFound } from '../../lib/errors.js';
import { generateInviteCode, normalizeInviteCode } from '../../lib/secrets.js';
import type { EventType, Pos, Regroup, Role, TripEvent, TripInfo } from '../realtime/protocol.js';

export const MAX_MEMBERS = 50;

/** Màu dễ phân biệt trên nền bản đồ, cấp theo thứ tự vào đoàn */
export const MEMBER_COLORS = [
  '#E53935', '#1E88E5', '#43A047', '#FB8C00', '#8E24AA', '#00ACC1',
  '#D81B60', '#6D4C41', '#3949AB', '#7CB342', '#F4511E', '#546E7A',
];

export interface MemberInfo {
  uid: string;
  name: string;
  role: Role;
  color: string;
  sharing: boolean;
}

export interface TripDetail extends TripInfo {
  members: MemberInfo[];
  regroup: Regroup | null;
  myRole: Role;
}

export interface RoomData {
  trip: TripInfo;
  members: (MemberInfo & { lastPos: Pos | null })[];
  regroup: Regroup | null;
}

/** Phía realtime nhận thông báo khi dữ liệu chuyến đổi qua REST */
export interface TripRealtime {
  membersChanged(tripId: string, event?: NewEvent): Promise<void>;
  regroupChanged(tripId: string, regroup: Regroup | null): void;
  tripEnded(tripId: string, event: TripEvent): void;
}

export interface NewEvent {
  type: EventType;
  uid: string | null;
  data?: Record<string, unknown>;
}

type TripRow = typeof trips.$inferSelect;

export class TripService {
  private realtime: TripRealtime | null = null;

  constructor(private readonly db: Db) {}

  attachRealtime(realtime: TripRealtime): void {
    this.realtime = realtime;
  }

  async createTrip(userId: string, name: string): Promise<TripDetail> {
    for (let attempt = 0; ; attempt++) {
      try {
        const tripId = await this.db.transaction(async (tx) => {
          const [trip] = await tx
            .insert(trips)
            .values({ name, inviteCode: generateInviteCode(), createdBy: userId })
            .returning({ id: trips.id });
          await tx.insert(tripMembers).values({ tripId: trip!.id, userId, role: 'leader', color: MEMBER_COLORS[0]! });
          return trip!.id;
        });
        return this.getTrip(userId, tripId);
      } catch (err) {
        // Trùng mã mời (rất hiếm): thử lại với mã khác
        if (isUniqueViolation(err) && attempt < 5) continue;
        throw err;
      }
    }
  }

  async joinByCode(userId: string, rawCode: string): Promise<TripDetail> {
    const code = normalizeInviteCode(rawCode);
    const result = await this.db.transaction(async (tx) => {
      // Khoá dòng chuyến đi để đếm thành viên và cấp màu không bị tranh chấp
      const [trip] = await tx
        .select()
        .from(trips)
        .where(and(eq(trips.inviteCode, code), eq(trips.status, 'active')))
        .for('update');
      if (!trip) throw notFound('Mã mời không đúng hoặc chuyến đi đã kết thúc');

      const rows = await tx.select().from(tripMembers).where(eq(tripMembers.tripId, trip.id));
      const existing = rows.find((r) => r.userId === userId);
      if (existing?.kickedAt) throw forbidden('Bạn đã bị mời ra khỏi chuyến đi này');
      if (existing && !existing.leftAt) return { tripId: trip.id, joined: false };

      const active = rows.filter((r) => !r.leftAt);
      if (active.length >= MAX_MEMBERS) throw conflict('trip_full', `Đoàn đã đủ ${MAX_MEMBERS} người`);

      const used = new Set(active.map((r) => r.color));
      const color = MEMBER_COLORS.find((c) => !used.has(c)) ?? MEMBER_COLORS[active.length % MEMBER_COLORS.length]!;
      await tx
        .insert(tripMembers)
        .values({ tripId: trip.id, userId, role: 'member', color })
        .onConflictDoUpdate({
          target: [tripMembers.tripId, tripMembers.userId],
          set: { leftAt: null, role: 'member', color, sharing: true, lastPos: null, joinedAt: sql`now()` },
        });
      return { tripId: trip.id, joined: true };
    });

    if (result.joined) await this.realtime?.membersChanged(result.tripId, { type: 'member_joined', uid: userId });
    return this.getTrip(userId, result.tripId);
  }

  async listMyTrips(userId: string): Promise<TripInfo[]> {
    const rows = await this.db
      .select({ trip: trips })
      .from(tripMembers)
      .innerJoin(trips, eq(trips.id, tripMembers.tripId))
      .where(and(eq(tripMembers.userId, userId), isNull(tripMembers.leftAt), eq(trips.status, 'active')))
      .orderBy(asc(trips.createdAt));
    return rows.map((r) => toTripInfo(r.trip));
  }

  async getTrip(userId: string, tripId: string): Promise<TripDetail> {
    const { trip, role } = await this.requireMember(userId, tripId, { allowEnded: true });
    const members = await this.activeMembers(tripId);
    return { ...toTripInfo(trip), members, regroup: toRegroup(trip), myRole: role };
  }

  async leave(userId: string, tripId: string): Promise<void> {
    const { role } = await this.requireMember(userId, tripId);
    if (role === 'leader') throw conflict('leader_cannot_leave', 'Trưởng đoàn không rời được, hãy kết thúc chuyến đi');
    await this.db
      .update(tripMembers)
      .set({ leftAt: sql`now()`, lastPos: null })
      .where(and(eq(tripMembers.tripId, tripId), eq(tripMembers.userId, userId)));
    await this.realtime?.membersChanged(tripId, { type: 'member_left', uid: userId });
  }

  async endTrip(userId: string, tripId: string): Promise<void> {
    await this.requireRole(userId, tripId, ['leader']);
    await this.db.update(trips).set({ status: 'ended', endedAt: sql`now()` }).where(eq(trips.id, tripId));
    // Chuyến kết thúc thì không giữ vị trí của ai nữa
    await this.db.update(tripMembers).set({ lastPos: null }).where(eq(tripMembers.tripId, tripId));
    const event = await this.recordEvent(tripId, { type: 'trip_ended', uid: userId });
    this.realtime?.tripEnded(tripId, event);
  }

  async rotateInvite(userId: string, tripId: string): Promise<TripInfo> {
    await this.requireRole(userId, tripId, ['leader']);
    for (let attempt = 0; ; attempt++) {
      try {
        const [trip] = await this.db
          .update(trips)
          .set({ inviteCode: generateInviteCode() })
          .where(eq(trips.id, tripId))
          .returning();
        await this.realtime?.membersChanged(tripId);
        return toTripInfo(trip!);
      } catch (err) {
        if (isUniqueViolation(err) && attempt < 5) continue;
        throw err;
      }
    }
  }

  async setRole(userId: string, tripId: string, targetId: string, role: 'sweeper' | 'member'): Promise<void> {
    await this.requireRole(userId, tripId, ['leader']);
    if (targetId === userId) throw conflict('cannot_change_self', 'Không đổi được vai trò của chính mình');
    await this.requireMember(targetId, tripId);
    await this.db
      .update(tripMembers)
      .set({ role })
      .where(and(eq(tripMembers.tripId, tripId), eq(tripMembers.userId, targetId)));
    await this.realtime?.membersChanged(tripId, { type: 'role_changed', uid: targetId, data: { role } });
  }

  async kick(userId: string, tripId: string, targetId: string): Promise<void> {
    await this.requireRole(userId, tripId, ['leader']);
    if (targetId === userId) throw conflict('cannot_kick_self', 'Không tự mời mình ra được');
    await this.requireMember(targetId, tripId);
    await this.db
      .update(tripMembers)
      .set({ leftAt: sql`now()`, kickedAt: sql`now()`, lastPos: null })
      .where(and(eq(tripMembers.tripId, tripId), eq(tripMembers.userId, targetId)));
    await this.realtime?.membersChanged(tripId, { type: 'member_left', uid: targetId, data: { kicked: true } });
  }

  async setRegroup(userId: string, tripId: string, point: { lat: number; lng: number; title?: string }): Promise<Regroup> {
    await this.requireRole(userId, tripId, ['leader', 'sweeper']);
    const [trip] = await this.db
      .update(trips)
      .set({
        regroupPoint: { x: point.lng, y: point.lat },
        regroupTitle: point.title?.trim() || 'Điểm tập kết',
        regroupSetBy: userId,
        regroupSetAt: sql`now()`,
      })
      .where(eq(trips.id, tripId))
      .returning();
    const regroup = toRegroup(trip!)!;
    this.realtime?.regroupChanged(tripId, regroup);
    return regroup;
  }

  async clearRegroup(userId: string, tripId: string): Promise<void> {
    await this.requireRole(userId, tripId, ['leader', 'sweeper']);
    await this.db
      .update(trips)
      .set({ regroupPoint: null, regroupTitle: null, regroupSetBy: null, regroupSetAt: null })
      .where(eq(trips.id, tripId));
    this.realtime?.regroupChanged(tripId, null);
  }

  /** Ném 404 nếu không phải thành viên đang hoạt động (kể cả khi chuyến không tồn tại) */
  async requireMember(
    userId: string,
    tripId: string,
    opts: { allowEnded?: boolean } = {},
  ): Promise<{ trip: TripRow; role: Role }> {
    const [row] = await this.db
      .select({ trip: trips, role: tripMembers.role })
      .from(tripMembers)
      .innerJoin(trips, eq(trips.id, tripMembers.tripId))
      .where(and(eq(tripMembers.tripId, tripId), eq(tripMembers.userId, userId), isNull(tripMembers.leftAt)));
    if (!row) throw notFound('Không tìm thấy chuyến đi');
    if (row.trip.status === 'ended' && !opts.allowEnded) throw conflict('trip_ended', 'Chuyến đi đã kết thúc');
    return row;
  }

  private async requireRole(userId: string, tripId: string, roles: Role[]): Promise<TripRow> {
    const { trip, role } = await this.requireMember(userId, tripId);
    if (!roles.includes(role)) throw forbidden();
    return trip;
  }

  private async activeMembers(tripId: string): Promise<(MemberInfo & { lastPos: Pos | null })[]> {
    const rows = await this.db
      .select({
        uid: tripMembers.userId,
        name: users.displayName,
        role: tripMembers.role,
        color: tripMembers.color,
        sharing: tripMembers.sharing,
        lastPos: tripMembers.lastPos,
      })
      .from(tripMembers)
      .innerJoin(users, eq(users.id, tripMembers.userId))
      .where(and(eq(tripMembers.tripId, tripId), isNull(tripMembers.leftAt)))
      .orderBy(asc(tripMembers.joinedAt));
    return rows.map((r) => ({ ...r, lastPos: r.lastPos ?? null }));
  }

  // ---- Dành cho realtime ----

  async loadRoom(tripId: string): Promise<RoomData | null> {
    const [trip] = await this.db.select().from(trips).where(eq(trips.id, tripId));
    if (!trip || trip.status !== 'active') return null;
    return { trip: toTripInfo(trip), members: await this.activeMembers(tripId), regroup: toRegroup(trip) };
  }

  async saveLastPositions(tripId: string, entries: { uid: string; pos: Pos | null }[]): Promise<void> {
    if (entries.length === 0) return;
    await this.db.transaction(async (tx) => {
      for (const e of entries) {
        // Điều kiện sharing/left_at nằm trong câu UPDATE: lệnh ghi này có chạy sau lệnh tạm dừng chia sẻ
        // hay mời ra (do chạy song song) thì cũng không ghi lại vị trí
        await tx
          .update(tripMembers)
          .set({ lastPos: e.pos })
          .where(
            and(
              eq(tripMembers.tripId, tripId),
              eq(tripMembers.userId, e.uid),
              eq(tripMembers.sharing, true),
              isNull(tripMembers.leftAt),
            ),
          );
      }
    });
  }

  async setSharing(tripId: string, userId: string, on: boolean): Promise<void> {
    await this.db
      .update(tripMembers)
      .set(on ? { sharing: true } : { sharing: false, lastPos: null })
      .where(and(eq(tripMembers.tripId, tripId), eq(tripMembers.userId, userId)));
  }

  async recordEvent(tripId: string, e: NewEvent): Promise<TripEvent> {
    const [row] = await this.db
      .insert(tripEvents)
      .values({ tripId, userId: e.uid, type: e.type, data: e.data ?? null })
      .returning();
    return { id: row!.id, type: e.type, uid: e.uid, at: row!.at.getTime(), ...(e.data ? { data: e.data } : {}) };
  }
}

function toTripInfo(t: TripRow): TripInfo {
  return { id: t.id, name: t.name, status: t.status, inviteCode: t.inviteCode, lagThresholdM: t.lagThresholdM };
}

function toRegroup(t: TripRow): Regroup | null {
  if (!t.regroupPoint || !t.regroupSetBy || !t.regroupSetAt) return null;
  return {
    lat: t.regroupPoint.y,
    lng: t.regroupPoint.x,
    title: t.regroupTitle ?? 'Điểm tập kết',
    setBy: t.regroupSetBy,
    setAt: t.regroupSetAt.getTime(),
  };
}

function isUniqueViolation(err: unknown): boolean {
  const e = err as { code?: string; cause?: { code?: string } };
  return e?.code === '23505' || e?.cause?.code === '23505';
}
