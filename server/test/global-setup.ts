import { runMigrations } from '../src/db/migrate.js';
import { TEST_DB_URL } from './helpers.js';

export default async function setup() {
  await runMigrations(TEST_DB_URL);
}
