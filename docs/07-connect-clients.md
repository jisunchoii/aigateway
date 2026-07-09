---
description: "클라이언트 온보딩 — 클라이언트별 APIM 경로와 설정 가이드"
---

# 클라이언트 온보딩

이 장은 VS Code, GitHub Copilot CLI, OpenCode, curl 같은 클라이언트를 APIM 게이트웨이에 연결하는 방법을 안내합니다. 클라이언트마다 **요청 형식과 보낼 수 있는 인증 헤더가 다르기 때문에 APIM 경로를 분리**합니다.

## 1. 공통 준비값

모든 클라이언트 설정 전에 아래 값을 준비합니다.

| 값 | 확인 위치 |
|---|---|
| APIM gateway URL | `terraform output -raw apim_gateway_url` |
| APIM subscription key | Admin UI Consumers 또는 Azure Portal APIM Subscriptions |
| 사용할 모델 이름 | Admin UI consumer allowed models 또는 `allowed_models` |
| APIM 공개 여부 | 외부 개발 도구에서 접속하면 `apim_public=true` 필요 |

{% hint style="warning" %}
APIM subscription key는 소스 코드, dotfiles, Git 저장소에 커밋하지 마세요. 가능하면 환경 변수나 각 도구의 secret 저장소를 사용하세요.
{% endhint %}

## 2. 어떤 클라이언트를 설정할까?

{% hint style="success" %}
**빠른 선택**

- VS Code의 BYOK/custom model 기능을 쓰면 [VS Code BYOK](07-connect-clients/vscode-byok.md)
- GitHub Copilot CLI를 Azure provider 모드로 쓰면 [GitHub Copilot CLI](07-connect-clients/copilot-cli.md)
- OpenCode를 provider config로 연결하면 [OpenCode](07-connect-clients/opencode.md)
- Codex CLI를 Responses provider로 연결하면 [Codex CLI](07-connect-clients/codex-cli.md)
- curl, REST Client, 애플리케이션 코드에서 직접 호출하면 [직접 API 호출](07-connect-clients/direct-api.md)
{% endhint %}

## 3. APIM 경로 선택

| 클라이언트 | APIM 경로 | 인증 헤더 | 라우팅 방식 |
|---|---|---|---|
| VS Code BYOK | `/vscode/models` | `Ocp-Apim-Subscription-Key` | URL의 deployment 이름을 모델로 사용 |
| GitHub Copilot CLI | `/openai` | `api-key` | CLI가 Azure OpenAI 경로를 자동 구성 |
| OpenCode | `/openai` 또는 `/foundry` | `api-key` 또는 `Ocp-Apim-Subscription-Key` | custom OpenAI-compatible provider를 APIM 경로별로 분리 |
| Codex CLI | `/responses` | `Ocp-Apim-Subscription-Key` | Responses 전용, **gpt 계열만**. AIServices native Responses로 직접 프록시 (grok·DeepSeek은 OpenCode 사용) |
| curl / REST Client | `/openai` 또는 `/foundry` | `api-key` 또는 `Ocp-Apim-Subscription-Key` | gpt 계열은 `/openai` path-route, partner 모델은 `/foundry` body-route |

`api-key`와 `Ocp-Apim-Subscription-Key`는 서로 다른 credential이 아닙니다. 같은 APIM subscription key를 어떤 헤더 이름으로 보내는지만 다릅니다.

## 4. 지원하지 않는 클라이언트

{% hint style="info" %}
**Claude Code는 아직 공식 온보딩 대상이 아닙니다.** Claude Code는 Anthropic Messages API(`/v1/messages`) 경로가 필요합니다. 지원 계획은 [향후 지원 계획](09-future.md)을 참고하세요. (Codex는 [Codex CLI](07-connect-clients/codex-cli.md)로 지원됩니다.)
{% endhint %}

## 5. 다음 단계

| 목적 | 이동 |
|---|---|
| VS Code 설정 | [VS Code BYOK](07-connect-clients/vscode-byok.md) |
| Copilot CLI 설정 | [GitHub Copilot CLI](07-connect-clients/copilot-cli.md) |
| OpenCode 설정 | [OpenCode](07-connect-clients/opencode.md) |
| Codex CLI 설정 | [Codex CLI](07-connect-clients/codex-cli.md) |
| 직접 호출 테스트 | [직접 API 호출](07-connect-clients/direct-api.md) |
| 오류 코드 확인 | [문제 해결](10-reference.md#4-문제-해결) |
