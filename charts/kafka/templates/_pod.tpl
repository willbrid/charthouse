{{/*
Pod template of the StatefulSet. Kept in its own file so the workload template holds
only what genuinely belongs to the set — replicas, service name, update strategy,
volume claim templates — and so the container definition stays readable.
Usage: {{ include "kafka.podTemplate" . | nindent 4 }}
*/}}
{{- define "kafka.podTemplate" -}}
{{- $fullname := include "kafka.fullname" . -}}
{{- $controller := include "kafka.controllerListener" . | fromYaml -}}
{{- $brokerListeners := include "kafka.brokerListeners" . | fromYamlArray -}}
{{- $persistence := .Values.persistence | default dict -}}
{{- $extraFiles := .Values.extraFiles | default dict -}}
{{- /* The port the probes dial: the first client-facing listener, or the controller
       listener on a node that has none. */ -}}
{{- $probePort := $controller.name | lower -}}
{{- if $brokerListeners -}}
{{- $probePort = (first $brokerListeners).name | lower -}}
{{- end -}}
metadata:
  annotations:
    {{- /* A change to the topology, or to an injected file, has to reach the pods:
           without these the ConfigMap content changes under a StatefulSet that
           Kubernetes sees as unchanged, and nothing restarts. */}}
    checksum/format: {{ include (print $.Template.BasePath "/configmap-format.yaml") . | sha256sum }}
    {{- if or $extraFiles.configMap $extraFiles.secret }}
    checksum/extra-files: {{ printf "%s%s" (toYaml ($extraFiles.configMap | default dict)) (toYaml ($extraFiles.secret | default dict)) | sha256sum }}
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
    {{- include "kafka.labels" . | nindent 4 }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  serviceAccountName: {{ include "kafka.serviceAccountName" . }}
  {{- with .Values.podSecurityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  terminationGracePeriodSeconds: {{ (.Values.statefulSet | default dict).terminationGracePeriodSeconds | default 120 }}
  initContainers:
    {{- with .Values.initContainers }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- /* Storage formatting. KRaft needs the log directory formatted with the
           cluster id before a node can start, and the flags differ per pod, which
           rules out doing it from the values alone. Running it here rather than
           leaving it to the image entrypoint is what lets the chart choose the
           quorum bootstrap flags — the entrypoint has no notion of ordinals. */}}
    - name: format-storage
      image: {{ include "kafka.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- with .Values.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      command:
        - /bin/sh
        - -ec
        - |
          # Ordinal of this pod, and the Kafka node id derived from it.
          ORDINAL="${POD_NAME##*-}"
          NODE_ID=$((ORDINAL + NODE_ID_OFFSET))
          echo "kafka: pod ${POD_NAME} is node ${NODE_ID} at ${POD_FQDN}"

          if [ -f "{{ include "kafka.dataDir" . }}/meta.properties" ]; then
            echo "kafka: storage already formatted, nothing to do"
            exit 0
          fi

          # The per-pod values the rendered properties file left as placeholders.
          sed -e "s/__NODE_ID__/${NODE_ID}/g" \
              -e "s#__POD_FQDN__#${POD_FQDN}#g" \
              /mnt/kafka-format/format.properties > /tmp/format.properties

          {{- if eq (include "kafka.quorumMode" .) "dynamic" }}
          # Dynamic quorum: the first controller formats itself as the sole initial
          # voter, and every other node formats without one and joins afterwards
          # through controller.quorum.auto.join.enable. Formatting them all as
          # standalone would create as many one-node clusters as there are pods.
          {{- if include "kafka.isController" . }}
          if [ "${ORDINAL}" -eq 0 ]; then
            INITIAL_CONTROLLERS="--standalone"
          else
            INITIAL_CONTROLLERS="--no-initial-controllers"
          fi
          {{- else }}
          INITIAL_CONTROLLERS="--no-initial-controllers"
          {{- end }}
          {{- else }}
          # Static quorum: the voter set is frozen in the configuration, and passing
          # an initial-controllers flag alongside it is rejected by Kafka.
          INITIAL_CONTROLLERS=""
          {{- end }}

          exec {{ (.Values.kraft.format | default dict).storageScript | default "/opt/kafka/bin/kafka-storage.sh" }} format \
            --cluster-id "${CLUSTER_ID}" \
            --config /tmp/format.properties \
            --ignore-formatted \
            ${INITIAL_CONTROLLERS} \
            {{- range (.Values.kraft.format | default dict).extraArgs }}
            {{ . | quote }} \
            {{- end }}
            ;
      env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: POD_FQDN
          value: "$(POD_NAME).{{ include "kafka.headlessServiceName" . }}.$(POD_NAMESPACE).svc.{{ include "kafka.clusterDomain" . }}"
        - name: CLUSTER_ID
          value: {{ .Values.kraft.clusterId | quote }}
        - name: NODE_ID_OFFSET
          value: {{ .Values.kraft.nodeIdOffset | default 0 | quote }}
      volumeMounts:
        - name: {{ $persistence.name | default "data" }}
          mountPath: {{ include "kafka.dataDir" . }}
        - name: format-config
          mountPath: /mnt/kafka-format
          readOnly: true
        - name: tmp
          mountPath: /tmp
  containers:
    - name: {{ .Chart.Name }}
      image: {{ include "kafka.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- with .Values.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- /* With the default offset, the node id is read straight from the downward
             API and the image entrypoint runs untouched. A non-zero offset needs an
             addition, which no Kubernetes field can express, so a shell computes it
             and hands over. */}}
      {{- if ne (int (.Values.kraft.nodeIdOffset | default 0)) 0 }}
      command:
        - /bin/sh
        - -ec
        - |
          export KAFKA_NODE_ID=$((${POD_INDEX} + ${KAFKA_NODE_ID_OFFSET}))
          exec {{ .Values.kraft.entrypoint | default "/etc/kafka/docker/run" }}
      {{- end }}
      ports:
        {{- range $brokerListeners }}
        - name: {{ .name | lower }}
          containerPort: {{ .port }}
          protocol: TCP
        {{- end }}
        {{- if include "kafka.isController" . }}
        - name: {{ $controller.name | lower }}
          containerPort: {{ $controller.port }}
          protocol: TCP
        {{- end }}
      {{- if or .Values.configmap .Values.secret }}
      envFrom:
        {{- if .Values.configmap }}
        - configMapRef:
            name: {{ $fullname }}
        {{- end }}
        {{- if .Values.secret }}
        - secretRef:
            name: {{ $fullname }}
        {{- end }}
      {{- end }}
      env:
        {{- include "kafka.env" . | nindent 8 }}
      {{- with .Values.startupProbe }}
      startupProbe:
        tcpSocket:
          port: {{ $probePort }}
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.livenessProbe }}
      livenessProbe:
        tcpSocket:
          port: {{ $probePort }}
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.readinessProbe }}
      readinessProbe:
        tcpSocket:
          port: {{ $probePort }}
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumeMounts:
        - name: {{ $persistence.name | default "data" }}
          mountPath: {{ include "kafka.dataDir" . }}
        - name: tmp
          mountPath: /tmp
        {{- if or $extraFiles.configMap $extraFiles.secret }}
        - name: extra-files
          mountPath: {{ include "kafka.extraFilesMountPath" . }}
          readOnly: true
        {{- end }}
        {{- with .Values.volumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    {{- with .Values.sidecars }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  volumes:
    - name: format-config
      configMap:
        name: {{ $fullname }}-format
    - name: tmp
      emptyDir: {}
    {{- if not $persistence.enabled }}
    {{- /* No PVC: the log directory lives and dies with the pod. */}}
    - name: {{ $persistence.name | default "data" }}
      emptyDir: {}
    {{- end }}
    {{- if or $extraFiles.configMap $extraFiles.secret }}
    {{- /* One projected volume rather than two mounts: both sources land in the
           same directory, and two volumes cannot share a mount path. */}}
    - name: extra-files
      projected:
        {{- /* Readable by the group, not by the owner alone: the files are owned by
               root and read by the Kafka user, which reaches them through fsGroup. */}}
        defaultMode: 0440
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
  {{- with .Values.topologySpreadConstraints }}
  topologySpreadConstraints:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
