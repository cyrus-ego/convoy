const EARTH_RADIUS_M = 6_371_008.8;
const rad = (d: number) => (d * Math.PI) / 180;

/** Khoảng cách đường chim bay (haversine), mét */
export function distanceM(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const dLat = rad(bLat - aLat);
  const dLng = rad(bLng - aLng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(aLat)) * Math.cos(rad(bLat)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Hướng từ A tới B, độ (0 = Bắc, theo chiều kim đồng hồ) */
export function bearingDeg(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const φ1 = rad(aLat);
  const φ2 = rad(bLat);
  const Δλ = rad(bLng - aLng);
  const y = Math.sin(Δλ) * Math.cos(φ2);
  const x = Math.cos(φ1) * Math.sin(φ2) - Math.sin(φ1) * Math.cos(φ2) * Math.cos(Δλ);
  return ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
}

/** Điểm cách A một khoảng `meters` theo hướng `bearing` (dùng cho test và bot giả lập) */
export function destination(lat: number, lng: number, bearing: number, meters: number): { lat: number; lng: number } {
  const δ = meters / EARTH_RADIUS_M;
  const θ = rad(bearing);
  const φ1 = rad(lat);
  const λ1 = rad(lng);
  const φ2 = Math.asin(Math.sin(φ1) * Math.cos(δ) + Math.cos(φ1) * Math.sin(δ) * Math.cos(θ));
  const λ2 = λ1 + Math.atan2(Math.sin(θ) * Math.sin(δ) * Math.cos(φ1), Math.cos(δ) - Math.sin(φ1) * Math.sin(φ2));
  return { lat: (φ2 * 180) / Math.PI, lng: ((((λ2 * 180) / Math.PI + 540) % 360) - 180) };
}
