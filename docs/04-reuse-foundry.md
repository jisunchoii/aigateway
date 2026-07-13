---
description: 모델 백엔드 기존 계정 재사용 — 기존 AIServices 계정·프로젝트·모델의 Terraform 관리 범위를 선택해 gateway에 연결
---

# 모델 백엔드 기존 계정 재사용

이 페이지는 이미 운영 중인 Azure AIServices(Foundry) 계정과 모델 배포를 **그대로 유지**하고, 기존 프로젝트 유무에 따라 Terraform 관리 범위를 선택하는 경로를 설명합니다.

<figure><img src=".gitbook/assets/diagram-reuse-topology.svg" alt="재사용 토폴로지 — 기존 계정과 모델은 유지하고 프로젝트 관리 방식과 gateway 연결 리소스를 선택"><figcaption><p>기존 계정과 모델 배포는 Terraform 소유 리소스로 편입하지 않습니다. 프로젝트가 없으면 Terraform이 새로 관리하고, 기존 프로젝트가 있으면 조회만 합니다.</p></figcaption></figure>

## 1. 배포 경로 선택

모델 백엔드는 아래 세 가지 경우 중 하나로 준비합니다.

| 경우 | 계정 | 프로젝트 | 모델 deployment | `reuse_foundry` | `reuse_foundry_project` |
| --- | --- | --- | --- | --- | --- |
| 1. 모델을 새로 배포 | Terraform이 생성 | Terraform이 생성 | Terraform이 생성 | `false` | `false` |
| 2-1. 기존 모델 활용, 프로젝트 없음 | 기존 계정 조회 | Terraform이 생성·관리 | 기존 deployment 유지 | `true` | `false` |
| 2-2. 기존 모델 활용, 프로젝트 있음 | 기존 계정 조회 | 기존 프로젝트 조회만 | 기존 deployment 유지 | `true` | `true` |

모델과 계정을 새로 만들려면 [모델 백엔드 신규 생성](03-deploy/case-foundry-greenfield.md)을 따릅니다. 이 페이지는 2-1과 2-2처럼 기존 계정과 모델 deployment를 유지하는 경우를 설명합니다.

{% hint style="warning" %}
현재 재사용 모드는 **gateway와 같은 Azure 구독**에 있는 기존 계정만 지원합니다.
{% endhint %}

## 2. 기존 계정 재사용 방식

두 재사용 경로는 모두 `reuse_foundry=true`를 사용합니다. 프로젝트가 없으면 `reuse_foundry_project=false`, 기존 프로젝트까지 유지하면 `reuse_foundry_project=true`를 사용합니다.

| 리소스 | 2-1. 프로젝트 없음 | 2-2. 프로젝트 있음 |
| --- | --- | --- |
| AIServices 계정 | `data` 소스로 읽기만 함 | `data` 소스로 읽기만 함 |
| 모델 deployment | 생성·수정·삭제 안 함 | 생성·수정·삭제 안 함 |
| Foundry 프로젝트 | Terraform이 `foundry_project_name`으로 생성·관리 | 기존 프로젝트를 같은 이름으로 조회만 함 |
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
| `allowProjectManagement` | `true`   | 프로젝트 생성 또는 기존 프로젝트 조회 |
| `disableLocalAuth`    | `true`     | API key 기반 직접 호출 차단      |
| `publicNetworkAccess` | `Disabled` | public endpoint 직접 접근 차단 |

먼저 계정 resource ID를 확인합니다.

```bash
existing_foundry_name="ais-customer-prod"
existing_foundry_rg="rg-customer-ai"

account_id="$(az resource show \
  --name "$existing_foundry_name" \
  --resource-group "$existing_foundry_rg" \
  --resource-type "Microsoft.CognitiveServices/accounts" \
  --api-version "2026-05-01" \
  --query id -o tsv)"

printf '%s\n' "$account_id"
```

project management, API key 인증, 공용 네트워크 접근을 최종 상태로 맞춥니다.

```bash
az resource update \
  --ids "$account_id" \
  --api-version "2026-05-01" \
  --set properties.allowProjectManagement=true properties.disableLocalAuth=true properties.publicNetworkAccess=Disabled
```

설정 상태를 확인합니다.

```bash
az resource show \
  --ids "$account_id" \
  --api-version "2026-05-01" \
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

2-1에서는 `reuse_foundry_project=false`와 새로 만들 `foundry_project_name`을 사용합니다. 2-2에서는 `reuse_foundry_project=true`와 기존 프로젝트 이름을 대소문자까지 정확히 입력합니다.

```
reuse_foundry         = true
reuse_foundry_project = false
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
| `reuse_foundry_project` | `false`면 새 프로젝트 생성·관리, `true`면 기존 프로젝트 조회만 |
| `existing_foundry_name` | 재사용할 AIServices 계정 이름         |
| `existing_foundry_rg`   | 기존 계정이 있는 리소스 그룹              |
| `foundry_project_name`  | 새로 만들거나 재사용할 프로젝트 이름 |
| `model_deployments`     | 기존 계정에 이미 존재하는 지원 모델 deployment 선언 |

{% hint style="danger" %}
`model_deployments`의 **map key는 기존 계정에 이미 존재하는 실제 deployment 이름과 대소문자까지 정확히 일치**해야 합니다. 기본 runbook은 지원 모델 네 개를 기대하며, 다른 이름을 쓰려면 `model_deployments`와 이후 smoke/config 예시를 함께 맞춰야 합니다.
{% endhint %}

재사용 모드에서는 `model_deployments`를 선언만 하고, 해당 deployment들은 기존 AIServices 계정에 **이미 존재**해야 합니다. Terraform은 기존 계정과 모델 deployment를 생성하거나 수정하지 않습니다.

2-2 경로는 위 예제에서 `reuse_foundry_project=true`로 바꾸고 `foundry_project_name`을 실제 기존 프로젝트 이름으로 설정합니다. `reuse_foundry_project=true`는 `reuse_foundry=true`와 함께만 사용할 수 있습니다.

## 5. 프로젝트 처리와 연결 리소스 import

### 2-1. 프로젝트가 없는 경우

프로젝트는 import하지 않습니다. Terraform plan에서 `module.foundry.azapi_resource.project[0]` 하나가 생성 대상으로 보여야 합니다.

Private Endpoint나 APIM 역할 할당도 기존에 없다면 Terraform이 생성합니다. 같은 용도의 리소스가 이미 있다면 정확한 ID를 확인한 후 해당 주소로 import합니다.

### 2-2. 프로젝트가 있는 경우

`reuse_foundry_project=true`와 정확한 `foundry_project_name`을 설정합니다. Terraform은 `module.foundry.data.azapi_resource.existing_project[0]`으로 프로젝트 존재 여부를 확인하지만 resource로 관리하지 않으므로 import하지 않습니다.

먼저 `terraform.tfvars`에 입력할 기존 계정 이름과 resource group으로 account ID를 조회합니다.

```bash
existing_foundry_name="ais-customer-prod"
existing_foundry_rg="rg-customer-ai"

account_id="$(az resource show \
  --name "$existing_foundry_name" \
  --resource-group "$existing_foundry_rg" \
  --resource-type "Microsoft.CognitiveServices/accounts" \
  --api-version "2026-05-01" \
  --query id -o tsv)"

printf '%s\n' "$account_id"
```

해당 account 아래 프로젝트 이름과 resource ID를 출력합니다.

```bash
az rest \
  --method get \
  --url "https://management.azure.com${account_id}/projects?api-version=2025-10-01-preview" \
  --query "value[].{projectName:name, resourceId:id}" \
  -o table
```

출력에서 사용할 프로젝트 이름을 선택해 `foundry_project_name`에 입력하고, 최종 resource ID를 확인합니다.

```bash
existing_project_name="codexproj"

project_id="$(az resource show \
  --ids "${account_id}/projects/${existing_project_name}" \
  --api-version "2025-10-01-preview" \
  --query id -o tsv)"

printf '%s\n' "$project_id"
```

출력된 `project_id`가 `${account_id}/projects/${existing_project_name}`과 일치하는지 확인합니다. `existing_project_name`은 `terraform.tfvars`의 `foundry_project_name`과 동일해야 합니다. 이 경로의 plan에는 `module.foundry.azapi_resource.project[0]`이 없어야 하며, 이후 `terraform destroy`도 기존 프로젝트를 삭제하지 않습니다.

두 재사용 경로 모두 Private Endpoint나 APIM 역할 할당이 이미 존재한다면 각각 정확한 리소스 ID로 import합니다.

```bash
terraform import 'module.foundry.azurerm_private_endpoint.project_account' '<existing-private-endpoint-resource-id>'
terraform import 'module.apim.azurerm_role_assignment.apim_to_model_openai' '<existing-openai-role-assignment-resource-id>'
terraform import 'module.apim.azurerm_role_assignment.apim_to_model_foundry' '<existing-foundry-role-assignment-resource-id>'
```

Import 전에는 Private Endpoint가 같은 account ID를 가리키는지, 역할 할당의 principal·role·scope가 모두 일치하는지 확인합니다.

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
| 2-2 프로젝트 있음 | data source 1개 read, 관리 프로젝트 create/update/delete 0 |
| Private Endpoint와 APIM RBAC | 없으면 create, import했다면 no-op |
| 이후 `terraform destroy` | 2-1의 Terraform 생성 프로젝트는 삭제, 2-2의 기존 프로젝트는 보존 |

{% hint style="success" %}
기존 계정과 모델 deployment에 변경이 없고, 프로젝트·Private Endpoint·RBAC가 위 표의 예상 결과와 일치할 때 apply합니다.
{% endhint %}

{% hint style="warning" %}
plan에 기존 AIServices 계정이나 모델 deployment의 create/update/delete가 보이면 apply하지 말고 `reuse_foundry`, `reuse_foundry_project`, `existing_foundry_name`, `existing_foundry_rg`, `foundry_project_name`, `model_deployments` 값을 다시 확인하세요.
{% endhint %}

## 7. APIM 배포와의 관계

기존 계정 재사용도 APIM과 따로 나중에 붙이는 방식이 아닙니다. 위 보안 설정과 tfvars를 먼저 완료한 뒤 [APIM 게이트웨이 배포](03-deploy/case-apim-core-first.md) 또는 [All-in-one 배포](03-deploy/case-all-in-one.md)의 첫 apply에서 gateway 연결 리소스가 함께 생성됩니다.

| 목적                | 이동                                                         |
| ----------------- | ---------------------------------------------------------- |
| APIM 게이트웨이만 먼저 검증 | [APIM 게이트웨이 배포](03-deploy/case-apim-core-first.md)         |
| 전체 스택 배포          | [All-in-one 배포](03-deploy/case-all-in-one.md)              |
| 배포 후 호출 확인        | [APIM 게이트웨이 배포](03-deploy/case-apim-core-first.md#7-호출-검증) |
