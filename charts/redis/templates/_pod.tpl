{{/*
Environment shared by every container and job of the chart.

The scripts under files/scripts/ hold no template expressions at all: they read
what they need from here. That is what keeps them plain shell — readable as
files, runnable outside Kubernetes, and diffable across chart versions.
*/}}
{{- define "redis.topologyEnv" -}}
{{- $auth := .Values.auth | default dict -}}
- name: POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: FULLNAME
  value: {{ include "redis.fullname" . | quote }}
- name: HEADLESS_SERVICE
  value: {{ include "redis.headlessServiceName" . | quote }}
- name: CLUSTER_DOMAIN
  value: {{ include "redis.clusterDomain" . | quote }}
- name: REDIS_MODE
  value: {{ .Values.mode | default "cluster" | quote }}
- name: REDIS_PORT
  value: {{ .Values.service.port | quote }}
- name: REPLICA_COUNT
  value: {{ .Values.replicaCount | quote }}
- name: DATA_DIR
  value: {{ include "redis.dataDir" . | quote }}
- name: CONFIG_DIR
  value: {{ include "redis.configDir" . | quote }}
- name: MOUNTED_CONFIG_DIR
  value: {{ include "redis.mountedConfigDir" . | quote }}
{{- if include "redis.isSentinel" . }}
- name: SENTINEL_PORT
  value: {{ .Values.sentinel.port | quote }}
- name: SENTINEL_MASTER_SET
  value: {{ .Values.sentinel.masterSet | quote }}
- name: SENTINEL_QUORUM
  value: {{ include "redis.sentinelQuorum" . | quote }}
{{- end }}
{{- if $auth.enabled }}
{{- /* A path, not the password. What is at that path is a file mounted out of a
       Secret, so the value never reaches a ConfigMap, an argument or the
       process table — only the config file the scripts write, on a volume the
       pod alone can read. */}}
- name: REDIS_PASSWORD_FILE
  value: /mnt/redis/secret/{{ include "redis.secretPasswordKey" . }}
{{- end }}
{{- end }}

{{/*
The password redis-cli should use, for the containers that talk to a Redis
server: the probes, the bootstrap job, the backup job. REDISCLI_AUTH is what
redis-cli reads on its own, which keeps the password off its command line and
therefore out of `ps`.

Deliberately NOT set on the sentinel container: sentinel has no password of its
own here, and a client that sends AUTH to a server that never asked for one gets
an error instead of an answer.
*/}}
{{- define "redis.cliAuthEnv" -}}
{{- if (.Values.auth | default dict).enabled }}
- name: REDISCLI_AUTH
  valueFrom:
    secretKeyRef:
      name: {{ include "redis.secretName" . }}
      key: {{ include "redis.secretPasswordKey" . }}
{{- end }}
{{- end }}

{{/*
Volumes shared by the pods of the set and by the jobs that need them.
*/}}
{{- define "redis.commonVolumes" -}}
{{- $fullname := include "redis.fullname" . -}}
{{- $config := .Values.config | default dict -}}
{{- $auth := .Values.auth | default dict -}}
{{- $extraFiles := .Values.extraFiles | default dict -}}
- name: mounted-config
  configMap:
    name: {{ include "redis.configMapName" . }}
- name: scripts
  configMap:
    name: {{ $fullname }}-scripts
    # Executable, which a ConfigMap mount is not by default.
    defaultMode: 0555
{{- if $auth.enabled }}
- name: password
  secret:
    secretName: {{ include "redis.secretName" . }}
    defaultMode: 0400
    items:
      - key: {{ include "redis.secretPasswordKey" . }}
        path: {{ include "redis.secretPasswordKey" . }}
{{- end }}
{{- if or $extraFiles.configMap $extraFiles.secret }}
{{- /* One projected volume rather than two mounts: both sources land in the
       same directory, and two volumes cannot share a mount path. */}}
- name: extra-files
  projected:
    defaultMode: {{ $extraFiles.defaultMode | default 0440 }}
    sources:
      {{- if $extraFiles.configMap }}
      - configMap:
          name: {{ $fullname }}-files
      {{- end }}
      {{- if $extraFiles.secret }}
      - secret:
          name: {{ $fullname }}-files
      {{- end }}
{{- end }}
{{- end }}

{{/*
The matching mounts.
*/}}
{{- define "redis.commonVolumeMounts" -}}
{{- $auth := .Values.auth | default dict -}}
{{- $extraFiles := .Values.extraFiles | default dict -}}
- name: mounted-config
  mountPath: {{ include "redis.mountedConfigDir" . }}
  readOnly: true
- name: scripts
  mountPath: {{ include "redis.scriptsDir" . }}
  readOnly: true
{{- if $auth.enabled }}
- name: password
  mountPath: /mnt/redis/secret
  readOnly: true
{{- end }}
{{- if or $extraFiles.configMap $extraFiles.secret }}
- name: extra-files
  mountPath: {{ include "redis.extraFilesMountPath" . }}
  readOnly: true
{{- end }}
{{- end }}

{{/*
Scheduling. Left to itself the scheduler is free to put every pod of a shard on
one node, which is the one placement that turns a node failure into data loss.
The default below is a preference rather than a requirement, so a cluster with
fewer nodes than pods still schedules — tighten it once you have the nodes.
*/}}
{{- define "redis.affinity" -}}
{{- if .Values.affinity -}}
{{- toYaml .Values.affinity -}}
{{- else -}}
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            {{- include "redis.selectorLabels" . | nindent 12 }}
{{- end -}}
{{- end }}

{{/*
Pod template of the StatefulSet. Kept in its own file so the workload template
holds only what genuinely belongs to the set — replicas, service name, update
strategy, volume claim templates.
Usage: {{ include "redis.podTemplate" . | nindent 4 }}
*/}}
{{- define "redis.podTemplate" -}}
{{- $fullname := include "redis.fullname" . -}}
{{- $persistence := .Values.persistence | default dict -}}
{{- $extraFiles := .Values.extraFiles | default dict -}}
{{- $cluster := include "redis.isCluster" . -}}
{{- $sentinel := include "redis.isSentinel" . -}}
{{- $scripts := include "redis.scriptsDir" . -}}
{{- /* Extra checks each probe runs, on top of answering PING. They are passed as
       arguments rather than read from the environment so that `kubectl describe
       pod` shows exactly what a probe verifies. */ -}}
{{- $liveChecks := list -}}
{{- $readyChecks := list -}}
{{- if $cluster -}}
{{- if (.Values.livenessProbe | default dict).checkClusterState -}}{{- $liveChecks = append $liveChecks "cluster-state" -}}{{- end -}}
{{- if (.Values.readinessProbe | default dict).checkClusterState -}}{{- $readyChecks = append $readyChecks "cluster-state" -}}{{- end -}}
{{- end -}}
{{- if $sentinel -}}
{{- if (.Values.readinessProbe | default dict).requireMasterLink -}}{{- $readyChecks = append $readyChecks "master-link" -}}{{- end -}}
{{- end -}}
metadata:
  annotations:
    {{- /* A change to the configuration or to an injected file has to reach the
           pods. Without these the ConfigMap content changes under a StatefulSet
           that Kubernetes sees as unchanged, and nothing restarts. */}}
    checksum/config: {{ include (print $.Template.BasePath "/configmap-config.yaml") . | sha256sum }}
    checksum/scripts: {{ include (print $.Template.BasePath "/configmap-scripts.yaml") . | sha256sum }}
    {{- if or $extraFiles.configMap $extraFiles.secret }}
    checksum/extra-files: {{ printf "%s%s" (toYaml ($extraFiles.configMap | default dict)) (toYaml ($extraFiles.secret | default dict)) | sha256sum }}
    {{- end }}
    {{- /* The auth values rather than the rendered Secret: a generated password
           is read back from the cluster by `lookup`, which returns nothing
           during a dry run, and hashing that would change the pod spec on every
           `helm template`. */}}
    checksum/auth: {{ toYaml (.Values.auth | default dict) | sha256sum }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  labels:
    {{- include "redis.labels" . | nindent 4 }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  serviceAccountName: {{ include "redis.serviceAccountName" . }}
  automountServiceAccountToken: {{ .Values.serviceAccount.automount | default false }}
  {{- with .Values.podSecurityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  terminationGracePeriodSeconds: {{ (.Values.statefulSet | default dict).terminationGracePeriodSeconds | default 60 }}
  {{- with .Values.initContainers }}
  initContainers:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: redis
      image: {{ include "redis.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- with .Values.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      command:
        - /bin/bash
        - {{ $scripts }}/start-redis.sh
      ports:
        - name: redis
          containerPort: {{ .Values.service.port }}
          protocol: TCP
        {{- if $cluster }}
        {{- /* The cluster bus: fixed by Redis at the client port + 10000. This
               is how the nodes gossip, detect failure and vote — a cluster
               whose bus is blocked looks up and never converges. */}}
        - name: cluster-bus
          containerPort: {{ add (int .Values.service.port) 10000 }}
          protocol: TCP
        {{- end }}
      env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        {{- include "redis.topologyEnv" . | nindent 8 }}
        {{- include "redis.cliAuthEnv" . | nindent 8 }}
        {{- with .Values.extraEnv }}
        {{ toYaml . | trim | nindent 8 }}
        {{- end }}
      {{- with .Values.extraEnvFrom }}
      envFrom:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.startupProbe }}
      startupProbe:
        exec:
          command:
            {{- if .command }}
            {{- toYaml .command | nindent 12 }}
            {{- else }}
            - /bin/bash
            - {{ $scripts }}/health.sh
            - startup
            {{- end }}
        {{- toYaml (omit . "command" "checkClusterState" "requireMasterLink") | nindent 8 }}
      {{- end }}
      {{- with .Values.livenessProbe }}
      livenessProbe:
        exec:
          command:
            {{- if .command }}
            {{- toYaml .command | nindent 12 }}
            {{- else }}
            - /bin/bash
            - {{ $scripts }}/health.sh
            - liveness
            {{- range $liveChecks }}
            - {{ . }}
            {{- end }}
            {{- end }}
        {{- toYaml (omit . "command" "checkClusterState" "requireMasterLink") | nindent 8 }}
      {{- end }}
      {{- with .Values.readinessProbe }}
      readinessProbe:
        exec:
          command:
            {{- if .command }}
            {{- toYaml .command | nindent 12 }}
            {{- else }}
            - /bin/bash
            - {{ $scripts }}/health.sh
            - readiness
            {{- range $readyChecks }}
            - {{ . }}
            {{- end }}
            {{- end }}
        {{- toYaml (omit . "command" "checkClusterState" "requireMasterLink") | nindent 8 }}
      {{- end }}
      {{- with .Values.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumeMounts:
        - name: {{ $persistence.name | default "data" }}
          mountPath: {{ include "redis.dataDir" . }}
        - name: config
          mountPath: {{ include "redis.configDir" . }}
        - name: tmp
          mountPath: /tmp
        {{- include "redis.commonVolumeMounts" . | nindent 8 }}
        {{- with .Values.volumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    {{- if $sentinel }}
    {{- /* One sentinel per Redis instance, sharing its pod and its fate. A lost
           node takes down one of each, which keeps the two majorities aligned —
           and keeps the chart to the single StatefulSet it is meant to be. */}}
    - name: sentinel
      image: {{ include "redis.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- with .Values.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      command:
        - /bin/bash
        - {{ $scripts }}/start-sentinel.sh
      ports:
        - name: sentinel
          containerPort: {{ .Values.sentinel.port }}
          protocol: TCP
      env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        {{- include "redis.topologyEnv" . | nindent 8 }}
        {{- /* Sends the probe at sentinel rather than at the server sharing this
               pod's network namespace. */}}
        - name: HEALTH_PORT
          value: {{ .Values.sentinel.port | quote }}
        {{- with .Values.extraEnv }}
        {{ toYaml . | trim | nindent 8 }}
        {{- end }}
      {{- with .Values.sentinel.livenessProbe }}
      livenessProbe:
        exec:
          command:
            - /bin/bash
            - {{ $scripts }}/health.sh
            - liveness
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.sentinel.readinessProbe }}
      readinessProbe:
        exec:
          command:
            - /bin/bash
            - {{ $scripts }}/health.sh
            - readiness
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.sentinel.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumeMounts:
        {{- /* The data volume, because sentinel's own configuration lives on it:
               the file it rewrites is the only durable record of a failover. */}}
        - name: {{ $persistence.name | default "data" }}
          mountPath: {{ include "redis.dataDir" . }}
        - name: tmp
          mountPath: /tmp
        {{- include "redis.commonVolumeMounts" . | nindent 8 }}
        {{- with .Values.volumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    {{- end }}
    {{- with .Values.sidecars }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  volumes:
    {{- /* Where the configuration Redis actually reads is written. A ConfigMap
           mount is read only, and the last layer of the configuration — this
           pod's DNS name, its master, its password — can only be written once
           the pod exists. */}}
    - name: config
      emptyDir: {}
    - name: tmp
      emptyDir: {}
    {{- if not $persistence.enabled }}
    {{- /* No PVC: the dataset lives and dies with the pod. In cluster mode that
           includes nodes.conf, so a restarted pod comes back as a node the
           cluster has never met. For caches and for CI. */}}
    - name: {{ $persistence.name | default "data" }}
      emptyDir: {}
    {{- end }}
    {{- include "redis.commonVolumes" . | nindent 4 }}
    {{- with .Values.volumes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  affinity:
    {{- include "redis.affinity" . | nindent 4 }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.topologySpreadConstraints }}
  topologySpreadConstraints:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
