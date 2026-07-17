import { Page } from "@playwright/test";

/**
 * 登录 headplane 并返回已认证的 page。
 * 如果已登录（访问 /admin/machines 无需跳转），直接复用 session。
 */
export async function login(page: Page, apiKey: string): Promise<void> {
  // 先尝试访问受保护页面看是否已登录
  await page.goto("/admin/machines");

  // 如果被重定向到登录页，执行登录
  if (page.url().includes("/admin/login")) {
    await page.locator('input[name="api_key"]').fill(apiKey);
    await page.locator('button[type="submit"]').click();
    await page.waitForURL(/\/admin\/machines/, { timeout: 15000 });
  }
}

/**
 * 登出并清除 session。
 */
export async function logout(page: Page): Promise<void> {
  await page.goto("/admin/logout");
  await page.context().clearCookies();
}
