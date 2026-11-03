import { describe, expect, it } from 'vitest';
import { AlertEngine, DEFAULT_ALERT_CONFIG } from '../src/modules/alert/engine.js';
import { bearingDeg, destination, distanceM } from '../src/lib/geo.js';
import { acceptPosition, parseClientMsg, toPos, type Pos } from '../src/modules/realtime/protocol.js';
import { generateInviteCode, normalizeInviteCode, generateDeviceSecret, hashSecret, secretMatches } from '../src/lib/secrets.js';
import { cleanDisplayName } from '../src/modules/auth/routes.js';

const HN = { lat: 21.0285, lng: 105.8542 };

describe('geo', () => {
  it('một độ vĩ ≈ 111,2 km', () => {
    expect(distanceM(0, 0, 1, 0)).toBeCloseTo(111_195, -1);
  });

  it('hướng theo 4 phía', () => {
    expect(bearingDeg(0, 0, 1, 0)).toBeCloseTo(0);
    expect(bearingDeg(0, 0, 0, 1)).toBeCloseTo(90);
    expect(bearingDeg(0, 0, -1, 0)).toBeCloseTo(180);
    expect(bearingDeg(0, 0, 0, -1)).toBeCloseTo(270);
  });

  it('destination đi đúng khoảng cách và hướng', () => {
    const p = destination(HN.lat, HN.lng, 45, 2500);
    expect(distanceM(HN.lat, HN.lng, p.lat, p.lng)).toBeCloseTo(2500, 0);
    expect(bearingDeg(HN.lat, HN.lng, p.lat, p.lng)).toBeCloseTo(45, 1);
  });
});

describe('parseClientMsg', () => {
  it('nhận bản tin hợp lệ', () => {
    expect(parseClientMsg(JSON.stringify({ t: 'pos', ts: 1, lat: 21, lng: 105, acc: 5, spd: 3 }))).toMatchObject({ t: 'pos' });
    expect(parseClientMsg('{"t":"sharing","on":false}')).toEqual({ t: 'sharing', on: false });
    expect(parseClientMsg('{"t":"sos","on":true}')).toEqual({ t: 'sos', on: true });
  });

  it('từ chối JSON hỏng, sai kiểu, thừa trường, ngoài miền, quá dài', () => {
    expect(parseClientMsg('{oops')).toBeNull();
    expect(parseClientMsg('{"t":"pos","ts":1,"lat":"21","lng":105,"acc":5}')).toBeNull();
    expect(parseClientMsg('{"t":"pos","ts":1,"lat":21,"lng":105,"acc":5,"uid":"x"}')).toBeNull();
    expect(parseClientMsg('{"t":"pos","ts":1,"lat":91,"lng":105,"acc":5}')).toBeNull();
    expect(parseClientMsg('{"t":"nope"}')).toBeNull();
    expect(parseClientMsg(JSON.stringify({ t: 'sos', on: true, pad: 'x'.repeat(2000) }))).toBeNull();
  });
});

describe('acceptPosition', () => {
  const now = 1_000_000_000;
  const prev: Pos = { ts: now - 5000, lat: HN.lat, lng: HN.lng, acc: 5 };
  const at = (ms: number, meters: number, acc = 5) => {
    const p = destination(HN.lat, HN.lng, 90, meters);
    return { t: 'pos' as const, ts: now - 5000 + ms, lat: p.lat, lng: p.lng, acc };
  };

  it('nhận vị trí đầu tiên và vị trí hợp lý', () => {
    expect(acceptPosition(null, at(0, 0), now)).toBe(true);
    expect(acceptPosition(prev, at(5000, 100), now)).toBe(true); // 20 m/s
  });

  it('bỏ bản đến trễ hoặc trùng', () => {
    expect(acceptPosition(prev, at(0, 10), now)).toBe(false);
    expect(acceptPosition(prev, at(-1000, 10), now)).toBe(false);
  });

  it('bỏ độ chính xác quá kém và thời gian ở tương lai', () => {
    expect(acceptPosition(null, at(0, 0, 1500), now)).toBe(false);
    expect(acceptPosition(null, { ...at(0, 0), ts: now + 120_000 }, now)).toBe(false);
  });

  it('bỏ cú nhảy phi lý trong vòng 1 phút, nhưng nhận sau khi mất sóng lâu', () => {
    expect(acceptPosition(prev, at(5000, 2000), now)).toBe(false); // 400 m/s
    expect(acceptPosition(prev, at(120_000, 5000), now + 120_000)).toBe(true);
  });

  it('toPos làm tròn gọn', () => {
    expect(toPos({ t: 'pos', ts: 1, lat: 21.12345678, lng: 105.98765432, acc: 3.456, spd: 12.345, hdg: 359.6, bat: 50 })).toEqual({
      ts: 1, lat: 21.123457, lng: 105.987654, acc: 3.5, spd: 12.3, hdg: 0, bat: 50,
    });
  });
});

describe('secrets', () => {
  it('mã mời 8 ký tự, không có ký tự dễ nhầm', () => {
    for (let i = 0; i < 200; i++) expect(generateInviteCode()).toMatch(/^[2-9A-HJKMNP-TV-Z]{8}$/);
  });

  it('chuẩn hoá mã người dùng gõ', () => {
    expect(normalizeInviteCode(' abcd-ef 23 ')).toBe('ABCDEF23');
  });

  it('so khớp device secret', () => {
    const s = generateDeviceSecret();
    expect(secretMatches(s, hashSecret(s))).toBe(true);
    expect(secretMatches(s + 'x', hashSecret(s))).toBe(false);
  });

  it('làm sạch tên hiển thị', () => {
    expect(cleanDisplayName('  Nam \u0000  Phượt  ')).toBe('Nam Phượt');
    expect(() => cleanDisplayName(' ​ ')).toThrow();
  });
});

describe('AlertEngine', () => {
  const now = 10_000_000;
  const pos = (meters: number, opts: Partial<Pos> = {}): Pos => {
    const p = destination(HN.lat, HN.lng, 0, meters);
    return { ts: now, lat: p.lat, lng: p.lng, acc: 5, ...opts };
  };
  const m = (uid: string, p: Pos | null, sharing = true) => ({ uid, sharing, pos: p });
  const types = (events: { type: string; uid: string }[]) => events.map((e) => `${e.type}:${e.uid}`);

  it('mất tín hiệu báo một lần, có lại thì báo khôi phục', () => {
    const engine = new AlertEngine();
    const stale = pos(0, { ts: now - 100_000 });
    expect(types(engine.evaluate([m('a', stale), m('b', pos(10))], now))).toEqual(['signal_lost:a']);
    expect(engine.evaluate([m('a', stale), m('b', pos(10))], now + 2000)).toEqual([]);
    const back = engine.evaluate([m('a', pos(0, { ts: now + 5000 })), m('b', pos(10, { ts: now + 5000 }))], now + 5000);
    expect(back).toEqual([{ type: 'signal_restored', uid: 'a', data: { gapMs: 105_000 } }]);
  });

  it('tụt lại có ngưỡng trễ, không báo bật/tắt quanh ngưỡng', () => {
    const engine = new AlertEngine({ ...DEFAULT_ALERT_CONFIG, lagThresholdM: 1000 });
    const group = [m('a', pos(0)), m('b', pos(50))];
    expect(types(engine.evaluate([...group, m('c', pos(1200))], now))).toEqual(['lagging:c']);
    // 900 m: dưới ngưỡng nhưng chưa dưới 80% → vẫn đang tụt, không báo gì
    expect(engine.evaluate([...group, m('c', pos(950))], now)).toEqual([]);
    expect(types(engine.evaluate([...group, m('c', pos(700))], now))).toEqual(['lagging_cleared:c']);
  });

  it('chỉ có một người thì không ai bị coi là tụt lại', () => {
    expect(new AlertEngine().evaluate([m('a', pos(0))], now)).toEqual([]);
  });

  it('đứng yên chỉ báo khi phần lớn đoàn đang chạy', () => {
    // Ngưỡng tụt lại rất lớn để chỉ kiểm luật đứng yên
    const engine = new AlertEngine({ ...DEFAULT_ALERT_CONFIG, lagThresholdM: 100_000 });
    const still = (t: number) => m('a', pos(0, { ts: now + t, spd: 0 }));
    // b, c chạy thật: vị trí đổi theo thời gian đúng với tốc độ báo về
    const moving = (t: number, spd: number) => [
      m('b', pos(500 + (t / 1000) * spd, { ts: now + t, spd })),
      m('c', pos(600 + (t / 1000) * spd, { ts: now + t, spd })),
    ];
    engine.evaluate([still(0), ...moving(0, 10)], now);
    expect(engine.evaluate([still(4 * 60_000), ...moving(4 * 60_000, 10)], now + 4 * 60_000)).toEqual([]);
    // Cả đoàn cũng đang dừng → không báo
    expect(engine.evaluate([still(6 * 60_000), ...moving(6 * 60_000, 0)], now + 6 * 60_000)).toEqual([]);
    expect(types(engine.evaluate([still(7 * 60_000), ...moving(7 * 60_000, 10)], now + 7 * 60_000))).toEqual(['stopped:a']);
    expect(engine.evaluate([still(8 * 60_000), ...moving(8 * 60_000, 10)], now + 8 * 60_000)).toEqual([]);
  });

  it('tạm dừng chia sẻ thì xoá trạng thái, không báo', () => {
    const engine = new AlertEngine();
    engine.evaluate([m('a', pos(0, { ts: now - 100_000 })), m('b', pos(10))], now);
    expect(engine.evaluate([m('a', null, false), m('b', pos(10))], now)).toEqual([]);
    expect(engine.evaluate([m('a', pos(0)), m('b', pos(10))], now)).toEqual([]);
  });

  it('markSignalLost: nạp lại phòng không báo trùng', () => {
    const engine = new AlertEngine();
    engine.markSignalLost('a', now - 100_000);
    expect(engine.evaluate([m('a', pos(0, { ts: now - 100_000 })), m('b', pos(10))], now)).toEqual([]);
  });
});
