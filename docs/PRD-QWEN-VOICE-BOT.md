# **Product Requirement Document: Qwen Modular Voice Bot**

# **1\. Executive Summary**

The **Qwen Modular Voice Bot** is a production-ready, real-time conversational voice service for OpenShift AI. It delivers natural multilingual spoken interactions by composing a full Qwen voice stack: **Qwen-ASR-1.7B → Qwen3.6-35B-A3B → Qwen-TTS-1.7B**. The product separates speech recognition, conversational intelligence, and speech synthesis into independently deployable modules while presenting one low-latency voice experience to users and client applications.

The Qwen-native pipeline is intended to preserve linguistic context across the interaction, with particular emphasis on English, Chinese, and mixed English/Chinese conversations. Unlike a collection of unrelated speech and language services, the aligned Qwen stack enables coherent transcription, reasoning, response generation, and spoken output for enterprise conversational agents.

The application will run on OpenShift and OpenShift AI. **Open WebUI** will provide the initial browser-based voice interface for users to start real-time microphone conversations with the bot. A Qwen Voice Orchestrator and compatible model adapters will provide the backend integration for the Qwen model cascade. The application will also expose a secure streaming API for programmatic clients and will be packaged so each model component can be scaled, upgraded, and observed independently.

# **2\. Functional Requirements**

## **2.1. Voice Conversation Experience**

* **Browser Voice Client:** Use **Open WebUI Voice Mode** as the initial web interface where a user can start, pause, and end a microphone-based conversation.
* **Streaming Interaction:** Audio input and synthesized audio output MUST be streamed; users must not wait for a complete recording before the system begins processing.
* **Conversation History:** The application MUST preserve turn history for the duration of a session and provide that context to the language model.
* **Interruptions:** A user speaking while the bot is responding MUST be able to stop playback and begin a new turn (barge-in).
* **Text Visibility:** The UI MUST display the recognized user transcript and generated assistant response for each turn.
* **Open WebUI Configuration:** Open WebUI MUST be configured to use a single Qwen conversational model, server-side STT and TTS integrations, HTTPS, and the `Allow Call` permission for authorized users.

## **2.2. Multilingual Speech Recognition**

| Feature | Requirement Description |
| :---- | :---- |
| **ASR Model** | Use **Qwen-ASR-1.7B** as the default speech-to-text engine. |
| **Languages** | Support English and Chinese at launch, including natural code-switching within a single utterance where supported by the model. |
| **Streaming Audio** | Accept mono PCM audio at a documented sample rate; the browser client MUST perform capture and conversion where necessary. |
| **Partial Results** | Return interim transcription events when available, followed by a final transcript event for the completed utterance. |
| **Confidence & Errors** | Return recognition confidence or model metadata when available, and clearly identify failed or empty recognition results. |

## **2.3. Conversational Intelligence**

* **LLM Model:** Use **Qwen3.6-35B-A3B** as the default conversational model.
* **System Prompt:** Administrators MUST be able to configure a system prompt, supported languages, safety instructions, and default assistant persona through deployment configuration.
* **Context Management:** The orchestration service MUST pass ordered conversation turns to the LLM and enforce configurable limits for history length and token budget.
* **Response Streaming:** The LLM response MUST be streamed to the orchestration layer so speech synthesis can begin before the complete response is available.
* **Tool-Ready Design:** The API design MUST reserve an extension point for future tool calls and retrieval-augmented generation without changing the client voice protocol.

## **2.4. Speech Synthesis**

* **TTS Model:** Use **Qwen-TTS-1.7B** as the default text-to-speech engine.
* **Voice Configuration:** Deployment configuration MUST select the default speaker, speaking style, language behavior, and audio format from the model's supported options.
* **Incremental Synthesis:** The service MUST synthesize safe response segments as text becomes available and stream playable audio back to the client.
* **Language Consistency:** The synthesis service MUST preserve the language and code-switching intent of the LLM response rather than applying client-side translation.
* **Fallback:** If synthesis fails, the API MUST return the text response and a structured error so clients can show a text-only answer.

## **2.5. Session and Administration**

* **Session Lifecycle:** Create, retrieve, and terminate conversation sessions. Session data MUST be isolated by authenticated user or client identity.
* **Admin Configuration:** Administrators MUST configure model endpoints, prompt templates, voice defaults, timeouts, and retention settings through environment variables, ConfigMaps, or Helm values.
* **Observability View:** Provide an operations view showing service availability, active sessions, end-to-end latency, model-level latency, and error rate.
* **Privacy Controls:** Audio recordings and transcripts MUST NOT be persisted by default. When persistence is enabled, the retention period and storage location MUST be explicitly configured.

# **3\. Technical Architecture**

## **3.1. Deployment Model**

The application uses an **orchestrator pattern**. **Open WebUI** is the supported browser voice interface: it manages microphone permission, the voice-call user experience, transcript display, response playback, and user interruption. Open WebUI sends work to the Qwen model services through an OpenAI-compatible integration layer. A Qwen Voice Orchestrator coordinates the three Qwen model services, manages session context, handles interruption events, and returns transcript, text, and audio events in order.

```
Browser
  └── Open WebUI Voice Mode
        │  configured STT, chat, and TTS API requests
        ▼
Voice Orchestrator (FastAPI)
        │
        ├──► Qwen-ASR-1.7B      Speech → transcript
        ├──► Qwen3.6-35B-A3B    transcript + history → response text
        └──► Qwen-TTS-1.7B      response text → streamed speech
        │
        ▼
Transcript, response text, and playable audio stream
```

Each inference component MUST be exposed through an internal service endpoint and deployed independently. This allows horizontal scaling based on the distinct pressure profiles of ASR, LLM, and TTS workloads. Open WebUI and the Voice Orchestrator are the public application components; model services remain private to the OpenShift namespace.

* **External Access:** The web client and public API are exposed through an OpenShift Route with TLS.
* **Open WebUI Integration:** Open WebUI MUST use its standard Voice Mode with a configured server-side STT provider, chat-completion model, and TTS provider. It MUST be configured to use only one selected chat model per voice session.
* **Compatibility Layer:** The Voice Orchestrator MUST expose OpenAI-compatible endpoints for transcription (`/audio/transcriptions`), chat completion (`/chat/completions`), and speech synthesis (`/audio/speech`), translating these requests to Qwen-ASR-1.7B, Qwen3.6-35B-A3B, and Qwen-TTS-1.7B respectively.
* **Model Serving:** Models SHOULD be served through OpenShift AI-compatible inference services, such as KServe or vLLM-based runtimes, when supported by the selected model implementation.
* **Authentication:** Production deployments MUST authenticate API requests using OIDC, with Keycloak as the reference identity provider. Development mode MAY use a clearly labeled mock identity provider.
* **Authorization:** The orchestrator MUST authorize session access before returning transcripts, audio, or conversation history.

## **3.2. Independent Scaling and Model Failover**

The ASR, LLM, and TTS layers MUST be operated as separate, switchable **model pools**. A pool contains one or more ready replicas serving the same model and compatible configuration. The Voice Orchestrator calls a stable internal Kubernetes Service for each pool rather than a server-specific address. This allows a layer to be scaled, upgraded, or failed over without changing Open WebUI or the public API.

```
                         ┌─ ASR replica: Server A ─┐
Open WebUI → Orchestrator ── ASR Service            ├─ Qwen-ASR-1.7B pool
                         └─ ASR replica: Server B ─┘

                         ┌─ LLM replica: Server A ─┐
              Orchestrator ── LLM Service            ├─ Qwen3.6-35B-A3B pool
                         └─ LLM replica: Server B ─┘

                         ┌─ TTS replica: Server A ─┐
              Orchestrator ── TTS Service            ├─ Qwen-TTS-1.7B pool
                         └─ TTS replica: Server B ─┘
```

The diagram expresses the target deployment pattern, not a requirement that every model replica fit simultaneously on both servers. Replication requires sufficient GPU memory and capacity. Where capacity cannot support two warm replicas of a model, that layer is not highly available and this limitation MUST be recorded in the deployment sizing decision.

* **Replica Placement:** When a pool has two or more replicas, replicas MUST use pod anti-affinity or topology-spread constraints keyed to hostname so that matching replicas are placed on different servers.
* **Readiness-Based Routing:** A replica MUST not receive production traffic until its model is loaded, its inference health check passes, and it has registered as ready. Kubernetes removes unready replicas from the Service endpoints.
* **Layer-Specific Scaling:** ASR, LLM, and TTS MUST have separate replica counts, resource requests, GPU assignments, concurrency limits, and autoscaling policies. Scaling ASR MUST NOT cause an LLM or TTS rollout.
* **Switchable Backends:** The Helm values MUST select the active pool independently for `asr`, `llm`, and `tts`. This supports changing a model version, endpoint, or serving runtime per layer without altering the browser UI.
* **Failover:** When an endpoint becomes unready or an adapter receives a retriable transport failure, the orchestrator MUST retry the affected request against another ready replica in that layer's pool. Retries MUST be bounded and include the session and turn correlation identifiers.
* **Graceful Draining:** Before planned maintenance, a replica MUST become unready and stop accepting new turns while allowing in-flight work to complete up to a configured deadline.

For an ASR stream already in progress, instantaneous migration is not generally possible because the failed server owns model state for that stream. The orchestrator MUST retain a short rolling buffer of recent input audio. If the ASR connection fails, it SHOULD reconnect to a healthy ASR replica and replay the buffered audio for the current unfinished utterance. If recovery cannot produce a trustworthy final transcript, the client MUST receive a recoverable prompt to repeat the utterance; it MUST NOT silently generate an LLM answer from a partial or uncertain transcript.

## **3.3. Open WebUI Voice Interface**

Open WebUI is the initial, sufficient voice interface for browser users. The initial release MUST use **Standard Voice Mode**, which connects Open WebUI's configured STT, chat-completion, and TTS services to the Qwen compatibility layer. This keeps the Qwen ASR → LLM → TTS cascade explicit, observable, and independently deployable.

* **Call Start:** A user opens Open WebUI, selects the approved Qwen model, enables Voice Mode, and grants browser microphone permission.
* **Turn Taking:** Open WebUI detects speech and sends the completed utterance to the transcription endpoint. The resulting final transcript is sent to the Qwen chat-completion endpoint with the conversation context.
* **Playback:** Open WebUI receives the streamed LLM response and reads it through the configured Qwen TTS endpoint in response-sized segments. Users can stop or speak over the response when voice interruption is enabled.
* **User Access:** The Open WebUI deployment MUST use HTTPS and restrict Voice Mode through its `Allow Call` permission. The browser microphone MUST never be enabled without a user action and browser consent.
* **Operational Scope:** Open WebUI provides the interaction surface; it is not the authority for model routing, model credentials, Qwen inference scaling, or cross-service telemetry. Those responsibilities remain in the Voice Orchestrator and platform configuration.

Open WebUI's optional Realtime call mode is **not required** for the initial release. It expects an OpenAI-compatible realtime speech-to-speech interface, while this product initially exposes the Qwen cascade through standard STT, chat, and TTS endpoints. A future release MAY add a realtime-protocol gateway when lower latency justifies that additional integration.

## **3.4. Qwen Model Cascade**

The voice bot is a **cascade architecture**, not a single speech-to-speech model. Each stage produces an explicit, inspectable artifact for the next stage:

```
Microphone audio
      │
      ▼
Qwen-ASR-1.7B
      │  partial transcript → final transcript + language signals
      ▼
Voice Orchestrator
      │  current transcript + system prompt + relevant conversation history
      ▼
Qwen3.6-35B-A3B
      │  streamed response text, preserving selected language and tone
      ▼
Response segmenter
      │  sentence / clause-sized text segments safe to speak
      ▼
Qwen-TTS-1.7B
      │  encoded audio chunks
      ▼
Client playback
```

### **3.4.1. Stage 1 — Qwen-ASR-1.7B: Speech to Text**

The ASR service receives small, ordered microphone audio chunks for the active turn. It emits partial hypotheses while speech is in progress, then a final transcript when voice activity detection, a client `end_of_utterance` event, or a configured silence threshold closes the turn. Partial transcripts improve UI responsiveness but MUST NOT be committed to the LLM conversation history until the final transcript is available.

The orchestrator normalizes ASR output into a transcript object containing the final text, detected or requested language, timestamps, model metadata, and turn identifier. This explicit text representation is important: it makes multilingual transcription reviewable, allows policy filtering before generation, and lets the system return a useful text-only response if later audio stages fail.

### **3.4.2. Stage 2 — Qwen3.6-35B-A3B: Text to Conversational Response**

After ASR finalizes a turn, the orchestrator constructs the LLM input in this order:

1. The administrator-configured system prompt and safety instructions.
2. Session-level settings, such as allowed languages, persona, and tool availability.
3. A bounded sequence of prior finalized user and assistant turns.
4. The newest user transcript, marked with its source language where available.

The LLM returns text incrementally. The orchestrator records the complete generated response in the session context only after the turn completes successfully. It may forward completed clauses to TTS while generation continues, reducing perceived latency without changing the logical order of the response.

For English/Chinese conversations, the LLM MUST be instructed to answer in the user's current language and retain meaningful code-switching, proper names, technical terms, and quotations. The system SHOULD not perform independent machine translation between ASR and LLM or between LLM and TTS, because that can lose the linguistic continuity provided by the Qwen stack.

### **3.4.3. Stage 3 — Qwen-TTS-1.7B: Text to Speech**

The TTS service receives response segments plus a voice configuration selected for the session. A response segmenter buffers streamed LLM tokens until a safe boundary—normally a sentence, clause, or punctuation boundary—then submits the segment for synthesis. The segmenter MUST avoid sending incomplete words, abbreviations, Markdown syntax, raw tool payloads, or unstable partial text to the TTS model.

The TTS adapter emits audio in sequence-numbered chunks. The client queues these chunks for continuous playback while later text continues to be generated and synthesized. Voice, speaking style, output encoding, and sample rate are session properties; the TTS adapter MUST preserve them consistently across all segments of one assistant turn.

### **3.4.4. Cross-Stage State, Errors, and Interruptions**

The Voice Orchestrator owns the state machine for the cascade. It assigns a `session_id`, `turn_id`, and correlation identifier before audio reaches ASR, then attaches those identifiers to every downstream request, metric, and client event. This makes it possible to diagnose a poor interaction by determining whether it originated in recognition, reasoning, synthesis, or transport.

| Event | Required cascade behavior |
| :---- | :---- |
| **ASR cannot produce a final transcript** | Do not invoke the LLM. Return a recoverable recognition error and allow the user to retry. |
| **LLM fails or times out** | Do not invoke TTS for unfinished text. Return the final transcript and a structured generation error. |
| **TTS fails after text generation** | Return the generated text, signal a synthesis error, and let the client render a text-only response. |
| **User barges in during playback** | Immediately stop client playback, cancel queued TTS work, mark the active assistant turn interrupted, and begin a new ASR turn. |
| **Client disconnects** | Cancel pending model work after a short configurable grace period and remove ephemeral session buffers. |

This separation allows each model to evolve independently. For example, the deployment can tune ASR concurrency for many short audio streams, allocate larger GPU capacity to the LLM, or provide multiple TTS voice profiles without changing the public conversation protocol.

## **3.5. Streaming API Specification**

The backend provides REST endpoints for control-plane operations and a WebSocket endpoint for the real-time media plane. A future WebRTC transport MAY be added without changing session semantics.

### **3.5.1. Session Management**

* **POST /api/v1/sessions:** Creates a conversation session and returns its identifier and streaming endpoint.
* **GET /api/v1/sessions/{session_id}:** Returns permitted session metadata and current state.
* **DELETE /api/v1/sessions/{session_id}:** Terminates a session and clears ephemeral in-memory context.

### **3.5.2. Real-Time Voice Transport**

* **WS /api/v1/sessions/{session_id}/stream:** Bidirectional WebSocket used for audio chunks, partial transcripts, generated text, synthesized audio, interruption events, and structured errors.
* **Client events:** `audio_chunk`, `end_of_utterance`, `interrupt`, `ping`.
* **Server events:** `transcript_partial`, `transcript_final`, `response_text_delta`, `audio_chunk`, `turn_complete`, `error`.

An `audio_chunk` event MUST include an explicit encoding, sample rate, channel count, sequence number, and turn identifier. All server events MUST include the session identifier, turn identifier, event timestamp, and a correlation identifier for observability.

## **3.6. Model Service Contract**

The model adapters isolate the orchestrator from serving-runtime differences. Each adapter MUST offer health, metadata, and inference methods and translate runtime-specific errors into the application error schema.

| Adapter | Input | Output | Primary Responsibility |
| :---- | :---- | :---- | :---- |
| **ASR Adapter** | Audio stream and language preference | Partial/final transcript | Qwen-ASR-1.7B invocation and transcript normalization |
| **LLM Adapter** | System prompt, history, user transcript | Streamed response text | Qwen3.6-35B-A3B invocation and generation controls |
| **TTS Adapter** | Response text, voice configuration, language | Audio stream | Qwen-TTS-1.7B invocation and audio normalization |

## **3.7. Deployment Configuration Example**

The Helm chart MUST expose a declarative configuration surface for model endpoints and voice behavior.

```yaml
voiceBot:
  defaultLanguages: ["en", "zh"]
  audio:
    inputSampleRateHz: 16000
    outputFormat: "wav"
  conversation:
    maxHistoryTurns: 12
    systemPrompt: |
      You are a helpful multilingual voice assistant. Reply naturally in the
      user's language and preserve English/Chinese code-switching when useful.
  models:
    asr:
      name: "Qwen-ASR-1.7B"
      activePool: "qwen-asr-v1"
      endpoint: "http://qwen-asr-v1:8080"
      replicas: 2
      failover:
        enabled: true
        replayBufferSeconds: 8
    llm:
      name: "Qwen3.6-35B-A3B"
      activePool: "qwen-llm-v1"
      endpoint: "http://qwen-llm-v1:8000"
      replicas: 2
      failover:
        enabled: true
    tts:
      name: "Qwen-TTS-1.7B"
      activePool: "qwen-tts-v1"
      endpoint: "http://qwen-tts-v1:8080"
      replicas: 2
      failover:
        enabled: true
      voice: "default"
```

The replica values are deployment targets and MUST be reduced only after an explicit GPU-capacity decision. For a two-server high-availability deployment, a pool with `replicas: 2` MUST schedule one ready replica per server. The active pool name is an indirection point: changing `activePool` switches a layer to a tested replacement service without changing Open WebUI configuration.

# **4\. Engineering & Operations (DevEx)**

## **4.1. Project Repository Layout**

The source repository must support local iteration and OpenShift deployment with the following structure:

```
/rhoai-voice-bot
├── /open-webui       # Open WebUI deployment, approved model definitions, and voice configuration
├── /orchestrator    # FastAPI streaming and session service
├── /adapters        # ASR, LLM, and TTS runtime adapters
├── /helm            # Helm chart and values
├── /openshift       # Routes, RBAC, and deployment examples
└── /docs            # Architecture and operational documentation
```

## **4.2. Local Development & Iteration**

* **Frontend:** MUST support `npm run dev` with a local proxy to the orchestrator.
* **Orchestrator:** MUST support `uvicorn main:app --reload` and provide mock ASR, LLM, and TTS adapters for end-to-end UI development without GPUs.
* **Runtime Selection:** The service MUST select in-cluster configuration when running on OpenShift and local configuration when running on a developer laptop.
* **Configuration:** No model endpoint, credential, or token may be committed to source control. Local secrets MUST be loaded from ignored environment files or a supported secret manager.
* **Test Coverage:** The project MUST include unit tests for adapters and session logic, plus an integration test that validates the complete event sequence using mocked model services.

## **4.3. OpenShift Requirements**

* **Packaging:** Deploy the frontend, orchestrator, and model-service integrations through a Helm chart.
* **Secrets:** Store external model credentials and OIDC configuration in OpenShift Secrets; mount or inject them only into the workload that requires them.
* **Resource Controls:** Each service MUST define requests, limits, health probes, and graceful shutdown behavior. GPU scheduling and model-serving resource values MUST be configurable per model.
* **High Availability:** Deployments with two or more replicas MUST use pod anti-affinity or topology spread constraints to avoid placing matching model replicas on the same server. Pod disruption budgets MUST preserve at least one ready replica during voluntary maintenance.
* **Monitoring:** Export Prometheus-compatible metrics and provide structured logs with correlation identifiers across all pipeline stages.

# **5\. Non-Functional Requirements (NFRs)**

* **Latency:** For a short utterance under normal capacity, target a first partial transcript within **1.5 seconds**, a first response-text token within **2.5 seconds** after final transcription, and first synthesized audio within **4 seconds** after end of utterance.
* **Availability:** The orchestrator MUST expose readiness and liveness checks; an unavailable model component MUST degrade a request clearly without causing session-service failure.
* **Scalability:** ASR, LLM, TTS, and orchestration services MUST scale independently. The deployment MUST support multiple concurrent sessions subject to configurable queue and concurrency limits.
* **Resilience:** A failure of one ready replica MUST route new requests to another ready replica in the same layer pool. Active ASR utterances MAY be retried using a short replay buffer; when recovery is uncertain, the system MUST request that the user repeat the utterance rather than fabricate a transcript.
* **Security:** All external traffic MUST use TLS. Authentication tokens, raw audio, transcripts, and model credentials MUST be excluded from application logs by default.
* **Privacy:** Ephemeral audio buffers and session context MUST be deleted when a session ends unless explicitly retained by policy.
* **Quality:** The launch acceptance suite MUST include English-only, Chinese-only, and English/Chinese code-switching conversations, covering recognition, response coherence, and synthesized speech intelligibility.
* **Accessibility:** The browser client MUST provide keyboard-accessible controls and full text equivalents for user and assistant speech.

---
