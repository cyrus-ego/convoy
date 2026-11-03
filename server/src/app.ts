import rateLimit from '@fastify/rate-limit';
import type { TypeBoxTypeProvider } from '@fastify/type-provider-typebox';
import websocket from '@fastify/websocket';
import Fastify, { type FastifyError, type FastifyRequest } from 'fastify';
import type { Config } from './config.js';
import type { Db } from './db/client.js';
import { AppError } from './lib/errors.js';
import { authRoutes } from './modules/auth/routes.js';
import { TokenService } from './modules/auth/tokens.js';
import { LogNotifier, type Notifier } from './modules/notify/notifier.js';
import { Hub } from './modules/realtime/hub.js';
import { realtimeRoutes } from './modules/realtime/routes.js';
import { tripRoutes } from './modules/trip/routes.js';
import { TripService } from './modules/trip/service.js';

export interface AppDeps {
  config: Config;
  db: Db;
  notifier?: Notifier;
  /** Tắt log khi chạy test */
  logger?: boolean;
}

/** Không để token trong query (WebSocket từ trình duyệt) lọt vào log */
function redactUrl(url: string): string {
  return url.replace(/([?&]access_token=)[^&]*/, '$1[redacted]');
}

export async function buildApp({ config, db, notifier, logger = true }: AppDeps) {
  const app = Fastify({
    logger: logger && {
      level: config.logLevel,
      serializers: {
        req: (req: FastifyRequest) => ({ method: req.method, url: redactUrl(req.url), remoteAddress: req.ip }),
      },
    },
    trustProxy: true,
  }).withTypeProvider<TypeBoxTypeProvider>();

  const tokens = new TokenService(config.jwtSecret, config.accessTokenTtlSec);
  const trips = new TripService(db);
  const hub = new Hub({
    store: trips,
    notifier: notifier ?? new LogNotifier(app.log),
    log: app.log,
    tickMs: config.tickMs,
  });
  trips.attachRealtime(hub);

  app.setErrorHandler((err: FastifyError | AppError, req, reply) => {
    if (err instanceof AppError) {
      return reply.code(err.status).send({ error: { code: err.code, message: err.message } });
    }
    if ('validation' in err && err.validation) {
      return reply.code(400).send({ error: { code: 'invalid_request', message: err.message } });
    }
    if (err.statusCode === 429) {
      return reply.code(429).send({ error: { code: 'rate_limited', message: 'Thao tác quá nhanh, thử lại sau' } });
    }
    req.log.error({ err }, 'unhandled error');
    return reply.code(500).send({ error: { code: 'internal', message: 'Lỗi máy chủ' } });
  });

  await app.register(rateLimit, { global: false });
  await app.register(websocket, { options: { maxPayload: 4096 } });

  app.get('/healthz', async () => ({ ok: true }));
  await app.register(authRoutes, { db, tokens });
  await app.register(tripRoutes, { trips, tokens });
  await app.register(realtimeRoutes, { hub, trips, tokens });

  app.addHook('onClose', async () => {
    await hub.close();
  });

  return { app, hub, trips, tokens };
}
