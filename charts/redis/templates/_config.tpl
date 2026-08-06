{{/*
Assembly of the configuration files.

Redis keeps the LAST occurrence of a directive, which is what makes a plain
concatenation a workable override mechanism — and what makes the order below the
whole of the contract:

    files/redis.conf          the base
    files/mode-<mode>.conf    the minimal configuration of the selected mode
    config.overrides          a map, for one-off changes
    config.extraConfig        raw text, for directives that repeat

`config.content` replaces the first two outright, for a configuration handed over
whole — `--set-file config.content=./redis.conf`. The layers after it still apply.

A fifth layer is appended by start-redis.sh inside the pod, for the directives
that cannot exist before the pod does. It is not here because it cannot be.
*/}}

{{/*
Renders a map of directives. Values are written as Redis expects them, which for
booleans means yes/no: a `appendonly: yes` in values.yaml is parsed by YAML as
the boolean true long before this template sees it, and `appendonly true` is a
configuration error Redis reports only at startup.
*/}}
{{- define "redis.directives" -}}
{{- range $key, $value := . }}
{{- if kindIs "bool" $value }}
{{ $key }} {{ ternary "yes" "no" $value }}
{{- else }}
{{ $key }} {{ $value }}
{{- end }}
{{- end }}
{{- end }}

{{/*
The redis.conf handed to the servers.
*/}}
{{- define "redis.assembledConfig" -}}
{{- $config := .Values.config | default dict -}}
{{- $mode := .Values.mode | default "cluster" -}}
{{- if $config.content }}
{{- /* A configuration supplied wholesale, typically by `--set-file`. It stands
       in for BOTH files — the base and the mode fragment — so what it does not
       say, nothing else says either. */ -}}
{{- tpl $config.content . | trim }}
{{ else }}
{{- $modeFile := $config.modeFile | default (printf "files/mode-%s.conf" $mode) -}}
{{- tpl (.Files.Get ($config.file | default "files/redis.conf")) . }}
{{ if ne $modeFile "-" }}
{{- tpl (.Files.Get $modeFile) . }}
{{ end }}
{{- end }}
{{- with $config.overrides }}

# =============================================================================
# config.overrides
# =============================================================================
{{- include "redis.directives" . }}
{{- end }}
{{- with $config.extraConfig }}

# =============================================================================
# config.extraConfig
# =============================================================================
{{ tpl . $ | trim }}
{{- end }}
{{- end }}

{{/*
The sentinel.conf handed to the sidecars.

Note what is NOT here: `sentinel monitor`. It names the current master, which is
not knowable at render time, and every other `sentinel <directive> <master>` line
is rejected before it is declared — so start-sentinel.sh writes it as a header
and this content follows it.
*/}}
{{- define "redis.assembledSentinelConfig" -}}
{{- $config := .Values.config | default dict -}}
{{- if $config.sentinelContent }}
{{- tpl $config.sentinelContent . | trim }}
{{ else }}
{{- tpl (.Files.Get ($config.sentinelFile | default "files/sentinel.conf")) . }}
{{- end }}
{{- with $config.sentinelOverrides }}

# =============================================================================
# config.sentinelOverrides
# =============================================================================
{{- include "redis.directives" . }}
{{- end }}
{{- with $config.sentinelExtraConfig }}

# =============================================================================
# config.sentinelExtraConfig
# =============================================================================
{{ tpl . $ | trim }}
{{- end }}
{{- end }}
