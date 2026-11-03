# Bám Đoàn

App cho đoàn đi phượt: mỗi người thấy vị trí cả đoàn, người dùng ở giữa màn hình, đồng đội ở xa
ghim lên rìa màn hình theo đúng hướng thực tế (bản đồ xoay theo hướng đi).

```
server/   Node.js + TypeScript: Fastify, WebSocket, PostgreSQL/PostGIS (Drizzle)
app/      Flutter (iOS + Android)
docs/     protocol.md: hợp đồng REST + WebSocket giữa app và server
```

## Chạy ở máy dev

Cần Docker, Node 22+, Flutter 3.44+.

```bash
docker compose up -d db                  # Postgres + PostGIS ở cổng 5433
cd server
npm install
cp .env.example .env                     # rồi điền JWT_SECRET (>= 32 ký tự)
npm run db:migrate
npm run dev                              # http://localhost:8080
```

```bash
cd app
flutter run                              # Android emulator tự gọi 10.0.2.2:8080, iOS simulator gọi localhost
flutter run --dart-define=API_BASE=http://192.168.1.10:8080   # máy thật trong cùng mạng
```

Thử với đồng đội ảo: tạo chuyến trong app, lấy mã mời, rồi

```bash
cd server
npm run sim -- --code ABCD-2345 --center 21.0285,105.8542
```

5 bot sẽ vào đoàn và chạy vòng quanh điểm `--center` (một bot đứng yên, một bot mất sóng sau 40 giây).

## Test

```bash
cd server && npm test        # unit + integration với Postgres thật (DB bamdoan_test)
cd app && flutter test
```

## Chưa làm

- Thông báo đẩy: `server/src/modules/notify/notifier.ts` mới ghi log, cần Firebase project để nối FCM/APNs.
- Chạy nhiều instance server (Redis Pub/Sub), bản đồ offline, thanh đoàn xe theo tuyến, trang web cho người nhà.
- Tile bản đồ đang dùng OpenStreetMap (chỉ hợp cho dev), production cần nhà cung cấp tile Việt Nam.
