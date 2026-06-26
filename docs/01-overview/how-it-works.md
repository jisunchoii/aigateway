---
description: 아키텍트·플랫폼 엔지니어를 위한 페이지 · 선행: 무엇인가
---

# 동작 방식

## 1. 요청 흐름

***

클라이언트의 AI 요청은 아래 순서로 처리됩니다.

<!-- diagram: request-flow -->
<div style="display:flex; align-items:stretch; gap:10px; font-family:'Segoe UI','Noto Sans KR',sans-serif; margin:16px 0;">
  <div style="flex:1; background:#EEF6FC; border-left:4px solid #0078D4; border-radius:4px; padding:14px;">
    <div style="font-size:11px; letter-spacing:1px; color:#0078D4; font-weight:700;">INGRESS · 입구</div>
    <div style="font-size:16px; font-weight:700; color:#0a2540; margin:6px 0;">개발 툴 (클라이언트)</div>
    <div style="font-size:12.5px; color:#1a1a2e; line-height:1.7;">▸ public APIM 접속<br>▸ 구독키 / Entra JWT<br>▸ 모델 키 미보유</div>
  </div>
  <div style="display:flex; align-items:center; color:#0078D4; font-weight:700; font-size:13px;">HTTPS ▶</div>
  <div style="flex:1.3; background:#0a2540; border-radius:4px; padding:14px; color:#fff;">
    <div style="font-size:11px; letter-spacing:1px; color:#5AC8FA; font-weight:700;">GATEWAY · 정책</div>
    <div style="font-size:16px; font-weight:700; margin:6px 0;">APIM 게이트웨이</div>
    <div style="font-size:12.5px; color:#dce6f0; line-height:1.8;">① 소비자 식별<br>② allowed-models → <span style="color:#FFB454;">403</span><br>③ rate limit → <span style="color:#FFB454;">429</span><br>④ 예산 모델 전환<br>⑤ 토큰 메트릭</div>
  </div>
  <div style="display:flex; align-items:center; color:#107C41; font-weight:700; font-size:11px; text-align:center;">Managed&nbsp;Identity<br>▶</div>
  <div style="flex:1; background:#EEF7F0; border-left:4px solid #107C41; border-radius:4px; padding:14px;">
    <div style="font-size:11px; letter-spacing:1px; color:#107C41; font-weight:700;">EGRESS · 백엔드</div>
    <div style="font-size:16px; font-weight:700; color:#0a2540; margin:6px 0;">Foundry / AOAI (Private)</div>
    <div style="font-size:12.5px; color:#1a1a2e; line-height:1.7;">✓ Private Endpoint 전용<br>✓ 키 인증 off<br>✓ MI로만 접속</div>
  </div>
</div>
<!-- /diagram -->

## 2. 클라이언트 입구 (Ingress) 표

***

클라이언트 종류마다 APIM에 진입하는 경로와 형식이 다릅니다. APIM 정책이 이를 통일된 v1 백엔드 형식으로 변환합니다.

| APIM API (입구) | 클라이언트 | 들어오는 형식 | 백엔드로 나갈 때 |
|---|---|---|---|
| `/openai` | GHCP CLI (azure provider) | path-route, model in URL, `?api-version=` | URL에서 model 추출 → body에 주입 → `/openai/v1/chat/completions` |
| `/vscode/openai` | VS Code BYOK | path-route, `Ocp-Apim-Subscription-Key` 헤더 | 동일 |
| `/foundry` | opencode / 직접 호출 | body-route, model in body | 거의 그대로 → `/openai/v1/chat/completions` |

{% hint style="info" %}
**v1 백엔드 통일:** path-route(URL에 모델명 포함)로 들어온 요청도 APIM 정책이 body에 `"model"` 필드를 주입해 동일한 `/openai/v1/chat/completions` 엔드포인트로 라우팅합니다. 클라이언트는 이 변환을 인식할 필요가 없습니다.
{% endhint %}

path-route로 들어온 요청이 v1 body-route로 변환되는 과정을 예시로 보면 다음과 같습니다.

#### As-Is — 클라이언트가 보내는 path-route 요청

```http
POST /openai/deployments/gpt-5.4/chat/completions?api-version=2025-01-01-preview
Ocp-Apim-Subscription-Key: <subscription-key>

{
  "messages": [{"role": "user", "content": "Hello"}]
}
```

#### To-be — APIM 정책이 백엔드로 전달하는 v1 body-route 요청

```http
POST /openai/v1/chat/completions
Authorization: Bearer <managed-identity-token>

{
  "model": "gpt-5.4",
  "messages": [{"role": "user", "content": "Hello"}]
}
```

URL의 배포 이름(`gpt-5.4`)이 body의 `"model"` 필드로 주입되고, `?api-version=` 파라미터는 제거됩니다.

## 3. consumerId 집계 축

***

게이트웨이의 모든 측정(토큰 사용량·속도 제한·예산)은 **consumerId 하나**를 기준으로 집계됩니다. 클라이언트가 APIM 구독 키를 사용하든, Entra ID Bearer 토큰을 사용하든 동일한 consumerId로 집계됩니다.

- `client_auth_mode=subscription-key` (기본): APIM 구독에 연결된 소비자 ID
- `client_auth_mode=entra-id`: JWT claim에서 추출한 소비자 ID (`team_claim` 변수로 지정)

이 덕분에 "팀 A가 이번 달 gpt-5.4에 쓴 토큰"처럼 팀 단위 집계가 가능합니다.

## 4. 정책 단계별 상세

***

### 1단계 — consumerId 식별

- **구독 키 모드:** `Ocp-Apim-Subscription-Key` 헤더로 소비자 식별
- **Entra ID 모드:** `validate-jwt` 정책으로 토큰 검증 후 지정 클레임 값을 consumerId로 사용

### 2단계 — allowed-models 검사

- Cosmos DB의 소비자 설정에서 `allowed_models` 목록 조회
- 요청 모델이 목록에 없으면 **`403 Forbidden`** 반환

### 3단계 — rate limit 검사

- 소비자의 `rate_tier`에 매핑된 `tokens_per_minute` 상한 적용
- 초과 시 **`429 Too Many Requests`** 반환

### 4단계 — budget 모델 전환

- 월 예산(`monthly_budget_amount`) 소진 시 APIM 정책이 body의 `"model"` 값을 `downgrade_ladder` 다음 단계로 교체
- 응답 헤더에 **모델 전환** 정보 포함

| 응답 헤더 | 의미 |
|---|---|
| `x-ai-gateway-requested-model` | 클라이언트가 요청한 원래 모델 |
| `x-ai-gateway-effective-model` | 실제로 사용된 모델 |
| `x-ai-gateway-downgrade-level` | 전환 단계 (`0` = 전환 없음) |

### 5단계 — 토큰 메트릭 기록

응답에서 토큰 사용량을 추출해 [Application Insights](https://learn.microsoft.com/ko-kr/azure/azure-monitor/app/app-insights-overview) 커스텀 이벤트로 전송합니다. Admin UI와 비용 추적에 활용됩니다.

---

## 5. 백엔드 통신 보안

***

APIM과 AIServices 사이의 모든 통신은 다음 두 가지로 보호됩니다.

1. **Managed Identity + RBAC** — APIM의 시스템 할당 관리 ID에 `Cognitive Services OpenAI User` 역할이 부여됩니다. API 키를 사용하지 않습니다.
2. **Private Endpoint** — APIM VNet에서 AIServices 계정으로의 트래픽은 공인 인터넷을 경유하지 않습니다. AIServices 계정의 `publicNetworkAccess=Disabled`로 설정합니다.
