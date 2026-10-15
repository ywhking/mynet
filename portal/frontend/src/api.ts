const TOKEN_KEY = "portal_token";

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}
export function setToken(t: string) {
  localStorage.setItem(TOKEN_KEY, t);
}
export function clearToken() {
  localStorage.removeItem(TOKEN_KEY);
}

// FastAPI 的 detail 有两种形态：HTTPException 给字符串，请求校验失败（422）给数组
// （"邮箱格式不对"、"密码少于 8 位"）。直接拼进 Error 会显示成 [object Object]，
// 而这恰恰是注册最常见的失败。两种都要能渲染。
export function detailMessage(body: any, fallback: string): string {
  const d = body?.detail;
  if (typeof d === "string") return d;
  if (Array.isArray(d)) return d.map((e: any) => e?.msg ?? JSON.stringify(e)).join("; ");
  return fallback;
}

async function request(path: string, opts: RequestInit & { skipAuth?: boolean } = {}) {
  const { skipAuth, ...init } = opts;
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(init.headers as Record<string, string> | undefined),
  };
  // 登录/注册不带旧 token：否则一个过期 token 会让"密码错误"的 401 被误判成
  // "会话过期"，跳转并刷新页面，把本该显示在表单里的错误提示冲掉。
  const token = skipAuth ? null : getToken();
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const res = await fetch(path, { ...init, headers });
  if (!res.ok) {
    // 带着 token 仍被拒 → 会话已失效：清掉并回登录页，别让用户卡在死界面上。
    if (res.status === 401 && token) {
      clearToken();
      window.location.assign("/login");
      throw new Error("登录已过期，请重新登录");
    }
    const body = await res.json().catch(() => ({}));
    throw new Error(detailMessage(body, res.statusText));
  }
  return res.json();
}

export const api = {
  register: (tenant_name: string, email: string, password: string) =>
    request("/api/auth/register", {
      method: "POST",
      body: JSON.stringify({ tenant_name, email, password }),
      skipAuth: true,
    }),
  login: (email: string, password: string) =>
    request("/api/auth/login", {
      method: "POST",
      body: JSON.stringify({ email, password }),
      skipAuth: true,
    }),
  createDeployment: (config: unknown) =>
    request("/api/deployments", { method: "POST", body: JSON.stringify(config) }),
  listDeployments: () => request("/api/deployments"),
  getDeployment: (id: number) => request(`/api/deployments/${id}`),
  destroyDeployment: (id: number) => request(`/api/deployments/${id}/destroy`, { method: "POST" }),
  retryDeployment: (id: number) => request(`/api/deployments/${id}/retry`, { method: "POST" }),
};
