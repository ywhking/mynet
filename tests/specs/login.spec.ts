import { test, expect } from "@playwright/test";

const VALID_API_KEY = process.env.HEADPLANE_API_KEY || "";

test.describe("Headplane Login", () => {
  test.beforeEach(async ({ page }) => {
    // 确保从已登出状态开始
    await page.goto("/admin/logout");
    await page.context().clearCookies();
  });

  test("should display login form", async ({ page }) => {
    await page.goto("/admin/login");

    // 验证页面标题
    await expect(page.locator("text=Welcome to Headplane")).toBeVisible();

    // 验证表单元素存在
    await expect(page.locator('input[name="api_key"]')).toBeVisible();
    await expect(page.locator('button[type="submit"]')).toBeVisible();
    await expect(page.locator('button[type="submit"]')).toHaveText("Sign In");
  });

  test("should show error with empty API key", async ({ page }) => {
    await page.goto("/admin/login");

    // 绕过 required 属性直接提交空表单
    await page.locator('input[name="api_key"]').evaluate((el) =>
      el.removeAttribute("required")
    );
    await page.locator('button[type="submit"]').click();

    // 验证后端返回错误
    await expect(
      page.locator("text=API key cannot be empty")
    ).toBeVisible({ timeout: 10000 });
  });

  test("should show error with invalid API key", async ({ page }) => {
    await page.goto("/admin/login");

    await page.locator('input[name="api_key"]').fill("invalid-key-12345");
    await page.locator('button[type="submit"]').click();

    await expect(
      page.locator("text=API key is invalid")
    ).toBeVisible({ timeout: 10000 });
  });

  test("should login successfully with valid API key", async ({ page }) => {
    test.skip(!VALID_API_KEY, "HEADPLANE_API_KEY 环境变量未设置");

    await page.goto("/admin/login");

    await page.locator('input[name="api_key"]').fill(VALID_API_KEY);
    await page.locator('button[type="submit"]').click();

    // 验证重定向到 /admin/machines
    await expect(page).toHaveURL(/\/admin\/machines/, { timeout: 15000 });
    await expect(
      page.getByRole("heading", { name: "Machines" })
    ).toBeVisible({ timeout: 10000 });
  });

  test("should redirect to login when accessing protected page while logged out", async ({
    page,
  }) => {
    await page.goto("/admin/machines");

    // 未登录应重定向到登录页
    await expect(page).toHaveURL(/\/admin\/login/, { timeout: 10000 });
  });

  test("should persist session after login", async ({ page }) => {
    test.skip(!VALID_API_KEY, "HEADPLANE_API_KEY 环境变量未设置");

    // 登录
    await page.goto("/admin/login");
    await page.locator('input[name="api_key"]').fill(VALID_API_KEY);
    await page.locator('button[type="submit"]').click();
    await expect(page).toHaveURL(/\/admin\/machines/, { timeout: 15000 });

    // 刷新页面 — 应保持登录状态
    await page.reload();
    await expect(page).toHaveURL(/\/admin\/machines/, { timeout: 10000 });
    await expect(
      page.getByRole("heading", { name: "Machines" })
    ).toBeVisible();
  });
});
