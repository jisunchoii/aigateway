> 읽는 사람: 개발자·AI 도구 사용자 · 선행: 05-verify/smoke-test.md

# 클라이언트 연동 개요

이 장에서는 게이트웨이를 실제 AI 개발 도구와 연결하는 방법을 다룹니다. **클라이언트가 사용하는 API 형식에 따라 게이트웨이 입구(APIM API 경로)가 결정됩니다.**

---

## 4가지 클라이언트 비교

| | GitHub Copilot (IDE) | GHCP CLI | opencode | Claude Code |
|---|---|---|---|---|
| API 형식 | OpenAI chat completions | OpenAI chat completions | OpenAI chat completions (`/v1/chat/completions`) | **Anthropic Messages** (`/v1/messages`) |
| base URL 변수 | — | `COPILOT_PROVIDER_BASE_URL` | `baseURL` | `ANTHROPIC_BASE_URL` / `ANTHROPIC_FOUNDRY_BASE_URL` |
| model 위치 | body | body (azure면 경로) | body | body |
| 이 게이트웨이 입구 | `/vscode/openai`·`/openai` | `/openai` | `/foundry` | ❌ 현재 미지원 (확장 A) |

> **Claude Code는 현재 이 게이트웨이에 직접 연결할 수 없습니다.** Claude Code는 Anthropic Messages API(`/v1/messages`)를 사용하지만, 이 게이트웨이는 현재 OpenAI 형식 입구만 지원합니다. 지원 계획은 [09-future/extension-a-claude-code.md](../09-future/extension-a-claude-code.md)를 참조하십시오.

---

## 입구와 클라이언트의 관계

게이트웨이는 동일한 APIM 엔드포인트(`https://<apim-host>`)에 여러 API 경로를 노출합니다. 클라이언트의 API 형식에 맞는 경로를 선택해야 합니다.

| APIM 경로 | 클라이언트 | 라우팅 방식 |
|---|---|---|
| `/openai` | GHCP CLI (azure provider) | URL 경로에서 model 추출 → body에 주입 |
| `/vscode/openai` | VS Code BYOK | `Ocp-Apim-Subscription-Key` 헤더 + path-route |
| `/foundry` | opencode / 직접 호출 | body에 model 포함 (body-route) |

모든 클라이언트는 동일한 `consumerId` 단위로 집계됩니다. 인증 방식(구독 키 vs Entra ID)에 무관하게 같은 소비자로 처리됩니다.

---

## 인증 방식

현재 기본 인증 방식은 **APIM 구독 키(`Ocp-Apim-Subscription-Key` 헤더)**입니다. 구독 키는 Admin UI의 Consumers 탭에서 발급합니다.

Entra ID 기반 클라이언트 인증(`client_auth_mode="entra-id"`)은 구현되어 있지만 운영 검증 전 단계이며, 확장 C로 분류됩니다. 상세는 [09-future/extension-c-entra-client-auth.md](../09-future/extension-c-entra-client-auth.md)를 참조하십시오.

---

## 클라이언트별 설정 가이드

- [VS Code BYOK](vscode.md) — chatLanguageModels.json 설정, `/vscode/openai` 경로
- [GHCP CLI](copilot-cli.md) — COPILOT_PROVIDER_* 환경 변수, `/openai` 경로
- [opencode](opencode.md) — opencode.json provider 블록, `/foundry` 경로
- [직접 호출 (curl)](direct-call.md) — `/foundry` 경로로 직접 REST 호출

---

## 참고 링크

- [GitHub Copilot CLI 문서](https://docs.github.com/en/copilot/concepts/agents/about-copilot-cli)
- [opencode 문서](https://opencode.ai/docs/providers/)
- [Claude Code LLM Gateway 문서](https://code.claude.com/docs/en/llm-gateway) (미지원, 확장 A 참조)
- [Claude Code LLM Gateway Protocol](https://code.claude.com/docs/en/llm-gateway-protocol) (미지원, 확장 A 참조)
