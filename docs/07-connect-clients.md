---
description: "개발 툴 연동 — VS Code BYOK, GitHub Copilot CLI, opencode, 직접 호출"
---

# 클라이언트 연동

이 장에서는 게이트웨이를 실제 AI 개발 도구와 연결하는 방법을 다룹니다. **클라이언트가 사용하는 API 형식에 따라 게이트웨이 입구(APIM API 경로)가 결정됩니다.**

- [1. 클라이언트 개요](#1-클라이언트-개요)
- [2. VS Code BYOK](#2-vs-code-byok)
- [3. GitHub Copilot CLI](#3-github-copilot-cli)
- [4. opencode](#4-opencode)
- [5. 직접 호출](#5-직접-호출)

## 1. 클라이언트 개요

***

### 1. 4가지 클라이언트 비교

***

| | GitHub Copilot (IDE) | GHCP CLI | opencode | Claude Code |
|---|---|---|---|---|
| API 형식 | OpenAI chat completions | OpenAI chat completions | OpenAI chat completions (`/v1/chat/completions`) | **Anthropic Messages** (`/v1/messages`) |
| base URL 변수 | — | `COPILOT_PROVIDER_BASE_URL` | `baseURL` | `ANTHROPIC_BASE_URL` / `ANTHROPIC_FOUNDRY_BASE_URL` |
| model 위치 | body | body (azure면 경로) | body | body |
| 이 게이트웨이 입구 | `/vscode/openai`·`/openai` | `/openai` | `/foundry` | ❌ 현재 미지원 (확장 A) |

{% hint style="info" %}
**Claude Code는 현재 이 게이트웨이에 직접 연결할 수 없습니다.** Claude Code는 Anthropic Messages API(`/v1/messages`)를 사용하지만, 이 게이트웨이는 현재 OpenAI 형식 입구만 지원합니다. 지원 계획은 [09-future.md](09-future.md)를 참조하세요.
{% endhint %}

### 2. 입구와 클라이언트의 관계

***

게이트웨이는 동일한 APIM 엔드포인트(`https://<apim-host>`)에 여러 API 경로를 노출합니다. 클라이언트의 API 형식에 맞는 경로를 선택해야 합니다.

| APIM 경로 | 클라이언트 | 라우팅 방식 |
|---|---|---|
| `/openai` | GHCP CLI (azure provider) | URL 경로에서 model 추출 → body에 주입 |
| `/vscode/openai` | VS Code BYOK | `Ocp-Apim-Subscription-Key` 헤더 + path-route |
| `/foundry` | opencode / 직접 호출 | body에 model 포함 (body-route) |

모든 클라이언트는 동일한 `consumerId` 단위로 집계됩니다. 인증 방식(구독 키 vs Entra ID)에 무관하게 같은 소비자로 처리됩니다.

### 3. 인증 방식

***

현재 기본 인증 방식은 **APIM 구독 키(`Ocp-Apim-Subscription-Key` 헤더)**입니다. 구독 키는 Admin UI의 Consumers 탭에서 발급합니다.

Entra ID 기반 클라이언트 인증(`client_auth_mode="entra-id"`)은 구현되어 있지만 운영 검증 전 단계이며, 확장 C로 분류됩니다. 상세는 [09-future.md](09-future.md)를 참조하세요.

### 4. 클라이언트별 설정 가이드

***

- [VS Code BYOK](#2-vs-code-byok)
- [GitHub Copilot CLI](#3-github-copilot-cli)
- [opencode](#4-opencode)
- [직접 호출 (curl)](#5-직접-호출)

### 5. 참고 링크

***

- [GitHub Copilot CLI 문서](https://docs.github.com/en/copilot/concepts/agents/about-copilot-cli)
- [opencode 문서](https://opencode.ai/docs/providers/)
- [Claude Code LLM Gateway 문서](https://code.claude.com/docs/en/llm-gateway) (미지원, 확장 A 참조)
- [Claude Code LLM Gateway Protocol](https://code.claude.com/docs/en/llm-gateway-protocol) (미지원, 확장 A 참조)

## 2. VS Code BYOK

***

VS Code의 **chatLanguageModels.json** 설정 파일에 APIM 게이트웨이를 AI 모델 제공자로 등록합니다. `/vscode/openai` 경로를 사용하며, APIM 구독 키를 `Ocp-Apim-Subscription-Key` 헤더로 전달합니다.

---

### 1. 사전 준비

***

- VS Code 최신 버전
- Admin UI에서 발급한 APIM 구독 키 (`<APIM subscription key>`)
- `terraform output -raw apim_gateway_url` 로 확인한 APIM 호스트 (`<apim-host>`)

### 2. chatLanguageModels.json 설정

***

VS Code 설정 파일(`chatLanguageModels.json`)에 아래 엔트리를 추가합니다. 모델 4개를 각각 1개씩 등록합니다.

```json
[
  {
    "id": "gpt-5.4",
    "name": "GPT-5.4 via APIM",
    "url": "https://<apim-host>/vscode/openai/deployments/gpt-5.4/chat/completions?api-version=2025-01-01-preview",
    "toolCalling": true, "vision": false,
    "maxInputTokens": 128000, "maxOutputTokens": 16000,
    "requestHeaders": { "Ocp-Apim-Subscription-Key": "<APIM subscription key>" }
  },
  {
    "id": "gpt-5.4-mini",
    "name": "GPT-5.4 Mini via APIM",
    "url": "https://<apim-host>/vscode/openai/deployments/gpt-5.4-mini/chat/completions?api-version=2025-01-01-preview",
    "toolCalling": true, "vision": false,
    "maxInputTokens": 128000, "maxOutputTokens": 16000,
    "requestHeaders": { "Ocp-Apim-Subscription-Key": "<APIM subscription key>" }
  },
  {
    "id": "grok-4.3",
    "name": "Grok 4.3 via APIM",
    "url": "https://<apim-host>/vscode/openai/deployments/grok-4.3/chat/completions?api-version=2025-01-01-preview",
    "toolCalling": false, "vision": false,
    "maxInputTokens": 128000, "maxOutputTokens": 16000,
    "requestHeaders": { "Ocp-Apim-Subscription-Key": "<APIM subscription key>" }
  },
  {
    "id": "DeepSeek-V4-Pro",
    "name": "DeepSeek V4 Pro via APIM",
    "url": "https://<apim-host>/vscode/openai/deployments/DeepSeek-V4-Pro/chat/completions?api-version=2025-01-01-preview",
    "toolCalling": false, "vision": false,
    "maxInputTokens": 128000, "maxOutputTokens": 16000,
    "requestHeaders": { "Ocp-Apim-Subscription-Key": "<APIM subscription key>" }
  }
]
```

{% hint style="info" %}
`<apim-host>` 와 `<APIM subscription key>` 를 실제 값으로 교체하세요. 구독 키는 소스 코드나 버전 관리 시스템에 커밋하지 마세요.
{% endhint %}

### 3. 경로 설명

***

- `/vscode/openai` 경로는 APIM 내부에서 VS Code BYOK 전용 입구입니다.
- URL 경로에 포함된 모델명(`/deployments/gpt-5.4`)을 APIM 정책이 추출하여 요청 body의 `model` 필드에 주입합니다.
- `api-version=2025-01-01-preview` 는 APIM 정책 처리에 필요한 파라미터입니다.

### 4. 연결 확인

***

설정 완료 후 VS Code의 GitHub Copilot Chat 또는 커스텀 LLM 채팅 패널에서 모델 목록에 등록한 모델이 표시되는지 확인합니다. 연결이 되지 않는 경우:

#### Step 1. 구독 키가 올바른지 Admin UI에서 재확인합니다.

#### Step 2. `<apim-host>` 에 `https://` 가 포함되어 있는지 확인합니다.

#### Step 3. `apim_public = true` 인지 확인합니다. Internal 모드라면 VPN 또는 VNet 연결이 필요합니다.

#### Step 4. 오류 코드 의미는 [10-reference.md](10-reference.md)를 참조하세요.

### 5. 참고 링크

***

- [VS Code — Language Model API (BYOK)](https://code.visualstudio.com/docs/copilot/language-models)
- [Azure API Management — 구독 키](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)

## 3. GitHub Copilot CLI

***

GHCP CLI를 Azure provider 모드로 설정하여 게이트웨이를 통해 모델을 호출합니다. 환경 변수 `COPILOT_PROVIDER_*` 블록으로 구성하며, `/openai` 경로를 사용합니다.

---

### 1. 사전 준비

***

- GitHub Copilot CLI 최신 버전 설치
- Admin UI에서 발급한 APIM 구독 키 (`<APIM subscription key>`)
- `terraform output -raw apim_gateway_url` 로 확인한 APIM 호스트 (`<apim-host>`)

### 2. 환경 변수 설정

***

터미널에서 다음 환경 변수를 설정합니다.

```bash
export COPILOT_PROVIDER_TYPE=azure
export COPILOT_PROVIDER_BASE_URL=https://<apim-host>
export COPILOT_PROVIDER_API_KEY="<APIM subscription key>"
export COPILOT_PROVIDER_AZURE_API_VERSION=2025-01-01-preview
export COPILOT_PROVIDER_WIRE_API=completions
export COPILOT_PROVIDER_MODEL_ID=gpt-5.4
export COPILOT_PROVIDER_WIRE_MODEL=gpt-5.4
```

{% hint style="warning" %}
`COPILOT_PROVIDER_BASE_URL` 에 `/openai` 를 포함하지 마세요. CLI가 azure provider 모드에서 경로를 자동으로 구성합니다. 예를 들어 `https://<apim-host>/openai` 로 설정하면 경로가 중복되어 요청이 실패합니다.
{% endhint %}

### 3. 동작 방식

***

- CLI가 azure provider 모드일 때 내부적으로 `<COPILOT_PROVIDER_BASE_URL>/openai/deployments/<model>/chat/completions?api-version=<version>` 형태로 URL을 조립합니다.
- APIM은 `/openai` 경로에서 URL 내 모델명을 추출하여 요청 body의 `model` 필드에 주입한 뒤 백엔드로 전달합니다.
- `COPILOT_PROVIDER_API_KEY` 는 APIM의 `Ocp-Apim-Subscription-Key` 헤더로 전달됩니다.

### 4. 모델 변경

***

다른 모델을 사용하려면 `COPILOT_PROVIDER_MODEL_ID` 와 `COPILOT_PROVIDER_WIRE_MODEL` 을 함께 변경합니다.

```bash
export COPILOT_PROVIDER_MODEL_ID=gpt-5.4-mini
export COPILOT_PROVIDER_WIRE_MODEL=gpt-5.4-mini
```

Admin UI에서 해당 소비자의 허용 모델 목록에 변경할 모델이 포함되어 있는지 확인하세요.

### 5. 연결 확인

***

환경 변수 설정 후 GHCP CLI를 사용하여 간단한 쿼리를 실행합니다.

```bash
gh copilot explain "git rebase"
```

오류가 발생하는 경우:

#### Step 1. `COPILOT_PROVIDER_BASE_URL` 에 `/openai` 가 포함되어 있지 않은지 확인합니다.

#### Step 2. 구독 키가 유효한지 Admin UI에서 재확인합니다.

#### Step 3. 오류 코드 의미는 [10-reference.md](10-reference.md)를 참조하세요.

### 6. 참고 링크

***

- [GitHub Copilot CLI — About Copilot CLI](https://docs.github.com/en/copilot/concepts/agents/about-copilot-cli)
- [Azure API Management — 구독 키](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)

## 4. opencode

***

opencode는 `@ai-sdk/openai-compatible` 어댑터를 사용하며, `/foundry` 경로로 게이트웨이에 연결합니다. `opencode.json` 의 provider 블록에 APIM 호스트와 구독 키를 설정합니다.

---

### 1. 사전 준비

***

- opencode 최신 버전 설치
- Admin UI에서 발급한 APIM 구독 키
- `terraform output -raw apim_gateway_url` 로 확인한 APIM 호스트 (`<apim-host>`)
- 환경 변수 `APIM_KEY` 에 구독 키 설정

```bash
export APIM_KEY="<APIM subscription key>"
```

### 2. opencode.json 설정

***

프로젝트 루트 또는 홈 디렉터리의 `opencode.json` 에 다음 provider 블록을 추가합니다.

```json
{ "provider": { "apim": {
  "npm": "@ai-sdk/openai-compatible",
  "options": { "baseURL": "https://<apim-host>/foundry", "apiKey": "{env:APIM_KEY}" },
  "models": { "grok-4.3": { "name": "Grok 4.3" } }
}}}
```

{% hint style="info" %}
`<apim-host>` 를 실제 APIM 호스트명으로 교체하세요. `apiKey` 는 `{env:APIM_KEY}` 형식으로 환경 변수를 참조하므로, 구독 키를 설정 파일에 직접 기입하지 않아도 됩니다.
{% endhint %}

### 3. 동작 방식

***

- opencode는 `@ai-sdk/openai-compatible` 어댑터를 통해 OpenAI chat completions 형식의 요청을 보냅니다.
- `baseURL` 이 `/foundry` 로 끝나므로 실제 요청은 `POST https://<apim-host>/foundry/chat/completions` 형태가 됩니다.
- APIM의 `/foundry` 입구는 body에 포함된 `model` 필드를 그대로 사용합니다 (body-route).
- `apiKey` 는 `Ocp-Apim-Subscription-Key` 헤더로 전달됩니다.

### 4. 모델 추가

***

`models` 객체에 다른 모델 엔트리를 추가하면 opencode UI에서 선택할 수 있습니다.

```json
"models": {
  "grok-4.3": { "name": "Grok 4.3" },
  "DeepSeek-V4-Pro": { "name": "DeepSeek V4 Pro" },
  "gpt-5.4": { "name": "GPT-5.4" },
  "gpt-5.4-mini": { "name": "GPT-5.4 Mini" }
}
```

Admin UI에서 해당 소비자의 허용 모델 목록에 추가할 모델이 포함되어 있는지 확인하세요.

### 5. 연결 확인

***

opencode를 실행하고 provider 목록에서 `apim` 이 표시되는지 확인합니다. 오류가 발생하는 경우:

#### Step 1. `APIM_KEY` 환경 변수가 설정되어 있는지 확인합니다.

#### Step 2. `baseURL` 에 `/foundry` 가 포함되어 있는지 확인합니다.

#### Step 3. 오류 코드 의미는 [10-reference.md](10-reference.md)를 참조하세요.

### 6. 참고 링크

***

- [opencode — Providers 문서](https://opencode.ai/docs/providers/)
- [Azure API Management — 구독 키](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)

## 5. 직접 호출

***

APIM 게이트웨이를 curl이나 REST 클라이언트로 직접 호출합니다. `/foundry` 경로를 사용하며, 요청 body에 `model` 을 포함하고 `Ocp-Apim-Subscription-Key` 헤더로 구독 키를 전달합니다.

---

### 1. 기본 호출 형식

***

```bash
curl -s -X POST https://<apim-host>/foundry/chat/completions \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: <APIM subscription key>" \
  -d '{
    "model": "gpt-5.4",
    "messages": [
      { "role": "user", "content": "Hello, how are you?" }
    ]
  }'
```

{% hint style="info" %}
`<apim-host>` 는 `terraform output -raw apim_gateway_url` 로 확인합니다. `<APIM subscription key>` 는 Admin UI의 Consumers 탭에서 발급합니다.
{% endhint %}

### 2. OSS/파트너 모델 호출

***

`model` 필드에 Foundry에 배포된 모델명을 그대로 넣으면 됩니다.

```bash
curl -s -X POST https://<apim-host>/foundry/chat/completions \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: <APIM subscription key>" \
  -d '{
    "model": "grok-4.3",
    "messages": [
      { "role": "user", "content": "Explain quantum entanglement briefly." }
    ],
    "max_completion_tokens": 200
  }'
```

### 3. 응답 확인

***

정상 응답은 HTTP 200이며, OpenAI chat completions 형식의 JSON이 반환됩니다.

모델 전환이 발생한 경우 응답 헤더에서 확인할 수 있습니다.

```bash
curl -s -i -X POST https://<apim-host>/foundry/chat/completions \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: <APIM subscription key>" \
  -d '{ "model": "gpt-5.4", "messages": [{"role":"user","content":"Hi"}] }' \
  | grep -E "x-ai-gateway"
```

| 헤더 | 설명 |
|---|---|
| `x-ai-gateway-requested-model` | 요청한 모델 |
| `x-ai-gateway-effective-model` | 실제 사용된 모델 |
| `x-ai-gateway-downgrade-level` | 모델 전환 단계 (0=없음, 1=80%, 2=100%) |

### 4. 오류 응답 의미

***

| HTTP 상태 | 의미 |
|---|---|
| 403 Forbidden | 구독 키가 없거나 유효하지 않음, 또는 해당 모델이 소비자 허용 목록에 없음 |
| 429 Too Many Requests | 토큰 레이트 리밋 또는 일별 쿼터 초과 |
| 401 Unauthorized | 인증 실패 |
| 500 / 502 | 백엔드 오류 |

{% hint style="info" %}
403은 구독 키 문제이거나 해당 소비자에게 모델 사용 권한이 없는 경우이고, 429는 레이트 리밋 또는 일별 쿼터 초과입니다. 상세 원인과 해결 방법은 [10-reference.md](10-reference.md)를 참조하세요.
{% endhint %}

### 5. 스모크 테스트 스크립트

***

여러 모델을 한꺼번에 확인하려면 제공된 스모크 테스트 스크립트를 사용합니다.

```bash
./scripts/smoke-v1-gateway.sh <apim-host> <subscription-key>
```

이 스크립트는 gpt-5.4(`/openai` 경로), grok-4.3, DeepSeek-V4-Pro(`/foundry` 경로)에 각각 HTTP 200 응답을 확인합니다. 상세는 [05-verify.md](05-verify.md)를 참조하세요.

### 6. 참고 링크

***

- [Azure API Management — 게이트웨이 요청 처리](https://learn.microsoft.com/en-us/azure/api-management/api-management-key-concepts)
- [Azure API Management — 구독 키](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)
