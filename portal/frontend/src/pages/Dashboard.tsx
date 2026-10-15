import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { api, clearToken } from "../api";

export default function Dashboard() {
  const [deps, setDeps] = useState<{ id: number; status: string }[]>([]);
  const [subdomain, setSubdomain] = useState("");
  const [publicVms, setPublicVms] = useState("bastion,web");
  const [internalVms, setInternalVms] = useState("db");
  const [error, setError] = useState("");
  // 与 error 分开：列表拉取失败要单独提示，否则用户看到的是一个空列表，
  // 分不清"没有部署"还是"根本没取到"。
  const [listError, setListError] = useState("");
  const [busy, setBusy] = useState(false);
  const nav = useNavigate();

  async function refresh() {
    try {
      setDeps(await api.listDeployments());
      setListError("");
    } catch (err) {
      setListError((err as Error).message);
    }
  }
  useEffect(() => { refresh(); }, []);

  function logout() {
    clearToken();
    nav("/login");
  }

  async function create(e: React.FormEvent) {
    e.preventDefault();
    setError("");
    const pubInstances: Record<string, unknown> = {};
    publicVms.split(",").map((s) => s.trim()).filter(Boolean).forEach((name, i) => {
      pubInstances[name] = {
        host_name: name,
        public_ip: true,
        is_bastion: i === 0,
        domain_name: name,
      };
    });
    const intInstances: Record<string, unknown> = {};
    internalVms.split(",").map((s) => s.trim()).filter(Boolean).forEach((name) => {
      intInstances[name] = { host_name: name };
    });
    const config = {
      subdomain,
      public_devices: { cidr: "172.16.0.0/24", instances: pubInstances },
      internal_devices: { cidr: "172.16.1.0/24", instances: intInstances },
    };
    setBusy(true);
    try {
      await api.createDeployment(config);
      await refresh();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div>
      <h2>部署</h2>
      <button onClick={logout}>登出</button>
      {error && <p style={{ color: "red" }}>{error}</p>}
      {listError && <p style={{ color: "orange" }}>列表加载失败：{listError}</p>}
      <form onSubmit={create}>
        <input placeholder="子域名前缀，如 acme" value={subdomain} onChange={(e) => setSubdomain(e.target.value)} />
        <input placeholder="公网 VM（逗号分隔，第一台为堡垒机）" value={publicVms} onChange={(e) => setPublicVms(e.target.value)} />
        <input placeholder="内网 VM（逗号分隔）" value={internalVms} onChange={(e) => setInternalVms(e.target.value)} />
        <button type="submit" disabled={busy}>创建部署</button>
      </form>
      {!listError && deps.length === 0 && <p>（暂无部署）</p>}
      <ul>
        {deps.map((d) => (
          <li key={d.id}>
            <Link to={`/deployments/${d.id}`}>#{d.id} ({d.status})</Link>
          </li>
        ))}
      </ul>
    </div>
  );
}
