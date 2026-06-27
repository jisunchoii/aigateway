---
description: "아키텍처 — 정책 흐름, 모듈 구조, 보안 설계, Cosmos 설정 스키마"
---

# 아키텍처 상세

이 챕터는 llm-gateway의 내부 아키텍처를 네 가지 관점으로 설명합니다.

- [1. APIM 정책 파이프라인 — 정책 흐름](#1-apim-정책-파이프라인--정책-흐름)
- [2. Terraform 모듈 구조](#2-terraform-모듈-구조)
- [3. 보안 설계 — Passwordless 전 구간](#3-보안-설계--passwordless-전-구간)
- [4. Cosmos DB 설정 스키마](#4-cosmos-db-설정-스키마)

## 1. APIM 정책 파이프라인 — 정책 흐름

***

{% hint style="info" %}
**6단계 파이프라인 요약**
① **`consumerId`** 도출 → ② **`allowed_models`** 검사(미허용 → 403) → ③ 토큰 rate limit(초과 → 429) → ④ **`downgrade_ladder`**로 예산 모델 전환(**`active_downgrade`** 적용) → ⑤ 토큰 메트릭 기록 → ⑥ 관리 ID 백엔드 인증
{% endhint %}

Azure API Management의 인바운드 정책은 클라이언트 요청을 백엔드로 전달하기 전에 일련의 단계를 순서대로 실행합니다. 이 절은 llm-gateway가 각 요청에 적용하는 정책 파이프라인을 단계별로 설명합니다.

<figure><img src="images/diagram-policy-pipeline.png" alt="APIM 정책 파이프라인 6단계 (①~⑥, allowed-models 403 / rate limit 429 분기 포함)"><figcaption>🖼️ APIM 정책 파이프라인 6단계 (①~⑥, allowed-models 403 / rate limit 429 분기 포함) <em>(다이어그램 이미지 추가 예정)</em></figcaption></figure>

---

### 1. 입구 형식 — 두 가지 진입 경로

***

클라이언트는 두 가지 형식으로 요청을 보낼 수 있습니다.

| 입구 API | 입구 URL 예시 | model 위치 | 정책 처리 |
|---|---|---|---|
| `/openai` (path-route) | `/openai/deployments/gpt-5.4/chat/completions?api-version=…` | URL 경로 | URL에서 model 추출 → body `"model"` 필드에 주입 |
| `/foundry` (body-route) | `/foundry/chat/completions` | 요청 body | 거의 그대로 통과 |

두 경로 모두 백엔드 URL은 `/openai/v1/chat/completions`로 정규화됩니다(`?api-version` 파라미터 제거, v1 통일).

---

### 2. 정책 파이프라인 단계

***

아래 순서는 APIM inbound 정책 실행 순서를 그대로 따릅니다.

#### 1단계 — consumerId 도출

모든 거버넌스 집계의 기준축인 **`consumerId`**를 결정합니다.

| `client_auth_mode` | 인증 수단 | consumerId 도출 방법 |
|---|---|---|
| `subscription-key` (기본값) | APIM 구독 키 | 구독의 **표시명(display name)** |
| `entra-id` | JWT (Entra ID 토큰) | JWT claim 값 (예: `sub`, custom app-role 등) |

`subscription-key` 모드에서는 `Ocp-Apim-Subscription-Key` 헤더를 검증한 뒤 해당 구독의 표시명을 `consumerId`로 사용합니다. `entra-id` 모드에서는 `validate-jwt` 정책으로 토큰을 검증하고 지정된 JWT claim을 `consumerId`로 추출합니다. ([APIM validate-jwt 정책](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy))

#### 2단계 — allowed-models 검사

요청 body의 `"model"` 값을 해당 consumer의 허용 모델 목록(**`allowed_models`**)과 대조합니다. 목록에 없는 모델이면 정책이 즉시 **HTTP 403**을 반환하고 이후 단계는 실행되지 않습니다.

허용 모델 목록은 Cosmos DB에서 APIM Named Values로 동기화된 값을 사용합니다. config-sync worker가 `*/5 * * * *` 주기로 갱신합니다.

#### 3단계 — 토큰 기반 속도 제한 (rate limit)

`llm-token-limit` 정책으로 **토큰 소비 속도**를 제어합니다.

- 초과 시 **HTTP 429** 반환
- counter key = `consumerId` (소비자별 독립 버킷)
- 제한 값은 `tokens_per_minute` 변수와 `rate_tiers(small/medium/large)` 설정으로 결정됩니다

([Azure APIM 토큰 한도 정책](https://learn.microsoft.com/en-us/azure/api-management/azure-openai-token-limit-policy))

#### 4단계 — 예산 기반 모델 전환

config-sync worker가 일일 사용량 × 단가를 계산하여 **`active_downgrade`**.level을 Cosmos에 기록하면, APIM 정책은 이 값을 Named Value에서 읽어 body의 `"model"` 필드를 **`downgrade_ladder`**에 따라 재작성합니다.

예: `active_downgrade.level=1`이면 `gpt-5.4` → `gpt-5.4-mini`로 body를 덮어씁니다.

모델 전환은 **항상 동일 백엔드** 내에서 일어납니다(v1 통일로 백엔드 URL 변경 없음, body의 `"model"` 값만 교체). 응답 헤더 `x-ai-gateway-requested-model` / `x-ai-gateway-effective-model` / `x-ai-gateway-downgrade-level`이 추가되어 클라이언트가 실제 전환 여부를 확인할 수 있습니다.

코드 식별자: `downgrade_ladder`, `active_downgrade`, `downgrade_level`.

#### 5단계 — 토큰 메트릭 기록

`llm-emit-token-metric` 정책으로 Application Insights에 토큰 소비량을 기록합니다. 기록하는 차원(dimension)에 `consumerId`가 포함되어 대시보드에서 소비자별 집계가 가능합니다.

([Azure APIM llm-emit-token-metric 정책](https://learn.microsoft.com/en-us/azure/api-management/llm-emit-token-metric-policy))

#### 6단계 — 관리 ID 백엔드 인증 (마지막)

`authentication-managed-identity` 정책이 APIM의 시스템 할당 관리 ID로 Entra ID 토큰을 취득하여 `Authorization: Bearer <token>` 헤더를 백엔드 요청에 첨부합니다.

{% hint style="info" %}
이 단계가 **파이프라인 마지막**에 위치하는 이유는 앞 단계에서 body rewrite가 완료된 뒤에 인증 토큰을 붙여야 하기 때문입니다. 순서를 앞당기면 body 재작성 후 토큰이 재첨부되지 않아 백엔드 인증이 실패할 수 있습니다.
{% endhint %}

백엔드는 키 인증이 비활성화(`local_auth=false`)되어 있으므로 관리 ID 토큰 없이는 도달할 수 없습니다.

([APIM authentication-managed-identity 정책](https://learn.microsoft.com/en-us/azure/api-management/authentication-managed-identity-policy))

---

### 3. 파이프라인 요약 다이어그램

***

파이프라인 다이어그램은 이 절 상단(절 도입부 바로 아래)을 참고하세요.

---

### 4. 관련 참조

***

- 아래 [3. 보안 설계](#3-보안-설계--passwordless-전-구간) 절 — 관리 ID RBAC 설정 상세
- 아래 [4. Cosmos DB 설정 스키마](#4-cosmos-db-설정-스키마) 절 — `downgrade_ladder` / `active_downgrade` 문서 구조
- 아래 [2. Terraform 모듈 구조](#2-terraform-모듈-구조) 절 — APIM 모듈과 정책 파일 위치
- [설정 변경](06-operate.md) — allowed-models·rate-limit 런타임 변경 방법

## 2. Terraform 모듈 구조

***

llm-gateway의 인프라는 `infra/modules/` 아래 기능 단위로 분리된 Terraform 모듈로 구성됩니다. 이 절은 각 모듈의 역할, 모듈 간 의존 관계, 그리고 brownfield(reuse) 모드에서의 동작 차이를 설명합니다.

---

### 1. 모듈 목록

***

| 모듈 디렉터리 | 주요 역할 |
|---|---|
| `modules/network` | VNet, 서브넷, NSG, Private DNS Zone |
| `modules/identity` | 시스템 할당 관리 ID, RBAC 역할 할당 |
| `modules/keyvault` | Azure Key Vault (PE + RBAC 접근) |
| `modules/observability` | Application Insights, Log Analytics Workspace |
| `modules/openai` | Azure OpenAI 전용 계정 및 gpt 모델 배포 (greenfield 전용) |
| `modules/foundry` | Azure AI Foundry(AIServices) 계정 + OSS/파트너 모델 배포 |
| `modules/apim` | Azure API Management 인스턴스, API 정의, 정책 |
| `modules/config_store` | Azure Cosmos DB (설정 저장소) |
| `modules/registry` | Azure Container Registry (워커·Admin UI 이미지) |
| `modules/control_plane` | Container Apps (config-sync worker + Admin UI BFF/SPA) |
| `modules/jumpbox` | 선택적 Windows VM (VNet 내 수동 진단용) |

각 모듈은 **별도 Resource Group**을 생성하거나 게이트웨이 전용 RG 내에 리소스를 배치합니다. 리소스 그룹 이름은 `prefix`·`env`·`location` 조합으로 결정됩니다.

---

### 2. 모듈 간 의존 관계

***

```
network
  └─▶ identity
  └─▶ keyvault
  └─▶ observability
  └─▶ openai           (greenfield, count=1)
  └─▶ foundry          (greenfield: 생성 / reuse: data 소스)
        └─▶ apim       (foundry·openai 백엔드 참조)
  └─▶ config_store
  └─▶ registry
  └─▶ control_plane    (registry, observability, config_store, apim 참조)
  └─▶ jumpbox          (enable_jumpbox=true 시)
```

`apim` 모듈은 `foundry`와 `openai` 모듈의 출력값(엔드포인트 URL, 배포 이름)을 **`gpt_backend_*`** locals로 받아 백엔드 URL을 구성합니다. 이 locals가 단일 AIServices 계정으로의 라우팅을 중재합니다.

---

### 3. Greenfield vs Reuse(Brownfield) 모드

***

**`reuse_foundry`** = `true`로 설정하면 `foundry` 모듈이 리소스 **생성** 대신 **data 소스**로 전환됩니다.

| 항목 | Greenfield (`reuse_foundry=false`) | Brownfield (`reuse_foundry=true`) |
|---|---|---|
| `modules/foundry` 동작 | `azurerm_cognitive_account` 생성 | `data.azurerm_cognitive_account` 로 읽기 |
| `modules/openai` | `count=1` (Azure OpenAI 계정 생성) | `count=0` (생성 안 함) |
| 모델 배포 | `azurerm_cognitive_deployment` 생성 | `for_each={}` (생성 안 함) |
| gpt 라우팅 | openai 모듈 엔드포인트 | foundry 모듈 엔드포인트(동일 AIServices 계정) |
| PE + RBAC | 모두 생성 | **게이트웨이 → 기존 계정** 방향으로 신규 생성 |

Reuse 모드에서는 `modules/openai`가 `count=0`이므로 gpt 트래픽도 foundry 모듈이 참조하는 동일 AIServices 계정의 `/openai/v1` 경로로 라우팅됩니다. `gpt_backend_*` locals가 이 분기를 처리합니다.

{% hint style="warning" %}
`foundry_deployments` map의 key는 AIServices 계정에 실제 등록된 배포 이름과 **정확히 일치**해야 합니다. 이 값이 `allowed_models`, 라우팅, Admin UI 레이블 전체에 사용됩니다.
{% endhint %}

---

### 4. 핵심 변수와 모듈 연결

***

| 변수 | 영향받는 모듈 |
|---|---|
| `reuse_foundry` | `foundry` (data/resource 전환), `openai` (count) |
| `existing_foundry_name` / `existing_foundry_rg` | `foundry` data 소스 |
| `openai_deployments` | `openai` (greenfield 전용) |
| `foundry_deployments` | `foundry` (both modes) |
| `client_auth_mode` | `apim` (validate-jwt vs. 구독키 분기) |
| `enable_jumpbox` | `jumpbox` (count) |

전체 변수 목록은 [변수 전체 목록](10-reference.md)을 참고하세요.

---

### 5. 관련 참조

***

- 위 [1. APIM 정책 파이프라인 — 정책 흐름](#1-apim-정책-파이프라인--정책-흐름) 절 — APIM 모듈이 실행하는 정책 파이프라인
- 아래 [3. 보안 설계](#3-보안-설계--passwordless-전-구간) 절 — identity 모듈의 RBAC 할당 상세
- 아래 [4. Cosmos DB 설정 스키마](#4-cosmos-db-설정-스키마) 절 — config_store 모듈이 사용하는 문서 구조
- [재사용 개요](04-reuse-foundry.md) — brownfield 모드 전체 가이드

## 3. 보안 설계 — Passwordless 전 구간

***

llm-gateway는 API 키·연결 문자열·비밀번호를 어디에도 저장하지 않습니다. 모든 서비스 간 인증은 [Azure 관리 ID(Managed Identity)](https://learn.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/overview)와 [Azure RBAC](https://learn.microsoft.com/en-us/azure/role-based-access-control/overview)으로 처리하며, 네트워크 경계는 Private Endpoint로 격리합니다.

---

### 1. 백엔드 격리 — Private Endpoint + 로컬 인증 비활성화

***

| 리소스 | Private Endpoint | local_auth |
|---|---|---|
| Azure AI Foundry (AIServices) | 게이트웨이 VNet 내 PE 생성 | `disableLocalAuth=true` |
| Azure OpenAI (greenfield) | 게이트웨이 VNet 내 PE 생성 | `disableLocalAuth=true` |

{% hint style="success" %}
`disableLocalAuth=true`이면 API 키로는 호출 자체가 불가능합니다. APIM의 관리 ID가 Entra ID 토큰을 제시해야만 백엔드에 도달할 수 있습니다.
{% endhint %}

Brownfield(reuse) 모드에서는 배포 전 `az` 명령으로 기존 계정에도 동일한 설정을 적용하고, Terraform precondition이 이를 검증합니다. ([계정 잠금 준비](04-reuse-foundry.md))

---

### 2. APIM → 백엔드 인증 (관리 ID + RBAC)

***

APIM 인스턴스는 시스템 할당 관리 ID를 가집니다. 이 ID에 아래 두 가지 Azure 내장 역할이 부여됩니다.

| 역할 | 대상 리소스 | 목적 |
|---|---|---|
| `Cognitive Services OpenAI User` | AIServices / Azure OpenAI 계정 | 채팅·완성 API 호출 |
| `Cognitive Services User` | AIServices / Azure OpenAI 계정 | 계정 메타데이터 읽기 (선택) |

역할 부여는 `modules/identity`에서 `azurerm_role_assignment`로 처리합니다. 수동 작업이 없으며, Terraform이 APIM 관리 ID를 참조하여 배포 시 자동으로 할당합니다.

([Azure RBAC for Cognitive Services](https://learn.microsoft.com/en-us/azure/ai-services/role-based-access-control))

---

### 3. 컨트롤 플레인 인증 (worker·Admin UI)

***

| 컴포넌트 | 인증 방식 | 부여 역할 |
|---|---|---|
| config-sync worker (Container App Job) | 시스템 할당 관리 ID | Cosmos DB: `Cosmos DB Built-in Data Contributor` (데이터 롤) |
| config-sync worker | 동일 관리 ID | Log Analytics Reader (모니터링 메트릭 읽기) |
| Admin UI BFF (FastAPI) | 시스템 할당 관리 ID | Cosmos DB 데이터 롤 |
| Admin UI SPA | Entra ID PKCE (사용자 로그인) | admin 보안 그룹 멤버십으로 접근 제어 |

{% hint style="info" %}
Cosmos DB 데이터 평면 롤 (`Cosmos DB Built-in Data Contributor`)은 컨트롤 플레인이 설정 문서를 읽고 쓸 수 있도록 합니다. 연결 문자열이나 마스터 키를 사용하지 않습니다.
{% endhint %}

([Azure Cosmos DB RBAC](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-setup-rbac))

---

### 4. 시크릿 관리 — Key Vault

***

**Key Vault**는 `modules/keyvault`가 생성하며, Private Endpoint와 RBAC 접근으로 보호됩니다.

| 저장 항목 | 저장소 |
|---|---|
| 인증서, 비밀 값 등 진짜 시크릿 | Azure Key Vault |
| `allowed_models`, token limits 등 비시크릿 설정 | Cosmos DB + APIM Named Values |
| API 키·연결 문자열 | **저장하지 않음** |

APIM Named Values는 Key Vault 참조 형식으로 시크릿을 간접 참조할 수 있습니다. config-sync worker가 Cosmos에서 읽은 값을 APIM Named Values로 동기화합니다.

([Azure Key Vault 개요](https://learn.microsoft.com/en-us/azure/key-vault/general/overview)) · ([APIM Key Vault 참조](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-properties#key-vault-secrets))

---

### 5. 네트워크 격리

***

모든 백엔드(AIServices, Cosmos DB, ACR, Key Vault)는 퍼블릭 네트워크 접근이 비활성화되거나 VNet 서브넷으로만 접근이 허용됩니다. APIM은 `apim_public=true`일 때만 인터넷에 노출되며, 백엔드는 항상 Private Endpoint 경유로만 통신합니다.

([Azure Private Link 개요](https://learn.microsoft.com/en-us/azure/private-link/private-link-overview))

---

### 6. 보안 원칙 요약

***

{% hint style="info" %}
- **키 없음**: API 키, 연결 문자열, SAS 토큰이 코드·설정·git 히스토리 어디에도 없습니다
- **최소 권한**: 각 컴포넌트는 자신의 업무에 필요한 역할만 보유합니다
- **네트워크 경계**: 백엔드는 Private Endpoint + 퍼블릭 네트워크 차단
- **감사 추적**: 모든 Entra ID 토큰 발급·RBAC 변경은 Azure 감사 로그에 기록됩니다
{% endhint %}

---

### 7. 관련 참조

***

- 위 [1. APIM 정책 파이프라인 — 정책 흐름](#1-apim-정책-파이프라인--정책-흐름) 절 — 런타임 MI 인증이 정책 파이프라인 마지막 단계에서 실행되는 이유
- 아래 [4. Cosmos DB 설정 스키마](#4-cosmos-db-설정-스키마) 절 — config-sync worker의 Cosmos 접근 구조
- [C — Entra ID 클라이언트 인증](10-reference.md) — 클라이언트 측 키 없는 인증 확장

## 4. Cosmos DB 설정 스키마

***

llm-gateway는 Azure Cosmos DB를 **설정 저장소**로 사용합니다. APIM 정책에 필요한 모든 거버넌스 설정(허용 모델, 토큰 한도, 예산, 가격)이 여기 저장되며, config-sync worker가 주기적으로 읽어 APIM Named Values로 동기화합니다.

{% hint style="info" %}
Cosmos DB 계정은 Private Endpoint로 격리되고 키 인증이 비활성화됩니다. 모든 접근은 관리 ID + RBAC 데이터 롤로만 가능합니다.
{% endhint %}

---

### 1. 컨테이너 구조

***

| 컨테이너 | 파티션 키 | 주요 문서 |
|---|---|---|
| `config` | `/id` | `global` (전역 기본값), 소비자별 문서 |
| `pricing` | `/id` | `pricing` (모델별 토큰 단가) |

---

### 2. `global` 문서 (id = "global")

***

전체 소비자에게 적용되는 기본값을 정의합니다. 소비자별 문서가 없으면 이 값이 적용됩니다.

```json
{
  "id": "global",
  "allowed_models": ["gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro"],
  "token_limits": {
    "tokens_per_minute": 1000,
    "token_quota": 50000,
    "token_quota_period": "Daily"
  }
}
```

| 필드 | 설명 |
|---|---|
| `allowed_models` | 게이트웨이 전체에서 허용되는 기본 모델 목록 |
| `token_limits.tokens_per_minute` | 분당 토큰 속도 제한 기본값 |
| `token_limits.token_quota` | 기간당 토큰 할당량 기본값 |
| `token_limits.token_quota_period` | 할당량 초기화 주기 (`Daily` / `Monthly`) |

---

### 3. `pricing` 문서 (id = "pricing")

***

config-sync worker가 일일 예산 계산 시 사용하는 모델별 토큰 단가입니다. `seed-pricing-jumpbox.sh`로 초기화합니다.

```json
{
  "id": "pricing",
  "per_1k_tokens": {
    "gpt-5.4": 0.015,
    "gpt-5.4-mini": 0.003,
    "grok-4.3": 0.009,
    "DeepSeek-V4-Pro": 0.005
  }
}
```

`per_1k_tokens` 값은 1,000 토큰당 USD 단가입니다. 이 값과 일일 토큰 사용량을 곱해 예산 소진율을 계산합니다.

---

### 4. 소비자별 문서 (id = `<consumerId>`)

***

특정 소비자에 대해 전역 기본값을 덮어씁니다.

```json
{
  "id": "team-a",
  "allowed_models": ["gpt-5.4", "gpt-5.4-mini"],
  "tier": "medium",
  "daily_budget_usd": 50.0,
  "downgrade_ladder": [
    { "level": 0, "model": "gpt-5.4" },
    { "level": 1, "model": "gpt-5.4-mini" }
  ],
  "active_downgrade": {
    "level": 0,
    "updated_at": "2026-06-26T00:00:00Z"
  }
}
```

| 필드 | 설명 |
|---|---|
| `allowed_models` | 이 소비자에게만 허용되는 모델 (전역 기본값 override) |
| `tier` | rate tier (`small` / `medium` / `large`) |
| `daily_budget_usd` | 일일 USD 예산 한도 |
| **`downgrade_ladder`** | 레벨별 모델 전환 매핑 (level 0 = 원래 모델, 1+ = 예산 초과 시 전환) |
| **`active_downgrade`**.level | **현재 적용 중인 전환 레벨**. config-sync worker가 매 동기화 사이클에 갱신합니다 |
| `active_downgrade.updated_at` | 레벨이 마지막으로 변경된 시각 (ISO 8601) |

`downgrade_ladder`의 `level` 값이 높을수록 저비용 모델로 전환됩니다. APIM 정책은 `active_downgrade.level`에 해당하는 `model` 값을 body에 주입합니다.

---

### 5. config-sync worker의 동기화 흐름

***

```
Cosmos DB (config 컨테이너)
    │
    │  1) 전역·소비자 문서 읽기
    ▼
config-sync worker (Container App Job)
    │
    │  2) 일일 사용량(App Insights) × pricing 단가 계산
    │     → active_downgrade.level 업데이트 (Cosmos 쓰기)
    │
    │  3) allowed_models, token limits, downgrade level
    │     → APIM Named Values 동기화
    ▼
APIM Named Values (정책 런타임에 참조)
```

동기화 주기: `config_sync_cron` 변수 (기본 `*/5 * * * *`, 5분마다).

---

### 6. Seed 스크립트

***

초기 문서 삽입은 아래 스크립트로 수행합니다. 두 스크립트 모두 jumpbox의 관리 ID를 이용한 passwordless 접근입니다.

```bash
# global 설정 문서 초기화
./scripts/seed-cosmos-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/

# pricing 문서 초기화
./scripts/seed-pricing-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
```

자세한 실행 방법은 [Seed 및 최종 설정](03-deploy.md)을 참고하세요.

---

### 7. 관련 참조

***

- 위 [1. APIM 정책 파이프라인 — 정책 흐름](#1-apim-정책-파이프라인--정책-흐름) 절 — APIM이 Named Values에서 `active_downgrade.level`을 읽어 모델 전환하는 방법
- 위 [3. 보안 설계](#3-보안-설계--passwordless-전-구간) 절 — Cosmos DB RBAC 접근 구조
- [설정 변경](06-operate.md) — 런타임 중 소비자 문서 수정 방법
- [Seed 및 최종 설정](03-deploy.md) — seed 스크립트 실행 상세
