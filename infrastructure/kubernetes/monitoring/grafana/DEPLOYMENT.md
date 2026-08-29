# Grafana on Kubernetes

The base Grafana deployment for issue #155. It runs the UI, keeps Grafana state
on persistent storage, and exposes the UI through a cluster-internal Service.
Prometheus datasource and dashboard provisioning are separate work in #156.

## Manifests

| File | Purpose |
| --- | --- |
| `../namespace.yaml` | Shared `monitoring` namespace for Prometheus and Grafana. |
| `pvc.yaml` | 5 GiB `ReadWriteOnce` storage for Grafana's SQLite database and local state. |
| `deployment.yaml` | One non-root Grafana replica with probes, resources, and Secret-backed bootstrap credentials. |
| `service.yaml` | ClusterIP `grafana` Service on port 80 for in-cluster access and local port-forwarding. |

The official Grafana image is pinned as a readable version plus an immutable
multi-architecture digest. The deployment uses one replica and the `Recreate`
strategy because the embedded SQLite database on a single-writer PVC is not a
high-availability backend. Moving to multiple replicas requires an external
MySQL or PostgreSQL database first.

## Prerequisites

- A reachable Kubernetes cluster with a default dynamic `StorageClass`.
- `kubectl` configured for that cluster.
- Permission to create a namespace, Secret, PVC, Deployment, and Service.

## Deploy

Create the namespace first:

```powershell
kubectl apply -f infrastructure/kubernetes/monitoring/namespace.yaml
```

Create the bootstrap credentials without committing a Secret manifest, putting
the password in shell history or process arguments, or writing it to disk. The
Secret manifest exists only in memory and is sent to `kubectl apply` over stdin:

```powershell
$grafanaSecurePassword = Read-Host "Grafana admin password" -AsSecureString
$grafanaCredential = [PSCredential]::new("admin", $grafanaSecurePassword)
$previousOutputEncoding = $OutputEncoding
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$grafanaSecret = [ordered]@{
  apiVersion = "v1"
  kind = "Secret"
  metadata = [ordered]@{ name = "grafana"; namespace = "monitoring" }
  type = "Opaque"
  stringData = [ordered]@{
    "admin-user" = $grafanaCredential.UserName
    "admin-password" = $grafanaCredential.GetNetworkCredential().Password
  }
}

try {
  $grafanaSecret | ConvertTo-Json -Depth 4 -Compress | kubectl apply -f -
  if ($LASTEXITCODE -ne 0) {
    throw "kubectl failed to apply Secret/grafana."
  }
} finally {
  $grafanaSecret.stringData["admin-password"] = $null
  $OutputEncoding = $previousOutputEncoding
  Remove-Variable grafanaSecret, grafanaCredential, grafanaSecurePassword
  Remove-Variable previousOutputEncoding
}
```

Then apply every deployable manifest in this directory:

```powershell
kubectl apply -f infrastructure/kubernetes/monitoring/grafana/
```

There is deliberately no example Secret in the directory. This keeps the
directory-wide apply safe: it cannot replace a real password with a checked-in
placeholder.

## Verify

Run the offline structural test under either supported PowerShell edition:

```powershell
pwsh ./scripts/tests/test-grafana-deployment-structure.ps1
powershell -File scripts\tests\test-grafana-deployment-structure.ps1
```

Against the cluster, validate the applied object contracts, PVC binding,
rollout convergence, Ready EndpointSlice, API/UI access, and a short pod
stability sample:

```powershell
pwsh ./scripts/validate-grafana-deployment.ps1
```

The live validator does not validate a Prometheus datasource or dashboards;
those are the acceptance checks owned by #156.

## Access the UI

Keep this command running:

```powershell
kubectl port-forward --namespace monitoring service/grafana 3000:80
```

Open `http://localhost:3000` and sign in with the credentials stored in
`Secret/grafana`. The Service remains `ClusterIP`; NodePort, LoadBalancer,
Ingress, SSO, and advanced RBAC are outside this issue.

## Operational notes

- The PVC uses the cluster's default `StorageClass`. If it remains `Pending`,
  check `kubectl get storageclass` and supply an environment-specific class.
- A fresh Grafana 13 database runs its complete migration history before the
  HTTP listener opens. The startup probe allows 20 minutes for slow development
  volumes while readiness keeps the Service from routing traffic; steady-state
  liveness remains much tighter after startup succeeds.
- Default suggested-plugin downloads and bundled-plugin auto-updates are
  disabled. The #156 dashboards need only built-in Prometheus support, and the
  immutable, read-only deployment must not rewrite image-bundled plugins or
  depend on the public plugin catalog during startup.
- `GF_SECURITY_ADMIN_USER` and `GF_SECURITY_ADMIN_PASSWORD` initialize a new
  Grafana database only. Updating `Secret/grafana` does not change the password
  of an existing admin account on the PVC; rotate that account through Grafana
  before updating the Secret to match.
- The PVC survives pod replacement and Deployment deletion. Deleting
  `PersistentVolumeClaim/grafana-data` can permanently remove Grafana state,
  depending on the StorageClass reclaim policy.
- The read-only container filesystem has only `/var/lib/grafana` (PVC) and
  `/tmp` (`emptyDir`) as writable paths. Logs and plugins are explicitly kept
  under the persistent data path.
