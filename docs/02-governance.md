---
description: "거버넌스 — consumer, 클라이언트 인증, 모델 권한, rate limit, budget 기반 모델 전환"
---

# 거버넌스

Azure AI Gateway의 거버넌스는 **consumer**라는 하나의 축으로 동작합니다. 클라이언트가 어떤 도구를 쓰든, APIM은 요청을 consumer로 식별한 뒤 모델 권한, 속도 제한, 예산 상태를 같은 순서로 적용합니다.

구현 세부사항(APIM policy XML, Terraform 모듈, 네트워크 경계)은 [아키텍처 상세](08-architecture.md)를 참고하세요. 이 장은 운영자가 정책을 어떻게 이해하고 설정할지에 집중합니다.

## 정책 모델 한눈에 보기

| 정책 | 무엇을 결정하나 | 설정 위치 | 실패/효과 |
|---|---|---|---|
| 클라이언트 인증 | 누가 호출했는가 | APIM subscription 또는 Entra ID | 401 |
| 모델 허용 목록 | 어떤 모델을 호출할 수 있는가 | consumer config `allowed_models` | 403 |
| Rate limit | 얼마나 빠르게/많이 쓸 수 있는가 | `rate_tiers`, consumer `tier` | 429 |
| Budget switch | 예산 소진 시 어떤 모델로 전환할 것인가 | `daily_budget_usd`, `downgrade_ladder` | effective model 변경 |
| 관측 | 무엇을 로그/메트릭으로 볼 것인가 | App Insights, Admin UI | dashboard / logs |

## Consumer

**consumer**는 게이트웨이를 사용하는 팀, 애플리케이션, 프로젝트 단위입니다. 모든 집계와 정책은 consumer 단위로 적용됩니다.

| 항목 | 설명 |
|---|---|
| 식별자 | APIM subscription display name 또는 JWT claim |
| 저장 문서 | Cosmos DB `consumer:<name>` |
| 관리 위치 | Admin UI |
| 대표 설정 | `allowed_models`, `tier`, `daily_budget_usd`, `downgrade_ladder` |

예를 들어 `vscode` consumer는 VS Code 사용자 그룹의 호출을 대표하고, `ghcp` consumer는 GitHub Copilot CLI 사용자를 대표할 수 있습니다.

## 클라이언트 인증

현재 운영 검증된 기본 방식은 **APIM subscription key**입니다. 일반 통합 API는 `api-key`를 사용하고, VS Code BYOK 전용 경로만 `Ocp-Apim-Subscription-Key`를 사용합니다.

| 클라이언트 | APIM 경로 | key 전달 방식 |
|---|---|---|
| GitHub Copilot CLI (Azure provider) | `/openai/v1/chat/completions` | `api-key: <APIM subscription key>` |
| VS Code BYOK custom endpoint | `/vscode/models` | `Ocp-Apim-Subscription-Key: <APIM subscription key>` |
| OpenCode, Codex, 직접 API 호출 | `/openai/v1` | `api-key: <APIM subscription key>` |
| Search MCP | `/mcp/` | `api-key: <APIM subscription key>` |

{% hint style="info" %}
`api-key`와 `Ocp-Apim-Subscription-Key`는 서로 다른 credential이 아닙니다. 둘 다 **같은 APIM subscription key를 담는 헤더 이름**입니다.
{% endhint %}

Entra ID 기반 클라이언트 인증(`client_auth_mode = "entra-id"`)은 향후 지원 계획으로 분류합니다. 자세한 내용은 [향후 지원 계획](09-future.md)을 참고하세요.

## 모델 허용 목록

consumer별로 직접 호출할 수 있는 모델을 제한합니다.

```json
{
  "consumer": "vscode",
  "allowed_models": ["gpt-5.6-sol", "DeepSeek-V4-Pro", "grok-4.3"]
}
```

| 상황 | 결과 |
|---|---|
| 요청 모델이 `allowed_models`에 있음 | 다음 정책 단계로 진행 |
| 요청 모델이 `allowed_models`에 없음 | 403 Forbidden |
| 예산으로 모델 전환 발생 | 전환 대상도 허용 모델 목록 안에 있어야 함 |

VS Code model picker에 여러 모델을 등록해도, 최종 허용 여부는 APIM의 allowed-models가 판단합니다.

## Rate limit

Rate limit은 consumer별 토큰 사용 속도와 총량을 제어합니다. APIM의 `llm-token-limit` 정책이 처리합니다.

| tier | 권장 용도 |
|---|---|
| `small` | 테스트, 저빈도 팀 |
| `medium` | 일반 팀, 일반적인 IDE assistant |
| `large` | OpenCode, VS Code/Copilot agent처럼 큰 context와 agent 호출을 쓰는 팀 |
| `default` | consumer에 tier가 없을 때 적용되는 전역 기본값 |

### Capacity와 APIM limit의 관계

토큰 한도는 두 레이어를 함께 봐야 합니다.

| 레이어 | 설정 | 의미 |
|---|---|---|
| 모델 deployment | `model_deployments[*].capacity` | Azure 모델 배포의 backend 처리 한도. Terraform이 `azurerm_cognitive_deployment.sku.capacity`로 설정 |
| APIM default limit | `tokens_per_minute`, `token_quota`, `token_quota_period` | consumer에 tier가 없을 때 쓰는 fallback. 모델별 capacity가 있으면 TPM은 `capacity * 1000`으로 계산 |
| APIM tier limit | `rate_tiers.small/medium/large` | consumer에 `tier`가 있으면 이 값이 우선 적용됨 |

APIM limit은 **consumer별 공정 사용량**을 제어합니다. 하지만 백엔드 모델 deployment capacity가 더 낮으면, APIM limit에 도달하기 전에 백엔드 429가 먼저 발생할 수 있습니다. 반대로 APIM tier TPM이 너무 낮으면, backend에는 여유가 있어도 APIM에서 먼저 429가 발생합니다.

{% hint style="info" %}
OpenCode 같은 agentic client는 한 번의 작업에서 title 생성, main agent, subagent 요청이 연속으로 발생합니다. 멀티에이전트 검증이나 대형 repository 분석에는 `large` tier처럼 높은 TPM과 충분한 기간 quota를 배정하세요.
{% endhint %}

기본 tier 값:

| tier | TPM | quota | period |
|---|---:|---:|---|
| `small` | 50,000 | 5,000,000 | Daily |
| `medium` | 150,000 | 30,000,000 | Daily |
| `large` | 300,000 | 1,000,000,000 | Monthly |

`large`도 backend quota보다 높게 잡으면 효과가 없습니다. 예를 들어 `large.tpm=300000`을 온전히 쓰려면 해당 모델 deployment의 token rate limit도 최소 300,000 TPM 이상이어야 합니다. 배포 후 실제 backend 한도는 아래처럼 확인합니다.

```bash
az cognitiveservices account deployment show \
  -g <resource-group> \
  -n <account-name> \
  --deployment-name <deployment-name> \
  --query "{sku:sku, rateLimits:properties.rateLimits}" -o json
```

## Budget switch

Budget switch는 consumer의 일일 USD 예산 사용률에 따라 더 저렴한 모델로 자동 전환하는 기능입니다.

| level | 조건 | 동작 |
|---|---|---|
| 0 | 예산 80% 미만 | 전환 없음 |
| 1 | 예산 80% 이상 | ladder에서 1칸 아래 모델로 전환 |
| 2 | 예산 100% 이상 | ladder에서 2칸 아래 모델로 전환 |

예시:

```text
downgrade_ladder = gpt-5.6-sol → DeepSeek-V4-Pro → grok-4.3
```

| 요청 모델 | level 0 | level 1 | level 2 |
|---|---|---|---|
| `gpt-5.6-sol` | `gpt-5.6-sol` | `DeepSeek-V4-Pro` | `grok-4.3` |
| `DeepSeek-V4-Pro` | `DeepSeek-V4-Pro` | `grok-4.3` | `grok-4.3` |

`active_downgrade`는 Admin UI가 직접 쓰는 값이 아니라 config-sync worker가 Log Analytics 사용량과 pricing 문서를 기반으로 계산합니다.

{% hint style="info" %}
Admin UI가 보여주는 모델 목록은 Terraform이 `model_deployments`에서 만든 `ALIAS_MODELS_JSON`으로 고정되고, config-sync는 Cosmos `allowed_models`를 APIM runtime named value로만 동기화합니다. 새 canonical 모델을 추가할 때는 Terraform과 Cosmos/runtime 갱신을 둘 다 수행하세요.
{% endhint %}

## 전환 확인

모델 전환이 발생하면 응답 헤더와 로그에 같은 정보가 남습니다.

| 위치 | 확인 필드 |
|---|---|
| 응답 헤더 | `x-ai-gateway-requested-model`, `x-ai-gateway-effective-model`, `x-ai-gateway-downgrade-level` |
| Admin UI Monitoring | Downgrade events 테이블 |
| AppTraces | `requestedModel`, `effectiveModel`, `downgradeLevel`, `consumer` |
| AppMetrics | `deployment`, `effectiveModel`, `consumer` |

{% hint style="warning" %}
`AppRequests`의 URL은 항상 요청 모델 기준입니다. 실제 처리 모델은 `effectiveModel` 필드나 응답 헤더에서 확인하세요.
{% endhint %}

## 운영 시 주의점

| 주의점 | 이유 |
|---|---|
| 예산 메뉴와 APIM 적용 상태가 몇 분 다를 수 있음 | Log Analytics ingestion + config-sync 주기 때문 |
| downgrade event가 request log보다 늦게 보일 수 있음 | `AppRequests`, `AppTraces`, `AppMetrics`가 별도 ingestion pipeline |
| `level 2`가 즉시 안 보일 수 있음 | worker가 최신 metric을 아직 읽지 못했을 수 있음 |
| 클라이언트별 APIM 경로를 섞으면 401 가능 | CLI와 VS Code가 지원하는 key 헤더가 다름 |

## 다음 단계

| 작업 | 이동할 문서 |
|---|---|
| 정책이 코드에서 어떻게 실행되는지 확인 | [아키텍처 상세](08-architecture.md) |
| 배포 방식 선택 | [배포](03-deploy.md) |
| VS Code / Copilot CLI 연결 | [클라이언트 온보딩](07-connect-clients.md) |
| 로그와 예산 운영 | [운영](06-operate.md) |
