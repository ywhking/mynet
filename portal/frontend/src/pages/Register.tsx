import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { api, setToken } from "../api";

export default function Register() {
  const [tenant, setTenant] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const nav = useNavigate();

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError("");
    try {
      const r = await api.register(tenant, email, password);
      setToken(r.access_token);
      nav("/");
    } catch (err) {
      setError((err as Error).message);
    }
  }

  return (
    <form onSubmit={submit}>
      <h2>注册</h2>
      {error && <p style={{ color: "red" }}>{error}</p>}
      <input placeholder="组织/租户名" value={tenant} onChange={(e) => setTenant(e.target.value)} />
      <input placeholder="邮箱" value={email} onChange={(e) => setEmail(e.target.value)} />
      <input type="password" placeholder="密码（至少8位）" value={password} onChange={(e) => setPassword(e.target.value)} />
      <button type="submit">注册</button>
    </form>
  );
}
