import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { api, newUser, resetDb, startServer, type TestServer, tripWithMembers } from './helpers.js';

let server: TestServer;
let base: string;

beforeAll(async () => {
  server = await startServer();
  base = server.base;
});
afterAll(() => server.stop());
beforeEach(() => resetDb(server));

describe('auth', () => {
  it('tạo tài khoản ẩn danh, đổi device secret lấy token mới', async () => {
    const u = await newUser(base, '  Nam  ');
    const me = await api(base, 'GET', '/v1/me', { token: u.accessToken });
    expect(me.body).toEqual({ id: u.userId, displayName: 'Nam' });

    const ok = await api(base, 'POST', '/v1/auth/token', { body: { userId: u.userId, deviceSecret: u.deviceSecret } });
    expect(ok.status).toBe(200);
    expect(ok.body.accessToken).toBeTypeOf('string');

    const bad = await api(base, 'POST', '/v1/auth/token', { body: { userId: u.userId, deviceSecret: 'wrong' } });
    expect(bad.status).toBe(401);
  });

  it('thiếu hoặc sai token thì 401, body sai thì 400', async () => {
    expect((await api(base, 'GET', '/v1/trips')).status).toBe(401);
    expect((await api(base, 'GET', '/v1/trips', { token: 'abc' })).status).toBe(401);
    const res = await api(base, 'POST', '/v1/auth/anonymous', { body: { displayName: '' } });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('invalid_request');
  });
});

describe('trips', () => {
  it('tạo chuyến, vào bằng mã gõ tay (chữ thường, gạch nối), vào lại không bị trùng', async () => {
    const leader = await newUser(base, 'An');
    const member = await newUser(base, 'Bình');
    const trip = await api(base, 'POST', '/v1/trips', { token: leader.accessToken, body: { name: 'Hà Giang' } });
    expect(trip.status).toBe(201);
    expect(trip.body).toMatchObject({ name: 'Hà Giang', status: 'active', myRole: 'leader' });

    const code = trip.body.inviteCode as string;
    const typed = `${code.slice(0, 4).toLowerCase()}-${code.slice(4)}`;
    const joined = await api(base, 'POST', '/v1/trips/join', { token: member.accessToken, body: { code: typed } });
    expect(joined.status).toBe(200);
    expect(joined.body.myRole).toBe('member');
    expect(joined.body.members).toHaveLength(2);
    const [c1, c2] = joined.body.members.map((m: { color: string }) => m.color);
    expect(c1).not.toBe(c2);

    const again = await api(base, 'POST', '/v1/trips/join', { token: member.accessToken, body: { code } });
    expect(again.body.members).toHaveLength(2);

    const mine = await api(base, 'GET', '/v1/trips', { token: member.accessToken });
    expect(mine.body.map((t: { id: string }) => t.id)).toEqual([trip.body.id]);
  });

  it('người ngoài đoàn nhận 404 (không lộ chuyến có tồn tại)', async () => {
    const { tripId } = await tripWithMembers(base, ['An', 'Bình']);
    const outsider = await newUser(base, 'Lạ');
    expect((await api(base, 'GET', `/v1/trips/${tripId}`, { token: outsider.accessToken })).status).toBe(404);
    expect((await api(base, 'GET', `/v1/trips/${randomUUID()}`, { token: outsider.accessToken })).status).toBe(404);
    const regroup = await api(base, 'PUT', `/v1/trips/${tripId}/regroup`, {
      token: outsider.accessToken,
      body: { lat: 21, lng: 105 },
    });
    expect(regroup.status).toBe(404);
  });

  it('mã mời sai thì 404', async () => {
    const u = await newUser(base, 'An');
    const res = await api(base, 'POST', '/v1/trips/join', { token: u.accessToken, body: { code: 'ZZZZZZZZ' } });
    expect(res.status).toBe(404);
  });

  it('phân quyền: chỉ trưởng đoàn đổi vai trò; trưởng đoàn và chốt đoàn đặt điểm tập kết', async () => {
    const { tripId, users } = await tripWithMembers(base, ['An', 'Bình', 'Cường']);
    const [leader, b, c] = users;

    const denied = await api(base, 'PATCH', `/v1/trips/${tripId}/members/${c!.userId}`, {
      token: b!.accessToken,
      body: { role: 'sweeper' },
    });
    expect(denied.status).toBe(403);

    expect(
      (await api(base, 'PUT', `/v1/trips/${tripId}/regroup`, { token: b!.accessToken, body: { lat: 21, lng: 105 } })).status,
    ).toBe(403);

    const promoted = await api(base, 'PATCH', `/v1/trips/${tripId}/members/${b!.userId}`, {
      token: leader!.accessToken,
      body: { role: 'sweeper' },
    });
    expect(promoted.status).toBe(204);

    const set = await api(base, 'PUT', `/v1/trips/${tripId}/regroup`, {
      token: b!.accessToken,
      body: { lat: 22.8233, lng: 104.9836, title: 'Cột cờ Lũng Cú' },
    });
    expect(set.status).toBe(200);
    expect(set.body).toMatchObject({ lat: 22.8233, lng: 104.9836, title: 'Cột cờ Lũng Cú', setBy: b!.userId });

    const detail = await api(base, 'GET', `/v1/trips/${tripId}`, { token: c!.accessToken });
    expect(detail.body.regroup).toMatchObject({ lat: 22.8233, lng: 104.9836 });
    expect(detail.body.members.find((m: { uid: string }) => m.uid === b!.userId).role).toBe('sweeper');

    expect((await api(base, 'DELETE', `/v1/trips/${tripId}/regroup`, { token: leader!.accessToken })).status).toBe(204);
    expect((await api(base, 'GET', `/v1/trips/${tripId}`, { token: c!.accessToken })).body.regroup).toBeNull();
  });

  it('bị mời ra thì không vào lại được; rời đoàn thì vào lại được; trưởng đoàn không rời được', async () => {
    const { tripId, inviteCode, users } = await tripWithMembers(base, ['An', 'Bình', 'Cường']);
    const [leader, b, c] = users;

    expect((await api(base, 'DELETE', `/v1/trips/${tripId}/members/${b!.userId}`, { token: leader!.accessToken })).status).toBe(204);
    expect((await api(base, 'GET', `/v1/trips/${tripId}`, { token: b!.accessToken })).status).toBe(404);
    expect((await api(base, 'POST', '/v1/trips/join', { token: b!.accessToken, body: { code: inviteCode } })).status).toBe(403);

    expect((await api(base, 'POST', `/v1/trips/${tripId}/leave`, { token: c!.accessToken })).status).toBe(204);
    expect((await api(base, 'POST', '/v1/trips/join', { token: c!.accessToken, body: { code: inviteCode } })).status).toBe(200);

    const leaderLeave = await api(base, 'POST', `/v1/trips/${tripId}/leave`, { token: leader!.accessToken });
    expect(leaderLeave.status).toBe(409);
  });

  it('đổi mã mời thì mã cũ hết hiệu lực', async () => {
    const { tripId, inviteCode, users } = await tripWithMembers(base, ['An']);
    const rotated = await api(base, 'POST', `/v1/trips/${tripId}/invite/rotate`, { token: users[0]!.accessToken });
    expect(rotated.body.inviteCode).not.toBe(inviteCode);
    const late = await newUser(base, 'Muộn');
    expect((await api(base, 'POST', '/v1/trips/join', { token: late.accessToken, body: { code: inviteCode } })).status).toBe(404);
    expect(
      (await api(base, 'POST', '/v1/trips/join', { token: late.accessToken, body: { code: rotated.body.inviteCode } })).status,
    ).toBe(200);
  });

  it('kết thúc chuyến: không vào thêm được, thành viên vẫn xem lại được', async () => {
    const { tripId, inviteCode, users } = await tripWithMembers(base, ['An', 'Bình']);
    expect((await api(base, 'POST', `/v1/trips/${tripId}/end`, { token: users[1]!.accessToken })).status).toBe(403);
    expect((await api(base, 'POST', `/v1/trips/${tripId}/end`, { token: users[0]!.accessToken })).status).toBe(204);

    const late = await newUser(base, 'Muộn');
    expect((await api(base, 'POST', '/v1/trips/join', { token: late.accessToken, body: { code: inviteCode } })).status).toBe(404);
    const detail = await api(base, 'GET', `/v1/trips/${tripId}`, { token: users[1]!.accessToken });
    expect(detail.body.status).toBe('ended');
    expect((await api(base, 'GET', '/v1/trips', { token: users[1]!.accessToken })).body).toEqual([]);
  });

  it('dò mã mời bị chặn sau 10 lần mỗi phút', async () => {
    const u = await newUser(base, 'Dò');
    const statuses: number[] = [];
    for (let i = 0; i < 12; i++) {
      statuses.push((await api(base, 'POST', '/v1/trips/join', { token: u.accessToken, body: { code: `AAAA${i}BBB` } })).status);
    }
    expect(statuses.slice(0, 10).every((s) => s === 404)).toBe(true);
    expect(statuses.slice(10)).toEqual([429, 429]);
  });
});
