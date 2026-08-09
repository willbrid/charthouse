{{/*
Pod template shared by the Deployment, the StatefulSet and the DaemonSet, so the
three workload kinds can never drift apart on how the container is configured.
Only what genuinely belongs to the workload — replicas, serviceName, update
strategy, volumeClaimTemplates — stays in the workload templates themselves.
Usage: {{ include "haproxy.podTemplate" . | nindent 4 }}
*/}}
{{- define "haproxy.podTemplate" -}}
{{- $host := .Values.hostNetwork | default dict -}}
{{- $check := .Values.configCheck | default dict -}}
{{- $claims := include "haproxy.volumeClaims" . | fromYamlArray -}}
{{- $hasConfig := include "haproxy.hasConfig" . -}}
metadata:
  {{- /*
  Checksums of the objects the pods read at startup, so that changing one of them
  rolls the pods instead of leaving them running on the previous content. The
  configuration is the one that matters here: HAProxy parses it once, at startup.
  An `existingConfigMap` is not checksummed — the chart does not render it and
  cannot see its content — so a change to it needs a restart of your own.
  */}}
  annotations:
    {{- if and $hasConfig (not .Values.existingConfigMap) }}
    checksum/config: {{ include (print $.Template.BasePath "/configmap-config.yaml") . | sha256sum }}
    {{- end }}
    {{- if .Values.configmap }}
    checksum/configmap: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    {{- end }}
    {{- if .Values.secret }}
    checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
    {{- end }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  labels:
    {{- include "haproxy.labels" . | nindent 4 }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  serviceAccountName: {{ include "haproxy.serviceAccountName" . }}
  {{- /*
  Host namespaces. hostNetwork opens the HAProxy ports on the node itself, which is
  how an edge proxy takes traffic without going through a Service, and forces the
  DNS policy to ClusterFirstWithHostNet, without which backends addressed by their
  service name stop resolving.
  */}}
  {{- if $host.enabled }}
  hostNetwork: true
  {{- end }}
  {{- if $host.hostPID }}
  hostPID: true
  {{- end }}
  {{- if $host.hostIPC }}
  hostIPC: true
  {{- end }}
  dnsPolicy: {{ include "haproxy.dnsPolicy" . }}
  {{- with .Values.priorityClassName }}
  priorityClassName: {{ . | quote }}
  {{- end }}
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds | default 30 }}
  {{- with .Values.podSecurityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if and $check.enabled $hasConfig }}
  {{- /*
  `haproxy -c` parses the configuration and exits: 0 when it is valid, 1 with the
  offending line otherwise. Running it before HAProxy itself turns a typo into a pod
  stuck in Init with the parser error in its logs, instead of a container that
  crash-loops — and, on an upgrade, into a new pod that never becomes ready while the
  old ones keep serving traffic.
  It needs the same configuration, the same environment (the ${VAR} the configuration
  expands) and the same volumes as the container it guards, or it would check
  something else than what runs.
  */}}
  initContainers:
    - name: config-check
      image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- with .Values.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      command:
        {{- range $check.command }}
        - {{ . | quote }}
        {{- end }}
      {{- with (include "haproxy.containerEnv" .) }}
      {{- . | nindent 6 }}
      {{- end }}
      {{- with $check.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumeMounts:
        - name: config
          mountPath: {{ trimSuffix "/" .Values.configMountPath }}
          readOnly: true
        {{- with .Values.volumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
  {{- end }}
  containers:
    - name: {{ .Chart.Name }}
      {{- with .Values.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- /*
      Passed verbatim. A Kubernetes `command` replaces the image ENTRYPOINT, so the
      `-W -db` the official entrypoint script would have added have to be part of it.
      */}}
      {{- with .Values.command }}
      command:
        {{- range . }}
        - {{ . | quote }}
        {{- end }}
      {{- end }}
      {{- with .Values.args }}
      args:
        {{- range . }}
        - {{ . | quote }}
        {{- end }}
      {{- end }}
      {{- with .Values.service.ports }}
      ports:
        {{- range . }}
        - name: {{ .name }}
          containerPort: {{ include "haproxy.containerPort" . }}
          protocol: {{ .protocol | default "TCP" }}
          {{- if $host.enabled }}
          {{- /* On the host network, a container port is the node port itself. */}}
          hostPort: {{ include "haproxy.containerPort" . }}
          {{- end }}
        {{- end }}
      {{- end }}
      {{- with (include "haproxy.containerEnv" .) }}
      {{- . | nindent 6 }}
      {{- end }}
      {{- with .Values.livenessProbe }}
      livenessProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.readinessProbe }}
      readinessProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.startupProbe }}
      startupProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.lifecycle }}
      lifecycle:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- /*
      Mounts come from three places: the configuration, mounted read-only by the
      chart; the volumeClaimTemplates entries carrying a mountPath, mounted for you;
      and the free-form volumeMounts, which also cover the claims left without one.
      */}}
      {{- $mounts := list }}
      {{- if $hasConfig }}
      {{- $mounts = append $mounts (dict "name" "config" "mountPath" (trimSuffix "/" .Values.configMountPath) "readOnly" true) }}
      {{- end }}
      {{- range $claims }}
      {{- if .mountPath }}
      {{- $mount := dict "name" .name "mountPath" .mountPath }}
      {{- with .subPath }}{{ $_ := set $mount "subPath" . }}{{ end }}
      {{- if hasKey . "readOnly" }}{{ $_ := set $mount "readOnly" .readOnly }}{{ end }}
      {{- $mounts = append $mounts $mount }}
      {{- end }}
      {{- end }}
      {{- $mounts = concat $mounts (.Values.volumeMounts | default list) }}
      {{- with $mounts }}
      volumeMounts:
        {{- toYaml . | nindent 8 }}
      {{- end }}
  {{- if or $hasConfig .Values.volumes }}
  volumes:
    {{- if $hasConfig }}
    - name: config
      configMap:
        name: {{ include "haproxy.configMapName" . }}
    {{- end }}
    {{- with .Values.volumes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.topologySpreadConstraints }}
  topologySpreadConstraints:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

{{/*
`env` and `envFrom` of a container, shared by the config-check init container and by
HAProxy itself: the check must see the same ${VAR} the configuration expands, or it
validates something else than what runs.
Emitted at column 0 and indented by the caller.
Usage: {{- include "haproxy.containerEnv" . | nindent 6 }}
*/}}
{{- define "haproxy.containerEnv" -}}
{{- with .Values.env }}
env:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- if or .Values.configmap .Values.secret .Values.envFrom }}
envFrom:
  {{- if .Values.configmap }}
  - configMapRef:
      name: {{ include "haproxy.fullname" . }}
  {{- end }}
  {{- if .Values.secret }}
  - secretRef:
      name: {{ include "haproxy.fullname" . }}
  {{- end }}
  {{- with .Values.envFrom }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}
{{- end }}
