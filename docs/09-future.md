---
description: "향후 확장 — Claude Code(Anthropic Messages), Responses API, Entra ID 클라이언트 인증 (권장 순서 C→A→B)"
---

# 향후 확장

현재 llm-gateway는 OpenAI 호환 클라이언트(VS Code BYOK, GitHub Copilot CLI, opencode, 직접 curl)를 지원합니다. 아래 세 가지 확장은 현재 코드베이스에 이미 일부 구현되어 있거나, 인프라를 최소한으로 추가해 활성화할 수 있는 항목들입니다.

- [1. 확장 개요](#1-확장-개요)
- [2. 확장 A — Claude Code 입구](#2-확장-a--claude-code-입구)
- [3. 확장 B — Responses API](#3-확장-b--responses-api)
- [4. 확장 C — Entra ID 클라이언트 인증](#4-확장-c--entra-id-클라이언트-인증-구독-키-미사용)

권장 구현 순서: **C → A → B** (아래 [1. 확장 개요](#1-확장-개요) 참조)

## 1. 확장 개요

***

### 1. 세 가지 확장 요약

***

| 확장 | 설명 | 구현 상태 |
|---|---|---|
| **C — Entra ID 클라이언트 인증** | 구독 키 없이 Entra ID 토큰으로 클라이언트 인증 | 토글 구현 완료, 운영 검증 전 |
| **A — Claude Code 입구** | Anthropic Messages API(`/v1/messages`) 신규 APIM 입구 추가 | 미구현 (신규 APIM API 필요) |
| **B — Responses API** | gpt 전용 stateful Responses API 입구 추가 | 미구현 (신규 입구 필요) |

---

### 2. 권장 구현 순서: **C → A → B**

***

세 확장의 권장 구현 순서는 **C → A → B**입니다.

1. **C를 먼저**: `client_auth_mode="entra-id"` 토글이 이미 구현되어 있습니다. production 권고 사항(consumerId 설계 개선)만 적용하면 운영에 투입할 수 있습니다. 이미 있는 기능을 완성하는 것이므로 리스크가 가장 낮습니다.

2. **A를 다음으로**: Claude Code를 게이트웨이에 연결하려는 수요가 큽니다. 신규 APIM API를 추가해야 하지만, 기존 consumerId·rate·budget·metric 파이프라인을 그대로 재사용할 수 있어 개발 범위가 명확합니다.

3. **B를 마지막으로**: Responses API는 현재 연동된 클라이언트가 보내지 않는 형식입니다. 클라이언트 측 준비가 완료된 뒤에 구현해도 늦지 않습니다.

각 확장 상세는 아래 [4. 확장 C — Entra ID 클라이언트 인증](#4-확장-c--entra-id-클라이언트-인증-구독-키-미사용), [2. 확장 A — Claude Code 입구](#2-확장-a--claude-code-입구), [3. 확장 B — Responses API](#3-확장-b--responses-api) 절을 참조하세요.

## 2. 확장 A — Claude Code 입구

***

Claude Code는 Anthropic Messages API(`/v1/messages`) 형식으로만 통신합니다. 현재 llm-gateway의 입구(`/openai`, `/foundry`)는 OpenAI 호환 형식만 처리하므로, **Claude Code는 현재 이 게이트웨이에 직접 연결할 수 없습니다**. 이 확장은 신규 APIM API를 추가하여 Claude Code를 게이트웨이로 라우팅하는 방법을 설명합니다.

{% hint style="info" %}
이 확장은 현재 미구현 상태입니다. 신규 APIM API 추가가 필요하며 운영 환경에서 검증되지 않았습니다.
{% endhint %}

---

### 1. 현황 및 제약

***

| 항목 | 현재 상태 |
|---|---|
| Claude Code API 형식 | Anthropic Messages API `POST /v1/messages` |
| 현재 입구 | `/openai` (OpenAI path-route), `/foundry` (OpenAI body-route) |
| Claude Code 지원 여부 | **미지원** — 형식 불일치로 현재 입구에 연결 불가 |

---

### 2. 구현 방향

***

#### Step 1. 신규 APIM API 추가

| 항목 | 값 |
|---|---|
| APIM API path | `anthropic` |
| 백엔드 엔드포인트 | Foundry Claude 배포의 `.../anthropic` 경로 |
| 클라이언트 요청 형식 | `POST https://<apim-host>/anthropic/v1/messages` |

Azure AI Foundry는 Claude 모델에 대해 Anthropic Messages API 호환 엔드포인트(`.../anthropic`)를 제공합니다. 신규 APIM API는 이 경로를 백엔드로 지정합니다.

아래는 Claude Code가 게이트웨이로 전송하는 요청 형식입니다.

```jsonc
// Claude Code → APIM /anthropic/v1/messages
POST https://<apim-host>/anthropic/v1/messages
anthropic-version: 2023-06-01
Authorization: Bearer <APIM subscription key>

{
  "model": "claude-sonnet-4-5",
  "max_tokens": 1024,
  "messages": [{"role": "user", "content": "Hello"}]
}
```

#### Step 2. 클라이언트 설정

Claude Code 클라이언트에 아래 환경 변수를 설정합니다.

```bash
export ANTHROPIC_BASE_URL=https://<apim-host>
export ANTHROPIC_AUTH_TOKEN=<APIM subscription key>
```

`ANTHROPIC_BASE_URL`을 게이트웨이 호스트로 지정하면 Claude Code가 APIM을 통해 백엔드에 도달합니다. 구독 키는 `ANTHROPIC_AUTH_TOKEN`으로 전달됩니다.

Claude Code llm-gateway 연동 공식 문서: [https://code.claude.com/docs/en/llm-gateway](https://code.claude.com/docs/en/llm-gateway) · [https://code.claude.com/docs/en/llm-gateway-protocol](https://code.claude.com/docs/en/llm-gateway-protocol)

#### Step 3. 기존 파이프라인 재사용

consumerId 도출, 토큰 rate limit, 예산 모델 전환, 관리 ID 백엔드 인증은 OpenAI 입구와 동일한 정책을 재사용할 수 있습니다.

단, **토큰 메트릭 정책**은 수정이 필요합니다. Anthropic Messages API의 사용량 스키마는 OpenAI와 다릅니다.

| API | 사용량 필드 |
|---|---|
| OpenAI Chat Completions | `usage.prompt_tokens` / `usage.completion_tokens` |
| Anthropic Messages | `usage.input_tokens` / `usage.output_tokens` |

`llm-emit-token-metric` 정책에서 응답 body의 `usage.input_tokens`와 `usage.output_tokens`를 읽도록 매핑을 추가해야 합니다.

#### Step 4. 헤더 처리 주의 사항

Anthropic Messages API는 요청에 아래 헤더를 사용합니다.

| 헤더 | 역할 |
|---|---|
| `anthropic-version` | API 버전 지정 (예: `2023-06-01`) |
| `anthropic-beta` | 베타 기능 활성화 |

{% hint style="warning" %}
`anthropic-version` 및 `anthropic-beta` 헤더를 APIM 정책에서 제거(strip)해서는 안 됩니다. 백엔드로 그대로 전달해야 Claude 모델이 올바르게 동작합니다.
{% endhint %}

---

### 3. 구현 체크리스트

***

- [ ] Foundry 계정에 Claude 모델 배포 확인 (Azure AI Foundry 포털)
- [ ] `modules/apim`에 `anthropic` path APIM API 추가
- [ ] 백엔드 URL을 Foundry Claude `.../anthropic` 경로로 설정
- [ ] `llm-emit-token-metric` 정책에 `input_tokens`/`output_tokens` 매핑 추가
- [ ] `anthropic-version` / `anthropic-beta` 헤더 pass-through 확인
- [ ] consumerId·rate·budget 정책을 신규 API에 적용
- [ ] smoke test: `POST https://<apim-host>/anthropic/v1/messages`

---

### 4. 참고 문서

***

- [Claude Code llm-gateway 공식 문서](https://code.claude.com/docs/en/llm-gateway)
- [Claude Code llm-gateway 프로토콜 명세](https://code.claude.com/docs/en/llm-gateway-protocol)
- [Azure AI Foundry — Microsoft 파트너 모델](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/models-featured)
- [정책 흐름](08-architecture.md) — 재사용하는 파이프라인 단계 상세

## 3. 확장 B — Responses API

***

Responses API는 Azure OpenAI(gpt 계열)가 제공하는 stateful 대화 API입니다. 클라이언트가 `previous_response_id`를 통해 이전 응답을 참조하면 서버 측에서 대화 상태를 관리합니다. 현재 llm-gateway에 연결된 클라이언트(VS Code BYOK, GitHub Copilot CLI, opencode)는 이 형식을 보내지 않으므로 현재는 미구현 상태입니다.

{% hint style="info" %}
이 확장은 현재 미구현 상태입니다. 연결된 클라이언트 중 Responses API 형식을 사용하는 클라이언트가 생긴 뒤에 구현을 진행합니다.
{% endhint %}

---

### 1. Responses API 특성 및 현황

***

| 항목 | 설명 |
|---|---|
| 지원 모델 | gpt 계열 전용 (OSS 파트너 모델 미지원) |
| 요청 형식 | `input` 필드 사용 (Chat Completions의 `messages`와 다름) |
| 상태 관리 | `previous_response_id`로 이전 응답 참조, 30일 저장 |
| 현재 클라이언트 지원 | 연결된 클라이언트 중 Responses API 형식을 보내는 클라이언트 없음 |
| OSS 미지원 | grok-4.3, DeepSeek-V4-Pro 등 파트너 모델은 지원 안 함 |

Chat Completions와 Responses API의 요청 body 구조 차이:

```jsonc
// Chat Completions (현재 지원)
{
  "model": "gpt-5.4",
  "messages": [{"role": "user", "content": "Hello"}]
}

// Responses API (확장 B)
{
  "model": "gpt-5.4",
  "input": "Hello",
  "previous_response_id": "resp_abc123"  // optional, stateful
}
```

---

### 2. 구현 방향

***

#### Step 1. 신규 APIM 입구 추가

| 항목 | 값 |
|---|---|
| 신규 입구 경로 | `/openai/v1/responses` |
| 백엔드 | 기존 동일 v1 백엔드 (`/openai/v1`) |
| 라우팅 방식 | `/responses` 엔드포인트를 백엔드로 그대로 전달 |

백엔드 URL 자체는 기존 v1 통일 구조를 유지합니다. 신규 입구는 `/openai/v1/responses`를 받아 동일 AIServices 계정의 `/openai/v1/responses`로 전달합니다.

#### Step 2. Stateful 요청 처리

`previous_response_id`를 포함한 stateful 요청은 변환 없이 백엔드로 통과합니다. 대화 상태는 Azure OpenAI 서비스가 서버 측에서 관리하며(30일 보존), APIM 정책은 상태를 건드리지 않습니다.

#### Step 3. 기존 정책 재사용

consumerId 도출, allowed-models 검사, rate limit, 예산 모델 전환, 관리 ID 인증 정책은 기존 파이프라인을 그대로 재사용할 수 있습니다. `model` 필드 위치가 동일하므로 body rewrite 정책도 수정 없이 동작합니다.

---

### 3. 구현 전 확인 사항

***

- 연결된 클라이언트 중 Responses API 형식을 사용하는 클라이언트가 생기면 구현을 진행합니다
- gpt-5.4 계열 배포에 Responses API가 활성화되어 있는지 Azure 포털에서 확인합니다
- `previous_response_id` 기반 stateful 세션의 APIM 정책 pass-through 동작을 검증합니다

---

### 4. 참고 문서

***

- [Azure OpenAI Responses API 사용 방법](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/responses)
- [Azure OpenAI API 버전 수명 주기](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/api-version-lifecycle)
- [정책 흐름](08-architecture.md) — 재사용하는 파이프라인 단계 상세

## 4. 확장 C — Entra ID 클라이언트 인증 (구독 키 미사용)

***

이 확장은 **이미 코드에 구현되어 있습니다**. `client_auth_mode="entra-id"` 변수 토글로 활성화할 수 있으며, APIM 정책이 구독 키 대신 JWT(Entra ID 토큰)로 클라이언트를 인증합니다. 운영 환경 검증이 완료되지 않아 확장 항목으로 분류합니다.

{% hint style="info" %}
토글 구현은 완료되어 있으나 운영 환경 검증 전입니다. 아래 체크리스트를 완료한 뒤 운영에 투입합니다.
{% endhint %}

---

### 1. 현재 구현 상태

***

| 항목 | 상태 |
|---|---|
| `client_auth_mode="entra-id"` 토글 | 구현 완료 |
| `validate-jwt` 정책 | 구현 완료 |
| consumerId = JWT claim 추출 | 구현 완료 |
| `subscription_required=false` | 구현 완료 |
| 운영 환경 검증 | **미완료** |

---

### 2. 동작 방식

***

`client_auth_mode="entra-id"`로 설정하면 APIM inbound 정책이 아래와 같이 바뀝니다.

#### Step 1. JWT 검증

`validate-jwt` 정책이 `Authorization: Bearer <token>` 헤더를 검증합니다.

#### Step 2. consumerId 추출

JWT의 지정된 claim 값을 `consumerId`로 추출합니다.

#### Step 3. 거버넌스 파이프라인 통과

이후 allowed-models 검사, rate limit, 예산 모델 전환 등 모든 거버넌스 파이프라인은 동일하게 동작합니다.

구독 키 검증이 없으므로 `subscription_required=false`로 설정해야 합니다.

([APIM validate-jwt 정책 공식 문서](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy))

---

### 3. consumerId 설계 — 권고 사항

***

`client_auth_mode="entra-id"` 모드에서 consumerId를 어떤 JWT claim에서 가져올지는 중요한 설계 결정입니다.

#### groups claim 사용의 문제점

Azure Entra ID는 사용자가 속한 그룹을 JWT `groups` claim에 포함합니다. 그러나 이 방식에는 한계가 있습니다.

- `groups` claim에는 **GUID**가 들어옵니다 (사람이 읽기 어려움)

{% hint style="warning" %}
사용자가 **150개 초과** 그룹에 속해 있으면 `groups` claim이 누락되고 Graph API 조회 링크로 대체됩니다 (over-claim 문제). consumerId 추출이 실패하므로 대규모 조직에서 `groups` claim에 의존하면 안 됩니다.
{% endhint %}

#### 권고: custom app-role 또는 extension attribute

consumerId로 사용할 단일 값을 명시적으로 표현하려면 아래 방법 중 하나를 권장합니다.

| 방법 | 설명 |
|---|---|
| **Custom app-role** | BFF API 앱 등록에 app-role 정의 → 사용자/그룹에 역할 할당 → JWT `roles` claim으로 수신 |
| **Extension attribute** | `user.extension_<appId>_consumerId` 형태로 디렉터리 확장 속성 정의 → JWT에 포함 |

두 방법 모두 단일 값으로 consumerId를 명확히 표현할 수 있고, groups over-claim 문제를 피할 수 있습니다.

([Azure Entra ID app roles 공식 문서](https://learn.microsoft.com/en-us/entra/identity-platform/howto-add-app-roles-in-apps))

---

### 4. 설정 예시

***

```hcl
# infra/terraform.tfvars
client_auth_mode = "entra-id"
entra_tenant_id  = "<your-tenant-id>"
api_audience     = "api://<bff-app-id>"
team_claim       = "roles"   # 또는 extension attribute 이름
```

`team_claim` 변수가 consumerId를 추출할 JWT claim 이름을 지정합니다.

---

### 5. 운영 투입 전 체크리스트

***

- [ ] BFF API 앱 등록에 app-role 또는 extension attribute 정의
- [ ] 테스트 사용자/서비스 주체에 역할 할당 후 JWT claim 포함 여부 확인
- [ ] `validate-jwt` 정책의 audience, issuer, claim 추출 동작 검증
- [ ] `subscription_required=false` 상태에서 무인증 요청이 401로 차단되는지 확인
- [ ] rate limit, allowed-models 검사가 JWT 기반 consumerId로 정상 동작하는지 smoke test

---

### 6. 참고 문서

***

- [APIM validate-jwt 정책](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy)
- [Azure Entra ID app roles 설정 방법](https://learn.microsoft.com/en-us/entra/identity-platform/howto-add-app-roles-in-apps)
- [정책 흐름](08-architecture.md) — consumerId 도출 단계 상세
- [보안 설계](08-architecture.md) — 전체 passwordless 아키텍처
