{{/*
Every check that can be made before anything is created.

A Redis topology fails in ways that are cheap to catch here and expensive to
catch later: a cluster whose pods do not divide into shards is only discovered
when the bootstrap job gives up, and a sentinel quorum of one is only discovered
the day two masters accept writes at the same time. `fail` turns each of those
into a message at install time.

Included from the StatefulSet, which is rendered on every install and upgrade.
*/}}
{{- define "redis.validate" -}}
{{- $fullname := include "redis.fullname" . -}}
{{- $mode := .Values.mode | default "cluster" -}}
{{- $replicas := int .Values.replicaCount -}}

{{- /* ---------------------------------------------------------------- mode */ -}}
{{- if not (has $mode (list "cluster" "sentinel")) -}}
{{- fail (printf "redis: mode must be \"cluster\" or \"sentinel\", got %q." $mode) -}}
{{- end -}}

{{- /* -------------------------------------------------------- replicaCount */ -}}
{{- if lt $replicas 1 -}}
{{- fail (printf "redis: replicaCount must be at least 1, got %d." $replicas) -}}
{{- end -}}

{{- /* -------------------------------------------------------- cluster mode */ -}}
{{- if eq $mode "cluster" -}}
{{- $cluster := .Values.cluster | default dict -}}
{{- $perShard := add1 (int ($cluster.replicas | default 0)) -}}
{{- if lt (int ($cluster.replicas | default 0)) 0 -}}
{{- fail (printf "redis: cluster.replicas must be 0 or more, got %v." $cluster.replicas) -}}
{{- end -}}
{{- if ne (mod $replicas $perShard) 0 -}}
{{- fail (printf "redis: replicaCount (%d) must divide evenly into shards of %d pods (1 master + cluster.replicas=%v). `redis-cli --cluster create` refuses an uneven set, so the cluster would never be formed. Usable sizes here: %d, %d, %d, ..." $replicas $perShard ($cluster.replicas | default 0) (mul $perShard 3) (mul $perShard 4) (mul $perShard 5)) -}}
{{- end -}}
{{- $masters := div $replicas $perShard -}}
{{- if lt $masters 3 -}}
{{- fail (printf "redis: a Redis Cluster needs at least 3 masters and this topology has %d (replicaCount=%d, cluster.replicas=%v). Masters vote on failure, and fewer than three of them can never reach a majority — the cluster would have no way to survive losing one. Raise replicaCount to %d or more." $masters $replicas ($cluster.replicas | default 0) (mul $perShard 3)) -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------- sentinel mode */ -}}
{{- if eq $mode "sentinel" -}}
{{- $sentinel := .Values.sentinel | default dict -}}
{{- if lt $replicas 3 -}}
{{- fail (printf "redis: sentinel mode needs at least 3 pods and got %d. One sentinel runs per pod, and a failover requires a majority of them: with two, losing one leaves no majority and no failover ever happens — which is the one thing sentinel is there for." $replicas) -}}
{{- end -}}
{{- if not $sentinel.masterSet -}}
{{- fail "redis: sentinel.masterSet must be set. Sentinel identifies the monitored master by that name and clients ask for it by that name." -}}
{{- end -}}
{{- if regexMatch "[[:space:]]" ($sentinel.masterSet | toString) -}}
{{- fail (printf "redis: sentinel.masterSet must not contain whitespace, got %q. It is a token in the sentinel configuration file, where a space would split it in two." $sentinel.masterSet) -}}
{{- end -}}
{{- if $sentinel.quorum -}}
{{- $quorum := int $sentinel.quorum -}}
{{- if or (lt $quorum 1) (gt $quorum $replicas) -}}
{{- fail (printf "redis: sentinel.quorum must be between 1 and replicaCount (%d), got %d." $replicas $quorum) -}}
{{- end -}}
{{- end -}}
{{- if eq (int ($sentinel.port | default 26379)) (int .Values.service.port) -}}
{{- fail (printf "redis: sentinel.port and service.port are both %d. Sentinel and Redis run in the same pod and share its network namespace, so they cannot share a port." (int .Values.service.port)) -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------------- service */ -}}
{{- $port := int .Values.service.port -}}
{{- if or (lt $port 1) (gt $port 65535) -}}
{{- fail (printf "redis: service.port must be between 1 and 65535, got %d." $port) -}}
{{- end -}}
{{- if eq $mode "cluster" -}}
{{- if gt (add $port 10000) 65535 -}}
{{- fail (printf "redis: service.port is %d, which leaves no room for the cluster bus. A cluster node listens on its port + 10000 (%d here), and that has to be a valid port too. Keep service.port below 55535." $port (add $port 10000)) -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------- configuration */ -}}
{{- $config := .Values.config | default dict -}}
{{- if and $config.content $config.existingConfigMap -}}
{{- fail "redis: config.content and config.existingConfigMap are both set, and they are two ways of doing the same thing. existingConfigMap points at a ConfigMap the chart does not render; content is rendered into the ConfigMap the chart does. Pick one." -}}
{{- end -}}
{{- /* The files are only read when nothing was handed over in their place. */ -}}
{{- if not (or $config.existingConfigMap $config.content) -}}
{{- if not $config.file -}}
{{- fail "redis: config.file must point at a configuration file inside the chart, or config.content / config.existingConfigMap must supply one instead." -}}
{{- end -}}
{{- if not (.Files.Get $config.file) -}}
{{- fail (printf "redis: config.file %q is empty or not found in the chart. Note that .Files.Get only reads files packaged with the chart — a path outside it, or one matched by .helmignore, reads as empty." $config.file) -}}
{{- end -}}
{{- $modeFile := $config.modeFile | default (printf "files/mode-%s.conf" $mode) -}}
{{- if and (ne $modeFile "-") (not (.Files.Get $modeFile)) -}}
{{- fail (printf "redis: config.modeFile %q is empty or not found in the chart. Set it to \"-\" to append no mode fragment at all." $modeFile) -}}
{{- end -}}
{{- end -}}

{{- /* Checked on its own: config.content stands in for the server's files and
       says nothing about sentinel's, which then still comes from the chart. */ -}}
{{- if eq $mode "sentinel" -}}
{{- if not (or $config.existingConfigMap $config.sentinelContent) -}}
{{- if not (.Files.Get ($config.sentinelFile | default "files/sentinel.conf")) -}}
{{- fail (printf "redis: config.sentinelFile %q is empty or not found in the chart." ($config.sentinelFile | default "files/sentinel.conf")) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* Directives the chart writes itself, per pod, after everything else. Left
       in the user's hands they would be silently overridden — or worse, not
       overridden, and break the topology in a way nothing reports. */ -}}
{{- $owned := list "dir" "port" "cluster-enabled" "cluster-config-file" "cluster-announce-hostname" "cluster-announce-ip" "cluster-announce-port" "cluster-announce-bus-port" "replicaof" "slaveof" "replica-announce-ip" "replica-announce-port" "requirepass" "masterauth" "unixsocket" -}}
{{- range $key, $value := ($config.overrides | default dict) -}}
{{- if has (lower $key) $owned -}}
{{- fail (printf "redis: config.overrides.%s is set, but %q is one of the directives the chart owns. It is written per pod at startup, from values only known then — this pod's DNS name, the current master, the mount path of its volume, the password read from a Secret — and it is appended last, so anything you set here would be overridden without warning. The full list: %s." $key $key (join ", " $owned)) -}}
{{- end -}}
{{- end -}}

{{- /* ---------------------------------------------------------------- auth */ -}}
{{- $auth := .Values.auth | default dict -}}
{{- if $auth.enabled -}}
{{- if and $auth.existingSecret (not $auth.existingSecretPasswordKey) -}}
{{- fail "redis: auth.existingSecret is set but auth.existingSecretPasswordKey is empty. The chart needs to know which key of that Secret holds the password." -}}
{{- end -}}
{{- if regexMatch "[\"'[:space:]]" ($auth.password | toString) -}}
{{- fail "redis: auth.password contains whitespace or a quote. The password is written into redis.conf as a bare token, where either one would truncate it — pass it through auth.existingSecret if it has to contain them, and quote it there as Redis expects." -}}
{{- end -}}
{{- end -}}

{{- /* --------------------------------------------------------- persistence */ -}}
{{- $persistence := .Values.persistence | default dict -}}
{{- if $persistence.enabled -}}
{{- if not $persistence.size -}}
{{- fail "redis: persistence.size is required when persistence.enabled is true — a volumeClaimTemplate has no default size." -}}
{{- end -}}
{{- end -}}

{{- /* ---------------------------------------------------------- extraFiles */ -}}
{{- $extraFiles := .Values.extraFiles | default dict -}}
{{- range $name, $content := ($extraFiles.configMap | default dict) -}}
{{- if hasKey ($extraFiles.secret | default dict) $name -}}
{{- fail (printf "redis: extraFiles name %q appears in both configMap and secret. Both are projected into %s, and one path cannot come from two sources." $name (include "redis.extraFilesMountPath" $)) -}}
{{- end -}}
{{- end -}}

{{- /* -------------------------------------------------------------- backup */ -}}
{{- $backup := .Values.backup | default dict -}}
{{- if $backup.enabled -}}
{{- if not (has ($backup.target | default "all") (list "all" "master" "replica")) -}}
{{- fail (printf "redis: backup.target must be \"all\", \"master\" or \"replica\", got %q." $backup.target) -}}
{{- end -}}
{{- if and (eq $mode "cluster") (ne ($backup.target | default "all") "all") -}}
{{- fail (printf "redis: backup.target is %q, which cannot mean anything in cluster mode: every master holds a different share of the keyspace, so a dump of one of them is a fraction of the data and a dump of the replicas is the same fraction again. Use \"all\"." $backup.target) -}}
{{- end -}}
{{- if not $backup.storage -}}
{{- fail "redis: backup.enabled is true but backup.storage is empty. It takes a volume spec — the key is what kind of volume the dumps are written to." -}}
{{- end -}}
{{- if not $backup.schedule -}}
{{- fail "redis: backup.enabled is true but backup.schedule is empty." -}}
{{- end -}}
{{- end -}}

{{- end }}
