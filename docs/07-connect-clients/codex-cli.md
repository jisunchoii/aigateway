---
description: "Codex CLI — Responses API provider로 APIM 게이트웨이(/responses) 연결"
---

# Codex CLI

OpenAI Codex CLI를 custom model provider로 설정해 APIM 게이트웨이를 통과하도록 구성합니다. Codex CLI는 **Responses API 전용**(`wire_api = "responses"`)이므로, gpt 계열과 partner/OSS 모델을 하나의 Responses 엔드포인트(`/responses`)로 통일해 노출하는 **LiteLLM 브리지**를 경유합니다.

{% hint style="warning" %}
`/responses` 경로는 LiteLLM 브리지와 함께 배포되어야 동작합니다. 아직 배포하지 않았다면 먼저 [Responses 브리지(LiteLLM) 배포](../03-deploy/case-litellm-responses.md)를 완료하세요. 브리지 없이 `/openai`·`/foundry` 경로에 Codex를 직접 붙이면 partner/OSS 모델에서 실패합니다(아래 §5 참고).
{% endhint %}

## 1. 선택 기준

{% hint style="success" %}
**이 경로가 맞는 경우**

* OpenAI Codex CLI를 사용한다.
* `codex` 명령을 실행하고 `~/.codex/config.toml`을 편집할 수 있다.
* gpt 계열과 partner/OSS 모델을 **하나의 provider**로 전환하며 쓰고 싶다.
* Responses API 기반 에이전트 워크플로가 필요하다.
{% endhint %}

## 2. 준비값

| 값                     | 예시                        |
| --------------------- | ------------------------- |
| APIM host             | `https://<apim-host>`     |
| APIM subscription key | `<APIM subscription key>` |
| APIM 경로               | `/responses`              |
| 인증 헤더                 | `Ocp-Apim-Subscription-Key` |

APIM subscription key는 환경 변수로 둡니다.

```bash
export GATEWAY_KEY="<APIM subscription key>"
```

{% hint style="warning" %}
APIM subscription key를 `config.toml`, dotfiles, Git 저장소에 평문으로 커밋하지 마세요. `config.toml`의 `env_key`는 **환경 변수 이름**만 담고, 실제 키는 환경 변수로 주입합니다.
{% endhint %}

## 3. 설정 파일

Codex global config는 `~/.codex/config.toml`에 둡니다.

```toml
model = "gpt-5.4"
model_provider = "aigateway"

[model_providers.aigateway]
name = "AI Gateway (Responses)"
base_url = "https://<apim-host>/responses"
env_key = "GATEWAY_KEY"
wire_api = "responses"
# Codex는 env_key를 Authorization: Bearer 로 보냅니다. APIM은 subscription key를
# Ocp-Apim-Subscription-Key 헤더로 받으므로 http_headers로 명시 전달합니다.
http_headers = { "Ocp-Apim-Subscription-Key" = "${GATEWAY_KEY}" }
```

{% hint style="info" %}
`wire_api`는 `"responses"`가 유일한 값입니다(Codex CLI는 chat completions wire 포맷을 더 이상 지원하지 않습니다). partner/OSS 모델은 게이트웨이의 LiteLLM 브리지가 내부적으로 `/chat/completions`로 변환하므로, Codex 쪽 설정은 모델과 무관하게 동일합니다.
{% endhint %}

{% hint style="info" %}
Azure OpenAI를 APIM 없이 직접 붙이는 경우 `base_url`은 `https://<resource>.openai.azure.com/openai`, `query_params = { api-version = "..." }`를 지정합니다. 이때 인증은 API key 대신 Entra ID를 권장합니다(`az login` 후 토큰). 다만 이 게이트웨이의 기본 경로는 위의 APIM `/responses`입니다.
{% endhint %}

## 4. 동작 방식

| 항목       | 값                                                      |
| -------- | ------------------------------------------------------ |
| base URL | `/responses` (LiteLLM 브리지)                            |
| 요청 경로    | Codex가 `base_url` + `/responses` 호출                    |
| APIM 인증  | `Ocp-Apim-Subscription-Key` 헤더                         |
| 라우팅      | LiteLLM이 모델별로 Responses passthrough 또는 chat 브리지 선택     |
| 모델 위치    | 요청 body `model` 필드                                     |

Codex가 보내는 요청은 항상 Responses 포맷입니다. gpt 계열은 backend가 Responses를 네이티브 지원하므로 그대로 전달되고, partner/OSS 모델은 LiteLLM이 Chat Completions로 변환해 backend에 전달합니다.

## 5. 모델별 지원 매트릭스

| 모델              | backend Responses 네이티브 | 게이트웨이 처리                    |
| --------------- | ----------------------- | --------------------------- |
| `gpt-5.4`       | ✅ 지원                    | LiteLLM passthrough (native) |
| `grok-4.3`      | ❌ 미지원                   | LiteLLM Responses→Chat 브리지  |
| `DeepSeek-V4-Pro` | ❌ 미지원                 | LiteLLM Responses→Chat 브리지  |

{% hint style="info" %}
Azure OpenAI Responses API는 gpt 계열(Azure OpenAI 모델)만 네이티브 지원합니다. Grok(xAI)·DeepSeek 등 partner/OSS 모델은 Model Inference의 Chat Completions만 지원하므로 브리지가 필요합니다. 새 partner/OSS 모델을 추가하면 기본적으로 브리지 대상입니다.
{% endhint %}

## 6. 모델 변경

`config.toml`의 `model`을 바꾸거나 실행 시 `--model`로 지정합니다.

```bash
codex --model grok-4.3
codex --model DeepSeek-V4-Pro
```

Admin UI에서 해당 consumer의 allowed models에 선택한 모델이 포함되어 있어야 합니다.

## 7. 검증

```bash
codex --model gpt-5.4 "Reply with the single word: pong"
```

native 모델(`gpt-5.4`)과 브리지 모델(`grok-4.3` 등)을 각각 한 번씩 실행해 두 경로 모두 응답하는지 확인합니다.

오류가 발생하면 아래를 확인합니다.

* `base_url`이 `/responses`로 끝나는지 (LiteLLM 브리지 배포 여부)
* `GATEWAY_KEY` 환경 변수가 올바른 APIM subscription key인지
* `http_headers`의 `Ocp-Apim-Subscription-Key`가 설정되어 있는지
* 선택한 모델이 consumer allowed models에 포함되어 있는지
* partner/OSS 모델 400 오류 → 브리지 미경유로 backend에 Responses가 직접 전달됐는지

| HTTP 상태 | 의미 |
|---|---|
| 401 | 인증 실패 |
| 403 | 구독 키 무효 또는 모델 미허용 |
| 404 | `/responses` 경로 미배포 (LiteLLM 브리지 확인) |
| 400 | Responses 미지원 모델이 브리지를 거치지 않음 |
| 429 | token rate limit 또는 quota 초과 |

## 8. 참고 링크

* [Codex CLI — Config reference](https://developers.openai.com/codex/config-reference)
* [LiteLLM — Responses API](https://docs.litellm.ai/docs/response_api)
* [Azure OpenAI — Responses API](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/responses)
* [Azure API Management — Subscriptions](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)
