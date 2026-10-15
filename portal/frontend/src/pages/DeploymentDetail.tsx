import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { api } from "../api";
import type { RunInfo } from "../types";

export default function DeploymentDetail() {
  const { id } = useParams();
  const [runs, setRuns] = useState<RunInfo[]>([]);

  useEffect(() => {
    const timer = setInterval(async () => {
      const data = await api.getDeployment(Number(id));
      setRuns(data.runs);
    }, 2000);
    return () => clearInterval(timer);
  }, [id]);

  const last = runs[runs.length - 1];

  return (
    <div>
      <h2>部署 #{id}</h2>
      {last && <p>状态: {last.status}</p>}
      <button onClick={() => api.destroyDeployment(Number(id))}>销毁</button>
      <button onClick={() => api.retryDeployment(Number(id))}>重试</button>
      <pre style={{ whiteSpace: "pre-wrap", background: "#111", color: "#0f0", padding: 8 }}>
        {last?.log || "（暂无日志）"}
      </pre>
    </div>
  );
}
