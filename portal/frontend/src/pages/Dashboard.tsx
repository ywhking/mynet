import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { api } from "../api";

export default function Dashboard() {
  const [deps, setDeps] = useState<{ id: number; status: string }[]>([]);
  const [subdomain, setSubdomain] = useState("");
  const [publicVms, setPublicVms] = useState("bastion,web");
  const [internalVms, setInternalVms] = useState("db");
  const [error, setError] = useState("");

  async function refresh() {
    setDeps(await api.listDeployments());
  }
  useEffect(() => { refresh(); }, []);

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
    try {
      await api.createDeployment(config);
      refresh();
    } catch (err) {
      setError((err as Error).message);
    }
  }

  return (
    <div>
      <h2>部署</h2>
      {error && <p style={{ color: "red" }}>{error}</p>}
      <form onSubmit={create}>
        <input placeholder="子域名前缀，如 acme" value={subdomain} onChange={(e) => setSubdomain(e.target.value)} />
        <input placeholder="公网 VM（逗号分隔，第一台为堡垒机）" value={publicVms} onChange={(e) => setPublicVms(e.target.value)} />
        <input placeholder="内网 VM（逗号分隔）" value={internalVms} onChange={(e) => setInternalVms(e.target.value)} />
        <button type="submit">创建部署</button>
      </form>
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
