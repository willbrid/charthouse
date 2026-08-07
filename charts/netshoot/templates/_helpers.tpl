{{/*
Expand the name of the chart.
*/}}
{{- define "netshoot.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "netshoot.fullname" -}}
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
{{- define "netshoot.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "netshoot.labels" -}}
helm.sh/chart: {{ include "netshoot.chart" . }}
{{ include "netshoot.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "netshoot.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netshoot.name" . }}
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
{{- define "netshoot.testLabels" -}}
helm.sh/chart: {{ include "netshoot.chart" . }}
app.kubernetes.io/name: {{ include "netshoot.name" . }}-test
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
{{- define "netshoot.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "netshoot.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the headless service governing the StatefulSet pod DNS names.
Usage: {{ include "netshoot.headlessServiceName" . }}
*/}}
{{- define "netshoot.headlessServiceName" -}}
{{- printf "%s-headless" (include "netshoot.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
volumeClaimTemplates entries actually requested: the list minus the entries whose
`enabled` is explicitly false. Returned as YAML, so callers get a list back through
`fromYamlArray` and every template agrees on which claims exist.
Usage: {{- $claims := include "netshoot.volumeClaims" . | fromYamlArray }}
*/}}
{{- define "netshoot.volumeClaims" -}}
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
Usage: {{- include "netshoot.validateWorkload" . -}}
*/}}
{{- define "netshoot.validateWorkload" -}}
{{- $kind := .Values.kind | default "Deployment" -}}
{{- if not (has $kind (list "Deployment" "StatefulSet" "DaemonSet")) -}}
{{- fail (printf "netshoot: kind must be one of Deployment, StatefulSet or DaemonSet, got %q" $kind) -}}
{{- end -}}
{{- $declared := .Values.volumeClaimTemplates | default list -}}
{{- if and $declared (ne $kind "StatefulSet") -}}
{{- fail (printf "netshoot: volumeClaimTemplates are only supported with kind: StatefulSet, got %q. Use volumes/volumeMounts instead." $kind) -}}
{{- end -}}
{{- $names := list -}}
{{- range $declared -}}
{{- if not .name -}}
{{- fail "netshoot: every volumeClaimTemplates entry requires a name" -}}
{{- end -}}
{{- if not .size -}}
{{- fail (printf "netshoot: volumeClaimTemplates entry %q requires a size" .name) -}}
{{- end -}}
{{- if has .name $names -}}
{{- fail (printf "netshoot: duplicated volumeClaimTemplates name %q" .name) -}}
{{- end -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- range .Values.volumes | default list -}}
{{- if has .name $names -}}
{{- fail (printf "netshoot: volume %q collides with a volumeClaimTemplates entry of the same name" .name) -}}
{{- end -}}
{{- end -}}
{{- if not (kindIs "slice" (.Values.command | default list)) -}}
{{- fail "netshoot: command must be a list, e.g. [\"sh\", \"-c\", \"while true; do sleep 5; done\"]" -}}
{{- end -}}
{{- end }}

{{/*
Workload kind running netshoot, validated.
Usage: {{ include "netshoot.kind" . }}
*/}}
{{- define "netshoot.kind" -}}
{{- include "netshoot.validateWorkload" . -}}
{{- .Values.kind | default "Deployment" -}}
{{- end }}

{{/*
Validate the .Values.service.ports entries. The list may be empty — netshoot exposes
nothing by default — but a service asked to be created without a port is a mistake.
Usage: {{- include "netshoot.validateServicePorts" . -}}
*/}}
{{- define "netshoot.validateServicePorts" -}}
{{- $service := .Values.service | default dict -}}
{{- $ports := $service.ports | default list -}}
{{- if and $service.enabled (not $ports) -}}
{{- fail "netshoot: service.enabled requires at least one entry in service.ports" -}}
{{- end -}}
{{- $names := list -}}
{{- range $ports -}}
{{- if not .name -}}
{{- fail "netshoot: every service.ports entry requires a name" -}}
{{- end -}}
{{- if not .port -}}
{{- fail (printf "netshoot: service port %q requires a port" .name) -}}
{{- end -}}
{{- if gt (len .name) 15 -}}
{{- fail (printf "netshoot: service port name %q exceeds 15 characters" .name) -}}
{{- end -}}
{{- if has .name $names -}}
{{- fail (printf "netshoot: duplicated service port name %q" .name) -}}
{{- end -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- end }}

{{/*
Container port matching a service.ports entry: targetPort when it holds a number,
the service port itself otherwise (named targetPort).
Usage: {{ include "netshoot.containerPort" $entry }}
*/}}
{{- define "netshoot.containerPort" -}}
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
Usage: {{ include "netshoot.servicePortNumber" (dict "ctx" $ "port" "iperf") }}
*/}}
{{- define "netshoot.servicePortNumber" -}}
{{- include "netshoot.validateServicePorts" .ctx -}}
{{- $ports := .ctx.Values.service.ports | default list -}}
{{- if not $ports -}}
{{- fail "netshoot: no service.ports entry to resolve a port number from" -}}
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
{{- fail (printf "netshoot: no service.ports entry matching %q" $wanted) -}}
{{- else -}}
{{- $selected -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
DNS policy of the pod. A hostNetwork pod keeping the default ClusterFirst falls back
to the resolver of its node and stops resolving *.svc.cluster.local, which is the
first thing a network toolbox is asked to do — hence the ClusterFirstWithHostNet
default. An explicit hostNetwork.dnsPolicy always wins.
Usage: {{ include "netshoot.dnsPolicy" . }}
*/}}
{{- define "netshoot.dnsPolicy" -}}
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
Usage: {{- include "netshoot.validateNetworkPolicy" . -}}
*/}}
{{- define "netshoot.validateNetworkPolicy" -}}
{{- $policy := .Values.networkPolicy | default dict -}}
{{- $host := .Values.hostNetwork | default dict -}}
{{- if and $policy.enabled $host.enabled (not $policy.allowHostNetwork) -}}
{{- fail "netshoot: networkPolicy.enabled has no effect with hostNetwork.enabled — a NetworkPolicy is enforced on the pod network and never selects a hostNetwork pod. Disable one of the two, or set networkPolicy.allowHostNetwork: true to create the policy anyway." -}}
{{- end -}}
{{- range $policy.policyTypes | default list -}}
{{- if not (has . (list "Ingress" "Egress")) -}}
{{- fail (printf "netshoot: networkPolicy.policyTypes entries must be Ingress or Egress, got %q" .) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Directions the NetworkPolicy governs. Both by default: a direction left out of
policyTypes is a direction the policy does not restrict at all, so deriving the list
from the rules that happen to be set would quietly leave the pods reachable by
anything as soon as no ingress rule was written. Both directions closed, plus the
rules explicitly allowed, is the reading that matches "enabled".
An explicit networkPolicy.policyTypes wins, for the case where only one direction
should be governed.
Usage: {{ include "netshoot.networkPolicyTypes" . | fromYamlArray }}
*/}}
{{- define "netshoot.networkPolicyTypes" -}}
{{- $policy := .Values.networkPolicy | default dict -}}
{{- if $policy.policyTypes -}}
{{- toYaml $policy.policyTypes -}}
{{- else -}}
{{- toYaml (list "Ingress" "Egress") -}}
{{- end -}}
{{- end }}
