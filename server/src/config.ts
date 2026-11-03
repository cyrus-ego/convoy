export interface Config {
  port: number;
  host: string;
  databaseUrl: string;
  jwtSecret: string;
  accessTokenTtlSec: number;
  /** Nhịp gộp bản tin của mỗi phòng */
  tickMs: number;
  logLevel: string;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const databaseUrl = env.DATABASE_URL;
  if (!databaseUrl) throw new Error('Thiếu DATABASE_URL');
  const jwtSecret = env.JWT_SECRET ?? '';
  if (jwtSecret.length < 32) throw new Error('JWT_SECRET phải dài ít nhất 32 ký tự');

  return {
    port: Number(env.PORT ?? 8080),
    host: env.HOST ?? '0.0.0.0',
    databaseUrl,
    jwtSecret,
    accessTokenTtlSec: Number(env.ACCESS_TOKEN_TTL_SEC ?? 3600),
    tickMs: Number(env.TICK_MS ?? 2000),
    logLevel: env.LOG_LEVEL ?? 'info',
  };
}
