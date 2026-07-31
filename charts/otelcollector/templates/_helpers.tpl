{{/*
Expand the name of the chart.
*/}}
{{- define "otelcollector.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "otelcollector.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "otelcollector.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "otelcollector.labels" -}}
helm.sh/chart: {{ include "otelcollector.chart" . }}
{{ include "otelcollector.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "otelcollector.selectorLabels" -}}
app.kubernetes.io/name: {{ include "otelcollector.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Validate the .Values.service.ports entries.
Usage: {{- include "otelcollector.validateServicePorts" . -}}
*/}}
{{- define "otelcollector.validateServicePorts" -}}
{{- $ports := .Values.service.ports | default list -}}
{{- if not $ports -}}
{{- fail "otelcollector: service.ports must contain at least one entry" -}}
{{- end -}}
{{- $names := list -}}
{{- range $ports -}}
{{- if not .name -}}
{{- fail "otelcollector: every service.ports entry requires a name" -}}
{{- end -}}
{{- if not .port -}}
{{- fail (printf "otelcollector: service port %q requires a port" .name) -}}
{{- end -}}
{{- if gt (len .name) 15 -}}
{{- fail (printf "otelcollector: service port name %q exceeds 15 characters" .name) -}}
{{- end -}}
{{- if has .name $names -}}
{{- fail (printf "otelcollector: duplicated service port name %q" .name) -}}
{{- end -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- end }}

{{/*
Container port matching a service.ports entry: targetPort when it holds a number,
the service port itself otherwise (named targetPort).
Usage: {{ include "otelcollector.containerPort" $entry }}
*/}}
{{- define "otelcollector.containerPort" -}}
{{- $target := .targetPort | default .port -}}
{{- if and (kindIs "string" $target) (not (regexMatch "^[0-9]+$" $target)) -}}
{{- .port -}}
{{- else -}}
{{- $target -}}
{{- end -}}
{{- end }}

{{/*
Service port number resolved from a service.ports entry designated either by its name
or by its number. An empty selector falls back to the first service.ports entry.
An unknown selector is fatal, unless "optional" is true (fallback to the first entry).
Usage: {{ include "otelcollector.servicePortNumber" (dict "ctx" $ "port" "otlp-http") }}
       {{ include "otelcollector.servicePortNumber" (dict "ctx" $ "port" 4318) }}
       {{ include "otelcollector.servicePortNumber" (dict "ctx" $ "port" "health" "optional" true) }}
*/}}
{{- define "otelcollector.servicePortNumber" -}}
{{- include "otelcollector.validateServicePorts" .ctx -}}
{{- $ports := .ctx.Values.service.ports -}}
{{- $wanted := "" -}}
{{- with .port -}}
{{- $wanted = . | toString -}}
{{- end -}}
{{- if not $wanted -}}
{{- (first $ports).port -}}
{{- else -}}
{{- $selected := "" -}}
{{- range $ports -}}
{{- if or (eq (.name | toString) $wanted) (eq (.port | toString) $wanted) -}}
{{- $selected = .port -}}
{{- end -}}
{{- end -}}
{{- if eq ($selected | toString) "" -}}
{{- if .optional -}}
{{- (first $ports).port -}}
{{- else -}}
{{- fail (printf "otelcollector: no service.ports entry matching %q" $wanted) -}}
{{- end -}}
{{- else -}}
{{- $selected -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "otelcollector.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "otelcollector.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
