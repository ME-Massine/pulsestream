# NetworkPolicies on Kubernetes

Platform network isolation for the `PulseStream` services (#147).

By default a Kubernetes pod accepts connections from, and initiates connections to, anything on the pod network. These policies replace that open default with an allow-list per service: each service can only be reached on the ports it serves, and can only reach the backends it actually uses.

## ⚠️ Enforcement depends on the CNI

**A NetworkPolicy is only enforced if the cluster's CNI plugin implements it.** Applying these manifests always succeeds, but on a CNI that ignores NetworkPolicy they block nothing.

| Environment | Enforces NetworkPolicy? |
| :--- | :--- |
| kind (default `kindnet`) | **No** |
| Docker Desktop Kubernetes | **No** |
| minikube (default) | **No** — enable with `--cni=calico` |
| Calico, Cilium, Weave, Antrea | **Yes** |

So on the usual local dev clusters these policies apply cleanly and are inert — nothing breaks, and nothing is blocked. The isolation only takes effect on a policy-enforcing CNI. The structural checks in `validate-network-policies.ps1` run everywhere; the connectivity checks under [Verify enforcement](#verify-enforcement-policy-enforcing-cni-only) only mean something on an enforcing CNI.

## Model

One **self-contained policy per service**. Each sets `policyTypes: [Ingress, Egress]`, which turns on a default-deny in both directions for the pods it selects, and then lists the only allowed paths. Nothing else is permitted. Keeping ingress and egress for one service in one file means the file fully describes that service's isolation, and deleting it never leaves the service half-policed.

Two rules apply throughout:

- **Selectors target one workload by its `app.kubernetes.io/name`**, never `app.kubernetes.io/part-of: pulsestream`. A platform-wide selector would also select the Strimzi-managed Kafka pods and the Postgres pod and cut off their traffic. Kafka and Postgres are deliberately **not** policed here — securing the broker listener is a separate concern (#275), and Postgres is provisioned separately.
- **DNS egress is always allowed.** With egress default-denied, a pod that cannot reach CoreDNS cannot resolve any name, and every outbound connection fails at lookup. Each policy allows UDP/TCP 53 to the `kube-dns` pods in `kube-system`.

### Effective posture

| Service | Ingress allowed | Egress allowed |
| :--- | :--- | :--- |
| `ingestion-service` | 8081 from **any** peer | DNS, Kafka `:9092` |
| `telemetry-processor` | 8082 from the labelled `service-connectivity-probe` only | DNS, Kafka `:9092`, Postgres `:5432` |
| `query-service` | 8083 from the **same namespace** | DNS |

Everything absent from this table is blocked when the CNI enforces policy — for example `query-service` cannot reach Kafka or Postgres, `ingestion-service` cannot reach Postgres, and nothing off-cluster can reach `query-service` or `telemetry-processor`.

### Three deliberate design points

**`ingestion-service` port 8081 is open to every peer.** External producers reach it through the NodePort Service (#145), whose default `externalTrafficPolicy: Cluster` SNATs the client to a node IP; kubelet probes also arrive as a node IP. Neither is a pod, so no selector can match them, and the endpoint is meant to be reachable by "anything that can reach a node" (#145). 8081 is therefore left open while every other port on those pods stays denied.

**Postgres egress is scoped by port, not by a Postgres label.** `telemetry-processor` allows egress to TCP 5432 within its own namespace (`podSelector: {}`) rather than to a labelled Postgres pod, because the Postgres workload is provisioned separately and its labels are not fixed here. Port 5432 still reaches only Postgres, since nothing else in the namespace listens there. Tighten it to a specific `podSelector` once Postgres provisioning lands.

**The service-connectivity probe has an explicit ingress identity.** The validator merged for #146 must reach every ClusterIP from outside the services themselves, including `telemetry-processor:8082/readyz`. Its throwaway pod carries `app.kubernetes.io/name=service-connectivity-probe` and `app.kubernetes.io/part-of=pulsestream`; the telemetry policy admits only that same-namespace identity on the `http` port. Ordinary pods remain blocked, while the repository's accepted connectivity check continues to work after these policies are enforced.

## Kubelet health probes

Liveness/readiness probes originate from the **kubelet on the node**, a host-network source, not a pod — so a `podSelector`/`namespaceSelector` cannot match them. The telemetry rule for the labelled connectivity pod and `query-service`'s same-namespace rule therefore do not cover kubelet traffic: standard CNIs (Calico, Cilium) allow the node to reach its local pods for health checking regardless of policy, and the non-enforcing CNIs above allow everything. Probes keep working in every case tested here.

If you run a CNI that *does* police kubelet→pod traffic, probes will fail (pods flip to `NotReady`). The fix is to allow the node network on the probe port. Add a rule like this to the affected service's policy, with your cluster's node CIDR:

```yaml
  ingress:
    - from:
        - ipBlock:
            cidr: 10.0.0.0/16 # replace with your node CIDR
      ports:
        - port: http
          protocol: TCP
```

## Apply

Applied into the same namespace as the workloads (`default`, matching the rest of `infrastructure/kubernetes/`):

```bash
kubectl apply -f infrastructure/kubernetes/network-policies/
```

```bash
kubectl get networkpolicies
```

## Verify structure

`validate-network-policies.ps1` asserts the applied policies are shaped correctly — the right pods are selected, both directions are default-denied, DNS is allowed, and each service's required allows are present. It is CNI-independent, so it is the check that means something on a non-enforcing dev cluster.

```powershell
.\scripts\validate-network-policies.ps1
```

Override `-Namespace` if the workloads run elsewhere.

## Verify enforcement (policy-enforcing CNI only)

The checks below only demonstrate isolation on a CNI that enforces NetworkPolicy (see the table above). On a non-enforcing cluster every probe reports "reachable"; that is the CNI, not a broken policy.

**Ingress — an allowed inbound path answers, a denied one does not.** An ordinary throwaway pod in the same namespace is admitted by `ingestion-service` (open to all) but not by `telemetry-processor` (only the specifically labelled service-connectivity probe is admitted):

```bash
# Allowed: ingestion-service is open on 8081.
kubectl run np-probe --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 http://ingestion-service:8081/readyz
# expect: 200

# Blocked: this ordinary pod lacks the two service-connectivity probe labels.
kubectl run np-probe --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 http://telemetry-processor:8082/readyz
# expect: curl exit 28 (timeout) when enforced
```

Run `scripts/validate-service-connectivity.ps1` for the matching positive path. It creates the short-lived pod with both required labels and must receive `200`/`UP` from all three ClusterIP Services, including `telemetry-processor`.

`query-service` admits the same-namespace probe above but rejects one from another namespace:

```bash
kubectl create namespace np-test
kubectl run np-probe --rm -it --restart=Never -n np-test --image=curlimages/curl -- \
  curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 \
  http://query-service.default.svc.cluster.local:8083/readyz
# expect: timeout when enforced (same-namespace probe would return 200)
kubectl delete namespace np-test
```

**Egress — a service reaches only its declared backends.** A debug pod carrying a service's `app.kubernetes.io/name` label is selected by that service's policy, so it inherits the same egress rules while providing tooling the Spring images lack. (It also briefly becomes an endpoint of that Service; it is short-lived and `--rm`.)

```bash
# query-service can resolve DNS but must NOT reach Kafka.
kubectl run np-egress --rm -it --restart=Never \
  --labels app.kubernetes.io/name=query-service --image=nicolaka/netshoot -- /bin/sh -c '
    nslookup pulsestream-kafka-bootstrap >/dev/null 2>&1 && echo "DNS: ok" || echo "DNS: blocked";
    nc -z -w3 pulsestream-kafka-bootstrap 9092 && echo "Kafka: reachable" || echo "Kafka: blocked"'
# expect: DNS ok, Kafka blocked

# ingestion-service, by contrast, is allowed to reach Kafka.
kubectl run np-egress --rm -it --restart=Never \
  --labels app.kubernetes.io/name=ingestion-service --image=nicolaka/netshoot -- \
  nc -z -w3 pulsestream-kafka-bootstrap 9092 && echo "Kafka: reachable"
# expect: Kafka reachable
```

## Not covered here

Each is a separate concern:

- **Kafka listener security** — TLS and authentication on the broker listener (#275). These policies restrict *who can open a TCP connection* to the brokers; they do not encrypt or authenticate it.
- **Ingestion authentication / TLS** — securing the external ingest entry point (#273). 8081 stays open at the network layer here.
- **Service mesh and zero-trust / mTLS** — explicitly out of scope for #147.
- **Policies for infrastructure pods** — Kafka, Postgres, and (later) the observability stack are not selected by these policies.
