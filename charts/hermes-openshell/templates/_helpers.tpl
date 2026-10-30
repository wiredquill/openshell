{{- define "hermes-openshell.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* The client Deployment and its pod (<release>-client-...): the openshell CLI
     that creates the sandbox and forwards its UI. The sandbox pod, with the
     OpenShell supervisor, is named after the sandbox (sandbox.name). */}}
{{- define "hermes-openshell.clientName" -}}
{{- printf "%s-client" (include "hermes-openshell.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hermes-openshell.labels" -}}
app.kubernetes.io/name: hermes-openshell
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "hermes-openshell.selector" -}}
app.kubernetes.io/name: hermes-openshell
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* The image the sandbox runs, from the form's dropdown. */}}
{{- define "hermes-openshell.sandboxImage" -}}
{{- if eq .Values.sandbox.image "custom" -}}
{{- required "sandbox.customImage is required when sandbox.image is custom" .Values.sandbox.customImage -}}
{{- else -}}
{{- required (printf "unknown sandbox.image %q (suse, opensuse or custom)" .Values.sandbox.image) (get .Values.sandbox.images .Values.sandbox.image) -}}
{{- end -}}
{{- end -}}

{{/* The selected profile's policy file; fails on an unknown profile. */}}
{{- define "hermes-openshell.policy" -}}
{{- $f := printf "profiles/%s.yaml" .Values.profile -}}
{{- $p := .Files.Get $f -}}
{{- if not $p -}}
{{- fail (printf "unknown profile %q (lockdown, research, developer or dangerous)" .Values.profile) -}}
{{- end -}}
{{- include "hermes-openshell.withOtel" (dict "root" . "policy" $p) -}}
{{- end -}}

{{/* A profile's policy as is, or with observability on, plus a network rule
     that lets the venv's python (the real path; OpenShell matches it) send
     OTLP to the collector. Re-serialised then, so the file's comments go. */}}
{{- define "hermes-openshell.withOtel" -}}
{{- $o := .root.Values.observability -}}
{{- if not $o.enabled -}}
{{- .policy -}}
{{- else -}}
{{- $u := urlParse (include "hermes-openshell.otlpEndpoint" .root) -}}
{{- $port := ternary "443" "80" (eq $u.scheme "https") -}}
{{- $hp := splitList ":" $u.host -}}
{{- if gt (len $hp) 1 }}{{ $port = last $hp }}{{ end -}}
{{- $endpoint := dict "host" $u.hostname "port" (atoi $port) "protocol" "rest" "access" "read-write" "enforcement" "enforce" -}}
{{- $rule := dict "name" "otel-collector" "endpoints" (list $endpoint) "binaries" (list (dict "path" "/usr/bin/python3.13")) -}}
{{- $p := fromYaml .policy -}}
{{- $np := $p.network_policies | default dict -}}
{{- $_ := set $np "otel-collector" $rule -}}
{{- $_ = set $p "network_policies" $np -}}
{{- toYaml $p -}}
{{- end -}}
{{- end -}}

{{/* The model backend's settings: url, name, and the Secret holding the key. */}}
{{- define "hermes-openshell.model" -}}
{{- $m := .Values.model -}}
{{- if eq $m.backend "vllm" -}}
{{- dict "url" $m.vllm.url "name" $m.vllm.name "secret" "" | toJson -}}
{{- else if eq $m.backend "external" -}}
{{- $secret := "" -}}
{{- if $m.external.existingSecret -}}{{- $secret = $m.external.existingSecret -}}
{{- else if $m.external.apiKey -}}{{- $secret = printf "%s-llm" (include "hermes-openshell.fullname" .) -}}
{{- end -}}
{{- dict "url" (required "model.external.url is required" $m.external.url) "name" (required "model.external.name is required" $m.external.name) "secret" $secret | toJson -}}
{{- else -}}
{{- fail (printf "unknown model.backend %q (vllm or external)" $m.backend) -}}
{{- end -}}
{{- end -}}

{{/* OTLP/HTTP endpoint: observability.otlpEndpoint, else the shared SUSE AI
     collector's Service found at install time (as the hr-assistant chart does:
     collectorNamespace, then observability, then suse-observability; a Service
     named *opentelemetry-collector* or labelled so), else the conventional
     name. `lookup` finds nothing under `helm template`. */}}
{{- define "hermes-openshell.otlpEndpoint" -}}
{{- $o := .Values.observability -}}
{{- if $o.otlpEndpoint -}}
{{- $o.otlpEndpoint -}}
{{- else -}}
{{- $found := "" -}}
{{- range $ns := compact (uniq (list $o.collectorNamespace "observability" "suse-observability")) -}}
{{- if not $found -}}
{{- range $svc := ((lookup "v1" "Service" $ns "").items | default list) -}}
{{- if not $found -}}
{{- $name := dig "app.kubernetes.io/name" "" ($svc.metadata.labels | default dict) -}}
{{- if or (contains "opentelemetry-collector" $svc.metadata.name) (eq $name "opentelemetry-collector") -}}
{{- $found = printf "http://%s.%s.svc.cluster.local:4318" $svc.metadata.name $ns -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $found | default "http://opentelemetry-collector.observability.svc.cluster.local:4318" -}}
{{- end -}}
{{- end -}}

{{/* Hermes's branding text, as {KEY: text} for HERMES_BRANDING_<KEY>: the
     form's branding fields, over the session's words (hermes.session): the
     profile in the prompt and response header, and a welcome line with what
     the profile allows. */}}
{{- define "hermes-openshell.branding" -}}
{{- $v := .Values -}}
{{- $profile := $v.profile -}}
{{- $out := dict -}}
{{- if $v.hermes.session.enabled -}}
{{- $welcome := printf "%s Approvals: %s." (get $v.hermes.session.welcome $profile) (get $v.approvals $profile) | trim -}}
{{- $_ := set $out "WELCOME" (printf "%s Type /help for commands." $welcome) -}}
{{- $_ := set $out "RESPONSE_LABEL" (printf " Hermes · %s " $profile) -}}
{{- $_ := set $out "PROMPT_SYMBOL" (printf "%s ❯" $profile) -}}
{{- end -}}
{{- if $v.hermes.branding.enabled -}}
{{- range $key, $env := dict "agentName" "AGENT_NAME" "welcome" "WELCOME" "goodbye" "GOODBYE" "responseLabel" "RESPONSE_LABEL" "promptSymbol" "PROMPT_SYMBOL" "helpHeader" "HELP_HEADER" -}}
{{- with get $v.hermes.branding $key }}{{ $_ := set $out $env . }}{{ end -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/* The browser tab's title: the agent's name and the profile. */}}
{{- define "hermes-openshell.title" -}}
{{- $name := "Hermes in OpenShell" -}}
{{- with .Values.hermes.branding -}}
{{- if and .enabled .agentName }}{{ $name = .agentName }}{{ end -}}
{{- end -}}
{{- printf "%s · %s" $name .Values.profile -}}
{{- end -}}

{{/* The SUSE AI inference engine Hermes calls: vllm for the vllm backend, else
     model.external.provider. Also its gen_ai.provider.name, so the engine the
     SUSE AI collector infers is the one declared. */}}
{{- define "hermes-openshell.provider" -}}
{{- if eq .Values.model.backend "vllm" }}vllm{{ else }}{{ .Values.model.external.provider | default "openai" }}{{ end -}}
{{- end -}}

{{- define "hermes-openshell.topologyAttr" -}}
{{- dict "key" (index . 0) "value" (dict "stringValue" (index . 1)) | toJson -}}
{{- end -}}

{{/* Declared SUSE AI topology, as an OTLP/JSON metrics request for the SUSE AI
     Declared Topology StackPack (wiredquill/ai-demos
     stackpacks/suse-ai-declared-topology): the agent uses the inference engine,
     which runs the model. One suse_ai_declared_component data point per
     component, one suse_ai_declared_relation per relation; timeUnixNano is
     set when it is sent (__NOW__). No service.name, so the OpenTelemetry
     StackPack does not turn the sender into a service. */}}
{{- define "hermes-openshell.topologyPayload" -}}
{{- $engine := include "hermes-openshell.provider" . -}}
{{- $vllm := eq .Values.model.backend "vllm" -}}
{{- $model := ternary .Values.model.vllm.name .Values.model.external.name $vllm -}}
{{- $components := list
  (list "application" .Values.observability.serviceName "application")
  (list "inference-engine" $engine (ternary "inference-engine.vllm" "inference-engine" $vllm))
  (list "llm-model" $model (ternary "llm-model.vllm" "llm-model" $vllm)) -}}
{{- $relations := list
  (list "application" .Values.observability.serviceName "inference-engine" $engine "uses")
  (list "inference-engine" $engine "llm-model" $model "runs") -}}
{{- $cpoints := list -}}
{{- range $components -}}
{{- $attrs := list (include "hermes-openshell.topologyAttr" (list "type" (index . 0)) | fromJson) (include "hermes-openshell.topologyAttr" (list "name" (index . 1)) | fromJson) (include "hermes-openshell.topologyAttr" (list "type_name" (index . 2)) | fromJson) -}}
{{- $cpoints = append $cpoints (dict "asInt" "1" "timeUnixNano" "__NOW__" "attributes" $attrs) -}}
{{- end -}}
{{- $rpoints := list -}}
{{- range $relations -}}
{{- $attrs := list (include "hermes-openshell.topologyAttr" (list "source.type" (index . 0)) | fromJson) (include "hermes-openshell.topologyAttr" (list "source.name" (index . 1)) | fromJson) (include "hermes-openshell.topologyAttr" (list "target.type" (index . 2)) | fromJson) (include "hermes-openshell.topologyAttr" (list "target.name" (index . 3)) | fromJson) (include "hermes-openshell.topologyAttr" (list "type" (index . 4)) | fromJson) -}}
{{- $rpoints = append $rpoints (dict "asInt" "1" "timeUnixNano" "__NOW__" "attributes" $attrs) -}}
{{- end -}}
{{- $resource := list (include "hermes-openshell.topologyAttr" (list "suse.ai.topology.declared" "true") | fromJson) (include "hermes-openshell.topologyAttr" (list "k8s.namespace.name" .Release.Namespace) | fromJson) -}}
{{- with dig "cattle" "clusterName" "" (.Values.global | default dict) -}}
{{- $resource = append $resource (include "hermes-openshell.topologyAttr" (list "k8s.cluster.name" .) | fromJson) -}}
{{- end -}}
{{- toJson (dict "resourceMetrics" (list (dict
  "resource" (dict "attributes" $resource)
  "scopeMetrics" (list (dict
    "scope" (dict "name" "suse-ai-declared-topology" "version" .Chart.Version)
    "metrics" (list
      (dict "name" "suse_ai_declared_component" "gauge" (dict "dataPoints" $cpoints))
      (dict "name" "suse_ai_declared_relation" "gauge" (dict "dataPoints" $rpoints)))))))) -}}
{{- end -}}

{{/* Pod spec shared by the topology Job and CronJob. */}}
{{- define "hermes-openshell.topologyPodSpec" -}}
restartPolicy: OnFailure
automountServiceAccountToken: false
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  seccompProfile:
    type: RuntimeDefault
containers:
  - name: push
    image: {{ .Values.observability.topology.image | quote }}
    command: ["/bin/sh", "/topology/push.sh"]
    env:
      - name: OTLP_ENDPOINT
        value: {{ include "hermes-openshell.otlpEndpoint" . | trimSuffix "/" | quote }}
    volumeMounts:
      - name: topology
        mountPath: /topology
        readOnly: true
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 64Mi
volumes:
  - name: topology
    configMap:
      name: {{ include "hermes-openshell.fullname" . }}-topology
{{- end -}}
