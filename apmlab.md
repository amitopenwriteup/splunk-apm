# Workshop: Auto-Instrumenting a Python Microservice with OpenTelemetry + Splunk on Kubernetes

## Goal

By the end of this workshop you will have:

- Verified your existing Splunk OTel Collector Helm install and operator webhook are healthy
- Created the `Instrumentation` custom resource the pod annotation depends on
- A working `api-gateway` service deployed in the `service-map-lab` namespace
- The `api-gateway` pod auto-instrumented via annotation (zero code changes)
- Verified traces flowing into Splunk Observability Cloud (or a local backend)

**Time:** ~30–40 minutes
**Level:** Intermediate (assumes basic `kubectl` familiarity)

**Starting point for this workshop:** you have already run `helm install`/`helm upgrade` for the `splunk-otel-collector` chart with:
- `agent.enabled` / collector chart installed in the cluster
- `gateway.enabled=false` (agent-only mode, no separate gateway deployment)
- `certmanager.enabled=false` (you're using a cert-manager already installed separately, or a cluster-issued cert)

This guide picks up from there — it does **not** re-install the collector chart.

---

## Prerequisites

- A Kubernetes cluster you can admin (kind, minikube, EKS/GKE/AKS, etc.)
- `kubectl` configured against that cluster
- `helm` v3+
- The `splunk-otel-collector` Helm release already installed (agent mode, `gateway.enabled=false`, `certmanager.enabled=false`)
- `operator.enabled=true` set on that release — **required** for the annotation-based webhook to exist at all; it's independent of the `gateway` and `certmanager` flags

Check your setup:

```bash
kubectl version --short
helm version
helm list -n default
```

---

## Step 1 — Confirm the operator flag and existing release are healthy

Since `certmanager` and `gateway` are both `false`, double-check `operator.enabled=true` was actually set — it's the one flag that's non-negotiable for injection to work:

```bash
helm get values splunk-otel-collector -n default
```

Look for `operator: enabled: true` in the output. If it's missing or `false`, upgrade the release:

```bash
helm upgrade splunk-otel-collector splunk-otel-collector-chart/splunk-otel-collector \
  --namespace default \
  --reuse-values \
  --set operator.enabled=true
```

Then check the pods:

```bash
kubectl get pods -n default | grep -E 'splunk-otel|opentelemetry-operator'
```

You should see the collector **agent** (DaemonSet, no gateway pods since that's disabled) and the `opentelemetry-operator-controller-manager` pod, both `Running`.

---

## Step 2 — Create the `Instrumentation` custom resource

This is the piece your pod annotation actually points to. **Without this object, the annotation does nothing.**

```yaml
# instrumentation.yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: splunk-otel-collector
  namespace: default
spec:
  exporter:
    endpoint: http://$(SPLUNK_OTEL_AGENT):4317
  propagators:
    - tracecontext
    - baggage
  python:
    env:
      - name: OTEL_EXPORTER_OTLP_PROTOCOL
        value: grpc
```

```bash
kubectl apply -f instrumentation.yaml
```

Verify:

```bash
kubectl get instrumentation -n default
kubectl describe instrumentation splunk-otel-collector -n default
```

> **Namespace/name must match the annotation exactly.** The annotation `default/splunk-otel-collector` means namespace=`default`, name=`splunk-otel-collector`. If either doesn't match, the webhook silently skips injection — no error, the pod just runs uninstrumented.

---

## Step 3 — Create the namespace and deploy api-gateway

```bash
kubectl create namespace service-map-lab
```

Save the manifest you already have as `api-gateway.yaml` (Service + Deployment with the `instrumentation.opentelemetry.io/inject-python` annotation), then:

```bash
kubectl apply -f api-gateway.yaml
```

> ⚠️ **Ordering matters.** The webhook only fires at pod *creation* time. If the `Instrumentation` CR (Step 2) isn't already applied before this Deployment creates its pod, you'll get an uninstrumented pod. If you applied things out of order, fix it with:
> ```bash
> kubectl rollout restart deployment/api-gateway -n service-map-lab
> ```

---

## Step 4 — Verify injection happened

```bash
kubectl get pods -n service-map-lab
kubectl describe pod -n service-map-lab -l app=api-gateway
```

Look for:

- An **init container** named something like `opentelemetry-auto-instrumentation-python`
- Env vars on the main container: `PYTHONPATH`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`

If you don't see these, jump to **Troubleshooting** below.

---

## Step 5 — Generate traffic and check traces

```bash
kubectl get svc -n service-map-lab api-gateway
```

If `EXTERNAL-IP` stays `<pending>` (common on kind/minikube without a cloud LB controller), port-forward instead:

```bash
kubectl port-forward -n service-map-lab svc/api-gateway 8080:80
```

Hit the health endpoint a few times:

```bash
curl http://localhost:8080/health
curl http://localhost:8080/api/orders
```

Then check your Splunk Observability Cloud **APM** tab — look for a service named `api-gateway` (or whatever `OTEL_SERVICE_NAME` resolved to) within a minute or two.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No init container present | Instrumentation CR name/namespace mismatch, or pod created before CR existed | Check `kubectl get instrumentation -n default`; restart the Deployment |
| Init container present but no traces arrive | Collector endpoint unreachable, or wrong access token/realm | `kubectl logs` the collector agent pod; check Helm values |
| Pod stuck in `ContainerCreating` | Webhook not ready yet | Wait a moment, then re-apply the Deployment |
| `EXTERNAL-IP: <pending>` on the Service | No cloud LoadBalancer controller in this cluster | Use `kubectl port-forward` or switch `type: NodePort` |
| Operator pod crash-looping | CRDs not installed / version mismatch | `helm upgrade` the operator chart, check `kubectl get crds \| grep opentelemetry` |
| Operator pod missing entirely | `operator.enabled` was left `false` on the existing Helm release | `helm get values splunk-otel-collector -n default`; `helm upgrade --reuse-values --set operator.enabled=true` |

Useful diagnostic commands:

```bash
kubectl logs -n default -l app.kubernetes.io/name=opentelemetry-operator
kubectl logs -n default -l app=splunk-otel-collector-agent
kubectl get mutatingwebhookconfigurations
```

---

## Cleanup

This removes only what *this workshop* added — it leaves your existing `splunk-otel-collector` Helm release in place:

```bash
kubectl delete namespace service-map-lab
kubectl delete -f instrumentation.yaml
```

---

## Key Takeaways

1. The pod annotation is a **pointer**, not a mechanism — it references an `Instrumentation` CR by `namespace/name`.
2. `gateway.enabled` and `certmanager.enabled` are unrelated to whether injection works — `operator.enabled=true` is the flag that actually turns on the webhook.
3. Injection happens **only at pod creation**; existing pods need a restart after prerequisites are in place.
4. No application code changes are required for supported languages — instrumentation is injected via init container + env vars (`PYTHONPATH` for Python).
5. Always verify injection with `kubectl describe pod`, not just by assuming the annotation worked.
