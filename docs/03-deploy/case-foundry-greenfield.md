---
description: "모델 백엔드 신규 생성 — Terraform이 project-enabled AIServices account/project와 지원 모델 배포를 새로 만드는 경로"
---

# 모델 백엔드 신규 생성

이 페이지는 Terraform이 **project-enabled AIServices account/project와 지원 모델 배포를 새로 만드는 경로**를 설명합니다. 모델 백엔드는 APIM과 따로 나중에 붙는 리소스가 아니라, [APIM 게이트웨이 배포](case-apim-core-first.md) 또는 [All-in-one 배포](case-all-in-one.md)의 첫 `terraform apply`에서 함께 생성됩니다.

## 1. 선택 기준

{% hint style="success" %}
**이 경로가 맞는 경우**

- 기존 AIServices/Foundry 운영 계정이 없다.
- 모델 quota와 region을 이번 gateway 기준으로 새로 설계할 수 있다.
- 데모, PoC, 랩 환경처럼 backend 계정까지 새로 만들어도 된다.
- Terraform이 모델 계정과 deployment를 소유해도 된다.
{% endhint %}

이미 고객 운영 계정과 모델 배포가 있다면 [모델 백엔드 기존 계정 재사용](../04-reuse-foundry.md)을 먼저 검토하세요.

## 2. 생성되는 리소스

| 리소스 | 설명 |
|---|---|
| AIServices 계정 | `allowProjectManagement=true`가 켜진 기준 모델 계정 |
| Foundry project | `codexproj` child project |
| 모델 배포 | `model_deployments` 기준으로 `gpt-5.6-sol`, `FW-GLM-5.2`, `DeepSeek-V4-Pro`, `grok-4.3` 생성 |
| Private Endpoint | APIM VNet에서 기준 모델 계정으로 private 연결 |
| RBAC | APIM managed identity에 기준 모델 계정 호출 권한 부여 |

{% hint style="info" %}
신규 backend 계정은 public access와 key auth를 끄고, APIM managed identity + RBAC 경로로만 호출합니다.
{% endhint %}

## 3. 배포 전 확인

| 항목 | 확인 방법 |
|---|---|
| Region | `location` 값이 APIM, Azure OpenAI, AIServices를 모두 지원하는지 확인 |
| 모델 quota | `az cognitiveservices usage list -l <region> -o table` 및 공식 quota 문서 확인 |
| Partner 모델 약관 | Azure Marketplace 구독 권한과 약관 동의 필요 여부 확인 |
| 배포 이름 | 클라이언트가 사용할 모델 이름과 `model_deployments` key를 일치 |


| 확인할 내용 | 공식 문서 |
|---|---|
| GPT-5.6 deployment 세부 정보 | [Foundry Models sold by Azure — GPT-5.6](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure#gpt-56) |
| Responses 지원 모델 확인 | [Responses API supported models](https://learn.microsoft.com/azure/foundry/openai/how-to/responses#supported-models) |
| Private Endpoint / DNS 요구사항 | [Configure private link for Azure AI Foundry resources](https://learn.microsoft.com/azure/foundry/how-to/configure-private-link) |
| APIM managed identity backend 인증 | [Authenticate with managed identity](https://learn.microsoft.com/azure/api-management/api-management-authenticate-authorize-ai-apis#authenticate-with-managed-identity) |
| Partner/community 모델의 Azure Marketplace 구독·약관 동의 | [Deploy Microsoft Foundry Models](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/deploy-foundry-models), [Models from partners and community](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/models-from-partners) |

공식 문서는 Foundry Models의 rate limit을 모델별 **TPM(tokens per minute)**, **RPM(requests per minute)**, **concurrent requests**로 나눠 제시합니다. 일부 모델은 TPM이 `not applicable`이거나 RPM/capacity 단위로 표시되므로, Terraform `capacity` 값을 정하기 전에 해당 모델의 최신 quota 표를 확인해야 합니다.

{% hint style="warning" %}
삭제된 Cognitive Services 계정이나 다른 Foundry 계정의 deployment가 quota를 잡고 있을 수 있습니다. 새 deployment가 `InsufficientQuota`로 실패하면 기존/삭제된 계정의 deployment를 먼저 정리하거나 quota 증설을 요청하세요.
{% endhint %}

## 4. tfvars 입력값 결정

여기서는 값만 결정합니다. 실제 `infra/terraform.tfvars` 파일 생성과 입력은 [APIM 게이트웨이 배포](case-apim-core-first.md#4-tfvars-핵심값) 단계에서 합니다.

``` 
reuse_foundry = false
foundry_project_name                  = "codexproj"
foundry_public_network_access_enabled = false

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

| 변수 | 의미 |
|---|---|
| `reuse_foundry` | `false`면 신규 backend 계정과 모델 배포를 생성 |
| `foundry_project_name` | 기준 child project 이름 (`codexproj`) |
| `foundry_public_network_access_enabled` | `false`면 private-only account로 배포 |
| `model_deployments` | 지원 모델 deployment 네 개 정의. map key가 곧 APIM/Admin UI 모델 이름 |

## 5. APIM 배포와의 관계

APIM 정책은 위 모델 이름과 backend URL을 기준으로 생성됩니다. 따라서 tfvars를 먼저 확정한 뒤 아래 배포 경로 중 하나로 진행합니다.

| 목적 | 다음 페이지 |
|---|---|
| APIM 게이트웨이만 먼저 검증 | [APIM 게이트웨이 배포](case-apim-core-first.md) |
| Admin UI와 worker까지 전체 배포 | [All-in-one 배포](case-all-in-one.md) |

첫 apply가 성공하면 모델 배포가 생성됐는지 확인합니다.

```bash
az cognitiveservices account deployment list \
  -g <resource-group> \
  -n <aiservices-account-name> \
  -o table
```

## 6. 다음 단계

| 목적 | 이동 |
|---|---|
| APIM 게이트웨이 배포 | [APIM 게이트웨이 배포](case-apim-core-first.md) |
| 전체 스택 배포 | [All-in-one 배포](case-all-in-one.md) |
| 배포 후 호출 확인 | [APIM 게이트웨이 배포](case-apim-core-first.md#7-호출-검증) |
