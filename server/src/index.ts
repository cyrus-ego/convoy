import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { createDb } from './db/client.js';

const config = loadConfig();
const database = createDb(config.databaseUrl);
const { app } = await buildApp({ config, db: database.db });

let shuttingDown = false;
async function shutdown(signal: string) {
  if (shuttingDown) return;
  shuttingDown = true;
  app.log.info({ signal }, 'shutting down');
  // Đóng các phòng (ghi nốt vị trí cuối) rồi mới đóng DB
  await app.close();
  await database.close();
  process.exit(0);
}
process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));

await app.listen({ port: config.port, host: config.host });
