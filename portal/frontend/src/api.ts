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

async function request(path: string, opts: RequestInit = {}) {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(opts.headers as Record<string, string> | undefined),
  };
  const token = getToken();
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const res = await fetch(path, { ...opts, headers });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.detail || res.statusText);
  }
  return res.json();
}

export const api = {
  register: (tenant_name: string, email: string, password: string) =>
    request("/api/auth/register", { method: "POST", body: JSON.stringify({ tenant_name, email, password }) }),
  login: (email: string, password: string) =>
    request("/api/auth/login", { method: "POST", body: JSON.stringify({ email, password }) }),
  createDeployment: (config: unknown) =>
    request("/api/deployments", { method: "POST", body: JSON.stringify(config) }),
  listDeployments: () => request("/api/deployments"),
  getDeployment: (id: number) => request(`/api/deployments/${id}`),
  destroyDeployment: (id: number) => request(`/api/deployments/${id}/destroy`, { method: "POST" }),
  retryDeployment: (id: number) => request(`/api/deployments/${id}/retry`, { method: "POST" }),
};
