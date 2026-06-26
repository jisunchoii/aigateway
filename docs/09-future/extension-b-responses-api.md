---
description: 플랫폼 엔지니어를 위한 페이지 · 선행: 확장 개요
---

# 확장 B — Responses API

Responses API는 Azure OpenAI(gpt 계열)가 제공하는 stateful 대화 API다. 클라이언트가 `previous_response_id`를 통해 이전 응답을 참조하면 서버 측에서 대화 상태를 관리한다. 현재 llm-gateway에 연결된 클라이언트(VS Code BYOK, GitHub Copilot CLI, opencode)는 이 형식을 보내지 않으므로 현재는 미구현 상태다.

{% hint style="info" %}
이 확장은 현재 미구현 상태다. 연결된 클라이언트 중 Responses API 형식을 사용하는 클라이언트가 생긴 뒤에 구현을 진행한다.
{% endhint %}

---

## Responses API 특성 및 현황

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

## 구현 방향

### 1. 신규 APIM 입구 추가

| 항목 | 값 |
|---|---|
| 신규 입구 경로 | `/openai/v1/responses` |
| 백엔드 | 기존 동일 v1 백엔드 (`/openai/v1`) |
| 라우팅 방식 | `/responses` 엔드포인트를 백엔드로 그대로 전달 |

백엔드 URL 자체는 기존 v1 통일 구조를 유지한다. 신규 입구는 `/openai/v1/responses`를 받아 동일 AIServices 계정의 `/openai/v1/responses`로 전달한다.

### 2. Stateful 요청 처리

`previous_response_id`를 포함한 stateful 요청은 변환 없이 백엔드로 통과한다. 대화 상태는 Azure OpenAI 서비스가 서버 측에서 관리하며(30일 보존), APIM 정책은 상태를 건드리지 않는다.

### 3. 기존 정책 재사용

consumerId 도출, allowed-models 검사, rate limit, 예산 모델 전환, 관리 ID 인증 정책은 기존 파이프라인을 그대로 재사용할 수 있다. 단, `model` 필드 위치가 동일하므로 body rewrite 정책도 수정 없이 동작한다.

---

## 구현 전 확인 사항

- 연결된 클라이언트 중 Responses API 형식을 사용하는 클라이언트가 생기면 구현을 진행한다
- gpt-5.4 계열 배포에 Responses API가 활성화되어 있는지 Azure 포털에서 확인
- `previous_response_id` 기반 stateful 세션의 APIM 정책 pass-through 동작 검증

---

## 참고 문서

- [Azure OpenAI Responses API 사용 방법](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/responses)
- [Azure OpenAI API 버전 수명 주기](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/api-version-lifecycle)
- [정책 흐름](../08-architecture/policy-flow.md) — 재사용하는 파이프라인 단계 상세
- [확장 개요](overview.md) — 권장 구현 순서 (C → A → B)
