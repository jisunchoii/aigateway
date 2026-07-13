---
description: 모델 백엔드 기존 계정 재사용 — 기존 AIServices(Foundry) 계정을 건드리지 않고 gateway에 연결
---

# 모델 백엔드 기존 계정 재사용

이 페이지는 이미 운영 중인 Azure AIServices(Foundry) 계정과 모델 배포를 **그대로 유지**하고, 프로젝트 유무에 따라 필요한 연결 리소스만 추가하는 경로를 설명합니다.

<figure><img src=".gitbook/assets/diagram-reuse-topology.svg" alt="재사용 토폴로지 — 기존 계정과 모델은 유지하고 Private Endpoint와 RBAC만 추가"><figcaption><p>기존 계정과 모델 배포는 Terraform 소유 리소스로 편입하지 않고, gateway 쪽 연결 리소스만 추가합니다.</p></figcaption></figure>

## 1. 배포 경로 선택

모델 백엔드는 아래 세 가지 경우 중 하나로 준비합니다.

| 경우 | 계정 | 프로젝트 | 모델 deployment | `reuse_foundry` |
| --- | --- | --- | --- | --- |
| 1. 모델을 새로 배포 | Terraform이 생성 | Terraform이 생성 | Terraform이 생성 | `false` |
| 2-1. 기존 모델 활용, 프로젝트 없음 | 기존 계정 사용 | Terraform이 생성 | 기존 deployment 유지 | `true` |
| 2-2. 기존 모델 활용, 프로젝트 있음 | 기존 계정 사용 | 기존 프로젝트 import | 기존 deployment 유지 | `true` |

모델과 계정을 새로 만들려면 [모델 백엔드 신규 생성](03-deploy/case-foundry-greenfield.md)을 따릅니다. 이 페이지는 2-1과 2-2처럼 기존 계정과 모델 deployment를 유지하는 경우를 설명합니다.

{% hint style="warning" %}
현재 재사용 모드는 **gateway와 같은 Azure 구독**에 있는 기존 계정만 지원합니다.
{% endhint %}

## 2. 기존 계정 재사용 방식

두 재사용 경로는 같은 `reuse_foundry=true` 설정을 사용합니다. 차이는 기존 프로젝트가 있는지와 apply 전에 프로젝트를 import해야 하는지입니다.

| 리소스 | 2-1. 프로젝트 없음 | 2-2. 프로젝트 있음 |
| --- | --- | --- |
| AIServices 계정 | `data` 소스로 읽기만 함 | `data` 소스로 읽기만 함 |
| 모델 deployment | 생성·수정·삭제 안 함 | 생성·수정·삭제 안 함 |
| Foundry 프로젝트 | Terraform이 `foundry_project_name`으로 생성 | 기존 프로젝트를 같은 이름으로 import |
| Private Endpoint | 없으면 생성, 있으면 import | 없으면 생성, 있으면 import |
| APIM RBAC | 없으면 생성, 있으면 import | 없으면 생성, 있으면 import |

지원 모델의 `/openai/v1/chat/completions`와 `/vscode/models` 요청은 기존 AIServices 계정의 OpenAI/v1 account path(`https://<account>.openai.azure.com/openai/v1`)로 전달됩니다. `/openai/v1/responses`는 같은 계정 아래 `foundry_project_name`으로 지정한 프로젝트의 Responses path(`/api/projects/<project>/openai/v1/responses`)를 사용합니다.

## 3. 배포 전 기존 계정 보안 설정

gateway는 APIM managed identity와 RBAC로 backend를 호출합니다. 따라서 Terraform apply 전에 기존 계정이 이미 **project management enabled**, **API key 인증 비활성화**, **공용 네트워크 접근 차단** 상태여야 합니다.

관련 공식 문서:

* [Foundry Models sold by Azure — GPT-5.6](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure#gpt-56)
* [Configure private link for Azure AI Foundry resources](https://learn.microsoft.com/azure/foundry/how-to/configure-private-link)
* [Authenticate with managed identity](https://learn.microsoft.com/azure/api-management/api-management-authenticate-authorize-ai-apis#authenticate-with-managed-identity)

| 설정                    | 기대값        | 이유                       |
| --------------------- | ---------- | ------------------------ |
| `allowProjectManagement` | `true`   | 프로젝트 생성 또는 기존 프로젝트 연결 |
| `disableLocalAuth`    | `true`     | API key 기반 직접 호출 차단      |
| `publicNetworkAccess` | `Disabled` | public endpoint 직접 접근 차단 |

먼저 계정 resource ID를 확인합니다.

```bash
az resource list \
  --resource-type "Microsoft.CognitiveServices/accounts" \
  --query "[].{name:name, resourceId:id, rg:resourceGroup}" \
  -o table
```

project management, API key 인증, 공용 네트워크 접근을 최종 상태로 맞춥니다.

```bash
az resource update --ids <aiservices-account-id> \
  --set properties.allowProjectManagement=true properties.disableLocalAuth=true properties.publicNetworkAccess=Disabled
```

설정 상태를 확인합니다.

```bash
az resource show --ids <aiservices-account-id> \
  --query "properties.{allowProjectManagement:allowProjectManagement, disableLocalAuth:disableLocalAuth, publicNetworkAccess:publicNetworkAccess}" -o jsonc
```

기대 출력:

```json
{
  "allowProjectManagement": true,
  "disableLocalAuth": true,
  "publicNetworkAccess": "Disabled"
}
```

{% hint style="warning" %}
`publicNetworkAccess=Disabled`로 설정하면 기존 public endpoint에 직접 붙던 클라이언트가 즉시 차단됩니다. 유지보수 창을 잡고 **보안 설정 변경 → gateway apply → 검증** 순서를 한 번에 진행하세요.
{% endhint %}

## 4. tfvars 입력값 결정

2-1에서는 `foundry_project_name`에 새로 만들 프로젝트 이름을 입력합니다. 2-2에서는 기존 프로젝트 이름을 대소문자까지 정확히 입력합니다.

```
reuse_foundry         = true
existing_foundry_name = "ais-customer-prod"
existing_foundry_rg   = "rg-customer-ai"
foundry_project_name  = "codexproj"

model_deployments = {
  "gpt-5.6-sol" = {
    model_name    = "gpt-5.6-sol"
    model_format  = "OpenAI"
    model_version = "2026-07-09"
    sku_name      = "GlobalStandard"
    capacity      = 500
  }
  "FW-GLM-5.2" = {
    model_name    = "FW-GLM-5.2"
    model_format  = "Fireworks"
    model_version = "1"
    sku_name      = "DataZoneStandard"
    capacity      = 500
  }
  "DeepSeek-V4-Pro" = {
    model_name    = "DeepSeek-V4-Pro"
    model_format  = "DeepSeek"
    model_version = "2026-04-23"
    sku_name      = "GlobalStandard"
    capacity      = 500
  }
  "grok-4.3" = {
    model_name    = "grok-4.3"
    model_format  = "xAI"
    model_version = "1"
    sku_name      = "GlobalStandard"
    capacity      = 10
  }
}
```

| 변수                      | 의미                            |
| ----------------------- | ----------------------------- |
| `reuse_foundry`         | `true`면 기존 계정 재사용 모드 활성화      |
| `existing_foundry_name` | 재사용할 AIServices 계정 이름         |
| `existing_foundry_rg`   | 기존 계정이 있는 리소스 그룹              |
| `foundry_project_name`  | 새로 만들거나 재사용할 프로젝트 이름 |
| `model_deployments`     | 기존 계정에 이미 존재하는 지원 모델 deployment 선언 |

{% hint style="danger" %}
`model_deployments`의 **map key는 기존 계정에 이미 존재하는 실제 deployment 이름과 대소문자까지 정확히 일치**해야 합니다. 기본 runbook은 지원 모델 네 개를 기대하며, 다른 이름을 쓰려면 `model_deployments`와 이후 smoke/config 예시를 함께 맞춰야 합니다.
{% endhint %}

재사용 모드에서는 `model_deployments`를 선언만 하고, 해당 deployment들은 기존 AIServices 계정에 **이미 존재**해야 합니다. Terraform은 기존 계정과 모델 deployment를 생성하거나 수정하지 않습니다.

## 5. 기존 프로젝트와 연결 리소스 import

### 2-1. 프로젝트가 없는 경우

프로젝트는 import하지 않습니다. Terraform plan에서 `module.foundry.azapi_resource.project[0]` 하나가 생성 대상으로 보여야 합니다.

Private Endpoint나 APIM 역할 할당도 기존에 없다면 Terraform이 생성합니다. 같은 용도의 리소스가 이미 있다면 정확한 ID를 확인한 후 해당 주소로 import합니다.

### 2-2. 프로젝트가 있는 경우

`foundry_project_name`을 기존 프로젝트 이름으로 설정한 후 프로젝트를 import합니다.

```bash
terraform import 'module.foundry.azapi_resource.project[0]' '<existing-project-resource-id>'
```

Private Endpoint나 APIM 역할 할당도 이미 존재한다면 각각 정확한 리소스 ID로 import합니다.

```bash
terraform import 'module.foundry.azurerm_private_endpoint.project_account' '<existing-private-endpoint-resource-id>'
terraform import 'module.apim.azurerm_role_assignment.apim_to_model_openai' '<existing-openai-role-assignment-resource-id>'
terraform import 'module.apim.azurerm_role_assignment.apim_to_model_foundry' '<existing-foundry-role-assignment-resource-id>'
```

Import 전에는 project parent가 재사용할 account ID와 일치하는지, Private Endpoint가 같은 account ID를 가리키는지, 역할 할당의 principal·role·scope가 모두 일치하는지 확인합니다.

## 6. Plan 검증

이 페이지에서 state backend를 먼저 만들지는 않습니다. 기존 계정 보안 설정과 `terraform.tfvars` 입력을 끝낸 뒤, 선택한 배포 runbook의 backend bootstrap 단계를 진행하고 **saved plan**을 생성합니다.

같은 워킹카피에서 backend 리소스 그룹이나 storage account를 삭제한 뒤 다시 bootstrap했다면, 로컬 `.terraform` 디렉터리에 이전 backend 설정이 남아 있을 수 있습니다. 이 경우 첫 초기화는 `terraform init -reconfigure`로 실행합니다.

```bash
cd infra
terraform init
terraform plan -out=reuse.tfplan
terraform show reuse.tfplan
```

| 확인 항목                             | 기대값 |
| --------------------------------- | --- |
| 기존 AIServices 계정과 모델 deployment | create/update/delete 0 |
| 2-1 프로젝트 없음 | 프로젝트 1개 create |
| 2-2 프로젝트 있음 | import 후 프로젝트 no-op |
| Private Endpoint와 APIM RBAC | 없으면 create, import했다면 no-op |
| destroy 대상 | 0 |

{% hint style="success" %}
기존 계정과 모델 deployment에 변경이 없고, 프로젝트·Private Endpoint·RBAC만 위 표의 예상 결과와 일치할 때 apply합니다.
{% endhint %}

{% hint style="warning" %}
plan에 기존 AIServices 계정이나 모델 deployment의 create/update/delete가 보이면 apply하지 말고 `reuse_foundry`, `existing_foundry_name`, `existing_foundry_rg`, `foundry_project_name`, `model_deployments` 값을 다시 확인하세요.
{% endhint %}

## 7. APIM 배포와의 관계

기존 계정 재사용도 APIM과 따로 나중에 붙이는 방식이 아닙니다. 위 보안 설정과 tfvars를 먼저 완료한 뒤 [APIM 게이트웨이 배포](03-deploy/case-apim-core-first.md) 또는 [All-in-one 배포](03-deploy/case-all-in-one.md)의 첫 apply에서 gateway 연결 리소스가 함께 생성됩니다.

| 목적                | 이동                                                         |
| ----------------- | ---------------------------------------------------------- |
| APIM 게이트웨이만 먼저 검증 | [APIM 게이트웨이 배포](03-deploy/case-apim-core-first.md)         |
| 전체 스택 배포          | [All-in-one 배포](03-deploy/case-all-in-one.md)              |
| 배포 후 호출 확인        | [APIM 게이트웨이 배포](03-deploy/case-apim-core-first.md#7-호출-검증) |
