# Hợp đồng giao thức Bám Đoàn

Hợp đồng giữa app (Flutter) và server (Node). Server định nghĩa schema bằng TypeBox trong
`server/src/modules/realtime/protocol.ts` và `server/src/modules/*/routes.ts`; model Dart trong
`app/lib/core/protocol.dart` phải khớp với tài liệu này.

Quy ước chung:
- Toạ độ WGS84, độ thập phân. Thời gian là epoch milliseconds (số nguyên).
- `ts` của vị trí lấy từ bản tin GPS, không lấy giờ máy.
- Tốc độ m/s, hướng độ (0 = Bắc, theo chiều kim đồng hồ), pin 0–100.

## Xác thực

Tài khoản ẩn danh theo thiết bị. App giữ `deviceSecret` trong secure storage, đổi lấy access token
(JWT, sống 1 giờ) mỗi khi cần.

| Method | Path | Body | Trả về |
|---|---|---|---|
| POST | `/v1/auth/anonymous` | `{displayName}` | `{userId, deviceSecret, accessToken, expiresAt}` |
| POST | `/v1/auth/token` | `{userId, deviceSecret}` | `{accessToken, expiresAt}` |
| GET | `/v1/me` | – | `{id, displayName}` |
| PATCH | `/v1/me` | `{displayName}` | `{id, displayName}` |

Các endpoint còn lại cần header `Authorization: Bearer <accessToken>`.

## Chuyến đi (REST)

| Method | Path | Ai được gọi | Ghi chú |
|---|---|---|---|
| POST | `/v1/trips` | mọi người | `{name}` → tạo chuyến, người tạo là `leader` |
| POST | `/v1/trips/join` | mọi người | `{code}` → vào chuyến bằng mã mời |
| GET | `/v1/trips` | – | các chuyến đang `active` mà mình là thành viên |
| GET | `/v1/trips/:tripId` | thành viên | chuyến + danh sách thành viên |
| POST | `/v1/trips/:tripId/leave` | thành viên | rời chuyến (trưởng đoàn không rời được, phải kết thúc chuyến) |
| POST | `/v1/trips/:tripId/end` | leader | kết thúc chuyến |
| POST | `/v1/trips/:tripId/invite/rotate` | leader | đổi mã mời |
| PATCH | `/v1/trips/:tripId/members/:userId` | leader | `{role: "sweeper" \| "member"}` |
| DELETE | `/v1/trips/:tripId/members/:userId` | leader | mời ra khỏi đoàn |
| PUT | `/v1/trips/:tripId/regroup` | leader, sweeper | `{lat, lng, title?}` đặt điểm tập kết |
| DELETE | `/v1/trips/:tripId/regroup` | leader, sweeper | xoá điểm tập kết |

Lỗi trả về dạng `{error: {code, message}}` với HTTP status tương ứng. Người không thuộc chuyến
nhận `404` (không lộ việc chuyến có tồn tại).

## Realtime (WebSocket)

`GET /v1/ws?trip=<tripId>` nâng cấp lên WebSocket. Token gửi qua header `Authorization: Bearer`
(app) hoặc query `access_token` (trình duyệt). Server kiểm JWT **và** tư cách thành viên trước khi
nâng cấp; sai thì trả HTTP, không mở socket: `401` token sai/hết hạn (lấy token mới rồi thử lại),
`404` không phải thành viên, `409` chuyến đã kết thúc.

Token chỉ được kiểm lúc kết nối; socket đang mở không bị cắt khi token hết hạn.

Mã đóng socket: `4403` bị mời ra hoặc chuyến kết thúc (không nối lại), `4008` gửi quá nhanh,
`1012` server khởi động lại (nối lại). Mất kết nối thì client nối lại với backoff 1–30 giây;
mỗi lần nối lại server gửi `snapshot` mới.

### Client → server

```jsonc
{"t": "pos", "ts": 1730620000123, "lat": 21.0285, "lng": 105.8542,
 "acc": 8, "spd": 12.5, "hdg": 87, "bat": 64}          // spd, hdg, bat có thể bỏ
{"t": "sharing", "on": false}                            // tạm dừng / bật lại chia sẻ
{"t": "sos", "on": true}                                 // bật / tắt SOS
```

Mỗi kết nối được gửi tối đa ~5 bản tin/giây (dồn được 10); vượt quá thì bị bỏ, vượt nhiều thì đóng `4008`.
Client gửi vị trí mỗi 3 giây khi đang chạy (đi được ≥ 15 m) và mỗi 25 giây khi đứng yên.

Server bỏ qua (không báo lỗi) bản tin vị trí:
- có `ts` cũ hơn hoặc bằng bản đã nhận (bản đến trễ),
- có `acc` > 1000 m,
- nhảy xa phi lý (> 70 m/s) so với bản trước trong vòng 60 giây (nhiễu GPS),
- gửi lúc đang tạm dừng chia sẻ.

### Server → client

```jsonc
// ngay khi kết nối: toàn bộ trạng thái
{"t": "snapshot", "serverTime": 1730620000500, "trip": TripInfo,
 "members": [MemberState, ...], "regroup": Regroup | null}

// mỗi nhịp gộp (mặc định 2 giây), chỉ những thành viên vừa đổi
{"t": "delta", "serverTime": 1730620002500, "members": [MemberState, ...]}

// thay đổi điểm tập kết
{"t": "regroup", "regroup": Regroup | null}

// sự kiện cảnh báo
{"t": "event", "event": TripEvent}
```

```jsonc
TripInfo    = {"id", "name", "status": "active" | "ended", "inviteCode", "lagThresholdM"}
MemberState = {"uid", "name", "role": "leader" | "sweeper" | "member", "color": "#RRGGBB",
               "online": bool,          // đang có kết nối WebSocket
               "sharing": bool,         // false = tạm dừng chia sẻ
               "sos": bool,
               "pos": Pos | null}       // vị trí cuối cùng đã biết (có thể cũ, xem pos.ts)
Pos         = {"ts", "lat", "lng", "acc", "spd"?, "hdg"?, "bat"?}
Regroup     = {"lat", "lng", "title", "setBy", "setAt"}
TripEvent   = {"id", "type", "uid", "at", "data"?}
```

`MemberState` trong `delta` là trạng thái đầy đủ của thành viên đó (ghi đè, không cộng dồn), nên
client chỉ cần thay bản cũ bằng bản mới.

### Sự kiện (`TripEvent.type`)

| type | Khi nào | `data` |
|---|---|---|
| `member_joined` / `member_left` | vào / rời / bị mời ra | – |
| `role_changed` | đổi vai trò | `{role}` |
| `sos` / `sos_cleared` | bật / tắt SOS | `{lat, lng}` nếu có |
| `lagging` | cách người gần nhất trong đoàn quá `lagThresholdM` | `{distanceM}` |
| `lagging_cleared` | đã bám lại (dưới 80% ngưỡng) | `{distanceM}` |
| `stopped` | đứng yên > 5 phút trong khi phần lớn đoàn đang chạy | `{sinceTs}` |
| `signal_lost` | đang chia sẻ mà > 90 giây không có vị trí mới | `{lastTs}` |
| `signal_restored` | có vị trí trở lại sau `signal_lost` | `{gapMs}` |
| `trip_ended` | trưởng đoàn kết thúc chuyến | – |

Mỗi cảnh báo chỉ phát một lần cho đến khi được xoá (có ngưỡng trễ), không lặp mỗi nhịp.
