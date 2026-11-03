import {
  bigserial,
  boolean,
  geometry,
  index,
  integer,
  jsonb,
  pgEnum,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uuid,
} from 'drizzle-orm/pg-core';
import type { Pos } from '../modules/realtime/protocol.js';

const tstz = (name: string) => timestamp(name, { withTimezone: true });

export const tripStatus = pgEnum('trip_status', ['active', 'ended']);
export const memberRole = pgEnum('member_role', ['leader', 'sweeper', 'member']);

export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  displayName: text('display_name').notNull(),
  deviceSecretHash: text('device_secret_hash').notNull(),
  createdAt: tstz('created_at').notNull().defaultNow(),
});

export const trips = pgTable('trips', {
  id: uuid('id').primaryKey().defaultRandom(),
  name: text('name').notNull(),
  status: tripStatus('status').notNull().default('active'),
  inviteCode: text('invite_code').notNull().unique(),
  lagThresholdM: integer('lag_threshold_m').notNull().default(3000),
  createdBy: uuid('created_by')
    .notNull()
    .references(() => users.id),
  createdAt: tstz('created_at').notNull().defaultNow(),
  endedAt: tstz('ended_at'),
  regroupPoint: geometry('regroup_point', { type: 'point', mode: 'xy', srid: 4326 }),
  regroupTitle: text('regroup_title'),
  regroupSetBy: uuid('regroup_set_by').references(() => users.id),
  regroupSetAt: tstz('regroup_set_at'),
});

export const tripMembers = pgTable(
  'trip_members',
  {
    tripId: uuid('trip_id')
      .notNull()
      .references(() => trips.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id),
    role: memberRole('role').notNull().default('member'),
    color: text('color').notNull(),
    sharing: boolean('sharing').notNull().default(true),
    joinedAt: tstz('joined_at').notNull().defaultNow(),
    /** null = đang là thành viên */
    leftAt: tstz('left_at'),
    /** Bị trưởng đoàn mời ra thì không vào lại được bằng mã mời */
    kickedAt: tstz('kicked_at'),
    /** Vị trí cuối, ghi định kỳ để server khởi động lại vẫn biết người đang mất sóng ở đâu */
    lastPos: jsonb('last_pos').$type<Pos>(),
  },
  (t) => [primaryKey({ columns: [t.tripId, t.userId] }), index('trip_members_user_idx').on(t.userId)],
);

export const tripEvents = pgTable(
  'trip_events',
  {
    id: bigserial('id', { mode: 'number' }).primaryKey(),
    tripId: uuid('trip_id')
      .notNull()
      .references(() => trips.id, { onDelete: 'cascade' }),
    userId: uuid('user_id'),
    type: text('type').notNull(),
    data: jsonb('data').$type<Record<string, unknown>>(),
    at: tstz('at').notNull().defaultNow(),
  },
  (t) => [index('trip_events_trip_idx').on(t.tripId, t.at)],
);
