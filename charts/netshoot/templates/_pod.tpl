{{/*
Pod template shared by the Deployment, the StatefulSet and the DaemonSet, so the
three workload kinds can never drift apart on how the container is configured.
Only what genuinely belongs to the workload — replicas, serviceName, update
strategy, volumeClaimTemplates — stays in the workload templates themselves.
Usage: {{ include "netshoot.podTemplate" . | nindent 4 }}
*/}}
{{- define "netshoot.podTemplate" -}}
{{- $host := .Values.hostNetwork | default dict -}}
{{- $claims := include "netshoot.volumeClaims" . | fromYamlArray -}}
metadata:
  {{- if or .Values.configmap .Values.secret .Values.podAnnotations }}
  {{- /*
  Checksums of the ConfigMap and the Secret holding the environment variables, so
  that changing one of them rolls the pods instead of leaving them with the values
  they were started with.
  */}}
  annotations:
    {{- if .Values.configmap }}
    checksum/configmap: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    {{- end }}
    {{- if .Values.secret }}
    checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
    {{- end }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
  labels:
    {{- include "netshoot.labels" . | nindent 4 }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  serviceAccountName: {{ include "netshoot.serviceAccountName" . }}
  {{- /*
  Host namespaces. hostNetwork gives the pod the network of its node — node
  interfaces, node traffic, node ports — and forces the DNS policy to
  ClusterFirstWithHostNet, without which cluster names stop resolving.
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
  dnsPolicy: {{ include "netshoot.dnsPolicy" . }}
  {{- with .Values.priorityClassName }}
  priorityClassName: {{ . | quote }}
  {{- end }}
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds | default 5 }}
  {{- with .Values.podSecurityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
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
      The netshoot entrypoint is a shell: a container started without a command
      exits as soon as it is created. The default command is the sleep loop that
      keeps the toolbox alive and available for `kubectl exec`.
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
          containerPort: {{ include "netshoot.containerPort" . }}
          protocol: {{ .protocol | default "TCP" }}
          {{- if $host.enabled }}
          {{- /* On the host network, containerPort is the node port itself. */}}
          hostPort: {{ include "netshoot.containerPort" . }}
          {{- end }}
        {{- end }}
      {{- end }}
      {{- with .Values.env }}
      env:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if or .Values.configmap .Values.secret .Values.envFrom }}
      envFrom:
        {{- if .Values.configmap }}
        - configMapRef:
            name: {{ include "netshoot.fullname" . }}
        {{- end }}
        {{- if .Values.secret }}
        - secretRef:
            name: {{ include "netshoot.fullname" . }}
        {{- end }}
        {{- with .Values.envFrom }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
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
      {{- with .Values.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- /*
      Mounts come from two places: the volumeClaimTemplates entries carrying a
      mountPath, mounted for you, and the free-form volumeMounts, which also cover
      the claims left without one.
      */}}
      {{- $mounts := list }}
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
  {{- with .Values.volumes }}
  volumes:
    {{- toYaml . | nindent 4 }}
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
