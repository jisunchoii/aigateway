---
description: "클라이언트 온보딩 — 클라이언트별 APIM 경로와 설정 가이드"
---

# 클라이언트 온보딩

이 장은 VS Code, GitHub Copilot CLI, OpenCode, Codex CLI, curl 같은 클라이언트를 APIM 게이트웨이에 연결하는 방법을 안내합니다. 일반 클라이언트는 통합 `/openai/v1` API를 사용하고, VS Code BYOK와 Search MCP만 전용 경로를 사용합니다.

## 1. 공통 준비값

모든 클라이언트 설정 전에 아래 값을 준비합니다.

| 값 | 확인 위치 |
|---|---|
| APIM gateway URL | `terraform output -raw apim_gateway_url` |
| APIM subscription key | Admin UI Consumers 또는 Azure Portal APIM Subscriptions |
| 사용할 모델 이름 | Admin UI consumer allowed models 또는 canonical `model_deployments` catalog |
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
| GitHub Copilot CLI | `/openai/v1/chat/completions` | `api-key` | API version을 unset한 Azure provider |
| OpenCode | `/openai/v1/chat/completions` 또는 `/openai/v1/responses` | `api-key` | provider별 wire API 사용 |
| Codex CLI | `/openai/v1/responses` | `api-key` | Responses 전용. partner/OSS 모델 요청은 Codex proxy sidecar가 payload를 정규화 |
| curl / REST Client | `/openai/v1/chat/completions` 또는 `/openai/v1/responses` | `api-key` | body의 `model`로 배포 선택 |

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
