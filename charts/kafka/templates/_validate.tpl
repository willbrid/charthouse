{{/*
Value validation, run once from the StatefulSet — the one template that is always
rendered — so a misconfiguration stops `helm install` with a readable message
instead of surfacing as a CrashLoopBackOff twenty seconds later.
Usage: {{- include "kafka.validate" . -}}
*/}}
{{- define "kafka.validate" -}}
{{- $replicas := int .Values.replicaCount -}}
{{- if lt $replicas 1 -}}
{{- fail (printf "kafka: replicaCount must be at least 1, got %d" $replicas) -}}
{{- end -}}

{{- /* Roles. The three combinations below are the only ones KRaft knows about. */ -}}
{{- $roles := include "kafka.roleSet" . -}}
{{- if not (has $roles (list "broker" "controller" "broker,controller")) -}}
{{- fail (printf "kafka: kraft.role must be \"controller\", \"broker\" or \"controller,broker\", got %q" (.Values.kraft.role | default "")) -}}
{{- end -}}

{{- /* A quorum needs an odd number of voters to tolerate a failure: 3 tolerates one,
       4 still tolerates one while costing an extra node. Only a hard stop on 2 is
       warranted — a two-voter quorum tolerates nothing yet doubles the failure surface. */ -}}
{{- if and (include "kafka.isController" .) (eq $replicas 2) (not (.Values.kraft.quorum | default dict).voters) (not (.Values.kraft.quorum | default dict).bootstrapServers) -}}
{{- fail "kafka: a controller quorum of 2 nodes tolerates no failure and loses availability as soon as one node is down. Use 1 (development), 3 or 5." -}}
{{- end -}}

{{- if not (trim (.Values.kraft.clusterId | default "")) -}}
{{- fail "kafka: kraft.clusterId is required. Generate one with `kafka-storage.sh random-uuid` and keep it stable for the life of the cluster: it is written to the storage at format time and a mismatch stops the node from starting." -}}
{{- end -}}

{{- $mode := include "kafka.quorumMode" . -}}
{{- if not (has $mode (list "static" "dynamic")) -}}
{{- fail (printf "kafka: kraft.quorum.mode must be \"dynamic\" or \"static\", got %q" $mode) -}}
{{- end -}}

{{- /* A broker-only set carries no controller, so replicaCount describes brokers and
       says nothing about where the quorum lives. It has to be named explicitly. */ -}}
{{- $quorum := .Values.kraft.quorum | default dict -}}
{{- if not (include "kafka.isController" .) -}}
{{- if and (eq $mode "dynamic") (not $quorum.bootstrapServers) -}}
{{- fail "kafka: a broker-only set (kraft.role: broker) cannot derive the controller quorum from its own replicaCount. Set kraft.quorum.bootstrapServers to the endpoints of the controller release." -}}
{{- end -}}
{{- if and (eq $mode "static") (not $quorum.voters) -}}
{{- fail "kafka: a broker-only set (kraft.role: broker) cannot derive the controller quorum from its own replicaCount. Set kraft.quorum.voters to the voters of the controller release." -}}
{{- end -}}
{{- end -}}

{{- if lt (int (.Values.kraft.nodeIdOffset | default 0)) 0 -}}
{{- fail (printf "kafka: kraft.nodeIdOffset must not be negative, got %v" .Values.kraft.nodeIdOffset) -}}
{{- end -}}

{{- /* Listeners. Names and ports are checked against each other across the broker
       list and the controller entry, because Kafka indexes listeners by name and
       the pod binds every port in the same network namespace. */ -}}
{{- $controller := include "kafka.controllerListener" . | fromYaml -}}
{{- $brokerListeners := .Values.listeners.broker | default list -}}
{{- if and (include "kafka.isBroker" .) (not $brokerListeners) -}}
{{- fail "kafka: listeners.broker must declare at least one listener when kraft.role includes \"broker\"" -}}
{{- end -}}
{{- $names := list $controller.name -}}
{{- $ports := list (toString $controller.port) -}}
{{- $protocols := list "PLAINTEXT" "SSL" "SASL_PLAINTEXT" "SASL_SSL" -}}
{{- if not (has $controller.securityProtocol $protocols) -}}
{{- fail (printf "kafka: listeners.controller.securityProtocol must be one of %s, got %q" (join ", " $protocols) $controller.securityProtocol) -}}
{{- end -}}
{{- range $brokerListeners -}}
{{- if not .name -}}
{{- fail "kafka: every listeners.broker entry requires a name" -}}
{{- end -}}
{{- if not .port -}}
{{- fail (printf "kafka: listeners.broker entry %q requires a port" .name) -}}
{{- end -}}
{{- if has .name $names -}}
{{- fail (printf "kafka: duplicated listener name %q — the controller listener and the broker listeners share one namespace" .name) -}}
{{- end -}}
{{- if has (toString .port) $ports -}}
{{- fail (printf "kafka: listener %q reuses port %v, already bound by another listener of the same pod" .name .port) -}}
{{- end -}}
{{- /* The listener name doubles as a service port name once lower-cased, and
       Kubernetes caps those at 15 characters of an RFC 1123 label. */ -}}
{{- if gt (len .name) 15 -}}
{{- fail (printf "kafka: listener name %q exceeds 15 characters, which is the limit of the service port name derived from it" .name) -}}
{{- end -}}
{{- if not (regexMatch "^[a-zA-Z]([a-zA-Z0-9-]*[a-zA-Z0-9])?$" .name) -}}
{{- fail (printf "kafka: listener name %q must be alphanumeric with dashes, starting with a letter" .name) -}}
{{- end -}}
{{- if not (has (.securityProtocol | default "PLAINTEXT") $protocols) -}}
{{- fail (printf "kafka: listener %q has securityProtocol %q, must be one of %s" .name .securityProtocol (join ", " $protocols)) -}}
{{- end -}}
{{- $names = append $names .name -}}
{{- $ports = append $ports (toString .port) -}}
{{- end -}}
{{- $interBroker := include "kafka.interBrokerListenerName" . -}}
{{- if and $interBroker (not (has $interBroker $names)) -}}
{{- fail (printf "kafka: listeners.interBrokerListenerName is %q, which matches no listeners.broker entry" $interBroker) -}}
{{- end -}}
{{- if and $interBroker (eq $interBroker $controller.name) -}}
{{- fail "kafka: listeners.interBrokerListenerName must not be the controller listener" -}}
{{- end -}}

{{- /* Configuration overrides. node.id is the one property the chart owns outright:
       it is per-pod, and a single value shared by the whole set would have every
       node claim the same identity. */ -}}
{{- $user := .Values.config | default dict -}}
{{- range $property, $_ := $user -}}
{{- if has $property (list "node.id" "broker.id") -}}
{{- fail (printf "kafka: config.%s cannot be set — the node id is derived from the StatefulSet ordinal (see kraft.nodeIdOffset)" $property) -}}
{{- end -}}
{{- end -}}

{{- /* Storage. A Kafka log directory on an emptyDir loses every partition the pod
       held as soon as it is rescheduled, so persistence is opt-out and loud. */ -}}
{{- $persistence := .Values.persistence | default dict -}}
{{- if $persistence.enabled -}}
{{- if not $persistence.size -}}
{{- fail "kafka: persistence.size is required when persistence.enabled is true" -}}
{{- end -}}
{{- end -}}

{{- /* Injected files. The two sources land in the same directory, so a name used
       twice would have one mount silently shadow the other. */ -}}
{{- $extraFiles := .Values.extraFiles | default dict -}}
{{- range $name, $_ := ($extraFiles.configMap | default dict) -}}
{{- if hasKey ($extraFiles.secret | default dict) $name -}}
{{- fail (printf "kafka: extraFiles %q is declared both in configMap and in secret, and both mount into %s" $name (include "kafka.extraFilesMountPath" $)) -}}
{{- end -}}
{{- end -}}
{{- end }}
