import { Routes, Route, Navigate } from "react-router-dom";
import { getToken } from "./api";
import Login from "./pages/Login";
import Register from "./pages/Register";
import Dashboard from "./pages/Dashboard";
import DeploymentDetail from "./pages/DeploymentDetail";

function RequireAuth({ children }: { children: JSX.Element }) {
  return getToken() ? children : <Navigate to="/login" replace />;
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route path="/register" element={<Register />} />
      <Route path="/" element={<RequireAuth><Dashboard /></RequireAuth>} />
      <Route path="/deployments/:id" element={<RequireAuth><DeploymentDetail /></RequireAuth>} />
    </Routes>
  );
}
