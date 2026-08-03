{{/*
Pod template shared by the Deployment, the StatefulSet and the DaemonSet, so the
three workload kinds can never drift apart on how the container is configured.
Only what genuinely belongs to the workload — replicas, serviceName, update
strategy, volumeClaimTemplates — stays in the workload templates themselves.
Usage: {{ include "fluentbit.podTemplate" . | nindent 4 }}
*/}}
{{- define "fluentbit.podTemplate" -}}
metadata:
  annotations:
    checksum/config: {{ include (print $.Template.BasePath "/configmap-config.yaml") . | sha256sum }}
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
    {{- include "fluentbit.labels" . | nindent 4 }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  serviceAccountName: {{ include "fluentbit.serviceAccountName" . }}
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
      command:
        {{- range .Values.command }}
        - {{ . | quote }}
        {{- end }}
        - "-c"
        - "{{ trimSuffix "/" .Values.configMountPath }}/{{ include "fluentbit.configFileName" . }}"
      ports:
        {{- range .Values.service.ports }}
        - name: {{ .name }}
          containerPort: {{ include "fluentbit.containerPort" . }}
          protocol: {{ .protocol | default "TCP" }}
        {{- end }}
      {{- if or .Values.configmap .Values.secret }}
      envFrom:
        {{- if .Values.configmap }}
        - configMapRef:
            name: {{ include "fluentbit.fullname" . }}
        {{- end }}
        {{- if .Values.secret }}
        - secretRef:
            name: {{ include "fluentbit.fullname" . }}
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
      {{- with .Values.resources }}
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
  volumes:
    - name: config
      configMap:
        name: {{ include "fluentbit.fullname" . }}-config
        items:
          - key: {{ include "fluentbit.configFileName" . }}
            path: {{ include "fluentbit.configFileName" . }}
          {{- if include "fluentbit.parsersContent" . }}
          - key: {{ include "fluentbit.parsersFileName" . }}
            path: {{ include "fluentbit.parsersFileName" . }}
          {{- end }}
    {{- with .Values.volumes }}
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
{{- end }}
