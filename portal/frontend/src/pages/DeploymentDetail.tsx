import { useEffect, useState } from "react";
import { useParams, Link } from "react-router-dom";
import { api } from "../api";
import type { RunInfo } from "../types";

export default function DeploymentDetail() {
  const { id } = useParams();
  const depId = Number(id);
  const [runs, setRuns] = useState<RunInfo[]>([]);
  // 轮询错误与操作错误分开：轮询成功会清掉前者，但绝不能顺手抹掉后者，
  // 否则"销毁失败"的提示 2 秒后就被一次成功的轮询吃掉了。
  const [pollError, setPollError] = useState("");
  const [actionError, setActionError] = useState("");
  const [actionMessage, setActionMessage] = useState("");
  const [busy, setBusy] = useState(false);

  async function load() {
    try {
      const data = await api.getDeployment(depId);
      setRuns(data.runs);
      setPollError("");
    } catch (err) {
      setPollError((err as Error).message);
    }
  }

  useEffect(() => {
    load();                                   // 先取一次，别让用户白等第一个 2 秒 tick
    const timer = setInterval(load, 2000);
    return () => clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [depId]);

  async function act(label: string, fn: () => Promise<any>) {
    setBusy(true);
    setActionError("");
    setActionMessage("");
    try {
      const r = await fn();
      setActionMessage(`${label}已提交（run #${r?.run_id ?? "-"}，状态 ${r?.status ?? "-"}）`);
      await load();                            // 立刻反映新 run，不用等下一次轮询
    } catch (err) {
      // 失败只提示，不动当前展示的状态——状态一律以服务端返回为准。
      setActionError(`${label}失败：${(err as Error).message}`);
    } finally {
      setBusy(false);
    }
  }

  const last = runs[runs.length - 1];

  return (
    <div>
      <h2>部署 #{id}</h2>
      <p><Link to="/">← 返回列表</Link></p>
      {pollError && <p style={{ color: "orange" }}>状态刷新失败：{pollError}</p>}
      {actionError && <p style={{ color: "red" }}>{actionError}</p>}
      {actionMessage && <p style={{ color: "green" }}>{actionMessage}</p>}
      {last && <p>状态: {last.status}</p>}
      <button disabled={busy} onClick={() => act("销毁", () => api.destroyDeployment(depId))}>
        销毁
      </button>
      <button disabled={busy} onClick={() => act("重试", () => api.retryDeployment(depId))}>
        重试
      </button>
      <pre style={{ whiteSpace: "pre-wrap", background: "#111", color: "#0f0", padding: 8 }}>
        {last?.log || "（暂无日志）"}
      </pre>
    </div>
  );
}
