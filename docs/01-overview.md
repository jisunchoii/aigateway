---
description: "Azure AI Gateway 개요 — 무엇인지, 동작 방식, 핵심 개념"
---

# 개요

## 1. 무엇인가

***

### 1. 한 문장 요약

Azure AI Gateway는 [Azure API Management](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-key-concepts) 위에 구축된 **엔터프라이즈 AI 거버넌스 엔드포인트**입니다. 다수의 LLM 백엔드를 단일 진입점 뒤에 숨기고, 소비자별 권한·속도 제한·예산 제어를 중앙에서 일괄 적용합니다.

### 2. 문제 정의

기업 내 여러 팀이 각자 Azure OpenAI나 Azure AI Foundry 모델을 직접 호출하면 다음 문제가 생깁니다.

- **키 관리 분산** — 팀마다 API 키를 별도로 발급·보관하면 키 유출·키 회전이 어렵습니다.
- **비용 통제 불가** — 어느 팀이 얼마나 쓰는지 집계할 중심 지점이 없습니다.
- **모델 거버넌스 없음** — 특정 팀에 특정 모델만 허용하거나 사용량을 제한할 방법이 없습니다.
- **백엔드 교체 영향** — 모델 배포가 바뀌면 모든 클라이언트 설정을 함께 변경해야 합니다.

Azure AI Gateway는 이 모든 문제를 **단일 거버넌스 레이어** 하나로 해결합니다.

### 3. 무엇을 제공하는가

| 기능 | 설명 |
|---|---|
| 단일 엔드포인트 | `https://<apim-host>` 하나로 gpt-5.4, gpt-5.4-mini, grok-4.3, DeepSeek-V4-Pro 모두 접근 |
| 소비자별 모델 허용 목록 | 허용되지 않은 모델 요청 → 403 반환 |
| 토큰 속도 제한 | rate-tier별 분당 토큰 상한, 초과 → 429 반환 |
| 예산 기반 모델 전환 | 월 예산 소진 시 고비용 모델을 저비용 모델로 자동 전환 |
| Passwordless 백엔드 | APIM → AIServices 구간은 Managed Identity + RBAC, 키 인증 비활성화 |
| Private Endpoint | APIM → AIServices 구간은 공인 인터넷 미경유 |
| 셀프서비스 Admin UI | React SPA + FastAPI BFF, Entra ID 로그인, 관리자 그룹 게이트 |
| 통합 관찰성 | [Application Insights](https://learn.microsoft.com/ko-kr/azure/azure-monitor/app/app-insights-overview)로 토큰 메트릭·오류율·지연 시간 수집 |

### 4. 아키텍처 개요

<figure><img src="images/architecture.png" alt=""><figcaption><p>아키텍처 개요</p></figcaption></figure>

백엔드는 **Azure AI Foundry(AIServices)** 단일 계정입니다. gpt-5.4 계열은 `azurerm_cognitive_account`(`/openai/v1` 경로)로, grok-4.3·DeepSeek-V4-Pro 등 OSS/파트너 모델은 같은 계정의 Foundry 배포로 제공합니다. 모든 백엔드 호출은 동일한 `/openai/v1/chat/completions` 형식을 사용하며, 클라이언트 쪽 입구 형식(path-route vs body-route)은 APIM 정책이 변환합니다.

### 5. 누구를 위한 것인가

- **플랫폼/인프라 팀** — Terraform으로 게이트웨이 스택을 배포·운영합니다.
- **개발팀** — APIM 구독 키 하나로 허용된 모델에 접근합니다. 백엔드 주소나 키를 직접 관리할 필요가 없습니다.
- **아키텍트·보안 담당자** — 모든 AI 트래픽의 중앙 감사·제어 지점을 확보합니다.

### 6. 관련 Azure 서비스 문서

- [Azure API Management](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-key-concepts)
- [Azure OpenAI Service](https://learn.microsoft.com/ko-kr/azure/ai-services/openai/overview)
- [Azure AI Foundry](https://learn.microsoft.com/ko-kr/azure/ai-foundry/what-is-azure-ai-foundry)
- [Azure Private Endpoint](https://learn.microsoft.com/ko-kr/azure/private-link/private-endpoint-overview)

## 2. 동작 방식

***

### 1. 요청 흐름

클라이언트의 AI 요청은 아래 순서로 처리됩니다.

<figure><img src="images/diagram-request-flow.png" alt="요청 흐름 — 개발 툴(Ingress) → APIM 게이트웨이(정책 ①~⑤) → Private 백엔드(Egress)"><figcaption>🖼️ 요청 흐름 — 개발 툴(Ingress) → APIM 게이트웨이(정책 ①~⑤) → Private 백엔드(Egress) <em>(다이어그램 이미지 추가 예정)</em></figcaption></figure>

### 2. 클라이언트 입구 (Ingress) 표

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

### 3. consumerId 집계 축

게이트웨이의 모든 측정(토큰 사용량·속도 제한·예산)은 **consumerId 하나**를 기준으로 집계됩니다. 클라이언트가 APIM 구독 키를 사용하든, Entra ID Bearer 토큰을 사용하든 동일한 consumerId로 집계됩니다.

- `client_auth_mode=subscription-key` (기본): APIM 구독에 연결된 소비자 ID
- `client_auth_mode=entra-id`: JWT claim에서 추출한 소비자 ID (`team_claim` 변수로 지정)

이 덕분에 "팀 A가 이번 달 gpt-5.4에 쓴 토큰"처럼 팀 단위 집계가 가능합니다.

### 4. 정책 단계별 상세

#### 1단계 — consumerId 식별

- **구독 키 모드:** `Ocp-Apim-Subscription-Key` 헤더로 소비자 식별
- **Entra ID 모드:** `validate-jwt` 정책으로 토큰 검증 후 지정 클레임 값을 consumerId로 사용

#### 2단계 — allowed-models 검사

- Cosmos DB의 소비자 설정에서 `allowed_models` 목록 조회
- 요청 모델이 목록에 없으면 **`403 Forbidden`** 반환

#### 3단계 — rate limit 검사

- 소비자의 `rate_tier`에 매핑된 `tokens_per_minute` 상한 적용
- 초과 시 **`429 Too Many Requests`** 반환

#### 4단계 — budget 모델 전환

- 월 예산(`monthly_budget_amount`) 소진 시 APIM 정책이 body의 `"model"` 값을 `downgrade_ladder` 다음 단계로 교체
- 응답 헤더에 **모델 전환** 정보 포함

| 응답 헤더 | 의미 |
|---|---|
| `x-ai-gateway-requested-model` | 클라이언트가 요청한 원래 모델 |
| `x-ai-gateway-effective-model` | 실제로 사용된 모델 |
| `x-ai-gateway-downgrade-level` | 전환 단계 (`0` = 전환 없음) |

#### 5단계 — 토큰 메트릭 기록

응답에서 토큰 사용량을 추출해 [Application Insights](https://learn.microsoft.com/ko-kr/azure/azure-monitor/app/app-insights-overview) 커스텀 이벤트로 전송합니다. Admin UI와 비용 추적에 활용됩니다.

### 5. 백엔드 통신 보안

APIM과 AIServices 사이의 모든 통신은 다음 두 가지로 보호됩니다.

1. **Managed Identity + RBAC** — APIM의 시스템 할당 관리 ID에 `Cognitive Services OpenAI User` 역할이 부여됩니다. API 키를 사용하지 않습니다.
2. **Private Endpoint** — APIM VNet에서 AIServices 계정으로의 트래픽은 공인 인터넷을 경유하지 않습니다. AIServices 계정의 `publicNetworkAccess=Disabled`로 설정합니다.

## 3. 핵심 개념

***

이 페이지는 문서 전체에서 반복 등장하는 용어를 정의합니다. 헷갈리는 단어가 있을 때 돌아와 참고하세요.

### 1. consumer (소비자)

게이트웨이를 통해 AI 모델에 접근하는 **논리적 단위**입니다. 개인·팀·애플리케이션 어느 수준으로도 정의할 수 있습니다. Cosmos DB의 소비자 문서에 `allowed_models`, `rate_tier`, 예산 등 모든 정책이 저장됩니다.

`consumerId`는 요청마다 APIM 정책이 결정하는 식별자입니다. 구독 키 모드에서는 APIM 구독에서 파생되고, Entra ID 모드에서는 JWT 클레임에서 추출됩니다.

### 2. allowed-models (허용 모델)

소비자 문서에 기록된 **접근 가능한 모델 목록**입니다. 요청한 모델이 목록에 없으면 APIM 정책이 `403 Forbidden`을 반환합니다. 허용 모델은 Admin UI 또는 Cosmos DB 문서를 직접 수정해 변경합니다.

예시 설정:
```json
{
  "consumerId": "team-a",
  "allowed_models": ["gpt-5.4", "gpt-5.4-mini"]
}
```

### 3. rate-tier (속도 등급)

소비자에게 적용되는 **토큰 속도 제한 등급**입니다. Terraform 변수 `rate_tiers`로 small·medium·large 등 이름별 분당 토큰 상한을 정의하고, 소비자 문서의 `rate_tier` 필드로 등급을 지정합니다.

초과 요청에는 `429 Too Many Requests`가 반환됩니다.

### 4. 모델 전환 (budget-driven model swap)

월 예산(`monthly_budget_amount`)이 소진되면 APIM 정책이 요청 body의 `"model"` 값을 **자동으로 더 저렴한 모델로 교체**하는 기능입니다. 클라이언트는 동일한 엔드포인트·모델 이름으로 요청하지만, 실제로는 다른 모델이 응답합니다.

{% hint style="info" %}
**용어 주의:** 코드 식별자(`downgrade_ladder`, `active_downgrade`, `downgrade_level`)와 응답 헤더(`x-ai-gateway-downgrade-level`)는 영문 원형 그대로 사용합니다. 한국어 설명에서는 **"모델 전환"**이라고 표현합니다("강등"이 아님).
{% endhint %}

전환 단계는 `downgrade_ladder` 설정에 정의됩니다. 예:

```hcl
downgrade_ladder = ["gpt-5.4", "gpt-5.4-mini"]
```

위 설정에서 `gpt-5.4`를 요청했는데 예산이 소진된 경우, 정책은 `"model": "gpt-5.4-mini"`로 교체해 전달합니다.

응답 헤더로 전환 여부를 확인할 수 있습니다.

| 헤더 | 예시 값 | 의미 |
|---|---|---|
| `x-ai-gateway-requested-model` | `gpt-5.4` | 클라이언트 원 요청 |
| `x-ai-gateway-effective-model` | `gpt-5.4-mini` | 실제 처리 모델 |
| `x-ai-gateway-downgrade-level` | `1` | 전환 단계 (0=전환 없음) |

### 5. Private Endpoint / Passwordless

**Private Endpoint**는 Azure 리소스(여기서는 AIServices 계정)를 VNet 내부의 사설 IP로 노출하는 기능입니다. APIM VNet에서 AIServices로 가는 트래픽은 공인 인터넷을 통하지 않습니다.

**Passwordless(키 없는 인증)**는 API 키 대신 [Managed Identity](https://learn.microsoft.com/ko-kr/entra/identity/managed-identities-azure-resources/overview)와 RBAC을 사용해 백엔드에 인증하는 방식입니다. APIM의 시스템 할당 관리 ID에 `Cognitive Services OpenAI User` 역할을 부여하고, AIServices 계정의 `disableLocalAuth=true`로 키 인증을 차단합니다.

### 6. named values (명명된 값)

[APIM Named Values](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-howto-properties)는 정책 XML에서 `{{변수명}}` 형태로 참조하는 설정 저장소입니다. 이 게이트웨이에서는 백엔드 URL, Cosmos DB 연결 정보, 예산 임계값 등을 Named Values에 저장합니다. Terraform `apply` 때 자동으로 설정됩니다.

### 7. Cosmos DB 소비자 문서

소비자별 정책(allowed_models, rate_tier, 예산, 전환 설정 등)은 [Azure Cosmos DB](https://learn.microsoft.com/ko-kr/azure/cosmos-db/introduction) 컨테이너에 JSON 문서로 저장됩니다. APIM 정책은 요청마다 이 문서를 참조합니다. 초기 seed는 `seed-cosmos-jumpbox.sh`·`seed-pricing-jumpbox.sh` 스크립트로 수행하고, 이후 Admin UI나 config-sync-worker를 통해 관리합니다.

### 8. greenfield / brownfield

| 용어 | 의미 |
|---|---|
| **greenfield** | AIServices 계정을 포함해 모든 리소스를 Terraform이 신규 생성하는 배포 경로 |
| **brownfield** | 구독 내에 이미 존재하는 AIServices(Foundry) 계정을 `data`로 읽어 게이트웨이에 연결하는 경로 (`reuse_foundry=true`) |

어느 경로를 선택할지는 [Greenfield vs Brownfield 결정](02-prerequisites.md) 페이지를 참고하세요.
