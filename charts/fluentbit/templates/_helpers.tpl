{{/*
Expand the name of the chart.
*/}}
{{- define "fluentbit.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "fluentbit.fullname" -}}
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
{{- define "fluentbit.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fluentbit.labels" -}}
helm.sh/chart: {{ include "fluentbit.chart" . }}
{{ include "fluentbit.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fluentbit.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fluentbit.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Labels of the helm test pod. Deliberately not the common labels: those contain the
selector labels, which would make the workload controller adopt the test pod as one
of its own. A DaemonSet acts on it immediately and deletes the pod as a surplus
replica on the node, failing the test before wget ever runs. Suffixing the name
label breaks the subset match the selector relies on, and keeps the pod recognisable.
*/}}
{{- define "fluentbit.testLabels" -}}
helm.sh/chart: {{ include "fluentbit.chart" . }}
app.kubernetes.io/name: {{ include "fluentbit.name" . }}-test
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: test
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Validate the workload configuration: the kind itself, and the values that only
make sense for some of the kinds.
Usage: {{- include "fluentbit.validateWorkload" . -}}
*/}}
{{- define "fluentbit.validateWorkload" -}}
{{- $kind := .Values.kind | default "Deployment" -}}
{{- if not (has $kind (list "Deployment" "StatefulSet" "DaemonSet")) -}}
{{- fail (printf "fluentbit: kind must be one of Deployment, StatefulSet or DaemonSet, got %q" $kind) -}}
{{- end -}}
{{- $claims := .Values.volumeClaimTemplates | default list -}}
{{- if and $claims (ne $kind "StatefulSet") -}}
{{- fail (printf "fluentbit: volumeClaimTemplates are only supported with kind: StatefulSet, got %q. Use volumes/volumeMounts instead." $kind) -}}
{{- end -}}
{{- if and .Values.autoscaling.enabled (eq $kind "DaemonSet") -}}
{{- fail "fluentbit: autoscaling.enabled is not compatible with kind: DaemonSet, which already runs one pod per node" -}}
{{- end -}}
{{- $names := list -}}
{{- range $claims -}}
{{- if not .name -}}
{{- fail "fluentbit: every volumeClaimTemplates entry requires a name" -}}
{{- end -}}
{{- if eq .name "config" -}}
{{- fail "fluentbit: volumeClaimTemplates name \"config\" is reserved by the configuration volume" -}}
{{- end -}}
{{- if not .size -}}
{{- fail (printf "fluentbit: volumeClaimTemplates entry %q requires a size" .name) -}}
{{- end -}}
{{- if has .name $names -}}
{{- fail (printf "fluentbit: duplicated volumeClaimTemplates name %q" .name) -}}
{{- end -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- end }}

{{/*
Workload kind running Fluent Bit, validated.
Usage: {{ include "fluentbit.kind" . }}
*/}}
{{- define "fluentbit.kind" -}}
{{- include "fluentbit.validateWorkload" . -}}
{{- .Values.kind | default "Deployment" -}}
{{- end }}

{{/*
Validate the .Values.service.ports entries.
Usage: {{- include "fluentbit.validateServicePorts" . -}}
*/}}
{{- define "fluentbit.validateServicePorts" -}}
{{- $ports := .Values.service.ports | default list -}}
{{- if not $ports -}}
{{- fail "fluentbit: service.ports must contain at least one entry" -}}
{{- end -}}
{{- $names := list -}}
{{- range $ports -}}
{{- if not .name -}}
{{- fail "fluentbit: every service.ports entry requires a name" -}}
{{- end -}}
{{- if not .port -}}
{{- fail (printf "fluentbit: service port %q requires a port" .name) -}}
{{- end -}}
{{- if gt (len .name) 15 -}}
{{- fail (printf "fluentbit: service port name %q exceeds 15 characters" .name) -}}
{{- end -}}
{{- if has .name $names -}}
{{- fail (printf "fluentbit: duplicated service port name %q" .name) -}}
{{- end -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- end }}

{{/*
Container port matching a service.ports entry: targetPort when it holds a number,
the service port itself otherwise (named targetPort).
Usage: {{ include "fluentbit.containerPort" $entry }}
*/}}
{{- define "fluentbit.containerPort" -}}
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
Usage: {{ include "fluentbit.servicePortNumber" (dict "ctx" $ "port" "health") }}
       {{ include "fluentbit.servicePortNumber" (dict "ctx" $ "port" 2020) }}
       {{ include "fluentbit.servicePortNumber" (dict "ctx" $ "port" "health" "optional" true) }}
*/}}
{{- define "fluentbit.servicePortNumber" -}}
{{- include "fluentbit.validateServicePorts" .ctx -}}
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
{{- fail (printf "fluentbit: no service.ports entry matching %q" $wanted) -}}
{{- end -}}
{{- else -}}
{{- $selected -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Name of the Fluent Bit configuration file. It also selects the parsing mode of Fluent Bit:
fluent-bit.conf is read in classic mode, fluent-bit.yaml in YAML mode.
Usage: {{ include "fluentbit.configFileName" . }}
*/}}
{{- define "fluentbit.configFileName" -}}
{{- $name := .Values.configFileName | default "fluent-bit.conf" -}}
{{- if not (has $name (list "fluent-bit.conf" "fluent-bit.yaml")) -}}
{{- fail (printf "fluentbit: configFileName must be \"fluent-bit.conf\" or \"fluent-bit.yaml\", got %q" $name) -}}
{{- end -}}
{{- $name -}}
{{- end }}

{{/*
Content of the Fluent Bit configuration file, taken from .Values.config: either a literal
string (inline block or --set-file config=<file>), or a YAML mapping, which only makes
sense when the file is read in YAML mode.
Usage: {{ include "fluentbit.configContent" . }}
*/}}
{{- define "fluentbit.configContent" -}}
{{- $config := "" -}}
{{- if kindIs "string" .Values.config -}}
{{- $config = .Values.config -}}
{{- else if eq (include "fluentbit.configFileName" .) "fluent-bit.yaml" -}}
{{- $config = toYaml .Values.config -}}
{{- else -}}
{{- fail "fluentbit: config must be a string in classic mode; a YAML mapping is only accepted with configFileName: fluent-bit.yaml" -}}
{{- end -}}
{{- if not (trim $config) -}}
{{- fail "fluentbit: config must hold the Fluent Bit configuration, either inline or through --set-file config=<file>" -}}
{{- end -}}
{{- $config -}}
{{- end }}

{{/*
Name of the custom parsers file, mounted next to the configuration file.
Usage: {{ include "fluentbit.parsersFileName" . }}
*/}}
{{- define "fluentbit.parsersFileName" -}}
{{- $parsers := .Values.parsers | default dict -}}
{{- $name := $parsers.fileName | default "custom_parsers.conf" -}}
{{- if eq $name (include "fluentbit.configFileName" .) -}}
{{- fail (printf "fluentbit: parsers.fileName %q collides with the configuration file name" $name) -}}
{{- end -}}
{{- $name -}}
{{- end }}

{{/*
Content of the custom parsers file, or an empty string when the user defines none.
Emptiness is the switch of the whole feature: no key in the ConfigMap, no item in the
volume, nothing mounted into the container.
Usage: {{ include "fluentbit.parsersContent" . }}
*/}}
{{- define "fluentbit.parsersContent" -}}
{{- $parsers := .Values.parsers | default dict -}}
{{- $content := "" -}}
{{- if kindIs "string" $parsers.content -}}
{{- $content = $parsers.content -}}
{{- else if $parsers.content -}}
{{- $content = toYaml $parsers.content -}}
{{- end -}}
{{- if trim $content -}}
{{- $content -}}
{{- end -}}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "fluentbit.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fluentbit.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
