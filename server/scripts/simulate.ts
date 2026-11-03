/**
 * Tạo vài đồng đội ảo vào đoàn bằng mã mời, chạy vòng quanh một điểm.
 * Dùng để thử app mà không cần nhiều điện thoại.
 *
 *   npm run sim -- --code ABCD2345 --center 21.0285,105.8542 [--server http://localhost:8080]
 */
import { parseArgs } from 'node:util';
import { WebSocket } from 'ws';
import { destination } from '../src/lib/geo.js';

const { values } = parseArgs({
  options: {
    code: { type: 'string' },
    center: { type: 'string', default: '21.0285,105.8542' },
    server: { type: 'string', default: 'http://localhost:8080' },
  },
});
if (!values.code) {
  console.error('Thiếu --code <mã mời>');
  process.exit(1);
}
const [centerLat, centerLng] = values.center!.split(',').map(Number) as [number, number];
const server = values.server!;

interface BotSpec {
  name: string;
  /** Vị trí ban đầu: hướng (độ) và khoảng cách (m) so với tâm */
  bearing: number;
  radiusM: number;
  speedMs: number;
  /** Ngừng gửi sau chừng này giây (giả lập mất sóng) */
  silentAfterSec?: number;
}

const BOTS: BotSpec[] = [
  { name: 'An (bot)', bearing: 20, radiusM: 1200, speedMs: 11 },
  { name: 'Bình (bot)', bearing: 190, radiusM: 600, speedMs: 9 },
  { name: 'Dũng (bot)', bearing: 160, radiusM: 900, speedMs: 9 },
  { name: 'Hà (bot)', bearing: 80, radiusM: 150, speedMs: 0 },
  { name: 'Cường (bot)', bearing: 280, radiusM: 4500, speedMs: 12, silentAfterSec: 40 },
];

async function post<T>(path: string, body: unknown, token?: string): Promise<T> {
  const res = await fetch(server + path, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${path} → ${res.status} ${await res.text()}`);
  return res.json() as Promise<T>;
}

async function runBot(spec: BotSpec) {
  const user = await post<{ accessToken: string }>('/v1/auth/anonymous', { displayName: spec.name });
  const trip = await post<{ id: string }>('/v1/trips/join', { code: values.code }, user.accessToken);
  const ws = new WebSocket(`${server.replace('http', 'ws')}/v1/ws?trip=${trip.id}`, {
    headers: { authorization: `Bearer ${user.accessToken}` },
  });
  await new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    if (msg.t === 'event') console.log(`[${spec.name}] sự kiện: ${msg.event.type}`, msg.event.data ?? '');
  });
  ws.on('close', (code) => console.log(`[${spec.name}] đóng kết nối ${code}`));
  console.log(`[${spec.name}] đã vào đoàn`);

  const started = Date.now();
  // Chạy vòng tròn quanh tâm: vận tốc góc = v / r
  const omegaDeg = spec.radiusM > 0 ? ((spec.speedMs / spec.radiusM) * 180) / Math.PI : 0;
  const timer = setInterval(() => {
    const elapsed = (Date.now() - started) / 1000;
    if (spec.silentAfterSec && elapsed > spec.silentAfterSec) return;
    const bearing = spec.bearing + omegaDeg * elapsed;
    const p = destination(centerLat, centerLng, bearing, spec.radiusM);
    ws.send(
      JSON.stringify({
        t: 'pos',
        ts: Date.now(),
        lat: p.lat,
        lng: p.lng,
        acc: 6,
        spd: spec.speedMs,
        hdg: (((bearing + 90) % 360) + 360) % 360,
        bat: 70,
      }),
    );
  }, 3000);
  process.once('SIGINT', () => {
    clearInterval(timer);
    ws.close();
  });
}

await Promise.all(BOTS.map(runBot));
console.log('Bot đang chạy. Ctrl+C để dừng.');
