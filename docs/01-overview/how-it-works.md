---
description: 아키텍트·플랫폼 엔지니어를 위한 페이지 · 선행: 무엇인가
---

# 동작 방식

## 요청 흐름

클라이언트의 AI 요청은 아래 순서로 처리됩니다.

```
클라이언트
  │
  │  HTTPS (Ocp-Apim-Subscription-Key 또는 Bearer)
  ▼
공개 APIM (apim_public=true)
  │
  ├─ 1. consumerId 식별
  ├─ 2. allowed-models 검사 → 불허 시 403
  ├─ 3. rate limit 검사 → 초과 시 429
  ├─ 4. budget 모델 전환 → 필요 시 body의 "model" 교체
  ├─ 5. 토큰 메트릭 기록 (App Insights)
  │
  │  Managed Identity + RBAC (Private Endpoint 경유)
  ▼
AIServices 계정 /openai/v1/chat/completions
```

---

## 클라이언트 입구 (Ingress) 표

클라이언트 종류마다 APIM에 진입하는 경로와 형식이 다릅니다. APIM 정책이 이를 통일된 v1 백엔드 형식으로 변환합니다.

| APIM API (입구) | 클라이언트 | 들어오는 형식 | 백엔드로 나갈 때 |
|---|---|---|---|
| `/openai` | GHCP CLI (azure provider) | path-route, model in URL, `?api-version=` | URL에서 model 추출 → body에 주입 → `/openai/v1/chat/completions` |
| `/vscode/openai` | VS Code BYOK | path-route, `Ocp-Apim-Subscription-Key` 헤더 | 동일 |
| `/foundry` | opencode / 직접 호출 | body-route, model in body | 거의 그대로 → `/openai/v1/chat/completions` |

{% hint style="info" %}
**v1 백엔드 통일:** path-route(URL에 모델명 포함)로 들어온 요청도 APIM 정책이 body에 `"model"` 필드를 주입해 동일한 `/openai/v1/chat/completions` 엔드포인트로 라우팅합니다. 클라이언트는 이 변환을 인식할 필요가 없습니다.
{% endhint %}

---

## consumerId 집계 축

게이트웨이의 모든 측정(토큰 사용량·속도 제한·예산)은 **consumerId 하나**를 기준으로 집계됩니다. 클라이언트가 APIM 구독 키를 사용하든, Entra ID Bearer 토큰을 사용하든 동일한 consumerId로 집계됩니다.

- `client_auth_mode=subscription-key` (기본): APIM 구독에 연결된 소비자 ID
- `client_auth_mode=entra-id`: JWT claim에서 추출한 소비자 ID (`team_claim` 변수로 지정)

이 덕분에 "팀 A가 이번 달 gpt-5.4에 쓴 토큰"처럼 팀 단위 집계가 가능합니다.

---

## 정책 단계별 상세

### 1단계 — consumerId 식별

구독 키 모드에서는 `Ocp-Apim-Subscription-Key` 헤더로 소비자를 찾습니다. Entra ID 모드에서는 `validate-jwt` 정책으로 토큰을 검증하고 지정된 클레임 값을 consumerId로 사용합니다.

### 2단계 — allowed-models 검사

Cosmos DB에 저장된 소비자 설정에서 `allowed_models` 목록을 읽어 요청한 모델이 포함되지 않으면 `403 Forbidden`을 반환합니다.

### 3단계 — rate limit 검사

소비자의 `rate_tier`에 매핑된 `tokens_per_minute` 상한을 초과하면 `429 Too Many Requests`를 반환합니다.

### 4단계 — budget 모델 전환

소비자의 월 예산(`monthly_budget_amount`)이 소진되면 APIM 정책이 body의 `"model"` 값을 `downgrade_ladder`에 정의된 다음 단계 모델로 교체합니다. 응답 헤더에 전환 정보가 포함됩니다.

| 응답 헤더 | 의미 |
|---|---|
| `x-ai-gateway-requested-model` | 클라이언트가 요청한 원래 모델 |
| `x-ai-gateway-effective-model` | 실제로 사용된 모델 |
| `x-ai-gateway-downgrade-level` | 전환 단계 (`0` = 전환 없음) |

### 5단계 — 토큰 메트릭 기록

응답에서 토큰 사용량을 추출해 [Application Insights](https://learn.microsoft.com/ko-kr/azure/azure-monitor/app/app-insights-overview) 커스텀 이벤트로 전송합니다. Admin UI와 비용 추적에 활용됩니다.

---

## 백엔드 통신 보안

APIM과 AIServices 사이의 모든 통신은 다음 두 가지로 보호됩니다.

1. **Managed Identity + RBAC** — APIM의 시스템 할당 관리 ID에 `Cognitive Services OpenAI User` 역할이 부여됩니다. API 키를 사용하지 않습니다.
2. **Private Endpoint** — APIM VNet에서 AIServices 계정으로의 트래픽은 공인 인터넷을 경유하지 않습니다. AIServices 계정의 `publicNetworkAccess=Disabled`로 설정합니다.
