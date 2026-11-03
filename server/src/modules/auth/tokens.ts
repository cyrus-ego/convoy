import type { FastifyRequest } from 'fastify';
import { jwtVerify, SignJWT } from 'jose';
import { unauthorized } from '../../lib/errors.js';

const AUDIENCE = 'bamdoan';

export class TokenService {
  private readonly key: Uint8Array;

  constructor(
    secret: string,
    private readonly ttlSec: number,
  ) {
    this.key = new TextEncoder().encode(secret);
  }

  async issue(userId: string): Promise<{ accessToken: string; expiresAt: number }> {
    const exp = Math.floor(Date.now() / 1000) + this.ttlSec;
    const accessToken = await new SignJWT({})
      .setProtectedHeader({ alg: 'HS256' })
      .setSubject(userId)
      .setAudience(AUDIENCE)
      .setIssuedAt()
      .setExpirationTime(exp)
      .sign(this.key);
    return { accessToken, expiresAt: exp * 1000 };
  }

  async verify(token: string): Promise<string> {
    try {
      const { payload } = await jwtVerify(token, this.key, { algorithms: ['HS256'], audience: AUDIENCE });
      if (!payload.sub) throw new Error('missing sub');
      return payload.sub;
    } catch {
      throw unauthorized();
    }
  }

  /** Đọc token từ header Authorization; WebSocket từ trình duyệt được phép dùng query `access_token` */
  async authenticate(req: FastifyRequest, opts: { allowQueryToken?: boolean } = {}): Promise<string> {
    const header = req.headers.authorization;
    let token: string | undefined;
    if (header?.startsWith('Bearer ')) token = header.slice(7);
    else if (opts.allowQueryToken) token = (req.query as { access_token?: string } | undefined)?.access_token;
    if (!token) throw unauthorized();
    return this.verify(token);
  }
}

declare module 'fastify' {
  interface FastifyRequest {
    userId: string;
  }
}
