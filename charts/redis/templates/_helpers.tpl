{{/*
Expand the name of the chart.
*/}}
{{- define "redis.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "redis.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Name of the headless service governing the stable per-pod DNS names of the set.
Not a convenience here but the backbone of the chart: in cluster mode those names
are what the nodes gossip and what clients are redirected to, and in sentinel mode
they are what sentinel monitors and announces. Everything else follows from them.
*/}}
{{- define "redis.headlessServiceName" -}}
{{- printf "%s-headless" (include "redis.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Name of the service fronting the sentinel port. Sentinel-aware clients are given
this one: they need to reach any sentinel, not a particular one, and asking the
quorum who the master is happens to be exactly what a round-robin service is good at.
*/}}
{{- define "redis.sentinelServiceName" -}}
{{- printf "%s-sentinel" (include "redis.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "redis.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redis.labels" -}}
helm.sh/chart: {{ include "redis.chart" . }}
{{ include "redis.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "redis.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Labels of the pods the chart creates outside the set — the cluster bootstrap job,
the backup job, the test pod. Deliberately not the common labels: those carry the
selector labels, and a pod wearing them is adopted by the StatefulSet as one of its
own. Suffixing the name label breaks the subset match the selector relies on and
keeps the pod recognisable.
Usage: {{ include "redis.jobLabels" (dict "ctx" $ "component" "backup") }}
*/}}
{{- define "redis.jobLabels" -}}
{{- $ctx := .ctx -}}
helm.sh/chart: {{ include "redis.chart" $ctx }}
app.kubernetes.io/name: {{ include "redis.name" $ctx }}-{{ .component }}
app.kubernetes.io/instance: {{ $ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- if $ctx.Chart.AppVersion }}
app.kubernetes.io/version: {{ $ctx.Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ $ctx.Release.Service }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "redis.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "redis.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference, shared by the Redis container, the sentinel sidecar, the bootstrap
job and the backup job. They must never run different builds: redis-cli speaks to
the cluster it is bundled with, and an RDB written by one version is not always
readable by another.
*/}}
{{- define "redis.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end }}

{{/*
Cluster DNS domain, without leading or trailing dots.
*/}}
{{- define "redis.clusterDomain" -}}
{{- .Values.clusterDomain | default "cluster.local" | trimAll "." -}}
{{- end }}

{{/*
Fully qualified DNS name of a pod of the set, from its ordinal. Stable across
restarts and reschedules, unlike a pod IP, and resolving to one specific member,
unlike the load-balanced service — which is what both modes need.
Usage: {{ include "redis.podFqdn" (dict "ctx" $ "ordinal" 0) }}
*/}}
{{- define "redis.podFqdn" -}}
{{- $ctx := .ctx -}}
{{- printf "%s-%d.%s.%s.svc.%s" (include "redis.fullname" $ctx) (int .ordinal) (include "redis.headlessServiceName" $ctx) $ctx.Release.Namespace (include "redis.clusterDomain" $ctx) -}}
{{- end }}

{{/*
Mode predicates. Return a non-empty string when true, so that `if` works on them.
*/}}
{{- define "redis.isCluster" -}}
{{- if eq (.Values.mode | default "cluster") "cluster" -}}true{{- end -}}
{{- end }}

{{- define "redis.isSentinel" -}}
{{- if eq (.Values.mode | default "cluster") "sentinel" -}}true{{- end -}}
{{- end }}

{{/*
Directory the data lives in, i.e. where the PersistentVolumeClaim is mounted. Redis
is told about it through `dir`, generated from this same value so the two can never
drift. /data is where the official image already points, and where its entrypoint
fixes ownership.
*/}}
{{- define "redis.dataDir" -}}
{{- $persistence := .Values.persistence | default dict -}}
{{- $persistence.mountPath | default "/data" | trimSuffix "/" -}}
{{- end }}

{{/*
Where the ConfigMap holding the assembled configuration is mounted, read only.
*/}}
{{- define "redis.mountedConfigDir" -}}
/mnt/redis/config
{{- end }}

{{/*
Where the configuration Redis actually reads is written, on an emptyDir.
A ConfigMap mount is read only, and neither process can live with that: sentinel
rewrites its file as it learns the topology, and the server's file has to receive
the handful of directives only knowable at startup — this pod's DNS name, the
current master, the password read from a Secret.
*/}}
{{- define "redis.configDir" -}}
/opt/redis/conf
{{- end }}

{{/*
Where the startup scripts are mounted, read only.
*/}}
{{- define "redis.scriptsDir" -}}
/opt/redis/scripts
{{- end }}

{{/*
Directory the user-provided files (TLS material, ACL file, sentinel hooks, ...) are
mounted in.
*/}}
{{- define "redis.extraFilesMountPath" -}}
{{- $extraFiles := .Values.extraFiles | default dict -}}
{{- $extraFiles.mountPath | default "/etc/redis/files" | trimSuffix "/" -}}
{{- end }}

{{/*
Name of the ConfigMap holding the configuration: the one brought by the user if
config.existingConfigMap is set, the one the chart renders otherwise.
*/}}
{{- define "redis.configMapName" -}}
{{- $config := .Values.config | default dict -}}
{{- if $config.existingConfigMap -}}
{{- tpl $config.existingConfigMap . -}}
{{- else -}}
{{- printf "%s-config" (include "redis.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Name of the Secret holding the password: the one brought by the user if
auth.existingSecret is set, the one the chart creates otherwise.
*/}}
{{- define "redis.secretName" -}}
{{- $auth := .Values.auth | default dict -}}
{{- if $auth.existingSecret -}}
{{- tpl $auth.existingSecret . -}}
{{- else -}}
{{- include "redis.fullname" . -}}
{{- end -}}
{{- end }}

{{- define "redis.secretPasswordKey" -}}
{{- (.Values.auth | default dict).existingSecretPasswordKey | default "redis-password" -}}
{{- end }}

{{/*
Number of masters in cluster mode. Every pod is a node; `cluster.replicas` of them
follow each master, so the set divides into replicaCount / (replicas + 1) shards.
The split is enforced in _validate.tpl — a set that does not divide evenly cannot
be turned into a cluster at all.
*/}}
{{- define "redis.masterCount" -}}
{{- $cluster := .Values.cluster | default dict -}}
{{- div (int .Values.replicaCount) (add1 (int ($cluster.replicas | default 0))) -}}
{{- end }}

{{/*
Number of sentinels that must agree before a failover starts. Explicit if given,
otherwise a strict majority of the pods — the only value that cannot elect two
masters at once on either side of a partition.
*/}}
{{- define "redis.sentinelQuorum" -}}
{{- $sentinel := .Values.sentinel | default dict -}}
{{- if $sentinel.quorum -}}
{{- int $sentinel.quorum -}}
{{- else -}}
{{- add1 (div (int .Values.replicaCount) 2) -}}
{{- end -}}
{{- end }}
