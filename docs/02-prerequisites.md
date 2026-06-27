---
description: "배포 전 준비 — Azure 요구사항, Entra ID 객체, Greenfield/Brownfield 결정"
---

# 사전 준비

이 챕터에서는 LLM Gateway 배포 전에 갖춰야 할 세 가지를 순서대로 다룹니다.

- [Azure 요구사항](#1-azure-요구사항)
- [Entra ID 객체](#2-entra-id-객체)
- [Greenfield vs Brownfield 결정](#3-greenfield-vs-brownfield-결정)

---

## 1. Azure 요구사항

***

### 구독·권한

- **Azure 구독** 1개 이상 필요. 게이트웨이 리소스(APIM, AIServices, Cosmos DB, Container Apps 등)가 모두 같은 구독에 배포됩니다.
- 배포 실행자는 해당 구독에서 **Contributor + User Access Administrator** 역할(또는 동등한 커스텀 역할)이 필요합니다. Terraform이 RBAC 역할 할당을 자동으로 수행하기 때문입니다.

---

### 모델 쿼터

배포 전에 아래 모델의 쿼터가 목표 지역에 충분히 확보되어 있는지 확인하세요.

| 모델 | 타입 | 쿼터 확인 위치 |
|---|---|---|
| gpt-5.4 | Azure OpenAI | Azure 포털 → Azure OpenAI → 쿼터 |
| gpt-5.4-mini | Azure OpenAI | 동일 |
| grok-4.3 | Azure AI Foundry (파트너) | Azure 포털 → AI Foundry 허브 |
| DeepSeek-V4-Pro | Azure AI Foundry (파트너) | 동일 |

{% hint style="info" %}
**파트너 모델 참고:** grok-4.3, DeepSeek-V4-Pro 등 파트너 모델은 테넌트에서 **마켓플레이스 약관 동의**가 필요할 수 있습니다. Azure 포털의 배포 플로우에서 약관에 동의한 뒤 재시도하세요.
{% endhint %}

기본 쿼터가 낮은 경우 [Azure OpenAI 쿼터 증설 요청](https://learn.microsoft.com/ko-kr/azure/ai-services/openai/quotas-limits)을 통해 사전에 증설하세요.

---

### 지원 지역

검증된 지역:

- `koreacentral` (기본값, Terraform 변수 `location`)
- `eastus2`

APIM Developer/Premium SKU와 AIServices VNet 통합이 지원되는 지역이면 대부분 동작합니다. 지역별 서비스 가용성은 [Azure 제품 지역별 가용성](https://azure.microsoft.com/ko-kr/explore/global-infrastructure/products-by-region/)에서 확인하세요.

---

### 필요 도구

로컬 머신에 아래 도구만 있으면 됩니다. **Docker는 불필요**합니다(컨테이너 이미지는 Azure Container Registry remote build로 처리).

| 도구 | 최소 버전 | 설치·확인 |
|---|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) | ≥ 1.7 | `terraform version` |
| [Azure CLI](https://learn.microsoft.com/ko-kr/cli/azure/install-azure-cli) | 최신 안정 | `az version` |
| az login | — | `az login` 으로 구독 인증 |

```bash
# 버전 확인
terraform version
az version

# Azure 로그인 (Entra ID 기반)
az login
az account set --subscription "<구독 ID>"
```

{% hint style="info" %}
**인증 방식:** 모든 Azure CLI 및 Terraform 작업은 `az login`으로 얻은 Entra ID 기반 토큰을 사용합니다. API 키나 서비스 주체 시크릿을 환경 변수에 노출하지 않습니다.
{% endhint %}

---

### Terraform azurerm provider

`infra/providers.tf`에서 `hashicorp/azurerm` 공급자 버전이 고정되어 있습니다. 첫 `terraform init` 시 자동 다운로드됩니다.

```bash
cd infra
terraform init
```

공급자 문서: [azurerm Terraform Registry](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)

---

## 2. Entra ID 객체

***

Terraform은 대부분의 Azure 리소스를 자동 생성하지만, **Entra ID 객체 3종은 Terraform이 생성할 수 없습니다**. 첫 배포 전 한 번만 수동으로 생성하면 됩니다. `./scripts/app-registration.sh` 스크립트가 이 과정을 자동화합니다.

---

### 왜 Terraform이 생성하지 못하는가

`azurerm` provider는 Entra ID(구 Azure AD) 앱 등록과 그룹 생성을 직접 지원하지 않습니다. `azuread` provider를 별도로 구성해야 하며, 권한 분리 원칙상 IaC 실행자에게 디렉터리 쓰기 권한을 주지 않는 조직도 많습니다. 따라서 Entra ID 객체는 스크립트로 먼저 생성하고, 생성된 ID를 tfvars에 입력하는 방식을 취합니다.

{% hint style="info" %}
**📸 [스크린샷 자리]** — Azure Portal — Entra ID 보안 그룹 생성 화면
{% endhint %}

---

### 3종 객체 상세

#### ① Admin 보안 그룹

Admin UI에 접근할 수 있는 사용자 그룹입니다. Entra ID 보안 그룹의 Object ID를 tfvars에 전달합니다.

| 속성 | 값 |
|---|---|
| 유형 | Entra ID 보안 그룹 |
| 목적 | Admin UI 접근 제어 (그룹 멤버만 관리 기능 접근 가능) |
| tfvars 변수 | `admin_group_object_id` |

```hcl
# infra/terraform.tfvars
admin_group_object_id = "<entra security group object id>"
```

참고: [Microsoft Entra 보안 그룹 관리](https://learn.microsoft.com/ko-kr/entra/fundamentals/how-to-manage-groups)

---

#### ② BFF API 앱등록

Admin UI의 FastAPI BFF(Backend For Frontend)가 사용하는 앱 등록입니다. SPA가 이 API에 접근할 때 Bearer 토큰을 발급받는 대상(audience)이 됩니다.

| 속성 | 값 |
|---|---|
| 유형 | Entra ID 앱 등록 (웹 API) |
| 노출 스코프 | `access_as_user` |
| 토큰 버전 | `requestedAccessTokenVersion=2` (v2.0 토큰) |
| tfvars 변수 | `bff_api_audience` |

```hcl
# infra/terraform.tfvars
bff_api_audience = "api://<bff app id>"
```

`bff_api_audience` 형식은 반드시 `api://` 접두사를 포함합니다. 앱 등록 생성 후 **앱 ID URI**를 확인하세요.

참고: [앱 등록에 API 범위 노출](https://learn.microsoft.com/ko-kr/entra/identity-platform/quickstart-configure-app-expose-web-apis)

---

#### ③ SPA public-client 앱등록

Admin UI React SPA가 사용하는 public-client 앱 등록입니다. 시크릿이 없고 PKCE 흐름으로 인증합니다.

| 속성 | 값 |
|---|---|
| 유형 | Entra ID 앱 등록 (SPA, public client) |
| 인증 흐름 | Authorization Code + PKCE (시크릿 없음) |
| redirect URI | Admin UI FQDN (`https://<admin-ui-fqdn>`) — 두 번째 apply 후 등록 |
| tfvars 변수 | `spa_client_id` |

```hcl
# infra/terraform.tfvars
spa_client_id = "<spa app id>"
```

redirect URI는 두 번째 `terraform apply` 이후 `admin_ui_fqdn` 출력값이 확정되면 등록합니다. 자동화된 등록 명령은 [배포 — Seed 및 최종 설정](03-deploy.md)을 참고하세요.

참고: [단일 페이지 앱 등록](https://learn.microsoft.com/ko-kr/entra/identity-platform/scenario-spa-app-registration)

---

### app-registration.sh 스크립트

위 3종 객체를 한 번에 생성하는 스크립트입니다.

```bash
# 사전 조건: az login 완료, 구독 설정 완료
./scripts/app-registration.sh
```

스크립트 실행 후 출력되는 값을 `infra/terraform.tfvars`에 입력합니다.

```hcl
admin_group_object_id = "<출력된 그룹 Object ID>"
bff_api_audience      = "api://<출력된 BFF App ID>"
spa_client_id         = "<출력된 SPA App ID>"
```

---

### 객체 → tfvars 변수 매핑 요약

| Entra ID 객체 | tfvars 변수 | 예시 값 |
|---|---|---|
| Admin 보안 그룹 | `admin_group_object_id` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| BFF API 앱등록 | `bff_api_audience` | `api://yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy` |
| SPA public-client | `spa_client_id` | `zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz` |

---

## 3. Greenfield vs Brownfield 결정

***

배포를 시작하기 전에 **AIServices(Foundry) 계정을 새로 만들 것인지, 아니면 구독 내 기존 계정을 재사용할 것인지** 결정해야 합니다. 이 결정에 따라 이어지는 배포 챕터가 달라집니다.

---

### 핵심 원칙

- **Greenfield:** Terraform이 AIServices 계정과 모델 배포를 포함한 모든 리소스를 신규 생성합니다.
- **Brownfield (reuse_foundry=true):** 기존 AIServices 계정은 `data` 소스로 읽기만 하고, Terraform은 Private Endpoint와 RBAC 할당만 신규 생성합니다. 핵심 원칙은 **"data로 읽기 + PE/RBAC만 신규"**입니다.

---

### 의사결정 플로우

<figure><img src="images/diagram-greenfield-vs-brownfield.png" alt="Greenfield(신규 생성) vs Brownfield(기존 Foundry 재사용) 비교"><figcaption>🖼️ Greenfield(신규 생성) vs Brownfield(기존 Foundry 재사용) 비교 <em>(다이어그램 이미지 추가 예정)</em></figcaption></figure>

---

### 비교 표

| 리소스 | Greenfield (기본) | Brownfield (reuse_foundry=true) |
|---|---|---|
| 게이트웨이 RG | 생성 (별도 RG) | 생성 (별도 RG, 변경 없음) |
| AIServices 계정 | `azurerm_cognitive_account` 생성 | **data로 읽기** (생성 안 함) |
| 모델 배포 | `azurerm_cognitive_deployment` 생성 | **생성 안 함** (`for_each={}`) |
| 계정 속성(local_auth off·public block) | Terraform이 설정 | **배포 전 `az` 토글 + precondition 검증** |
| Private Endpoint | 생성 | **생성** (게이트웨이 VNet → 기존 계정) |
| APIM MI RBAC | 부여 | **부여** |

---

### Brownfield 제약사항

1. **같은 구독만 지원.** 게이트웨이와 기존 AIServices 계정이 **같은 Azure 구독**에 있어야 합니다. 교차 구독 재사용은 현재 지원하지 않습니다.

2. **계정 잠금 사전 준비 필요.** Brownfield 경로에서는 Terraform `apply` 전에 `az` CLI로 기존 계정의 `disableLocalAuth=true`, `publicNetworkAccess=Disabled`를 수동으로 설정해야 합니다. Terraform의 `precondition`이 이를 검증합니다.

{% hint style="warning" %}
Brownfield 경로에서는 `terraform apply` 전에 반드시 기존 AIServices 계정에 `disableLocalAuth=true`, `publicNetworkAccess=Disabled`를 설정하세요. 사전 준비 없이 apply하면 `precondition` 검증에서 실패합니다.
{% endhint %}

3. **foundry_deployments 키 = 실제 배포 이름.** `foundry_deployments` tfvars의 map 키가 계정에 실제로 존재하는 배포 이름과 **정확히 일치**해야 합니다. 이 값이 `allowed_models`, 라우팅, Admin UI 레이블에 모두 사용됩니다.

{% hint style="danger" %}
`foundry_deployments` map 키가 실제 배포 이름과 다르면 라우팅이 조용히 실패하거나 잘못된 모델로 연결됩니다. apply 전에 `az cognitiveservices account deployment list` 출력과 대조해 키를 정확히 맞추세요.
{% endhint %}

---

### 각 경로의 tfvars 핵심 차이

**Greenfield (기본값, 별도 설정 불필요):**
```hcl
reuse_foundry         = false   # 기본값
```

**Brownfield:**
```hcl
reuse_foundry         = true
existing_foundry_name = "ais-customer-prod"
existing_foundry_rg   = "rg-customer-ai"
# foundry_deployments에 기존 계정의 실제 배포 이름을 키로 선언
foundry_deployments = {
  "grok-4.3"          = { ... }
  "DeepSeek-V4-Pro"   = { ... }
}
```

---

### 결정 후 다음 단계

- [03 배포 — 새 AIServices 계정 포함 전체 스택 (Greenfield)](03-deploy.md)
- [04 기존 Foundry 재사용 — 기존 Foundry 계정 재사용 (Brownfield)](04-reuse-foundry.md)
