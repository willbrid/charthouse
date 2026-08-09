# Quickstart — what you get out of the box

Install the chart with no values at all and you get a working HAProxy that proxies nothing: two
replicas, a `health` endpoint answering probes and Prometheus, a traffic port on 8080 and an empty
backend behind it. This page is about seeing that, understanding each piece, and then pointing it at
something real.

## Install

```bash
helm install haproxy oci://ghcr.io/willbrid/charts/haproxy \
  --version 0.1.0 \
  --namespace edge --create-namespace
```

```bash
kubectl get pods -n edge
# NAME                       READY   STATUS    RESTARTS   AGE
# haproxy-6d784c76c-wppsq    1/1     Running   0          12s
# haproxy-6d784c76c-zx4hh    1/1     Running   0          12s
```

Each pod went through an init container first:

```bash
kubectl logs -n edge deploy/haproxy -c config-check
# [NOTICE] (1) : haproxy version is 3.4.3-80ea565fd
# [NOTICE] (1) : path to executable is /usr/local/sbin/haproxy
```

That is `haproxy -c` parsing the configuration and exiting 0. Break the configuration and this is
where you find out — the pod stays in `Init` and the parser error, with its line number, is in that
container's logs.

## What the default configuration is

```
frontend health          # bind *:8404  → /healthz, /metrics, /stats
frontend http_in         # bind *:8080  → default_backend app
backend app              # no servers
```

Two service ports map onto it:

| Service port | Container port | Frontend |
|---|---|---|
| `http` 80 | 8080 | `http_in` |
| `health` 8404 | 8404 | `health` |

Port 80 on the Service and 8080 in the container is not an oversight: the official image runs as uid
99 with every capability dropped, so it cannot bind a port below 1024. The Service remaps it and
clients never notice.

## First requests

```bash
kubectl port-forward -n edge svc/haproxy 8404:8404
```

```bash
curl -i http://127.0.0.1:8404/healthz
# HTTP/1.1 200 OK
# <html><body><h1>200 OK</h1>
# Service ready.
# </body></html>

curl -s http://127.0.0.1:8404/metrics | head -3
# # HELP haproxy_process_nbthread Number of started threads (global.nbthread)
# # TYPE haproxy_process_nbthread gauge
# haproxy_process_nbthread 8
```

Open `http://127.0.0.1:8404/stats` in a browser for the statistics page: frontends, backends, every
server and its state.

Now the traffic port:

```bash
kubectl port-forward -n edge svc/haproxy 8080:80
curl -i http://127.0.0.1:8080/
# HTTP/1.1 503 Service Unavailable
```

That `503` is correct: `backend app` has no server, so there is nowhere to send the request. This is
the one thing the default configuration leaves for you.

## Point it at something

```yaml
# values-quickstart.yaml
config: |
  global
      log stdout format raw local0 info
      maxconn 4096

  defaults
      log     global
      mode    http
      option  httplog
      option  dontlognull
      retries 3
      timeout connect 5s
      timeout client  50s
      timeout server  50s

  frontend health
      bind *:8404
      mode http
      http-request set-log-level silent
      monitor-uri /healthz
      http-request use-service prometheus-exporter if { path /metrics }
      stats enable
      stats uri /stats

  frontend http_in
      bind *:8080
      mode http
      default_backend app

  backend app
      mode http
      balance roundrobin
      option httpchk GET /
      # A Service name resolves from inside the cluster. Kubernetes balances
      # across its endpoints; HAProxy sees one address.
      server app1 my-app.default.svc.cluster.local:80 check
```

Keep the `health` frontend as it is unless you also change the probes: they call `/healthz` on the
port named `health`, and removing `monitor-uri` makes every pod unready.

> **The backend name has to resolve at startup.** HAProxy exits with
> `could not resolve address 'my-app.default.svc.cluster.local'` if the Service does not exist yet,
> and the `config-check` init container catches it first — so the pod never starts. Add
> `init-addr none` to the `server` line to let it start with that server marked down instead.

```bash
helm upgrade haproxy oci://ghcr.io/willbrid/charts/haproxy \
  --version 0.1.0 --namespace edge --values values-quickstart.yaml
```

The pods roll on their own — the workload carries a `checksum/config` annotation of the rendered
ConfigMap, so a changed configuration is a changed pod template.

## Keeping the configuration in its own file

An HAProxy configuration inside a YAML string loses editor support and makes diffs noisy. Keep it as
`haproxy.cfg` and hand it over at install time:

```bash
helm upgrade --install haproxy oci://ghcr.io/willbrid/charts/haproxy \
  --version 0.1.0 --namespace edge \
  --set-file config=./haproxy.cfg \
  --values values-quickstart.yaml     # everything except the config
```

## Check it

```bash
helm test haproxy --namespace edge
```

The test pod calls the Service from inside the cluster: the name resolves, endpoints are ready,
`/healthz` and `/metrics` answer.

## What to know

- **The `503` is the default backend, not a failure.** Verify with the stats page: `backend app` with
  zero servers.
- **Two replicas by default.** A single proxy pod turns every rollout and every node drain into an
  outage. Add `topologySpreadConstraints` so the two do not land on the same node.
- **Pin the image tag.** `image.tag` defaults to `latest`, which follows the newest stable branch —
  fine to try the chart, not fine for a proxy you depend on. Set `tag: "3.4"`.
- **`kubectl logs` shows the HAProxy log** because the configuration sends it to stdout
  (`log stdout format raw local0 info`). Drop that line and the logs disappear.
