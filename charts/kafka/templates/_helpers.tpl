{{/*
Expand the name of the chart.
*/}}
{{- define "kafka.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "kafka.fullname" -}}
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
Every KRaft address the chart generates — quorum endpoints, advertised listeners —
is built on it, which is why it gets its own helper rather than being inlined.
*/}}
{{- define "kafka.headlessServiceName" -}}
{{- printf "%s-headless" (include "kafka.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "kafka.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kafka.labels" -}}
helm.sh/chart: {{ include "kafka.chart" . }}
{{ include "kafka.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kafka.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kafka.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Labels of the helm test pod. Deliberately not the common labels: those contain the
selector labels, which would make the StatefulSet adopt the test pod as one of its
own. Suffixing the name label breaks the subset match the selector relies on, and
keeps the pod recognisable.
*/}}
{{- define "kafka.testLabels" -}}
helm.sh/chart: {{ include "kafka.chart" . }}
app.kubernetes.io/name: {{ include "kafka.name" . }}-test
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: test
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "kafka.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kafka.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference of the Kafka container, shared by the init container formatting the
storage and by the Kafka container itself: the two must never run different builds,
the format step writes the metadata the broker then reads.
*/}}
{{- define "kafka.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end }}

{{/*
Cluster DNS domain, without leading or trailing dots.
*/}}
{{- define "kafka.clusterDomain" -}}
{{- .Values.clusterDomain | default "cluster.local" | trimAll "." -}}
{{- end }}

{{/*
Fully qualified DNS name of a pod of the set, from its ordinal. This is the address
form KRaft needs everywhere: it is stable across restarts and reschedules, unlike a
pod IP, and it resolves to one specific member, unlike the load-balanced service.
Usage: {{ include "kafka.podFqdn" (dict "ctx" $ "ordinal" 0) }}
*/}}
{{- define "kafka.podFqdn" -}}
{{- $ctx := .ctx -}}
{{- printf "%s-%d.%s.%s.svc.%s" (include "kafka.fullname" $ctx) (int .ordinal) (include "kafka.headlessServiceName" $ctx) $ctx.Release.Namespace (include "kafka.clusterDomain" $ctx) -}}
{{- end }}

{{/*
Directory the Kafka log dirs live in, i.e. where the PVC is mounted. Kafka is told
about it through log.dirs, generated from this same value so the two can never drift.
*/}}
{{- define "kafka.dataDir" -}}
{{- $persistence := .Values.persistence | default dict -}}
{{- $persistence.mountPath | default "/var/lib/kafka/data" | trimSuffix "/" -}}
{{- end }}

{{/*
Directory the user-provided files (JAAS, keystores, credentials, ...) are mounted in.
Defaults to /etc/kafka/secrets, the path the apache/kafka image derives SSL file names
from, so a plain file name in an SSL config keeps resolving.
*/}}
{{- define "kafka.extraFilesMountPath" -}}
{{- $extraFiles := .Values.extraFiles | default dict -}}
{{- $extraFiles.mountPath | default "/etc/kafka/secrets" | trimSuffix "/" -}}
{{- end }}
