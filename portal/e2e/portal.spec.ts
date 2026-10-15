import { test, expect } from "@playwright/test";

test("register and see empty deployment list", async ({ page }) => {
  await page.goto("/register");
  await page.getByPlaceholder("组织/租户名").fill("Acme");
  await page.getByPlaceholder("邮箱").fill(`u${Date.now()}@acme.com`);
  await page.getByPlaceholder("密码").fill("s3cret123");
  await page.getByRole("button", { name: "注册" }).click();
  // exact 匹配：Dashboard 同时渲染 <h2>部署</h2>、<button>创建部署</button> 和
  // <p>（暂无部署）</p>，默认的子串匹配会让定位器命中 3 个元素并触发 strict mode 报错。
  await expect(page.getByText("部署", { exact: true })).toBeVisible();
});
