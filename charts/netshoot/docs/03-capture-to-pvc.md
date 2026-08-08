# A rolling packet capture, written to per-pod storage

A capture that runs for days and survives the pod being rescheduled — for the intermittent failure
nobody can reproduce on demand. `kind: StatefulSet` is what gives each pod a stable identity and its
own PVC, so pod 0's capture comes back to pod 0.

## Values

```yaml
# values-capture.yaml
# volumeClaimTemplates only work with a StatefulSet; the chart fails the render
# with any other kind rather than dropping storage that was asked for.
kind: StatefulSet
replicaCount: 2

statefulSet:
  # Capture pods have no ordering between them: start them at once.
  podManagementPolicy: Parallel
  updateStrategy:
    type: RollingUpdate

image:
  repository: nicolaka/netshoot
  tag: "v0.16"
  pullPolicy: IfNotPresent

# -G 3600 -W 24 keeps a rolling 24 hours in hourly files, overwriting the
# oldest — a capture that cannot fill the volume. %H names each file by hour.
# $(hostname) keeps the two pods from writing the same names.
command:
  - "sh"
  - "-c"
  - "tcpdump -ni any -s 96 -G 3600 -W 24 -w /captures/$(hostname)-%H.pcap 'not port 22'"

# tcpdump opens a raw socket: without NET_RAW it exits immediately with a
# permission error and the pod crash-loops.
securityContext:
  capabilities:
    drop:
      - ALL
    add:
      - NET_RAW
  allowPrivilegeEscalation: false

# One PVC per pod, named captures-netshoot-0 and captures-netshoot-1. Each stays
# bound to its ordinal across restarts and rescheduling.
volumeClaimTemplates:
  - name: captures
    size: 20Gi
    # mountPath is enough — the chart derives the volumeMount from it.
    mountPath: /captures
    accessModes:
      - ReadWriteOnce
    storageClassName: ""          # "" takes the cluster default StorageClass

# A capture is only useful next to the traffic it is capturing.
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: my-flaky-app

serviceAccount:
  create: true
  automount: false

# tcpdump needs a moment to flush its last buffer to the file on shutdown.
terminationGracePeriodSeconds: 30

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: "1"
    memory: 512Mi
```

## Install

```bash
helm install netshoot oci://ghcr.io/willbrid/charts/netshoot \
  --version 0.1.0 \
  --namespace production \
  --values values-capture.yaml
```

## Retrieve a capture

```bash
kubectl -n production get pvc -l app.kubernetes.io/name=netshoot
# captures-netshoot-0, captures-netshoot-1 — Bound

kubectl -n production exec netshoot-0 -- ls -lh /captures/

# copy one file out and open it in Wireshark
kubectl -n production cp netshoot-0:/captures/netshoot-0-14.pcap ./14.pcap

# or read it in place
kubectl -n production exec netshoot-0 -- tcpdump -nr /captures/netshoot-0-14.pcap 'port 443' | head -50
```

## Verify it really survives

```bash
kubectl -n production exec netshoot-0 -- touch /captures/marker
kubectl -n production delete pod netshoot-0
kubectl -n production wait --for=condition=Ready pod/netshoot-0 --timeout=120s
kubectl -n production exec netshoot-0 -- ls /captures/marker   # still there
```

## What to know

- **Size the capture, not the volume.** `-s 96` keeps headers only, which is enough for a
  connectivity or retransmission question and roughly ten times smaller than full packets. `-W`
  bounds the file count so the PVC cannot fill — without it, a full volume stops the capture and
  possibly the node's disk pressure eviction takes the pod with it.
- **The PVCs outlive the release.** `helm uninstall` leaves them, on purpose: the whole point is
  that the evidence is still there afterwards. Delete them explicitly when the investigation is
  over: `kubectl -n production delete pvc -l app.kubernetes.io/name=netshoot`.
- **`-i any` captures every interface of the pod's own namespace**, which for a normal pod is one
  veth. To see a node's traffic, this needs `hostNetwork` instead — see
  [Node debugging](02-per-node-daemonset.md).
- **Captures contain payloads.** Anything unencrypted on the wire ends up on that volume, including
  credentials and personal data. Treat the PVC as sensitive, and prefer `-s 96` for that reason too.
- **An entry with `enabled: false`** stays declared in the values and creates nothing — a way to
  turn a second volume off without deleting its configuration.
- **A headless service is created automatically** for the StatefulSet, so each pod is reachable at
  `netshoot-0.netshoot.production.svc.cluster.local` — useful when you want to target one specific
  capture pod.
