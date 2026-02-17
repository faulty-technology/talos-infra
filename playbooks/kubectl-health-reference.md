# kubectl & talosctl Health/State Quick Reference

Commands you'll use regularly to understand what's happening in your cluster.

## Cluster-Level Health

```bash
# Is the node up and schedulable?
kubectl get nodes

# Resource pressure (CPU/memory) — requires metrics-server
kubectl top nodes
kubectl top pods -A

# Everything running across all namespaces
kubectl get pods -A

# Events (recent cluster activity — scheduling, pulls, crashes, OOM kills)
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

## App-Level Debugging (the 3-step pattern)

Almost every issue follows this flow:

```bash
# 1. What's the pod status?
kubectl get pods -n <namespace>
#    - Running = healthy
#    - CrashLoopBackOff = app starts then dies (check logs)
#    - ImagePullBackOff = can't pull container image (wrong tag? private registry?)
#    - Pending = can't be scheduled (no resources? no node? PVC not bound?)
#    - Init:0/1 = init container hasn't finished

# 2. Why is it in that state?
kubectl describe pod <pod-name> -n <namespace>
#    → scroll to "Events" at the bottom — that's where the answer usually is

# 3. What did the app say before it died?
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous   # logs from the LAST crash
```

## Deployment State

```bash
# Is the rollout complete?
kubectl rollout status deployment/<name> -n <namespace>

# What version is running?
kubectl get deployment <name> -n <namespace> -o jsonpath='{.spec.template.spec.containers[0].image}'

# Rollout history
kubectl rollout history deployment/<name> -n <namespace>

# Undo last rollout
kubectl rollout undo deployment/<name> -n <namespace>
```

## Storage

```bash
# PVC status (Bound = working, Pending = problem)
kubectl get pvc -A

# Why is a PVC pending?
kubectl describe pvc <name> -n <namespace>
#    → usually: no StorageClass, CSI driver not running, or AZ mismatch
```

## Networking / Ingress

```bash
# Services and their endpoints
kubectl get svc -A

# Does a service have endpoints? (empty = no matching pods)
kubectl get endpoints <service-name> -n <namespace>

# Traefik IngressRoutes
kubectl get ingressroute -A

# Test connectivity from inside the cluster
kubectl run tmp --rm -it --image=busybox -- wget -qO- http://<service>.<namespace>.svc.cluster.local
```

## Talos-Specific

```bash
# Is the Talos API responding? (use instead of `talosctl health` pre-bootstrap)
talosctl version

# Live dashboard (CPU, memory, processes, logs — like htop for Talos)
talosctl dashboard

# Node health (requires running etcd + k8s)
talosctl health

# System services status (etcd, kubelet, apid, etc.)
talosctl services

# Kernel + system logs
talosctl dmesg
talosctl logs kubelet
talosctl logs etcd
```

## Patterns to Recognize

| Symptom | Likely cause |
|---------|-------------|
| Pod `Pending` forever | Not enough CPU/memory, or PVC can't bind |
| Pod `CrashLoopBackOff` | App is crashing — check `kubectl logs --previous` |
| Pod `ImagePullBackOff` | Wrong image tag, private registry auth, or rate limit |
| Pod `Running` but service 503s | Readiness probe failing, or Service selector doesn't match pod labels |
| PVC `Pending` | StorageClass missing, CSI driver not installed, or AZ mismatch |
| Node `NotReady` | kubelet down — check `talosctl services` and `talosctl logs kubelet` |
| `kubectl` times out | KUBECONFIG wrong, API server down, or security group blocks 6443 |
| `talosctl` times out | Endpoint/node misconfigured (see CLAUDE.md networking section) |
