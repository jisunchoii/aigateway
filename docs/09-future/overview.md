> 읽는 사람: 아키텍트·플랫폼 엔지니어 · 선행: [클라이언트 개요](../07-connect-clients/overview.md)

# 향후 확장 개요

현재 llm-gateway는 OpenAI 호환 클라이언트(VS Code BYOK, GitHub Copilot CLI, opencode, 직접 curl)를 지원한다. 아래 세 가지 확장은 현재 코드베이스에 이미 일부 구현되어 있거나, 인프라를 최소한으로 추가해 활성화할 수 있는 항목들이다.

---

## 세 가지 확장 요약

| 확장 | 설명 | 구현 상태 |
|---|---|---|
| **C — Entra ID 클라이언트 인증** | 구독 키 없이 Entra ID 토큰으로 클라이언트 인증 | 토글 구현 완료, 운영 검증 전 |
| **A — Claude Code 입구** | Anthropic Messages API(`/v1/messages`) 신규 APIM 입구 추가 | 미구현 (신규 APIM API 필요) |
| **B — Responses API** | gpt 전용 stateful Responses API 입구 추가 | 미구현 (신규 입구 필요) |

---

## 권장 구현 순서: **C → A → B**

세 확장의 권장 구현 순서는 **C → A → B**다.

1. **C를 먼저**: `client_auth_mode="entra-id"` 토글이 이미 구현되어 있다. production 권고 사항(consumerId 설계 개선)만 적용하면 운영에 투입할 수 있다. 이미 있는 기능을 완성하는 것이므로 리스크가 가장 낮다.

2. **A를 다음으로**: Claude Code를 게이트웨이에 연결하려는 수요가 크다. 신규 APIM API를 추가해야 하지만, 기존 consumerId·rate·budget·metric 파이프라인을 그대로 재사용할 수 있어 개발 범위가 명확하다.

3. **B를 마지막으로**: Responses API는 현재 연동된 클라이언트가 보내지 않는 형식이다. 클라이언트 측 준비가 완료된 뒤에 구현해도 늦지 않다.

---

## 각 확장 상세

- [C — Entra ID 클라이언트 인증](extension-c-entra-client-auth.md)
- [A — Claude Code 입구](extension-a-claude-code.md)
- [B — Responses API](extension-b-responses-api.md)
