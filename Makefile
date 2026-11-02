BASE:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
SHELL=/bin/sh
NAMESPACE=rhoai-voice-bot
GPU_CONFIG_NAME=voice-bot
GPU_OPERATOR_NS=nvidia-gpu-operator

# Resolve the DeepSeek key from either DEEPSEEK_API_KEY (env var) or
# app/rhoai-voice-bot/.env (gitignored, see .env.example). Never echoed.
ifneq (,$(wildcard $(BASE)/.env))
include $(BASE)/.env
export
endif

.PHONY: deploy
deploy: namespace enable-gpu-sharing secret deploy-asr deploy-tts deploy-open-webui
	@echo
	@echo "Deployed. Check status with: make status"

.PHONY: namespace
namespace:
	oc apply -f $(BASE)/openshift/namespace.yaml

# Enables NVIDIA GPU time-slicing on ONE free GPU node so voice-asr and
# voice-tts can share a single physical GPU (see openshift/gpu-time-slicing-cm.yaml
# for why). Auto-detects the first GPU node with zero GPU-requesting pods
# scheduled on it -- does not touch any node already running other GPU
# workloads. Safe to re-run.
.PHONY: enable-gpu-sharing
enable-gpu-sharing:
	@oc apply -f $(BASE)/openshift/gpu-time-slicing-cm.yaml
	@oc patch clusterpolicy gpu-cluster-policy --type merge \
		-p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config"}}}}'
	@FREE_NODE=""; \
	for n in $$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do \
		already=$$(oc get node $$n -o jsonpath='{.metadata.labels.nvidia\.com/device-plugin\.config}' 2>/dev/null); \
		if [ "$$already" = "$(GPU_CONFIG_NAME)" ]; then echo "GPU sharing already enabled on $$n"; exit 0; fi; \
		gpu_pods=$$(oc get pods -A --field-selector spec.nodeName=$$n -o json | \
			python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for p in d['items'] for c in p['spec'].get('containers',[]) if 'nvidia.com/gpu' in (c.get('resources',{}).get('requests') or {})))"); \
		if [ "$$gpu_pods" = "0" ]; then FREE_NODE=$$n; break; fi; \
	done; \
	if [ -z "$$FREE_NODE" ]; then echo "ERROR: no free GPU node found (all GPU nodes already have GPU-requesting pods)"; exit 1; fi; \
	echo "Enabling GPU time-slicing on free node: $$FREE_NODE"; \
	oc label node $$FREE_NODE nvidia.com/device-plugin.config=$(GPU_CONFIG_NAME) --overwrite

.PHONY: secret
secret:
	@test -n "$(DEEPSEEK_API_KEY)" || { echo "ERROR: DEEPSEEK_API_KEY is not set (see .env.example)"; exit 1; }
	@WEBUI_SECRET_KEY=$${WEBUI_SECRET_KEY:-$$(openssl rand -hex 32)}; \
	DEEPSEEK_API_KEY="$(DEEPSEEK_API_KEY)" WEBUI_SECRET_KEY="$$WEBUI_SECRET_KEY" \
		envsubst < $(BASE)/openshift/deepseek-secret.yaml.tmpl | oc apply -n $(NAMESPACE) -f -

.PHONY: deploy-asr
deploy-asr:
	oc apply -f $(BASE)/openshift/asr-sr.yaml
	oc apply -f $(BASE)/openshift/asr-isvc.yaml

.PHONY: deploy-tts
deploy-tts:
	oc apply -f $(BASE)/openshift/tts-sr.yaml
	oc apply -f $(BASE)/openshift/tts-isvc.yaml

.PHONY: deploy-open-webui
deploy-open-webui:
	oc apply -f $(BASE)/openshift/open-webui.yaml

.PHONY: register-voice
# Registers a CosyVoice3 voice named "default" (required -- CosyVoice3 has
# no built-in preset voices). Usage:
#   make register-voice VOICE_WAV=/path/to/ref.wav VOICE_TEXT="exact transcript of ref.wav"
VOICE_NAME ?= default
register-voice:
	@test -n "$(VOICE_WAV)" || { echo "ERROR: VOICE_WAV is not set (path to a short reference audio clip)"; exit 1; }
	@test -n "$(VOICE_TEXT)" || { echo "ERROR: VOICE_TEXT is not set (exact transcript of VOICE_WAV)"; exit 1; }
	@oc port-forward -n $(NAMESPACE) svc/voice-tts-predictor 18081:80 >/tmp/voice-bot-pf-tts.log 2>&1 & \
	PF_PID=$$!; sleep 4; \
	curl -sS --max-time 30 -X POST http://127.0.0.1:18081/v1/audio/voices \
		-F "audio_sample=@$(VOICE_WAV)" \
		-F "consent=voice-bot-$(VOICE_NAME)-consent" \
		-F "name=$(VOICE_NAME)" \
		-F "ref_text=$(VOICE_TEXT)"; \
	echo; \
	kill $$PF_PID 2>/dev/null

.PHONY: test-asr
test-asr:
	@oc port-forward -n $(NAMESPACE) svc/voice-asr-predictor 18080:80 >/tmp/voice-bot-pf-asr.log 2>&1 & \
	PF_PID=$$!; sleep 4; \
	curl -fL https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512-vllm/resolve/vllm-0.27.1-20260830/example/zh.mp3 -o /tmp/voice-bot-test.mp3 -s; \
	curl -sS --max-time 30 http://127.0.0.1:18080/v1/audio/transcriptions \
		-F "file=@/tmp/voice-bot-test.mp3;type=audio/mpeg" \
		-F model=fun-asr-nano -F language=zh -F temperature=0 -F response_format=json; \
	echo; \
	kill $$PF_PID 2>/dev/null

.PHONY: test-tts
test-tts:
	@oc port-forward -n $(NAMESPACE) svc/voice-tts-predictor 18081:80 >/tmp/voice-bot-pf-tts.log 2>&1 & \
	PF_PID=$$!; sleep 4; \
	curl -sS --max-time 30 -X POST http://127.0.0.1:18081/v1/audio/speech \
		-H "Content-Type: application/json" \
		-d '{"input":"Hello from the voice bot.","voice":"$(VOICE_NAME)"}' \
		-o /tmp/voice-bot-test-speech.wav -w "HTTP %{http_code}\n"; \
	file /tmp/voice-bot-test-speech.wav; \
	kill $$PF_PID 2>/dev/null

.PHONY: status
status:
	@echo "=== Pods ==="
	@oc get pods -n $(NAMESPACE)
	@echo
	@echo "=== Services ==="
	@oc get svc -n $(NAMESPACE)
	@echo
	@echo "=== Routes ==="
	@oc get route -n $(NAMESPACE)
	@echo
	@echo "=== PVCs ==="
	@oc get pvc -n $(NAMESPACE)

.PHONY: webui-url
webui-url:
	@echo "https://$$(oc get route open-webui -n $(NAMESPACE) -o jsonpath='{.spec.host}')"

.PHONY: undeploy
undeploy:
	-oc delete -f $(BASE)/openshift/open-webui.yaml
	-oc delete -f $(BASE)/openshift/asr-isvc.yaml
	-oc delete -f $(BASE)/openshift/asr-sr.yaml
	-oc delete -f $(BASE)/openshift/tts-isvc.yaml
	-oc delete -f $(BASE)/openshift/tts-sr.yaml
	-oc delete secret voice-bot-secrets -n $(NAMESPACE)
	-oc delete namespace $(NAMESPACE)
	@echo "Note: GPU time-slicing node label and ClusterPolicy patch are left"
	@echo "in place (cluster-wide infra, harmless when unused). To fully revert:"
	@echo "  oc label node <node> nvidia.com/device-plugin.config- "
	@echo "  oc patch clusterpolicy gpu-cluster-policy --type merge -p '{\"spec\":{\"devicePlugin\":{\"config\":{\"name\":\"\"}}}}'"
