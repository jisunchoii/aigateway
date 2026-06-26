---
description: 플랫폼 엔지니어·IaC 담당자를 위한 페이지 · 선행: 배포 개요
---

# Terraform 모듈 구조

llm-gateway의 인프라는 `infra/modules/` 아래 기능 단위로 분리된 Terraform 모듈로 구성됩니다. 이 페이지는 각 모듈의 역할, 모듈 간 의존 관계, 그리고 brownfield(reuse) 모드에서의 동작 차이를 설명합니다.

---

## 1. 모듈 목록

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

## 2. 모듈 간 의존 관계

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

## 3. Greenfield vs Reuse(Brownfield) 모드

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

## 4. 핵심 변수와 모듈 연결

***

| 변수 | 영향받는 모듈 |
|---|---|
| `reuse_foundry` | `foundry` (data/resource 전환), `openai` (count) |
| `existing_foundry_name` / `existing_foundry_rg` | `foundry` data 소스 |
| `openai_deployments` | `openai` (greenfield 전용) |
| `foundry_deployments` | `foundry` (both modes) |
| `client_auth_mode` | `apim` (validate-jwt vs. 구독키 분기) |
| `enable_jumpbox` | `jumpbox` (count) |

전체 변수 목록은 [변수 전체 목록](../10-reference/variables.md)을 참고하세요.

---

## 5. 관련 페이지

***

- [정책 흐름](policy-flow.md) — APIM 모듈이 실행하는 정책 파이프라인
- [보안 설계](security-design.md) — identity 모듈의 RBAC 할당 상세
- [Cosmos DB 설정 스키마](cosmos-schema.md) — config_store 모듈이 사용하는 문서 구조
- [재사용 개요](../04-reuse-foundry/overview.md) — brownfield 모드 전체 가이드
