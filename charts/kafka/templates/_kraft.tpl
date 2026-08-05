{{/*
KRaft configuration engine.

Everything Kafka needs to know about its own topology — who it is, who the other
members are, which sockets it opens and which addresses it hands out to clients —
is derived here from three values and nothing else:

  kraft.role     what the nodes are (controller, broker, or both)
  replicaCount   how many of them there are
  listeners      which sockets they open

The rest of the chart never builds a Kafka address by hand. That is the whole
point: a listener the pod binds, an endpoint a peer dials and an address a client
is told to use are three views of the same fact, and they cannot be allowed to
drift apart.

Everything lands on the container as KAFKA_* environment variables, following the
conversion rules of the apache/kafka image:
https://github.com/apache/kafka/blob/trunk/docker/examples/README.md
*/}}

{{/*
Roles carried by every node of the set, normalised and sorted: "broker",
"controller", or "broker,controller".
Usage: {{ include "kafka.roleSet" . }}
*/}}
{{- define "kafka.roleSet" -}}
{{- $roles := list -}}
{{- range (splitList "," (.Values.kraft.role | default "controller,broker")) -}}
{{- $role := . | trim | lower -}}
{{- if and $role (not (has $role $roles)) -}}
{{- $roles = append $roles $role -}}
{{- end -}}
{{- end -}}
{{- join "," (sortAlpha $roles) -}}
{{- end }}

{{/*
Non-empty when the nodes act as controllers, i.e. take part in the metadata quorum.
Usage: {{ if include "kafka.isController" . }}
*/}}
{{- define "kafka.isController" -}}
{{- if has "controller" (splitList "," (include "kafka.roleSet" .)) -}}true{{- end -}}
{{- end }}

{{/*
Non-empty when the nodes act as brokers, i.e. serve clients and hold partitions.
Usage: {{ if include "kafka.isBroker" . }}
*/}}
{{- define "kafka.isBroker" -}}
{{- if has "broker" (splitList "," (include "kafka.roleSet" .)) -}}true{{- end -}}
{{- end }}

{{/*
Broker-facing listeners, as declared in .Values.listeners.broker. Empty on a
controller-only set, which serves no client: the listeners a node opens follow
from its role, they are never configured twice.
Usage: {{ range (include "kafka.brokerListeners" . | fromYamlArray) }}
*/}}
{{- define "kafka.brokerListeners" -}}
{{- if include "kafka.isBroker" . -}}
{{- toYaml (.Values.listeners.broker | default list) -}}
{{- else -}}
[]
{{- end -}}
{{- end }}

{{/*
The controller listener. Present on every node — a broker also needs to know the
name and the security protocol of the listener it uses to reach the controllers —
but only bound by the nodes that carry the controller role.
Usage: {{ $c := include "kafka.controllerListener" . | fromYaml }}
*/}}
{{- define "kafka.controllerListener" -}}
{{- $controller := .Values.listeners.controller | default dict -}}
name: {{ $controller.name | default "CONTROLLER" }}
port: {{ $controller.port | default 9093 }}
securityProtocol: {{ $controller.securityProtocol | default "PLAINTEXT" }}
{{- end }}

{{/*
Name of the listener brokers use to talk to each other. Defaults to the first
broker listener, so a single-listener setup needs no extra value.
Usage: {{ include "kafka.interBrokerListenerName" . }}
*/}}
{{- define "kafka.interBrokerListenerName" -}}
{{- $listeners := include "kafka.brokerListeners" . | fromYamlArray -}}
{{- if $listeners -}}
{{- .Values.listeners.interBrokerListenerName | default (first $listeners).name -}}
{{- end -}}
{{- end }}

{{/*
listeners: the sockets the node binds, all on 0.0.0.0. Broker listeners appear only
on a node carrying the broker role, the controller listener only on a controller.
Usage: {{ include "kafka.listenersProperty" . }}
*/}}
{{- define "kafka.listenersProperty" -}}
{{- $entries := list -}}
{{- range (include "kafka.brokerListeners" . | fromYamlArray) -}}
{{- $entries = append $entries (printf "%s://0.0.0.0:%d" .name (int .port)) -}}
{{- end -}}
{{- if include "kafka.isController" . -}}
{{- $controller := include "kafka.controllerListener" . | fromYaml -}}
{{- $entries = append $entries (printf "%s://0.0.0.0:%d" $controller.name (int $controller.port)) -}}
{{- end -}}
{{- join "," $entries -}}
{{- end }}

{{/*
advertised.listeners: the addresses the node hands out to clients, one per broker
listener. The controller listener is deliberately absent — Kafka rejects it there,
and the apache/kafka image refuses to start a controller-only node that defines
advertised listeners at all, which is why the caller must skip the property
entirely rather than pass an empty string.

`host` is the address template the pod advertises itself under. It is a parameter
because the same list is needed twice with two different substitution mechanisms:
"$(POD_FQDN)" for the container, where Kubernetes expands the reference, and a
"__POD_FQDN__" placeholder for the storage formatting step, where a shell does.
A listener entry may override it with `advertisedHost` / `advertisedPort`, which
is what an externally reachable listener needs.
Usage: {{ include "kafka.advertisedListenersProperty" (dict "ctx" $ "host" "$(POD_FQDN)") }}
*/}}
{{- define "kafka.advertisedListenersProperty" -}}
{{- $ctx := .ctx -}}
{{- $host := .host -}}
{{- $entries := list -}}
{{- range (include "kafka.brokerListeners" $ctx | fromYamlArray) -}}
{{- $advertisedHost := .advertisedHost | default $host -}}
{{- $advertisedPort := .advertisedPort | default .port -}}
{{- $entries = append $entries (printf "%s://%s:%v" .name $advertisedHost $advertisedPort) -}}
{{- end -}}
{{- join "," $entries -}}
{{- end }}

{{/*
listener.security.protocol.map: the security protocol of every listener the node
knows about. The controller entry is kept even on a broker-only node, which needs
it to dial the controller listener.
Usage: {{ include "kafka.securityProtocolMap" . }}
*/}}
{{- define "kafka.securityProtocolMap" -}}
{{- $entries := list -}}
{{- range (include "kafka.brokerListeners" . | fromYamlArray) -}}
{{- $entries = append $entries (printf "%s:%s" .name (.securityProtocol | default "PLAINTEXT")) -}}
{{- end -}}
{{- $controller := include "kafka.controllerListener" . | fromYaml -}}
{{- $entries = append $entries (printf "%s:%s" $controller.name $controller.securityProtocol) -}}
{{- join "," $entries -}}
{{- end }}

{{/*
Node id of the pod of ordinal `ordinal`: the ordinal itself, shifted by
kraft.nodeIdOffset. The offset is what keeps ids unique across a split
deployment, where a controller release and a broker release form one Kafka
cluster and each numbers its pods from zero.
Usage: {{ include "kafka.nodeId" (dict "ctx" $ "ordinal" 0) }}
*/}}
{{- define "kafka.nodeId" -}}
{{- add (int .ordinal) (int (.ctx.Values.kraft.nodeIdOffset | default 0)) -}}
{{- end }}

{{/*
Endpoints of the controller quorum, in the form the *dynamic* quorum expects
(host:port), generated from replicaCount: one entry per pod of the set.

A broker-only set has no controller of its own, so there is nothing to derive:
kraft.quorum.bootstrapServers must then name the controllers of the other release.
Usage: {{ include "kafka.quorumBootstrapServers" . }}
*/}}
{{- define "kafka.quorumBootstrapServers" -}}
{{- $quorum := .Values.kraft.quorum | default dict -}}
{{- if $quorum.bootstrapServers -}}
{{- join "," $quorum.bootstrapServers -}}
{{- else -}}
{{- $controller := include "kafka.controllerListener" . | fromYaml -}}
{{- $entries := list -}}
{{- range $i := until (int .Values.replicaCount) -}}
{{- $entries = append $entries (printf "%s:%v" (include "kafka.podFqdn" (dict "ctx" $ "ordinal" $i)) $controller.port) -}}
{{- end -}}
{{- join "," $entries -}}
{{- end -}}
{{- end }}

{{/*
Members of the controller quorum, in the form the *static* quorum expects
(id@host:port), generated from replicaCount. Same rule as above for a broker-only
set: the voters of the controller release must be given explicitly.
Usage: {{ include "kafka.quorumVoters" . }}
*/}}
{{- define "kafka.quorumVoters" -}}
{{- $quorum := .Values.kraft.quorum | default dict -}}
{{- if $quorum.voters -}}
{{- join "," $quorum.voters -}}
{{- else -}}
{{- $controller := include "kafka.controllerListener" . | fromYaml -}}
{{- $entries := list -}}
{{- range $i := until (int .Values.replicaCount) -}}
{{- $entries = append $entries (printf "%v@%s:%v" (include "kafka.nodeId" (dict "ctx" $ "ordinal" $i)) (include "kafka.podFqdn" (dict "ctx" $ "ordinal" $i)) $controller.port) -}}
{{- end -}}
{{- join "," $entries -}}
{{- end -}}
{{- end }}

{{/*
Quorum mode: "dynamic" (controller.quorum.bootstrap.servers, KRaft version 1) or
"static" (controller.quorum.voters, deprecated). The two are mutually exclusive —
Kafka refuses a node formatted for one and configured for the other — so the chart
emits exactly one of the two properties.
Usage: {{ include "kafka.quorumMode" . }}
*/}}
{{- define "kafka.quorumMode" -}}
{{- (.Values.kraft.quorum | default dict).mode | default "dynamic" -}}
{{- end }}

{{/*
Kafka properties the chart derives from the values above. Anything the user sets in
.Values.config wins over them, which is the escape hatch for a topology the chart
does not model — at the cost of the guarantees this file exists to provide.
Note that node.id is absent: it is the one property that differs from pod to pod,
and it is resolved on the container from the StatefulSet ordinal.
Usage: {{ $config := include "kafka.generatedConfig" . | fromYaml }}
*/}}
{{- define "kafka.generatedConfig" -}}
{{- $config := dict -}}
{{- $controller := include "kafka.controllerListener" . | fromYaml -}}
{{- $_ := set $config "process.roles" (include "kafka.roleSet" .) -}}
{{- $_ := set $config "log.dirs" (include "kafka.dataDir" .) -}}
{{- $_ := set $config "listeners" (include "kafka.listenersProperty" .) -}}
{{- $_ := set $config "listener.security.protocol.map" (include "kafka.securityProtocolMap" .) -}}
{{- $_ := set $config "controller.listener.names" $controller.name -}}
{{- if include "kafka.isBroker" . -}}
{{- $_ := set $config "advertised.listeners" (include "kafka.advertisedListenersProperty" (dict "ctx" . "host" "$(POD_FQDN)")) -}}
{{- $_ := set $config "inter.broker.listener.name" (include "kafka.interBrokerListenerName" .) -}}
{{- end -}}
{{- if eq (include "kafka.quorumMode" .) "static" -}}
{{- $_ := set $config "controller.quorum.voters" (include "kafka.quorumVoters" .) -}}
{{- else -}}
{{- $_ := set $config "controller.quorum.bootstrap.servers" (include "kafka.quorumBootstrapServers" .) -}}
{{- if include "kafka.isController" . -}}
{{- /* KIP-853 auto-join: a controller formatted without an initial voter set adds
       itself to the quorum through the bootstrap servers above. This is what makes
       a dynamic quorum come up unattended, and it needs Kafka 4.2 or later —
       before that the property does not exist and is silently dropped, leaving
       every node but the first an observer. */ -}}
{{- $_ := set $config "controller.quorum.auto.join.enable" "true" -}}
{{- end -}}
{{- end -}}
{{- toYaml $config -}}
{{- end }}

{{/*
Full Kafka configuration: the generated properties, overridden by .Values.config.
Usage: {{ $config := include "kafka.config" . | fromYaml }}
*/}}
{{- define "kafka.config" -}}
{{- $generated := include "kafka.generatedConfig" . | fromYaml -}}
{{- $user := .Values.config | default dict -}}
{{- toYaml (merge (deepCopy $user) $generated) -}}
{{- end }}

{{/*
Environment variable name of a Kafka property, following the conversion rules of the
apache/kafka image: `_` becomes `__`, `-` becomes `___`, `.` becomes `_`, the result
is upper-cased and prefixed with KAFKA_. The order matters — converting the dots
first would make `a.b` and `a_b` collide on the same variable.
Usage: {{ include "kafka.propertyToEnv" "num.partitions" }}  →  KAFKA_NUM_PARTITIONS
*/}}
{{- define "kafka.propertyToEnv" -}}
{{- printf "KAFKA_%s" (. | replace "_" "__" | replace "-" "___" | replace "." "_" | upper) -}}
{{- end }}

{{/*
The environment of the Kafka container, in dependency order: Kubernetes expands a
$(VAR) reference only against a variable declared before it, and POD_FQDN — the
address every broker advertises itself under — is built from POD_NAME.
Usage: {{ include "kafka.env" . | nindent 8 }}
*/}}
{{- define "kafka.env" -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
{{- /* Ordinal of the pod in the set, published by the StatefulSet controller as a
       pod label since Kubernetes 1.28. Reading it from the downward API is what
       lets the node id be derived without a shell wrapping the entrypoint. */}}
- name: POD_INDEX
  valueFrom:
    fieldRef:
      fieldPath: metadata.labels['apps.kubernetes.io/pod-index']
- name: POD_FQDN
  value: "$(POD_NAME).{{ include "kafka.headlessServiceName" . }}.$(POD_NAMESPACE).svc.{{ include "kafka.clusterDomain" . }}"
- name: CLUSTER_ID
  value: {{ .Values.kraft.clusterId | quote }}
{{- if eq (int (.Values.kraft.nodeIdOffset | default 0)) 0 }}
- name: KAFKA_NODE_ID
  value: "$(POD_INDEX)"
{{- else }}
{{- /* A non-zero offset needs arithmetic, which the downward API cannot do: the
       node id is computed by the shell wrapping the entrypoint instead. Only the
       offset is passed here. */}}
- name: KAFKA_NODE_ID_OFFSET
  value: {{ .Values.kraft.nodeIdOffset | quote }}
{{- end }}
{{- $config := include "kafka.config" . | fromYaml }}
{{- range $property := (keys $config | sortAlpha) }}
- name: {{ include "kafka.propertyToEnv" $property }}
  value: {{ get $config $property | quote }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . | trim }}
{{- end }}
{{- end }}

{{/*
The properties file handed to `kafka-storage format`, with the two per-pod values
left as placeholders for the init container to substitute. It is deliberately not
the container configuration: the format step needs the topology, not the runtime
tuning, and an advertised address of 0.0.0.0 would be rejected.
Usage: rendered into the ConfigMap as format.properties
*/}}
{{- define "kafka.formatProperties" -}}
{{- $config := include "kafka.config" . | fromYaml -}}
{{- $keep := list "process.roles" "log.dirs" "listeners" "listener.security.protocol.map" "controller.listener.names" "inter.broker.listener.name" "controller.quorum.voters" "controller.quorum.bootstrap.servers" -}}
node.id=__NODE_ID__
{{- range $property := (keys $config | sortAlpha) }}
{{- if has $property $keep }}
{{ $property }}={{ get $config $property }}
{{- end }}
{{- end }}
{{- if include "kafka.isBroker" . }}
advertised.listeners={{ include "kafka.advertisedListenersProperty" (dict "ctx" . "host" "__POD_FQDN__") }}
{{- end }}
{{- end }}
