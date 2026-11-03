import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';

/** Bỏ các ký tự dễ nhầm khi đọc qua điện thoại: 0/O, 1/I/L, U */
const INVITE_ALPHABET = '23456789ABCDEFGHJKMNPQRSTVWXYZ';
export const INVITE_CODE_LENGTH = 8;

export function generateInviteCode(): string {
  let code = '';
  for (let i = 0; i < INVITE_CODE_LENGTH; i++) code += INVITE_ALPHABET[randomInt(INVITE_ALPHABET.length)];
  return code;
}

/** Chấp nhận mã người dùng gõ có dấu cách, gạch nối, chữ thường */
export function normalizeInviteCode(input: string): string {
  return input.toUpperCase().replace(/[^0-9A-Z]/g, '');
}

export function generateDeviceSecret(): string {
  return randomBytes(32).toString('base64url');
}

export function hashSecret(secret: string): string {
  return createHash('sha256').update(secret).digest('hex');
}

export function secretMatches(secret: string, expectedHash: string): boolean {
  const a = Buffer.from(hashSecret(secret), 'hex');
  const b = Buffer.from(expectedHash, 'hex');
  return a.length === b.length && timingSafeEqual(a, b);
}
