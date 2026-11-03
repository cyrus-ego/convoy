import { type FastifyPluginAsyncTypebox, Type, type TypeBoxTypeProvider } from '@fastify/type-provider-typebox';
import { eq } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { users } from '../../db/schema.js';
import { badRequest, notFound, unauthorized } from '../../lib/errors.js';
import { generateDeviceSecret, hashSecret, secretMatches } from '../../lib/secrets.js';
import type { TokenService } from './tokens.js';

const DisplayName = Type.String({ minLength: 1, maxLength: 40 });

/** Bỏ ký tự điều khiển và khoảng trắng thừa; tên rỗng sau khi làm sạch thì từ chối */
export function cleanDisplayName(raw: string): string {
  const name = raw.replace(/[\p{Cc}\p{Cf}]/gu, '').replace(/\s+/g, ' ').trim();
  if (!name) throw badRequest('invalid_name', 'Tên không được để trống');
  return name;
}

export const authRoutes: FastifyPluginAsyncTypebox<{ db: Db; tokens: TokenService }> = async (app, { db, tokens }) => {
  app.post(
    '/v1/auth/anonymous',
    {
      schema: { body: Type.Object({ displayName: DisplayName }) },
      config: { rateLimit: { max: 20, timeWindow: '1 hour' } },
    },
    async (req, reply) => {
      const deviceSecret = generateDeviceSecret();
      const [user] = await db
        .insert(users)
        .values({ displayName: cleanDisplayName(req.body.displayName), deviceSecretHash: hashSecret(deviceSecret) })
        .returning({ id: users.id });
      const token = await tokens.issue(user!.id);
      return reply.code(201).send({ userId: user!.id, deviceSecret, ...token });
    },
  );

  app.post(
    '/v1/auth/token',
    {
      schema: {
        body: Type.Object({ userId: Type.String({ format: 'uuid' }), deviceSecret: Type.String({ maxLength: 100 }) }),
      },
      config: { rateLimit: { max: 30, timeWindow: '1 minute' } },
    },
    async (req) => {
      const [user] = await db
        .select({ hash: users.deviceSecretHash })
        .from(users)
        .where(eq(users.id, req.body.userId));
      if (!user || !secretMatches(req.body.deviceSecret, user.hash)) throw unauthorized('Thông tin thiết bị không hợp lệ');
      return tokens.issue(req.body.userId);
    },
  );

  app.register(async (instance) => {
    const authed = instance.withTypeProvider<TypeBoxTypeProvider>();
    authed.addHook('preHandler', async (req) => {
      req.userId = await tokens.authenticate(req);
    });

    authed.get('/v1/me', async (req) => {
      const [me] = await db
        .select({ id: users.id, displayName: users.displayName })
        .from(users)
        .where(eq(users.id, req.userId));
      if (!me) throw notFound();
      return me;
    });

    authed.patch('/v1/me', { schema: { body: Type.Object({ displayName: DisplayName }) } }, async (req) => {
      const [me] = await db
        .update(users)
        .set({ displayName: cleanDisplayName(req.body.displayName) })
        .where(eq(users.id, req.userId))
        .returning({ id: users.id, displayName: users.displayName });
      if (!me) throw notFound();
      return me;
    });
  });
};
