{{/*
Expand the name of the chart.
*/}}
{{- define "haproxy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "haproxy.fullname" -}}
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
{{- define "haproxy.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "haproxy.labels" -}}
helm.sh/chart: {{ include "haproxy.chart" . }}
{{ include "haproxy.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "haproxy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "haproxy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Labels of the helm test pod. Deliberately not the common labels: those contain the
selector labels, which would make the workload controller adopt the test pod as one
of its own. A DaemonSet acts on it immediately and deletes the pod as a surplus
replica on the node, failing the test before the command ever runs. Suffixing the
name label breaks the subset match the selector relies on, and keeps the pod
recognisable.
*/}}
{{- define "haproxy.testLabels" -}}
helm.sh/chart: {{ include "haproxy.chart" . }}
app.kubernetes.io/name: {{ include "haproxy.name" . }}-test
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
{{- define "haproxy.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "haproxy.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the headless service governing the StatefulSet pod DNS names.
Usage: {{ include "haproxy.headlessServiceName" . }}
*/}}
{{- define "haproxy.headlessServiceName" -}}
{{- printf "%s-headless" (include "haproxy.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Name of the ConfigMap holding the configuration: the one the chart renders, or the
one the user points at with `existingConfigMap`.
Usage: {{ include "haproxy.configMapName" . }}
*/}}
{{- define "haproxy.configMapName" -}}
{{- if .Values.existingConfigMap -}}
{{- .Values.existingConfigMap -}}
{{- else -}}
{{- printf "%s-config" (include "haproxy.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Absolute path of the configuration file inside the container, built from
configMountPath and configFileName. This is the path the `-f` flag of `command` and
of `configCheck.command` must point at, and the one the chart validates them against.
Usage: {{ include "haproxy.configFilePath" . }}
*/}}
{{- define "haproxy.configFilePath" -}}
{{- printf "%s/%s" (trimSuffix "/" .Values.configMountPath) .Values.configFileName -}}
{{- end }}

{{/*
Whether a configuration volume is mounted at all: either the chart renders one from
`config`, or the user brings an `existingConfigMap`. Both empty means the
configuration is supplied some other way — a volume of their own — and the chart
stops checking the command line.
Returns a non-empty string when there is one, the empty string otherwise.
Usage: {{ if include "haproxy.hasConfig" . }}
*/}}
{{- define "haproxy.hasConfig" -}}
{{- if or .Values.existingConfigMap .Values.config -}}
true
{{- end -}}
{{- end }}

{{/*
Validate the configuration values, and the command line that has to agree with them.
The command is passed to the container verbatim, so a configMountPath changed without
the matching `-f` produces a pod that crash-loops on "cannot open configuration file"
— reported here instead.
Usage: {{- include "haproxy.validateConfig" . -}}
*/}}
{{- define "haproxy.validateConfig" -}}
{{- if and .Values.config .Values.existingConfigMap -}}
{{- fail "haproxy: config and existingConfigMap are mutually exclusive — the chart cannot mount both at configMountPath. Clear `config` to use the ConfigMap you manage yourself." -}}
{{- end -}}
{{- if not .Values.configFileName -}}
{{- fail "haproxy: configFileName must not be empty" -}}
{{- end -}}
{{- if contains "/" .Values.configFileName -}}
{{- fail (printf "haproxy: configFileName must be a file name, not a path, got %q. Use configMountPath for the directory." .Values.configFileName) -}}
{{- end -}}
{{- range $name, $content := .Values.extraFiles | default dict -}}
{{- if eq $name $.Values.configFileName -}}
{{- fail (printf "haproxy: extraFiles entry %q collides with configFileName" $name) -}}
{{- end -}}
{{- if contains "/" $name -}}
{{- fail (printf "haproxy: extraFiles keys must be file names, not paths, got %q — a ConfigMap key cannot contain a slash" $name) -}}
{{- end -}}
{{- end -}}
{{- range .Values.volumes | default list -}}
{{- if eq .name "config" -}}
{{- fail "haproxy: the volume name \"config\" is reserved for the configuration mounted by the chart" -}}
{{- end -}}
{{- end -}}
{{- include "haproxy.validateCommand" (dict "ctx" . "command" (concat (.Values.command | default list) (.Values.args | default list)) "field" "command") -}}
{{- $check := .Values.configCheck | default dict -}}
{{- if $check.enabled -}}
{{- include "haproxy.validateCommand" (dict "ctx" . "command" ($check.command | default list) "field" "configCheck.command") -}}
{{- end -}}
{{- end }}

{{/*
Check one command line: it must be a non-empty list, and — when the chart mounts a
configuration — it must load it with `-f <configFilePath>`. HAProxy accepts several
-f flags, so any of them matching is enough.
Usage: {{- include "haproxy.validateCommand" (dict "ctx" . "command" $list "field" "command") -}}
*/}}
{{- define "haproxy.validateCommand" -}}
{{- $ctx := .ctx -}}
{{- $field := .field -}}
{{- if not (kindIs "slice" .command) -}}
{{- fail (printf "haproxy: %s must be a list, e.g. [\"haproxy\", \"-W\", \"-db\", \"-f\", \"%s\"]" $field (include "haproxy.configFilePath" $ctx)) -}}
{{- end -}}
{{- if not .command -}}
{{- fail (printf "haproxy: %s must not be empty" $field) -}}
{{- end -}}
{{- if include "haproxy.hasConfig" $ctx -}}
{{- $path := include "haproxy.configFilePath" $ctx -}}
{{- $found := false -}}
{{- $previous := "" -}}
{{- range .command -}}
{{- if and (eq $previous "-f") (eq (toString .) $path) -}}
{{- $found = true -}}
{{- end -}}
{{- $previous = toString . -}}
{{- end -}}
{{- if not $found -}}
{{- fail (printf "haproxy: %s does not load the configuration the chart mounts — expected the flags `-f %s` (configMountPath + configFileName), got %v. Adjust the command, or configMountPath/configFileName." $field $path .command) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
volumeClaimTemplates entries actually requested: the list minus the entries whose
`enabled` is explicitly false. Returned as YAML, so callers get a list back through
`fromYamlArray` and every template agrees on which claims exist.
Usage: {{- $claims := include "haproxy.volumeClaims" . | fromYamlArray }}
*/}}
{{- define "haproxy.volumeClaims" -}}
{{- $enabled := list -}}
{{- range .Values.volumeClaimTemplates | default list -}}
{{- if not (hasKey . "enabled") -}}
{{- $enabled = append $enabled . -}}
{{- else if .enabled -}}
{{- $enabled = append $enabled . -}}
{{- end -}}
{{- end -}}
{{- toYaml $enabled -}}
{{- end }}

{{/*
Validate the workload configuration: the kind itself, and the values that only make
sense for some of the kinds. Every incoherence is reported at render time — a chart
that silently drops storage or a policy is worse than one that refuses to install.
Usage: {{- include "haproxy.validateWorkload" . -}}
*/}}
{{- define "haproxy.validateWorkload" -}}
{{- $kind := .Values.kind | default "Deployment" -}}
{{- if not (has $kind (list "Deployment" "StatefulSet" "DaemonSet")) -}}
{{- fail (printf "haproxy: kind must be one of Deployment, StatefulSet or DaemonSet, got %q" $kind) -}}
{{- end -}}
{{- $declared := .Values.volumeClaimTemplates | default list -}}
{{- if and $declared (ne $kind "StatefulSet") -}}
{{- fail (printf "haproxy: volumeClaimTemplates are only supported with kind: StatefulSet, got %q. Use volumes/volumeMounts instead." $kind) -}}
{{- end -}}
{{- $names := list -}}
{{- range $declared -}}
{{- if not .name -}}
{{- fail "haproxy: every volumeClaimTemplates entry requires a name" -}}
{{- end -}}
{{- if not .size -}}
{{- fail (printf "haproxy: volumeClaimTemplates entry %q requires a size" .name) -}}
{{- end -}}
{{- if has .name $names -}}
{{- fail (printf "haproxy: duplicated volumeClaimTemplates name %q" .name) -}}
{{- end -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- range .Values.volumes | default list -}}
{{- if has .name $names -}}
{{- fail (printf "haproxy: volume %q collides with a volumeClaimTemplates entry of the same name" .name) -}}
{{- end -}}
{{- end -}}
{{- if and (.Values.autoscaling).enabled (eq $kind "DaemonSet") -}}
{{- fail "haproxy: autoscaling.enabled has no meaning with kind: DaemonSet — its pod count already follows the number of nodes." -}}
{{- end -}}
{{- include "haproxy.validateConfig" . -}}
{{- end }}

{{/*
Workload kind running HAProxy, validated.
Usage: {{ include "haproxy.kind" . }}
*/}}
{{- define "haproxy.kind" -}}
{{- include "haproxy.validateWorkload" . -}}
{{- .Values.kind | default "Deployment" -}}
{{- end }}

{{/*
Validate the .Values.service.ports entries. Container ports are declared from this
list whatever `service.enabled` says, so it may not be empty: HAProxy binds ports and
a pod that declares none is a pod nothing documents.
Usage: {{- include "haproxy.validateServicePorts" . -}}
*/}}
{{- define "haproxy.validateServicePorts" -}}
{{- $service := .Values.service | default dict -}}
{{- $ports := $service.ports | default list -}}
{{- if and $service.enabled (not $ports) -}}
{{- fail "haproxy: service.enabled requires at least one entry in service.ports" -}}
{{- end -}}
{{- $names := list -}}
{{- range $ports -}}
{{- if not .name -}}
{{- fail "haproxy: every service.ports entry requires a name" -}}
{{- end -}}
{{- if not .port -}}
{{- fail (printf "haproxy: service port %q requires a port" .name) -}}
{{- end -}}
{{- if gt (len .name) 15 -}}
{{- fail (printf "haproxy: service port name %q exceeds 15 characters" .name) -}}
{{- end -}}
{{- if has .name $names -}}
{{- fail (printf "haproxy: duplicated service port name %q" .name) -}}
{{- end -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- end }}

{{/*
Container port matching a service.ports entry: targetPort when it holds a number,
the service port itself otherwise (named targetPort).
Usage: {{ include "haproxy.containerPort" $entry }}
*/}}
{{- define "haproxy.containerPort" -}}
{{- $target := .targetPort | default .port -}}
{{- if and (kindIs "string" $target) (not (regexMatch "^[0-9]+$" $target)) -}}
{{- .port -}}
{{- else -}}
{{- $target -}}
{{- end -}}
{{- end }}

{{/*
Service port number resolved from a service.ports entry designated either by its name
or by its number. With "optional" set, a selector matching nothing falls back to the
first entry instead of failing — which is how the helm test targets the health port
when it exists and the traffic port otherwise.
Usage: {{ include "haproxy.servicePortNumber" (dict "ctx" $ "port" "health" "optional" true) }}
*/}}
{{- define "haproxy.servicePortNumber" -}}
{{- include "haproxy.validateServicePorts" .ctx -}}
{{- $ports := .ctx.Values.service.ports | default list -}}
{{- if not $ports -}}
{{- fail "haproxy: no service.ports entry to resolve a port number from" -}}
{{- end -}}
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
{{- fail (printf "haproxy: no service.ports entry matching %q" $wanted) -}}
{{- end -}}
{{- else -}}
{{- $selected -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
DNS policy of the pod. A hostNetwork pod keeping the default ClusterFirst falls back
to the resolver of its node and stops resolving *.svc.cluster.local, which breaks
every backend addressed by its service name — hence the ClusterFirstWithHostNet
default. An explicit hostNetwork.dnsPolicy always wins.
Usage: {{ include "haproxy.dnsPolicy" . }}
*/}}
{{- define "haproxy.dnsPolicy" -}}
{{- $host := .Values.hostNetwork | default dict -}}
{{- if $host.dnsPolicy -}}
{{- $host.dnsPolicy -}}
{{- else if $host.enabled -}}
ClusterFirstWithHostNet
{{- else -}}
ClusterFirst
{{- end -}}
{{- end }}

{{/*
Validate the NetworkPolicy configuration. A NetworkPolicy selects pods on the pod
network: a hostNetwork pod is never selected by one, so the combination would create
an object enforcing nothing at all — reported rather than rendered, unless the user
says they know.
Usage: {{- include "haproxy.validateNetworkPolicy" . -}}
*/}}
{{- define "haproxy.validateNetworkPolicy" -}}
{{- $policy := .Values.networkPolicy | default dict -}}
{{- $host := .Values.hostNetwork | default dict -}}
{{- if and $policy.enabled $host.enabled (not $policy.allowHostNetwork) -}}
{{- fail "haproxy: networkPolicy.enabled has no effect with hostNetwork.enabled — a NetworkPolicy is enforced on the pod network and never selects a hostNetwork pod. Disable one of the two, or set networkPolicy.allowHostNetwork: true to create the policy anyway." -}}
{{- end -}}
{{- range $policy.policyTypes | default list -}}
{{- if not (has . (list "Ingress" "Egress")) -}}
{{- fail (printf "haproxy: networkPolicy.policyTypes entries must be Ingress or Egress, got %q" .) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Directions the NetworkPolicy governs. Both by default: a direction left out of
policyTypes is a direction the policy does not restrict at all, so deriving the list
from the rules that happen to be set would quietly leave the proxy reachable by
anything as soon as no ingress rule was written. Both directions closed, plus the
rules explicitly allowed, is the reading that matches "enabled".
An explicit networkPolicy.policyTypes wins, for the case where only one direction
should be governed.
Usage: {{ include "haproxy.networkPolicyTypes" . | fromYamlArray }}
*/}}
{{- define "haproxy.networkPolicyTypes" -}}
{{- $policy := .Values.networkPolicy | default dict -}}
{{- if $policy.policyTypes -}}
{{- toYaml $policy.policyTypes -}}
{{- else -}}
{{- toYaml (list "Ingress" "Egress") -}}
{{- end -}}
{{- end }}
