import { type FastifyPluginAsyncTypebox, Type } from '@fastify/type-provider-typebox';
import type { TokenService } from '../auth/tokens.js';
import type { TripService } from '../trip/service.js';
import type { Hub } from './hub.js';

export const realtimeRoutes: FastifyPluginAsyncTypebox<{ hub: Hub; trips: TripService; tokens: TokenService }> = async (
  app,
  { hub, trips, tokens },
) => {
  app.get(
    '/v1/ws',
    {
      websocket: true,
      schema: {
        querystring: Type.Object({ trip: Type.String({ format: 'uuid' }), access_token: Type.Optional(Type.String()) }),
      },
      // Chạy trước khi nâng cấp: lỗi ở đây trả HTTP 401/404/409, socket không được mở
      preHandler: async (req) => {
        req.userId = await tokens.authenticate(req, { allowQueryToken: true });
        await trips.requireMember(req.userId, req.query.trip);
      },
    },
    (socket, req) => hub.accept(req.query.trip, req.userId, socket),
  );
};
