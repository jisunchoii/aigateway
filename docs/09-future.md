---
description: "향후 지원 계획 — Entra ID 인증, Claude Code, Codex/Responses API"
---

# 향후 지원 계획

이 페이지는 아직 공식 온보딩 경로로 제공하지 않는 클라이언트와 인증 방식을 **지원 후보**로 정리합니다. 지금 지원하는 경로는 [클라이언트 온보딩](07-connect-clients.md)에 있고, 이 페이지는 다음에 제품화할 후보의 우선순위와 설계 기준을 설명합니다.

## 1. 지원 후보와 우선순위

| 후보 | 목적 | 현재 상태 | 우선순위 |
|---|---|---|---:|
| Entra ID 클라이언트 인증 | API key 없이 JWT로 consumer 식별 | Terraform/APIM 토글 구현 완료, 운영 검증 전 | 1 |
| Claude Code | Anthropic Messages API 클라이언트 연결 | 신규 APIM 경로 필요 | 2 |
| Codex + Responses API | Codex provider와 stateful Responses API 연결 | 신규 APIM 경로와 클라이언트 설정 검증 필요 | 2 |

우선순위는 **Entra ID 인증 운영화 → Claude Code 또는 Codex 중 수요가 큰 클라이언트 → 남은 클라이언트** 순서가 안전합니다. Entra ID 인증을 먼저 안정화하면 Claude Code와 Codex 모두 `Authorization: Bearer <token>` 기반 흐름으로 설계하기 쉬워집니다.

{% hint style="info" %}
Claude Code와 Codex는 서로 다른 문제입니다. Claude Code는 Anthropic Messages API(`/v1/messages`) 형식이고, Codex는 OpenAI provider 설정과 Responses API wire format 검증이 핵심입니다.
{% endhint %}

## 2. Entra ID 클라이언트 인증 운영화

이 항목은 신규 클라이언트 추가가 아니라, 이미 구현된 `client_auth_mode="entra-id"` 토글을 운영 가능한 상태로 검증하는 작업입니다.

| 항목 | 상태 |
|---|---|
| `client_auth_mode="entra-id"` 변수 | 구현 완료 |
| APIM `validate-jwt` 정책 | 구현 완료 |
| JWT claim 기반 consumerId 추출 | 구현 완료 |
| subscription key 미사용 모드 | 구현 완료 |
| 운영 환경 검증 | 필요 |

### consumerId claim 설계

`groups` claim은 대규모 조직에서 over-claim 문제가 생길 수 있으므로 consumerId 용도로 권장하지 않습니다. 단일 값을 안정적으로 담을 수 있는 방식을 선택하세요.

| 방식 | 설명 |
|---|---|
| Custom app role | 앱 등록에 역할 정의 → 사용자/그룹에 역할 할당 → JWT `roles` claim으로 수신 |
| Directory extension attribute | 사용자 속성에 consumerId 저장 → JWT에 해당 claim 포함 |

```text
client_auth_mode = "entra-id"
entra_tenant_id  = "<tenant-id>"
api_audience     = "api://<gateway-api-app-id>"
team_claim       = "roles"
```

### 운영 투입 체크리스트

| 확인 항목 | 기대 결과 |
|---|---|
| audience / issuer | APIM `validate-jwt`가 올바른 tenant와 app만 허용 |
| consumerId claim | 토큰에서 단일 consumerId 추출 |
| 무토큰 요청 | `401 Unauthorized` |
| 허용 모델 검사 | JWT consumerId 기준으로 `403`/허용 분기 정상 동작 |
| rate limit / budget | subscription key 없이도 consumer별 집계 정상 동작 |

## 3. Claude Code 지원 후보

Claude Code는 Anthropic Messages API 형식으로 요청합니다. 현재 gateway의 `/openai`, `/vscode/models`, `/foundry` 경로는 OpenAI Chat Completions 호환 형식이므로 Claude Code를 그대로 붙일 수 없습니다.

### 설계 방향

| 항목 | 방향 |
|---|---|
| 신규 APIM path | `/anthropic/v1/messages` |
| 백엔드 | Azure AI Foundry Claude 배포의 Anthropic Messages 엔드포인트 |
| 요청 형식 | `POST /v1/messages`, `anthropic-version` 헤더, `messages` body |
| 인증 | Entra ID Bearer 토큰 권장. subscription key 모드는 별도 헤더 처리 설계 필요 |
| 재사용 정책 | consumerId, allowed models, rate limit, budget, metric 파이프라인 |

```bash
export ANTHROPIC_BASE_URL="https://<apim-host>/anthropic"
export ANTHROPIC_AUTH_TOKEN="<entra-token-or-gateway-token>"
```

{% hint style="warning" %}
Claude Code는 일반적으로 `Authorization: Bearer <token>` 형태로 토큰을 보냅니다. 현재 subscription key 중심 경로처럼 `Ocp-Apim-Subscription-Key`를 기대하면 바로 호환되지 않을 수 있으므로, Entra ID 인증을 먼저 운영화하거나 Anthropic 경로의 인증 정책을 별도로 설계해야 합니다.
{% endhint %}

### 정책 변경 포인트

| 영역 | 필요한 변경 |
|---|---|
| APIM API | `anthropic` API와 `/v1/messages` operation 추가 |
| Header pass-through | `anthropic-version`, `anthropic-beta` 제거 금지 |
| Token metric | `usage.input_tokens`, `usage.output_tokens`를 기존 metric에 매핑 |
| Model governance | body의 `model` 값을 allowed models와 budget 정책에 연결 |
| Smoke test | Claude 모델 배포 기준으로 `POST /anthropic/v1/messages` 호출 |

## 4. Codex + Responses API 지원 후보

Codex 지원은 단순히 “OpenAI 호환 endpoint 하나 추가”로 끝나지 않습니다. Codex provider가 어떤 wire API와 인증 헤더를 쓰는지 확인하고, gateway가 Responses API를 통과시킬 수 있어야 합니다.

### 먼저 결정할 것

| 결정 | 선택지 | 기준 |
|---|---|---|
| Codex wire API | Chat Completions / Responses | Codex profile에서 사용할 `wire_api` |
| APIM 경로 | 기존 `/openai` 재사용 / 신규 `/openai/v1/responses` | Responses API를 쓰면 신규 path 필요 |
| 인증 헤더 | `Ocp-Apim-Subscription-Key` / `api-key` / Bearer JWT | Codex provider 설정과 Entra ID 적용 여부 |
| 지원 모델 | gpt 계열만 / partner 모델 포함 | Responses API는 gpt 계열 중심으로 먼저 검증 |
| 모델 전환 | response-capable 모델끼리만 전환 | budget 전환이 unsupported 모델로 떨어지면 실패 |

### Codex provider 설정 초안

아래는 Codex를 gateway에 붙일 때 검증할 수 있는 사용자 설정 예시입니다. 실제 키 이름과 provider 동작은 Codex 버전에 맞춰 확인해야 합니다.

```toml
# ~/.codex/config.toml
model = "gpt-5.4"
model_provider = "aigateway"

[model_providers.aigateway]
name = "AI Gateway APIM"
base_url = "https://<apim-host>/openai/v1"
wire_api = "responses"
env_http_headers = { "Ocp-Apim-Subscription-Key" = "AI_GATEWAY_API_KEY" }
```

{% hint style="info" %}
Codex는 custom provider에서 base URL, wire API, 추가 HTTP header를 설정할 수 있습니다. gateway 쪽에서는 Codex가 실제로 보내는 path, header, streaming 방식을 먼저 캡처한 뒤 APIM operation을 고정하는 편이 안전합니다.
{% endhint %}

### Responses API 경로 설계

Responses API는 Chat Completions와 body 구조가 다릅니다.

```jsonc
// 현재 Chat Completions
{
  "model": "gpt-5.4",
  "messages": [{"role": "user", "content": "Hello"}]
}

// Responses API
{
  "model": "gpt-5.4",
  "input": "Hello",
  "previous_response_id": "resp_abc123"
}
```

| 항목 | 설계 기준 |
|---|---|
| APIM path | `/openai/v1/responses` |
| 백엔드 | 동일 AIServices 계정의 `/openai/v1/responses` |
| Body 변환 | 가능하면 변환 없이 pass-through |
| Stateful 대화 | `previous_response_id`는 APIM이 저장하지 않고 백엔드로 전달 |
| Streaming | SSE 응답을 끊지 않고 pass-through |
| Tool calls | Codex agent payload를 수정하지 않고 전달 |
| Token metric | `usage.input_tokens`, `usage.output_tokens`, `usage.total_tokens` 매핑 |

### 모델 권한과 budget 정책 보강

Responses API 경로는 allowed models와 budget 정책을 그대로 재사용하되, 전환 후보를 더 엄격하게 제한해야 합니다.

| 정책 | 보강 내용 |
|---|---|
| Allowed models | Responses API를 지원하는 gpt 모델만 허용 |
| Budget model switch | 전환 사다리를 response-capable 모델로만 구성 |
| Partner/OSS 모델 | `/openai/v1/responses` 경로에서는 제외 |
| Stateful 세션 | `previous_response_id`가 있는 요청에서 모델 전환이 안전한지 별도 검증 |

{% hint style="warning" %}
Responses API 요청을 budget 정책으로 다른 모델에 전환할 때, 이전 응답 ID와 모델 호환성이 깨질 수 있습니다. `previous_response_id`가 있는 요청은 모델 전환을 금지하거나, 같은 모델 패밀리 안에서만 전환하도록 정책을 분리하는 것이 안전합니다.
{% endhint %}

### 구현 체크리스트

| 확인 항목 | 기대 결과 |
|---|---|
| Codex config | gateway base URL과 header로 요청 생성 |
| APIM operation | `/openai/v1/responses`가 backend까지 전달 |
| Auth | subscription key 또는 Entra ID 모드 중 하나로 인증 성공 |
| Governance | consumerId, allowed models, rate limit, budget 적용 |
| Streaming | Codex 실행 중 SSE stream이 중간에 끊기지 않음 |
| Metrics | input/output/total token metric 기록 |

## 5. 공통 완료 기준

새 지원 후보를 공식 온보딩 문서로 올리기 전에 아래 기준을 통과해야 합니다.

| 기준 | 완료 조건 |
|---|---|
| 배포 | Terraform module과 variables에 반영 |
| 보안 | subscription key 또는 Entra ID 인증 방식 명확화 |
| 정책 | allowed models, rate limit, budget, metric 모두 적용 |
| 관측 | Monitoring과 Application Insights에서 요청·차단·토큰 확인 |
| 문서 | 클라이언트 온보딩에 별도 페이지 추가 |
| 검증 | 실제 클라이언트로 smoke test 성공 |

## 6. 참고 문서

- [Claude Code llm-gateway](https://code.claude.com/docs/en/llm-gateway)
- [Claude Code gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol)
- [OpenAI Codex advanced configuration](https://developers.openai.com/codex/config-advanced)
- [Azure OpenAI Responses API](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/responses)
- [APIM validate-jwt 정책](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy)
