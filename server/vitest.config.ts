import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globalSetup: ['./test/global-setup.ts'],
    // Các file test dùng chung một database nên chạy tuần tự
    fileParallelism: false,
    testTimeout: 15_000,
  },
});
