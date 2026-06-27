---
description: "기존 AIServices(Foundry) 계정 재사용 — 잠금 준비, tfvars, plan 검증"
---

# 기존 Foundry 재사용

이 챕터는 이미 구독에 Azure AIServices(Foundry) 계정이 존재하는 **brownfield** 시나리오를 다룹니다.
게이트웨이는 기존 계정과 그 안의 모델 배포를 전혀 건드리지 않고, Private Endpoint와 RBAC만 새로 추가해 붙습니다.

- [재사용 개요](#1-기존-foundry-재사용-개요)
- [계정 잠금 준비](#2-계정-잠금-사전-준비)
- [tfvars 구성](#3-tfvars-설정--재사용-모드)
- [Plan 검증 및 apply](#4-plan--apply)

## 1. 기존 Foundry 재사용 개요

***

{% hint style="success" %}
**핵심 원리 — data로 읽기 + PE/RBAC만 신규**
기존 Foundry 계정·모델을 건드리지 않고, 게이트웨이가 **Private Endpoint**와 **RBAC**만 추가해 붙습니다.
Terraform은 계정을 `data` 소스로만 참조하며 생성·수정·삭제 동작이 일절 없습니다.
{% endhint %}

재사용 모드(`reuse_foundry=true`)에서 Terraform은 기존 AIServices 계정을 `data` 소스로 참조합니다.
계정 생성(`azurerm_cognitive_account`)도 모델 배포(`azurerm_cognitive_deployment`)도 없습니다.
대신 게이트웨이 VNet에서 기존 계정 쪽으로 새 **Private Endpoint**를 뻗고, APIM의 **Managed Identity**에 필요한 RBAC 역할을 부여합니다.

고객 계정은 수정되지 않으며, 이미 서비스 중인 모델 배포는 그대로 유지됩니다.
게이트웨이는 그 위에 얹히는 거버넌스 레이어일 뿐입니다.

<figure><img src="images/diagram-reuse-topology.png" alt="재사용 토폴로지 — 기존 Foundry 계정에 게이트웨이 VNet의 새 Private Endpoint를 연결"><figcaption>재사용 토폴로지 — 기존 Foundry 계정에 게이트웨이 VNet의 새 Private Endpoint를 연결 <em>(다이어그램 이미지 추가 예정)</em></figcaption></figure>

*왼쪽: 기존 Foundry 계정(격리) / 오른쪽: 게이트웨이 VNet에서 신규 PE·RBAC만 추가해 연결*

### 1. 핵심 원리: "data로 읽기 + PE/RBAC만 신규"

***

재사용 모드에서 Terraform이 실제로 하는 일:

- 기존 AIServices 계정을 `data` 소스로 참조 (읽기 전용)
- 게이트웨이 VNet에 새 **Private Endpoint** 생성
- APIM Managed Identity에 RBAC 역할 부여

### 2. Greenfield vs Brownfield 리소스 비교

***

| 리소스 | greenfield (기본) | brownfield (`reuse_foundry=true`) |
|---|---|---|
| 게이트웨이 RG | 생성 (별도 RG) | 생성 (별도 RG, 변경 없음) |
| AIServices 계정 | `azurerm_cognitive_account` 생성 | **data로 읽기** (생성 안 함) |
| 모델 배포 | `azurerm_cognitive_deployment` 생성 | **생성 안 함** (`for_each={}`) |
| 계정 속성(local\_auth off·public block) | Terraform이 설정 | **배포 전 `az` 토글 + precondition 검증** |
| Private Endpoint | 생성 | **생성** (게이트웨이 VNet → 기존 계정) |
| APIM MI RBAC | 부여 | **부여** |

단일 AIServices 계정이 gpt 계열과 OSS 모델(grok-4.3, DeepSeek-V4-Pro)을 함께 호스팅합니다.
재사용 모드에서는 `modules/openai`의 `count=0`이 되어 별도 OpenAI 리소스를 만들지 않으며, gpt 요청도 동일한 AIServices 계정의 `/openai/v1` 엔드포인트로 라우팅됩니다.

### 3. 같은 구독 제약

***

{% hint style="warning" %}
재사용 모드는 **동일 Azure 구독** 내에서만 동작합니다.
- 기존 Foundry 계정이 **다른 구독**에 있으면 재사용 모드를 사용할 수 없습니다.
- 구독 간 시나리오는 현재 지원 범위 밖입니다.
{% endhint %}

### 4. Foundry가 다른 RG/VNet에 있어도 괜찮은 이유

***

- 게이트웨이는 기존 Foundry의 VNet 안으로 들어가지 않습니다.
- **게이트웨이 전용 VNet에서** 기존 계정을 향해 새 **Private Endpoint**를 뻗는 방식입니다.
- Foundry가 완전히 다른 리소스 그룹이나 별도 VNet에 있어도 문제없습니다.
- Private Endpoint는 구독 내에서 계정 resource ID만 알면 생성할 수 있습니다.

### 5. 왜 이 방식이 안전한가

***

- **고객 계정 무수정**: `az` 명령으로 `disableLocalAuth`와 `publicNetworkAccess`를 잠그는 것은 고객이 직접 사전 작업으로 수행하며, Terraform이 계정 속성을 변경하지 않습니다.
- **모델 무수정**: 기존 모델 배포에 대한 `create/update/delete` 동작이 전혀 없습니다.
- **최소 권한 RBAC**: APIM Managed Identity에는 `Cognitive Services OpenAI User` 등 필요한 역할만 부여되며, 키 기반 접근은 비활성화 상태를 유지합니다.
- **격리된 네트워크 경로**: 새 PE는 게이트웨이 VNet에 귀속되므로, 기존 Foundry의 네트워크 구성을 바꾸지 않습니다.

### 6. 참고 문서

***

- [Azure AI Services (Cognitive Services) 개요](https://learn.microsoft.com/ko-kr/azure/ai-services/what-are-ai-services)
- [Azure Private Endpoint란?](https://learn.microsoft.com/ko-kr/azure/private-link/private-endpoint-overview)
- [Azure RBAC란?](https://learn.microsoft.com/ko-kr/azure/role-based-access-control/overview)
- [Azure AI Foundry에서 관리 ID 사용](https://learn.microsoft.com/ko-kr/azure/ai-foundry/how-to/managed-identity)

## 2. 계정 잠금 사전 준비

***

게이트웨이는 APIM Managed Identity와 RBAC만으로 AIServices 계정에 접근합니다.
키 기반 인증이 활성화되어 있거나 공용 네트워크 접근이 열려 있으면, 보안 태세가 약해지고 게이트웨이의 설계 전제가 무너집니다.
따라서 **Terraform apply 전에** 고객이 직접 기존 AIServices 계정을 passwordless 상태로 잠가야 합니다.

{% hint style="danger" %}
**왜 Terraform이 직접 하지 않나?**
재사용 모드에서 Terraform은 기존 계정을 `data` 소스로만 읽습니다. 기존 계정의 속성을 Terraform이 관리하기 시작하면 상태 파일에 계정이 들어오고, 이후 `terraform destroy` 시 계정이 삭제될 위험이 있습니다. 고객이 직접 `az` 명령으로 잠그는 방식이 훨씬 안전합니다.
{% endhint %}

### 1. 사전 확인: 계정 resource ID 조회

***

```bash
az resource list \
  --resource-type "Microsoft.CognitiveServices/accounts" \
  --query "[].{name:name, id:id, rg:resourceGroup}" \
  -o table
```

`existing_foundry_name`과 `existing_foundry_rg`에 사용할 이름을 확인합니다.
계정 resource ID(`<aiservices-account-id>`)는 아래 명령에서 `--ids` 인수로 사용합니다.

### 2. 계정 잠금

***

```bash
az resource update --ids <aiservices-account-id> \
  --set properties.disableLocalAuth=true properties.publicNetworkAccess=Disabled
```

- `disableLocalAuth=true`: API 키 기반 인증을 비활성화합니다. Entra ID(관리 ID 포함)만 허용됩니다.
- `publicNetworkAccess=Disabled`: 공용 인터넷에서의 직접 접근을 차단합니다. Private Endpoint 경유만 허용됩니다.

### 3. 잠금 확인

***

```bash
az resource show --ids <aiservices-account-id> \
  --query "properties.{disableLocalAuth:disableLocalAuth, publicNetworkAccess:publicNetworkAccess}" -o jsonc
```

기대 출력:

```jsonc
{
  "disableLocalAuth": true,
  "publicNetworkAccess": "Disabled"
}
```

두 값이 모두 올바르면 Terraform 배포를 진행해도 됩니다.

### 4. 주의 사항

***

#### 기존 직접 접근이 끊길 수 있다

{% hint style="warning" %}
`publicNetworkAccess=Disabled`로 설정하면 공용 인터넷에서 해당 계정의 엔드포인트에 직접 붙는 모든 클라이언트가 즉시 차단됩니다.
게이트웨이 배포가 완료되어 Private Endpoint가 생성되기 전까지는 계정이 사실상 고립됩니다.
**잠금 → apply → 검증** 순서를 한 번에 진행하거나, 유지보수 창(maintenance window)을 잡고 진행할 것을 권장합니다.
{% endhint %}

#### `disableLocalAuth` 되돌리기

{% hint style="warning" %}
필요한 경우 아래 명령으로 원복할 수 있습니다. 단, 게이트웨이가 운영 중인 상태에서는 키 기반 접근을 다시 여는 것이 보안 규정 위반이 될 수 있으므로 주의합니다.
{% endhint %}

```bash
az resource update --ids <aiservices-account-id> \
  --set properties.disableLocalAuth=false
```

---

> **[각주] 파트너 모델 marketplace 약관 (gotcha 5)**
> grok-4.3, DeepSeek-V4-Pro 같은 파트너 모델은 테넌트에서 marketplace 약관 동의가 필요할 수 있습니다.
> 기존 계정에 이미 해당 모델 배포가 있다면 약관은 이미 동의된 상태입니다.
> 그러나 새 테넌트에서 처음 사용하는 경우, Azure 포털의 배포 플로우에서 약관에 동의한 뒤 재시도해야 합니다.
> 자세한 내용은 [10-reference.md](10-reference.md)를 참고합니다.

### 5. 참고 문서

***

- [Cognitive Services 로컬 인증 비활성화](https://learn.microsoft.com/ko-kr/azure/ai-services/disable-local-auth)
- [Azure Cognitive Services에서 Private Link 사용](https://learn.microsoft.com/ko-kr/azure/ai-services/cognitive-services-virtual-networks)
- [Azure AI Services용 관리 ID](https://learn.microsoft.com/ko-kr/azure/ai-services/cognitive-services-virtual-networks#use-private-endpoints)

### 6. 다음 단계

***

계정 잠금을 확인했으면 아래 『tfvars 설정 — 재사용 모드』 절로 넘어갑니다.

## 3. tfvars 설정 — 재사용 모드

***

기존 Foundry 계정을 재사용하는 경우, `infra/terraform.tfvars`에 아래 변수들을 추가하거나 수정합니다.
그린필드 배포 시 사용하는 나머지 변수(`prefix`, `location`, `owner` 등)는 [03-deploy.md](03-deploy.md)를 참고합니다.

### 1. 핵심 스위치

***

```hcl
reuse_foundry         = true
existing_foundry_name = "ais-customer-prod"
existing_foundry_rg   = "rg-customer-ai"
```

| 변수 | 설명 |
|---|---|
| `reuse_foundry` | `true`로 설정하면 재사용 모드 활성화. `false`(기본)이면 새 AIServices 계정을 생성하는 greenfield 모드. |
| `existing_foundry_name` | 재사용할 AIServices 계정의 Azure 리소스 이름 (포털·`az resource list`에서 확인). |
| `existing_foundry_rg` | 해당 계정이 속한 리소스 그룹 이름. 게이트웨이 RG와 달라도 됩니다. |

### 2. foundry\_deployments: 이미 존재하는 모델 선언

***

```hcl
foundry_deployments = {
  "grok-4.3"         = { model_name = "grok-4.3",          sku = "GlobalStandard", capacity = 1 }
  "DeepSeek-V4-Pro"  = { model_name = "DeepSeek-V4-Pro",   sku = "GlobalStandard", capacity = 1 }
}
```

{% hint style="danger" %}
**중요: 키가 실제 배포 이름과 완전히 일치해야 합니다.**

`foundry_deployments`의 키(map key)는 AIServices 계정에 실제로 존재하는 배포 이름이어야 합니다.
Azure 포털 → AI Foundry → 해당 계정 → "모델 배포"에서 배포 이름을 확인할 수 있습니다.

키가 틀리면 다음 세 곳이 **조용히(silently) 깨집니다**:
- `allowed_models` 검사: 허용 목록에 없는 모델로 인식되어 403 반환
- 라우팅: 잘못된 모델 이름이 백엔드 요청 body에 들어가 404/422 반환
- Admin UI 라벨: 존재하지 않는 배포 이름이 표시되어 운영 혼란 야기
{% endhint %}

재사용 모드에서 `foundry_deployments`는 모델을 **생성하지 않습니다**(`for_each={}` 처리됨).
기존 배포가 실제로 있는지 선언하는 역할만 하며, 그 값을 기반으로 allowed\_models, 라우팅, Admin UI 라벨이 구성됩니다.

### 3. openai\_deployments는 무시됩니다

***

재사용 모드(`reuse_foundry=true`)에서는 `openai_deployments` 변수가 무시됩니다.
`modules/openai`의 `count=0`이 되어 별도 Azure OpenAI 리소스가 생성되지 않으며, gpt 계열 요청도 `existing_foundry_name` 계정의 `/openai/v1` 엔드포인트로 라우팅됩니다.

따라서 재사용 모드에서는 tfvars에서 `openai_deployments`를 정의하지 않거나, 정의하더라도 실제로 적용되지 않습니다.

### 4. 전체 재사용 tfvars 예시

***

```hcl
# -- 공통 (greenfield와 동일) --
prefix         = "aigw"
env            = "dev"
location       = "koreacentral"
owner          = "<owner>"
cost_center    = "<cost-center>"
apim_public    = true

# -- 재사용 모드 --
reuse_foundry         = true
existing_foundry_name = "ais-customer-prod"
existing_foundry_rg   = "rg-customer-ai"

# foundry_deployments: 키 = 실제 배포 이름 (대소문자 포함 정확히 일치)
foundry_deployments = {
  "grok-4.3"         = { model_name = "grok-4.3",         sku = "GlobalStandard", capacity = 1 }
  "DeepSeek-V4-Pro"  = { model_name = "DeepSeek-V4-Pro",  sku = "GlobalStandard", capacity = 1 }
}

# -- 예산·레이트 리밋 (greenfield와 동일) --
monthly_budget_amount = 200
budget_alert_email    = "<email>"
budget_start_date     = "<YYYY-MM-01>"
```

### 5. 다음 단계

***

tfvars 편집을 마쳤으면 아래 『Plan & Apply』 절로 넘어갑니다.

## 4. Plan & Apply

***

### 1. terraform plan — 재사용 단언 확인

***

`terraform apply` 전에 반드시 `plan`을 실행해 재사용이 제대로 설정됐는지 확인합니다.

```bash
cd infra
terraform init   # 최초 1회 또는 provider 변경 시
terraform plan
```

#### 재사용이 진짜 됐다는 증거 — plan 출력에서 확인할 항목

재사용 모드가 올바르게 설정됐다면 plan 결과는 반드시 다음 조건을 충족해야 합니다.

| 확인 항목 | 기대값 |
|---|---|
| `azurerm_cognitive_account` 생성 수 | **0** |
| `azurerm_cognitive_deployment` 생성 수 | **0** |
| Foundry Private Endpoint | **생성됨** |
| `apim_to_foundry` 역할 할당 | **생성됨** |
| `apim_to_openai` 역할 할당 | **생성됨** |
| `destroy` 대상 리소스 수 | **0** |

plan 출력 예시 (핵심 부분):

```
Plan: 5 to add, 0 to change, 0 to destroy.
```

생성될 리소스 목록에서 `azurerm_cognitive_account`나 `azurerm_cognitive_deployment`가 보인다면 `reuse_foundry=true`가 올바르게 설정되지 않은 것입니다. tfvars를 재확인한 뒤 다시 plan을 실행합니다.

{% hint style="success" %}
plan 결과에서 `azurerm_cognitive_account` 생성 수 = 0, `azurerm_cognitive_deployment` 생성 수 = 0이고 PE + RBAC 역할 할당만 추가된다면 재사용 단언이 충족된 것입니다. 이 plan 단언은 **라이브 환경에서 검증 완료**된 동작입니다.
{% endhint %}

{% hint style="warning" %}
`destroy` 항목이 있다면 기존 리소스에 영향을 줄 수 있으므로 반드시 내용을 확인한 후 진행합니다.
{% endhint %}

#### data 소스 precondition이 작동하지 않는 경우 (gotcha 4)

`data.azurerm_cognitive_account`는 provider 버전에 따라 `local_auth_enabled` 속성을 노출하지 않을 수 있습니다.
이 경우 Terraform precondition으로 사전 점검을 강제할 수 없습니다.

대신 위 『계정 잠금 확인』 절에서 안내한 `az resource show` 명령으로 사전 점검을 직접 수행합니다.

```bash
az resource show --ids <aiservices-account-id> \
  --query "properties.{disableLocalAuth:disableLocalAuth, publicNetworkAccess:publicNetworkAccess}" -o jsonc
```

`disableLocalAuth: true`, `publicNetworkAccess: "Disabled"` 두 값을 확인한 뒤 apply를 진행합니다.

### 2. terraform apply

***

plan 결과를 확인했으면 apply를 실행합니다.

```bash
terraform apply
```

#### 소요 시간

{% hint style="warning" %}
첫 apply는 약 **45분** 소요됩니다. APIM Developer/Premium SKU의 VNet 주입이 오래 걸리는 것이 정상입니다.
{% endhint %}

#### OpenAPI import 400 오류 시 재-apply (gotcha 2)

{% hint style="warning" %}
첫 apply에서 APIM OpenAPI import 단계가 400 오류로 실패할 수 있습니다.
이는 APIM 리소스 생성 직후 API import가 일시적으로 실패하는 레이스 컨디션이며, 정상 범위의 동작입니다.

```bash
terraform apply   # 재-apply 하면 해결됨
```

Foundry API는 wildcard 방식이라 OpenAPI import가 없어 해당 없습니다.
{% endhint %}

### 3. Apply 완료 후

***

apply가 끝나면 Terraform outputs에서 주요 정보를 확인할 수 있습니다.

```bash
terraform output apim_gateway_url
terraform output resource_group_name
```

재사용 모드에서는 `openai_endpoint` 출력이 `null`임에 유의합니다. 기존 Foundry 계정의 엔드포인트는 `existing_foundry_name`으로 이미 알고 있으므로 별도 출력이 없습니다.

### 4. 다음 단계

***

게이트웨이가 정상적으로 배포됐는지 확인하려면 [05-verify.md](05-verify.md)로 넘어갑니다.
