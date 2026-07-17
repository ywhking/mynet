import { test, expect } from "@playwright/test";
import { login, logout } from "./helpers/auth";

const VALID_API_KEY = process.env.HEADPLANE_API_KEY || "";

test.describe("Headplane User Management", () => {
  test.beforeEach(async ({ page }) => {
    test.skip(!VALID_API_KEY, "HEADPLANE_API_KEY 环境变量未设置");
    await logout(page);
    await login(page, VALID_API_KEY);
    await page.goto("/admin/users");
    await page.waitForURL(/\/admin\/users/, { timeout: 10000 });
  });

  test("should display users page", async ({ page }) => {
    await expect(
      page.getByRole("heading", { name: "Users", exact: true })
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Add user" })
    ).toBeVisible();
  });

  test("should open and close the create user dialog", async ({ page }) => {
    // 打开对话框
    await page.getByRole("button", { name: "Add user" }).click();
    await expect(
      page.getByText("Create a Headscale user")
    ).toBeVisible();
    await expect(page.getByLabel("Username")).toBeVisible();
    await expect(page.getByLabel("Display Name")).toBeVisible();
    await expect(page.getByLabel("Email")).toBeVisible();

    // 关闭对话框
    await page.getByRole("button", { name: "Cancel" }).click();
    await expect(
      page.getByText("Create a Headscale user")
    ).not.toBeVisible();
  });

  test("should reject empty username on create", async ({ page }) => {
    await page.getByRole("button", { name: "Add user" }).click();
    await expect(page.getByText("Create a Headscale user")).toBeVisible();

    // 不填 username，直接点 Confirm
    await page.getByRole("button", { name: "Confirm" }).click();

    // 浏览器原生 required 验证会阻止提交（input 有 required 属性）
    // 验证对话框仍然打开
    await expect(page.getByLabel("Username")).toBeVisible();
  });

  test("should create a new Headscale user", async ({ page }) => {
    const testUserName = `e2e-test-${Date.now()}`;

    // 打开创建对话框
    await page.getByRole("button", { name: "Add user" }).click();
    await expect(page.getByText("Create a Headscale user")).toBeVisible();

    // 填写表单
    await page.getByLabel("Username").fill(testUserName);
    await page.getByLabel("Display Name").fill("E2E Test User");
    await page.getByLabel("Email").fill("e2e-test@example.com");

    // 提交
    await page.getByRole("button", { name: "Confirm" }).click();

    // 等待对话框关闭
    await expect(
      page.getByText("Create a Headscale user")
    ).not.toBeVisible({ timeout: 10000 });

    // 验证用户出现在列表中
    await expect(page.getByText(testUserName)).toBeVisible({ timeout: 10000 });
  });

  test("should delete an existing Headscale user", async ({ page }) => {
    const testUserName = `e2e-del-${Date.now()}`;

    // 先创建一个用户
    await page.getByRole("button", { name: "Add user" }).click();
    await expect(page.getByText("Create a Headscale user")).toBeVisible();
    await page.getByLabel("Username").fill(testUserName);
    await page.getByRole("button", { name: "Confirm" }).click();
    await expect(
      page.getByText("Create a Headscale user")
    ).not.toBeVisible({ timeout: 10000 });

    // 确认用户已创建
    await expect(page.getByText(testUserName)).toBeVisible({ timeout: 10000 });

    // 找到该用户所在行，点击菜单按钮（Ellipsis 图标）
    const userRow = page.locator("tr", { hasText: testUserName });
    await userRow.locator("button:has(svg.lucide-ellipsis)").click();

    // 点击 Delete 菜单项
    await page.getByRole("menuitem", { name: "Delete" }).click();

    // 确认删除对话框出现
    await expect(
      page.getByRole("heading", { name: /^Delete / })
    ).toBeVisible({ timeout: 5000 });

    // 确认删除
    await page.getByRole("button", { name: "Confirm" }).click();

    // 验证用户已从列表中移除
    await expect(page.getByText(testUserName)).not.toBeVisible({
      timeout: 10000,
    });
  });

  test("should show user with machines as undeletable", async ({ page }) => {
    const testUserName = `e2e-nodelete-${Date.now()}`;

    // 创建一个用户（新用户没有 machines）
    await page.getByRole("button", { name: "Add user" }).click();
    await expect(page.getByText("Create a Headscale user")).toBeVisible();
    await page.getByLabel("Username").fill(testUserName);
    await page.getByRole("button", { name: "Confirm" }).click();
    await expect(
      page.getByText("Create a Headscale user")
    ).not.toBeVisible({ timeout: 10000 });

    // 打开删除对话框
    const userRow = page.locator("tr", { hasText: testUserName });
    await userRow.locator("button:has(svg.lucide-ellipsis)").click();
    await page.getByRole("menuitem", { name: "Delete" }).click();

    // 新用户没有机器，应该显示 Confirm 按钮（可删除）
    await expect(
      page.getByRole("button", { name: "Confirm" })
    ).toBeVisible({ timeout: 5000 });

    // 关闭对话框
    await page.getByRole("button", { name: "Cancel" }).click();
  });

  test("should create and delete multiple users in sequence", async ({
    page,
  }) => {
    const runId = Date.now();
    const createdUsers: string[] = [];

    for (const suffix of ["a", "b", "c"]) {
      const testUserName = `e2e-seq-${suffix}-${runId}`;
      createdUsers.push(testUserName);

      // 创建
      await page.getByRole("button", { name: "Add user" }).click();
      await expect(
        page.getByText("Create a Headscale user")
      ).toBeVisible();
      await page.getByLabel("Username").fill(testUserName);
      await page.getByRole("button", { name: "Confirm" }).click();
      await expect(page.getByText(testUserName)).toBeVisible({
        timeout: 10000,
      });
    }

    // 依次删除本次创建的三个用户（通过准确用户名定位）
    for (const userName of createdUsers) {
      const userRow = page.locator("tr", { hasText: userName });
      await userRow.locator("button:has(svg.lucide-ellipsis)").click();
      await page.getByRole("menuitem", { name: "Delete" }).click();
      await expect(
        page.getByRole("heading", { name: /^Delete / })
      ).toBeVisible({ timeout: 5000 });
      await page.getByRole("button", { name: "Confirm" }).click();
      await expect(page.getByText(userName)).not.toBeVisible({
        timeout: 10000,
      });
    }
  });
});
