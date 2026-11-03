import { type FastifyPluginAsyncTypebox, Type } from '@fastify/type-provider-typebox';
import type { TokenService } from '../auth/tokens.js';
import type { TripService } from './service.js';

const TripParams = Type.Object({ tripId: Type.String({ format: 'uuid' }) });
const MemberParams = Type.Object({ tripId: Type.String({ format: 'uuid' }), userId: Type.String({ format: 'uuid' }) });

export const tripRoutes: FastifyPluginAsyncTypebox<{ trips: TripService; tokens: TokenService }> = async (
  app,
  { trips, tokens },
) => {
  app.addHook('preHandler', async (req) => {
    req.userId = await tokens.authenticate(req);
  });

  app.post(
    '/v1/trips',
    { schema: { body: Type.Object({ name: Type.String({ minLength: 1, maxLength: 80 }) }) } },
    async (req, reply) => reply.code(201).send(await trips.createTrip(req.userId, req.body.name.trim() || 'Chuyến đi')),
  );

  app.post(
    '/v1/trips/join',
    {
      schema: { body: Type.Object({ code: Type.String({ minLength: 4, maxLength: 20 }) }) },
      // Chặn dò mã mời. Rate limit chạy trước bước xác thực nên tính theo token (mỗi tài khoản một token)
      config: {
        rateLimit: { max: 10, timeWindow: '1 minute', keyGenerator: (req) => `join:${req.headers.authorization ?? req.ip}` },
      },
    },
    async (req) => trips.joinByCode(req.userId, req.body.code),
  );

  app.get('/v1/trips', async (req) => trips.listMyTrips(req.userId));

  app.get('/v1/trips/:tripId', { schema: { params: TripParams } }, async (req) =>
    trips.getTrip(req.userId, req.params.tripId),
  );

  app.post('/v1/trips/:tripId/leave', { schema: { params: TripParams } }, async (req, reply) => {
    await trips.leave(req.userId, req.params.tripId);
    return reply.code(204).send();
  });

  app.post('/v1/trips/:tripId/end', { schema: { params: TripParams } }, async (req, reply) => {
    await trips.endTrip(req.userId, req.params.tripId);
    return reply.code(204).send();
  });

  app.post('/v1/trips/:tripId/invite/rotate', { schema: { params: TripParams } }, async (req) =>
    trips.rotateInvite(req.userId, req.params.tripId),
  );

  app.patch(
    '/v1/trips/:tripId/members/:userId',
    {
      schema: {
        params: MemberParams,
        body: Type.Object({ role: Type.Union([Type.Literal('sweeper'), Type.Literal('member')]) }),
      },
    },
    async (req, reply) => {
      await trips.setRole(req.userId, req.params.tripId, req.params.userId, req.body.role);
      return reply.code(204).send();
    },
  );

  app.delete('/v1/trips/:tripId/members/:userId', { schema: { params: MemberParams } }, async (req, reply) => {
    await trips.kick(req.userId, req.params.tripId, req.params.userId);
    return reply.code(204).send();
  });

  app.put(
    '/v1/trips/:tripId/regroup',
    {
      schema: {
        params: TripParams,
        body: Type.Object({
          lat: Type.Number({ minimum: -90, maximum: 90 }),
          lng: Type.Number({ minimum: -180, maximum: 180 }),
          title: Type.Optional(Type.String({ maxLength: 80 })),
        }),
      },
    },
    async (req) => trips.setRegroup(req.userId, req.params.tripId, req.body),
  );

  app.delete('/v1/trips/:tripId/regroup', { schema: { params: TripParams } }, async (req, reply) => {
    await trips.clearRegroup(req.userId, req.params.tripId);
    return reply.code(204).send();
  });
};
