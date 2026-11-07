import type { AddressInfo } from 'node:net';
import { WebSocket } from 'ws';
import { buildApp } from '../src/app.js';
import type { Config } from '../src/config.js';
import { createDb } from '../src/db/client.js';
import type { Notifier } from '../src/modules/notify/notifier.js';
import type { ServerMsg, TripEvent } from '../src/modules/realtime/protocol.js';

export const TEST_DB_URL = process.env.DATABASE_URL_TEST ?? 'postgres://convoy:convoy@localhost:5433/convoy_test';

export class RecordingNotifier implements Notifier {
  readonly sent: { tripId: string; event: TripEvent; recipientIds: string[] }[] = [];
  async notifyTripEvent(tripId: string, event: TripEvent, recipientIds: string[]) {
    this.sent.push({ tripId, event, recipientIds });
  }
}

export type TestServer = Awaited<ReturnType<typeof startServer>>;

export async function startServer(opts: { tickMs?: number } = {}) {
  const database = createDb(TEST_DB_URL);
  const config: Config = {
    port: 0,
    host: '127.0.0.1',
    databaseUrl: TEST_DB_URL,
    jwtSecret: 'test-secret-test-secret-test-secret-1234',
    accessTokenTtlSec: 3600,
    tickMs: opts.tickMs ?? 50,
    logLevel: 'silent',
  };
  const notifier = new RecordingNotifier();
  const built = await buildApp({ config, db: database.db, notifier, logger: false });
  await built.app.listen({ port: 0, host: '127.0.0.1' });
  const { port } = built.app.server.address() as AddressInfo;
  const base = `http://127.0.0.1:${port}`;
  return {
    ...built,
    base,
    notifier,
    sql: database.sql,
    async stop() {
      await built.app.close();
      await database.close();
    },
  };
}

export async function resetDb(server: TestServer) {
  await server.sql`TRUNCATE trip_events, trip_members, trips, users CASCADE`;
}

export async function api<T = any>(
  base: string,
  method: string,
  path: string,
  opts: { token?: string; body?: unknown } = {},
): Promise<{ status: number; body: T }> {
  const res = await fetch(base + path, {
    method,
    headers: {
      ...(opts.body !== undefined ? { 'content-type': 'application/json' } : {}),
      ...(opts.token ? { authorization: `Bearer ${opts.token}` } : {}),
    },
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : undefined };
}

export async function newUser(base: string, displayName: string) {
  const res = await api(base, 'POST', '/v1/auth/anonymous', { body: { displayName } });
  if (res.status !== 201) throw new Error(`anonymous failed: ${res.status}`);
  return res.body as { userId: string; deviceSecret: string; accessToken: string; expiresAt: number };
}

/** Một trưởng đoàn và n thành viên đã vào chung một chuyến */
export async function tripWithMembers(base: string, names: string[]) {
  const users = await Promise.all(names.map((n) => newUser(base, n)));
  const [leader, ...rest] = users;
  const trip = await api(base, 'POST', '/v1/trips', { token: leader!.accessToken, body: { name: 'Hà Giang' } });
  for (const u of rest) {
    const res = await api(base, 'POST', '/v1/trips/join', { token: u.accessToken, body: { code: trip.body.inviteCode } });
    if (res.status !== 200) throw new Error(`join failed: ${res.status}`);
  }
  return { tripId: trip.body.id as string, inviteCode: trip.body.inviteCode as string, users };
}

export class TestSocket {
  readonly messages: ServerMsg[] = [];
  closeCode: number | null = null;
  private waiters: (() => void)[] = [];

  constructor(readonly ws: WebSocket) {
    ws.on('message', (data) => {
      this.messages.push(JSON.parse(data.toString()));
      this.notify();
    });
    ws.on('close', (code) => {
      this.closeCode = code;
      this.notify();
    });
  }

  send(msg: unknown) {
    this.ws.send(JSON.stringify(msg));
  }

  /** Chờ tới khi có bản tin thoả điều kiện (tính cả bản tin đã nhận trước đó) */
  async waitFor<M extends ServerMsg>(pred: (m: ServerMsg) => m is M, timeoutMs?: number): Promise<M>;
  async waitFor(pred: (m: ServerMsg) => boolean, timeoutMs?: number): Promise<ServerMsg>;
  async waitFor(pred: (m: ServerMsg) => boolean, timeoutMs = 3000): Promise<ServerMsg> {
    return this.until(() => this.messages.find(pred), timeoutMs, 'message');
  }

  async waitForClose(timeoutMs = 3000): Promise<number> {
    return this.until(() => this.closeCode ?? undefined, timeoutMs, 'close');
  }

  clear() {
    this.messages.length = 0;
  }

  close() {
    this.ws.close();
  }

  private async until<T>(get: () => T | undefined, timeoutMs: number, what: string): Promise<T> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const v = get();
      if (v !== undefined) return v;
      const left = deadline - Date.now();
      if (left <= 0) throw new Error(`timeout waiting for ${what}; got ${JSON.stringify(this.messages)}`);
      await new Promise<void>((resolve) => {
        const t = setTimeout(resolve, left);
        this.waiters.push(() => {
          clearTimeout(t);
          resolve();
        });
      });
    }
  }

  private notify() {
    const w = this.waiters;
    this.waiters = [];
    for (const f of w) f();
  }
}

/** Mở WebSocket; nếu server từ chối nâng cấp thì trả về HTTP status */
export function connect(base: string, tripId: string, token?: string): Promise<TestSocket | { status: number }> {
  const url = `${base.replace('http', 'ws')}/v1/ws?trip=${tripId}`;
  const ws = new WebSocket(url, { headers: token ? { authorization: `Bearer ${token}` } : {} });
  const socket = new TestSocket(ws);
  return new Promise((resolve, reject) => {
    ws.once('open', () => resolve(socket));
    ws.once('unexpected-response', (_req, res) => resolve({ status: res.statusCode ?? 0 }));
    ws.once('error', reject);
  });
}

export async function mustConnect(base: string, tripId: string, token: string): Promise<TestSocket> {
  const s = await connect(base, tripId, token);
  if (!(s instanceof TestSocket)) throw new Error(`upgrade rejected: ${s.status}`);
  await s.waitFor((m) => m.t === 'snapshot');
  return s;
}

export const isDeltaWith =
  (uid: string, pred: (m: Extract<ServerMsg, { t: 'delta' }>['members'][number]) => boolean = () => true) =>
  (m: ServerMsg): m is Extract<ServerMsg, { t: 'delta' }> =>
    m.t === 'delta' && m.members.some((x) => x.uid === uid && pred(x));

export const isEvent =
  (type: TripEvent['type'], uid?: string) =>
  (m: ServerMsg): m is Extract<ServerMsg, { t: 'event' }> =>
    m.t === 'event' && m.event.type === type && (uid === undefined || m.event.uid === uid);
