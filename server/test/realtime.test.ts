import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { destination } from '../src/lib/geo.js';
import {
  api,
  connect,
  isDeltaWith,
  isEvent,
  mustConnect,
  newUser,
  resetDb,
  startServer,
  type TestServer,
  TestSocket,
  tripWithMembers,
} from './helpers.js';

const HN = { lat: 21.0285, lng: 105.8542 };
let server: TestServer;
let base: string;
const sockets: TestSocket[] = [];

async function open(tripId: string, token: string) {
  const s = await mustConnect(base, tripId, token);
  sockets.push(s);
  return s;
}

function pos(meters: number, ts = Date.now(), extra: Record<string, number> = {}) {
  const p = destination(HN.lat, HN.lng, 90, meters);
  return { t: 'pos', ts, lat: p.lat, lng: p.lng, acc: 5, ...extra };
}

beforeAll(async () => {
  server = await startServer({ tickMs: 50 });
  base = server.base;
});
afterAll(() => server.stop());
beforeEach(() => resetDb(server));
afterEach(() => {
  for (const s of sockets.splice(0)) s.close();
});

describe('kết nối', () => {
  it('từ chối trước khi mở socket: thiếu token 401, người ngoài 404, chuyến đã kết thúc 409', async () => {
    const { tripId, users } = await tripWithMembers(base, ['An', 'Bình']);
    expect(await connect(base, tripId)).toEqual({ status: 401 });

    const outsider = await newUser(base, 'Lạ');
    expect(await connect(base, tripId, outsider.accessToken)).toEqual({ status: 404 });

    await api(base, 'POST', `/v1/trips/${tripId}/end`, { token: users[0]!.accessToken });
    expect(await connect(base, tripId, users[1]!.accessToken)).toEqual({ status: 409 });
  });

  it('snapshot ban đầu có đủ thành viên; người kia thấy mình online', async () => {
    const { tripId, users } = await tripWithMembers(base, ['An', 'Bình']);
    const [a, b] = users;
    const sa = await open(tripId, a!.accessToken);
    const snap = sa.messages[0]!;
    expect(snap.t).toBe('snapshot');
    if (snap.t !== 'snapshot') return;
    expect(snap.trip).toMatchObject({ id: tripId, name: 'Hà Giang', status: 'active' });
    expect(snap.members.map((m) => m.name).sort()).toEqual(['An', 'Bình']);
    expect(snap.members.find((m) => m.uid === a!.userId)).toMatchObject({ online: true, role: 'leader', pos: null });

    await open(tripId, b!.accessToken);
    await sa.waitFor(isDeltaWith(b!.userId, (m) => m.online));
  });
});

describe('vị trí', () => {
  it('vị trí của A tới B qua delta; bản đến trễ và cú nhảy phi lý bị bỏ', async () => {
    const { tripId, users } = await tripWithMembers(base, ['An', 'Bình']);
    const [a, b] = users;
    const sa = await open(tripId, a!.accessToken);
    const sb = await open(tripId, b!.accessToken);

    const t0 = Date.now();
    sa.send(pos(0, t0, { spd: 12.34, hdg: 91.6, bat: 80 }));
    const d = await sb.waitFor(isDeltaWith(a!.userId, (m) => m.pos !== null));
    expect(d.members.find((m) => m.uid === a!.userId)!.pos).toMatchObject({ ts: t0, spd: 12.3, hdg: 92, bat: 80 });

    sb.clear();
    sa.send(pos(30, t0 - 1000)); // đến trễ
    sa.send(pos(5000, t0 + 2000)); // 2,5 km/s
    sa.send(pos(40, t0 + 3000)); // hợp lệ
    const next = await sb.waitFor(isDeltaWith(a!.userId, (m) => m.pos?.ts === t0 + 3000));
    expect(next).toBeDefined();
    const seen = sb.messages.flatMap((m) => (m.t === 'delta' ? m.members.map((x) => x.pos?.ts) : []));
    expect(seen).not.toContain(t0 - 1000);
    expect(seen).not.toContain(t0 + 2000);
  });

  it('bản tin gửi ngay khi vừa mở socket không bị mất', async () => {
    const { tripId, users } = await tripWithMembers(base, ['An', 'Bình']);
    const [a, b] = users;
    const sb = await open(tripId, b!.accessToken);
    const raw = await connect(base, tripId, a!.accessToken);
    if (!(raw instanceof TestSocket)) throw new Error('rejected');
    sockets.push(raw);
    raw.send(pos(0));
    await sb.waitFor(isDeltaWith(a!.userId, (m) => m.pos !== null));
  });

  it('tạm dừng chia sẻ: người khác mất vị trí của mình, vị trí gửi sau đó bị bỏ, DB không còn giữ', async () => {
    const { tripId, users } = await tripWithMembers(base, ['An', 'Bình']);
    const [a, b] = users;
    const sa = await open(tripId, a!.accessToken);
    const sb = await open(tripId, b!.accessToken);
    sa.send(pos(0));
    await sb.waitFor(isDeltaWith(a!.userId, (m) => m.pos !== null));

    sa.send({ t: 'sharing', on: false });
    await sb.waitFor(isDeltaWith(a!.userId, (m) => !m.sharing && m.pos === null));
    sb.clear();
    sa.send(pos(10, Date.now() + 1000));
    await new Promise((r) => setTimeout(r, 200));
    expect(sb.messages.some(isDeltaWith(a!.userId, (m) => m.pos !== null))).toBe(false);

    const [row] = await server.sql`SELECT sharing, last_pos FROM trip_members WHERE user_id = ${a!.userId}`;
    expect(row).toMatchObject({ sharing: false, last_pos: null });
  });

  it('vị trí cuối được giữ qua lần khởi động lại server', async () => {
    const { tripId, users } = await tripWithMembers(base, ['An', 'Bình']);
    const [a, b] = users;
    const sa = await open(tripId, a!.accessToken);
    const ts = Date.now();
    sa.send(pos(123, ts));
    await sa.waitFor(isDeltaWith(a!.userId, (m) => m.pos?.ts === ts));

    // Tắt server (ghi nốt vị trí xuống DB), bật server mới
    await server.stop();
    sockets.length = 0;
    server = await startServer({ tickMs: 50 });
    base = server.base;

    const sb = await open(tripId, b!.accessToken);
    const snap = sb.messages[0]!;
    if (snap.t !== 'snapshot') throw new Error('expected snapshot');
    expect(snap.members.find((m) => m.uid === a!.userId)).toMatchObject({ online: false, pos: { ts } });
  });
});

describe('sự kiện', () => {
  it('SOS tới ngay người khác và đẩy thông báo cho mọi người trừ người bấm', async () => {
    const { tripId, users } = await tripWithMembers(base, ['An', 'Bình', 'Cường']);
    const [a, b] = users;
    const sa = await open(tripId, a!.accessToken);
    const sb = await open(tripId, b!.accessToken);
    sa.send(pos(0));
    await sb.waitFor(isDeltaWith(a!.userId, (m) => m.pos !== null));

    sa.send({ t: 'sos', on: true });
    const ev = await sb.waitFor(isEvent('sos', a!.userId));
    expect(ev.event.data).toMatchObject({ lat: expect.any(Number), lng: expect.any(Number) });
    await sb.waitFor(isDeltaWith(a!.userId, (m) => m.sos));

    const push = server.notifier.sent.find((p) => p.event.type === 'sos');
    expect(push?.recipientIds.sort()).toEqual([users[1]!.userId, users[2]!.userId].sort());

    sa.send({ t: 'sos', on: false });
    await sb.waitFor(isEvent('sos_cleared', a!.userId));
  });

  it('tụt lại được phát hiện ở server và báo cho cả đoàn', async () => {
    const { tripId, users } = await tripWithMembers(base, ['An', 'Bình']);
    const [a, b] = users;
    const sa = await open(tripId, a!.accessToken);
    const sb = await open(tripId, b!.accessToken);
    sa.send(pos(0));
    sb.send(pos(4000)); // ngưỡng mặc định 3 km
    const ev = await sa.waitFor(isEvent('lagging'));
    expect(ev.event.data?.distanceM).toBeGreaterThan(3000);
  });

  it('điểm tập kết đặt qua REST tới mọi socket', async () => {
    const { tripId, users } = await tripWithMembers(base, ['An', 'Bình']);
    const sb = await open(tripId, users[1]!.accessToken);
    await api(base, 'PUT', `/v1/trips/${tripId}/regroup`, {
      token: users[0]!.accessToken,
      body: { lat: 22.8, lng: 105.3, title: 'Cây xăng Yên Minh' },
    });
    const msg = await sb.waitFor((m) => m.t === 'regroup');
    expect(msg).toMatchObject({ regroup: { lat: 22.8, lng: 105.3, title: 'Cây xăng Yên Minh' } });
  });

  it('bị mời ra: socket bị đóng 4403, người còn lại nhận snapshot mới và sự kiện', async () => {
    const { tripId, users } = await tripWithMembers(base, ['An', 'Bình', 'Cường']);
    const [leader, b, c] = users;
    const sb = await open(tripId, b!.accessToken);
    const sc = await open(tripId, c!.accessToken);
    sc.clear();

    await api(base, 'DELETE', `/v1/trips/${tripId}/members/${b!.userId}`, { token: leader!.accessToken });
    expect(await sb.waitForClose()).toBe(4403);
    await sc.waitFor(isEvent('member_left', b!.userId));
    const snap = await sc.waitFor((m) => m.t === 'snapshot');
    if (snap.t !== 'snapshot') return;
    expect(snap.members.map((m) => m.uid)).not.toContain(b!.userId);
  });

  it('người mới vào đoàn: người đang kết nối thấy ngay', async () => {
    const { tripId, inviteCode, users } = await tripWithMembers(base, ['An']);
    const sa = await open(tripId, users[0]!.accessToken);
    const late = await newUser(base, 'Muộn');
    await api(base, 'POST', '/v1/trips/join', { token: late.accessToken, body: { code: inviteCode } });
    await sa.waitFor(isEvent('member_joined', late.userId));
    await sa.waitFor((m) => m.t === 'snapshot' && m.members.some((x) => x.uid === late.userId));
  });

  it('kết thúc chuyến: mọi người nhận trip_ended rồi socket đóng 4403', async () => {
    const { tripId, users } = await tripWithMembers(base, ['An', 'Bình']);
    const sb = await open(tripId, users[1]!.accessToken);
    await api(base, 'POST', `/v1/trips/${tripId}/end`, { token: users[0]!.accessToken });
    await sb.waitFor(isEvent('trip_ended'));
    expect(await sb.waitForClose()).toBe(4403);
  });
});

describe('chống lạm dụng', () => {
  it('gửi dồn dập thì bị đóng 4008', async () => {
    const { tripId, users } = await tripWithMembers(base, ['An']);
    const sa = await open(tripId, users[0]!.accessToken);
    for (let i = 0; i < 100; i++) sa.send({ t: 'sharing', on: i % 2 === 0 });
    expect(await sa.waitForClose()).toBe(4008);
  });
});
