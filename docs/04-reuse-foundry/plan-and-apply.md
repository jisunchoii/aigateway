---
description: 플랫폼 엔지니어 (Terraform 담당)를 위한 페이지 · 선행: tfvars 설정
---

# Plan & Apply

## 1. terraform plan — 재사용 단언 확인

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

대신 [prepare-account.md](prepare-account.md)에서 안내한 `az resource show` 명령으로 사전 점검을 직접 수행합니다.

```bash
az resource show --ids <aiservices-account-id> \
  --query "properties.{disableLocalAuth:disableLocalAuth, publicNetworkAccess:publicNetworkAccess}" -o jsonc
```

`disableLocalAuth: true`, `publicNetworkAccess: "Disabled"` 두 값을 확인한 뒤 apply를 진행합니다.

## 2. terraform apply

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

## 3. Apply 완료 후

***

apply가 끝나면 Terraform outputs에서 주요 정보를 확인할 수 있습니다.

```bash
terraform output apim_gateway_url
terraform output resource_group_name
```

재사용 모드에서는 `openai_endpoint` 출력이 `null`임에 유의합니다. 기존 Foundry 계정의 엔드포인트는 `existing_foundry_name`으로 이미 알고 있으므로 별도 출력이 없습니다.

## 4. 다음 단계

***

게이트웨이가 정상적으로 배포됐는지 확인하려면 [05-verify/smoke-test.md](../05-verify/smoke-test.md)로 넘어갑니다.
