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
{{- /* The two quorum modes are bootstrapped by different parties, because the
       apache/kafka image can only format one of them. Its entrypoint runs
       `kafka-storage format --cluster-id … --config …` and nothing else: enough
       for a static voter set, but a dynamic quorum additionally requires one of
       --standalone / --initial-controllers / --no-initial-controllers, and the
       argument check fires before the already-formatted check, so the node dies
       on every start no matter what the volume holds.
       Static therefore stays with the image entrypoint, untouched. Dynamic is
       formatted by the init container below, and the container command is
       rearranged so the image renders its configuration without formatting. */ -}}
{{- $dynamic := eq (include "kafka.quorumMode" .) "dynamic" -}}
{{- $offset := int (.Values.kraft.nodeIdOffset | default 0) -}}
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
    {{- if $dynamic }}
    checksum/format: {{ include (print $.Template.BasePath "/configmap-format.yaml") . | sha256sum }}
    {{- end }}
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
  {{- if or .Values.initContainers $dynamic }}
  initContainers:
    {{- with .Values.initContainers }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- if $dynamic }}
    {{- /* Storage formatting for the dynamic quorum, which the image cannot do.
           The flags differ per pod — only the first controller formats itself as
           a voter — so this cannot be expressed in the values alone either. */}}
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

          {{- if include "kafka.isController" . }}
          # The first controller formats itself as the sole initial voter, and every
          # other node formats without one and joins afterwards through
          # controller.quorum.auto.join.enable. Formatting them all as standalone
          # would create as many one-node clusters as there are pods.
          if [ "${ORDINAL}" -eq 0 ]; then
            INITIAL_CONTROLLERS="--standalone"
          else
            INITIAL_CONTROLLERS="--no-initial-controllers"
          fi
          {{- else }}
          # A broker never votes, so it is never an initial controller.
          INITIAL_CONTROLLERS="--no-initial-controllers"
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
    {{- end }}
  {{- end }}
  containers:
    - name: {{ .Chart.Name }}
      image: {{ include "kafka.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- with .Values.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- /* Left to the image entrypoint whenever it can do the job. It is replaced
             only for the two things it cannot express: an offset node id, which
             needs an addition no Kubernetes field can perform, and the dynamic
             quorum, whose formatting it always fails. */}}
      {{- if or $dynamic (ne $offset 0) }}
      command:
        - /bin/bash
        - -ec
        - |
          {{- if ne $offset 0 }}
          export KAFKA_NODE_ID=$((POD_INDEX + KAFKA_NODE_ID_OFFSET))
          {{- end }}
          {{- if $dynamic }}
          # What follows is the image entrypoint (/etc/kafka/docker/run) with one
          # change. Its last step, `launch`, renders server.properties from the
          # KAFKA_* variables *and* formats the storage in the same call, then
          # aborts unless the failure says "already formatted". For a dynamic
          # quorum that call can only fail — it passes none of the required
          # initial-controllers flags — so the storage is formatted by the init
          # container instead and the expected failure is tolerated here. The
          # configuration file is fully written before the format is attempted,
          # which is what makes this safe; any other failure still aborts.
          . /etc/kafka/docker/bash-config
          . /etc/kafka/docker/configureDefaults
          . /etc/kafka/docker/configure

          result=$(/opt/kafka/bin/kafka-run-class.sh kafka.docker.KafkaDockerWrapper setup \
            --default-configs-dir /etc/kafka/docker \
            --mounted-configs-dir /mnt/shared/config \
            --final-configs-dir /opt/kafka/config 2>&1) || {
              echo "$result"
              echo "$result" | grep -qiE "already formatted|must specify one of the following" || exit 1
              echo "kafka: storage formatting left to the init container, as expected"
            }

          # Class-data sharing archive of the broker, as the image would set it.
          export KAFKA_JVM_PERFORMANCE_OPTS="${KAFKA_JVM_PERFORMANCE_OPTS-} -XX:SharedArchiveFile=/opt/kafka/kafka.jsa"
          exec /opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
          {{- else }}
          exec {{ .Values.kraft.entrypoint | default "/etc/kafka/docker/run" }}
          {{- end }}
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
    {{- if $dynamic }}
    - name: format-config
      configMap:
        name: {{ $fullname }}-format
    {{- end }}
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
