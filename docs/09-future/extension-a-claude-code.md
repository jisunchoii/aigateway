---
description: 플랫폼 엔지니어·AI 도구 담당자를 위한 페이지 · 선행: 확장 개요
---

# 확장 A — Claude Code 입구

Claude Code는 Anthropic Messages API(`/v1/messages`) 형식으로만 통신합니다. 현재 llm-gateway의 입구(`/openai`, `/foundry`)는 OpenAI 호환 형식만 처리하므로, **Claude Code는 현재 이 게이트웨이에 직접 연결할 수 없습니다**. 이 확장은 신규 APIM API를 추가하여 Claude Code를 게이트웨이로 라우팅하는 방법을 설명합니다.

{% hint style="info" %}
이 확장은 현재 미구현 상태입니다. 신규 APIM API 추가가 필요하며 운영 환경에서 검증되지 않았습니다.
{% endhint %}

---

## 1. 현황 및 제약

***

| 항목 | 현재 상태 |
|---|---|
| Claude Code API 형식 | Anthropic Messages API `POST /v1/messages` |
| 현재 입구 | `/openai` (OpenAI path-route), `/foundry` (OpenAI body-route) |
| Claude Code 지원 여부 | **미지원** — 형식 불일치로 현재 입구에 연결 불가 |

---

## 2. 구현 방향

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

## 3. 구현 체크리스트

***

- [ ] Foundry 계정에 Claude 모델 배포 확인 (Azure AI Foundry 포털)
- [ ] `modules/apim`에 `anthropic` path APIM API 추가
- [ ] 백엔드 URL을 Foundry Claude `.../anthropic` 경로로 설정
- [ ] `llm-emit-token-metric` 정책에 `input_tokens`/`output_tokens` 매핑 추가
- [ ] `anthropic-version` / `anthropic-beta` 헤더 pass-through 확인
- [ ] consumerId·rate·budget 정책을 신규 API에 적용
- [ ] smoke test: `POST https://<apim-host>/anthropic/v1/messages`

---

## 4. 참고 문서

***

- [Claude Code llm-gateway 공식 문서](https://code.claude.com/docs/en/llm-gateway)
- [Claude Code llm-gateway 프로토콜 명세](https://code.claude.com/docs/en/llm-gateway-protocol)
- [Azure AI Foundry — Microsoft 파트너 모델](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/models-featured)
- [정책 흐름](../08-architecture/policy-flow.md) — 재사용하는 파이프라인 단계 상세
