import { defineConfig } from "@playwright/test";
import dotenv from "dotenv";
import path from "path";

// 加载 .env 文件
dotenv.config({ path: path.resolve(__dirname, ".env") });

export default defineConfig({
  testDir: "./specs",
  timeout: 30000,
  expect: { timeout: 10000 },
  retries: 0,
  use: {
    baseURL: "http://localhost:3000",
    headless: true,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { browserName: "chromium" },
    },
  ],
});
