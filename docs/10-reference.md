---
description: "부록 — Terraform 변수·출력·문제 해결 사전"
---

# 부록: 변수·출력·문제 해결

이 페이지는 앞 장의 배포·운영 절차를 따라가다가 **정확한 변수명, 출력값, 오류 대응**을 빠르게 확인하기 위한 부록입니다. 비용 관리와 리소스 정리의 운영 절차는 [운영](06-operate.md)에서 다루고, 이 페이지는 사전처럼 찾아보는 정보만 모읍니다.

## 1. 빠른 찾기

{% hint style="success" %}
**이 페이지를 보는 경우**

- `infra/` 디렉터리의 `terraform.tfvars` 파일에 넣을 변수 이름과 기본값을 확인한다.
- `terraform output -raw <name>`으로 어떤 값을 꺼내야 하는지 찾는다.
- `403`, `429`, 첫 apply 지연, destroy 중단 같은 알려진 이슈를 빠르게 진단한다.
{% endhint %}

| 찾는 것 | 위치 |
|---|---|
| tfvars 변수명과 기본값 | [2. Terraform 변수 사전](#2-terraform-변수-사전) |
| 배포 후 출력값 | [3. Terraform 출력 사전](#3-terraform-출력-사전) |
| HTTP 오류와 알려진 배포 이슈 | [4. 문제 해결](#4-문제-해결) |
| 비용 관리 / 리소스 정리 절차 | [운영](06-operate.md) |

## 2. Terraform 변수 사전

`infra/variables.tf` 기준입니다. “필수”로 표시된 값은 기본값이 없으므로 `infra/terraform.tfvars` 또는 입력 변수로 제공해야 합니다.

### 기본값과 태그

| 변수 | 기본값 | 설명 |
|---|---|---|
| `prefix` | `aigw` | 리소스 이름 prefix |
| `env` | `dev` | `dev`, `test`, `prod` 중 하나 |
| `location` | `koreacentral` | 지원 리전: `koreacentral`, `koreasouth`, `eastus`, `eastus2`, `westeurope` |
| `owner` | 필수 | 리소스 태그 owner |
| `cost_center` | 필수 | 리소스 태그 costCenter |

### APIM

| 변수 | 기본값 | 설명 |
|---|---|---|
| `apim_publisher_name` | 필수 | APIM publisher display name |
| `apim_publisher_email` | 필수 | APIM publisher contact email |
| `apim_sku_name` | `Developer_1` | 개발·데모 기본값. 프로덕션은 `Premium_1` 권장 |
| `apim_public` | `false` | `true`면 public gateway VIP, `false`면 VNet 내부 전용 |

{% hint style="warning" %}
`apim_public` 변경은 APIM 네트워크 재구성을 유발합니다. 첫 배포처럼 오래 걸릴 수 있으므로 운영 환경에서는 유지보수 창을 잡고 변경하세요.
{% endhint %}

### 모델 백엔드

| 변수 | 기본값 | 설명 |
|---|---|---|
| `openai_deployments` | `gpt-5.4`, `gpt-5.4-mini` | greenfield에서 생성할 Azure OpenAI deployment map |
| `foundry_deployments` | `grok-4.3`, `DeepSeek-V4-Pro` | AIServices/Foundry partner model deployment map |
| `allowed_models` | `gpt-5.4`, `gpt-5.4-mini`, `grok-4.3`, `DeepSeek-V4-Pro` | APIM 정책이 허용하는 모델 목록 |
| `openai_api_version` | `2025-01-01-preview` | 클라이언트가 보내는 Azure OpenAI API version |
| `openai_openapi_spec_url` | Azure REST API spec URL | APIM OpenAPI import에 사용하는 spec URL |

### 기존 Foundry 계정 재사용

| 변수 | 기본값 | 설명 |
|---|---|---|
| `reuse_foundry` | `false` | `true`면 기존 AIServices 계정을 data source로 읽고 gateway 연결만 추가 |
| `existing_foundry_name` | `""` | 재사용할 AIServices 계정 이름. `reuse_foundry=true`면 필수 |
| `existing_foundry_rg` | `""` | 기존 AIServices 계정의 resource group. `reuse_foundry=true`면 필수 |

{% hint style="info" %}
`reuse_foundry=true`에서는 기존 계정과 모델 deployment를 Terraform이 생성하거나 삭제하지 않습니다. 연결에 필요한 Private Endpoint와 APIM managed identity RBAC만 gateway 쪽에서 추가합니다.
{% endhint %}

### 클라이언트 인증

| 변수 | 기본값 | 설명 |
|---|---|---|
| `client_auth_mode` | `subscription-key` | `subscription-key` 또는 `entra-id` |
| `entra_tenant_id` | `""` | `entra-id` 모드에서 JWT issuer 검증에 사용 |
| `entra_api_audience` | `""` | `entra-id` 모드에서 JWT `aud` 기대값 |
| `entra_team_claim` | `groups` | JWT에서 consumer/team ID를 읽을 claim 이름 |

{% hint style="warning" %}
`groups` claim은 대규모 조직에서 누락될 수 있습니다. 운영 환경에서 Entra ID 인증을 쓰려면 [향후 지원 계획](09-future.md)의 consumerId claim 설계를 먼저 확인하세요.
{% endhint %}

### Admin UI와 config-sync

| 변수 | 기본값 | 설명 |
|---|---|---|
| `worker_image` | `""` | config-sync worker image. 비어 있으면 job 미배포 |
| `config_sync_cron` | `*/5 * * * *` | config-sync Container Apps Job cron |
| `admin_ui_image` | `""` | Admin UI image. 비어 있으면 Admin UI 미배포 |
| `admin_ui_public` | `false` | `true`면 Admin UI public FQDN 노출 |
| `bff_api_audience` | `""` | Admin UI BFF JWT audience |
| `spa_client_id` | `""` | SPA app registration client ID |
| `admin_group_object_id` | `""` | Admin UI 쓰기 권한을 가진 Entra security group object ID |

### 예산과 rate limit

| 변수 | 기본값 | 설명 |
|---|---|---|
| `monthly_budget_amount` | `200` | Azure Cost Management 월 예산. 알림 전용 |
| `budget_alert_email` | 필수 | 예산 알림 수신 이메일 |
| `budget_start_date` | `<당월 1일>T00:00:00Z` | Cost Management budget 시작일. 반드시 apply 당월 1일(UTC), 과거 달 금지 |
| `rate_tiers` | `small`, `medium`, `large` | Admin UI와 APIM Named Values에 공급되는 티어 map |
| `tokens_per_minute` | `150000` | tier/model-derived limit이 없을 때 쓰는 fallback TPM |
| `token_quota` | `30000000` | 쿼터 기간 내 토큰 총량 |
| `token_quota_period` | `Daily` | `Hourly`, `Daily`, `Weekly`, `Monthly`, `Yearly` |

`rate_tiers` 기본값:

```text
small  = { tpm = 50000,  quota = 5000000,    period = "Daily" }
medium = { tpm = 150000, quota = 30000000,   period = "Daily" }
large  = { tpm = 300000, quota = 1000000000, period = "Monthly" }
```

{% hint style="info" %}
`openai_deployments[*].capacity`와 `foundry_deployments[*].capacity`는 Azure 모델 deployment의 `sku.capacity`로 배포됩니다. APIM default tier는 모델별 `capacity * 1000`을 TPM으로 계산하지만, consumer에 `small`/`medium`/`large` tier가 있으면 `rate_tiers` 값이 우선합니다. APIM tier TPM은 backend deployment rate limit 이하로 잡아야 효과가 있습니다. 자세한 운영 기준은 [거버넌스 — Rate limit](02-governance.md#rate-limit)을 참고하세요.
{% endhint %}

### Jumpbox

| 변수 | 기본값 | 설명 |
|---|---|---|
| `enable_jumpbox` | `false` | VNet 내부 진단용 Bastion + jumpbox VM 배포 여부 |
| `jumpbox_admin_password` | `null` | jumpbox VM admin password. `enable_jumpbox=true`면 필수 |
| `jumpbox_vm_size` | `Standard_B2s_v2` | jumpbox VM size |

## 3. Terraform 출력 사전

`infra/outputs.tf` 기준입니다. 배포 후 `infra/` 디렉터리에서 `terraform output -raw <name>`으로 확인합니다.

| 출력 | 언제 사용하나 |
|---|---|
| `resource_group_name` | Azure CLI로 리소스 조회, 삭제, job 실행 |
| `apim_gateway_url` | Copilot CLI, 직접 API 호출 base URL |
| `apim_private_ip` | VNet 내부 진단에서 APIM private IP 확인 |
| `vscode_base_url` | VS Code BYOK custom model URL |
| `openai_endpoint` | greenfield Azure OpenAI 계정 endpoint 확인. `reuse_foundry=true`면 `null` |
| `registry_name` | `az acr build --registry` 입력값 |
| `registry_login_server` | `worker_image`, `admin_ui_image` 구성 |
| `config_store_endpoint` | Cosmos DB seed script 입력값 |
| `config_store_account_name` | Azure Portal/CLI에서 Cosmos DB 계정 찾기 |
| `config_sync_job_name` | config-sync worker 수동 실행 |
| `admin_ui_fqdn` | Admin UI 접속 URL |

자주 쓰는 조합:

```bash
# 클라이언트 base URL
terraform output -raw apim_gateway_url
terraform output -raw vscode_base_url

# ACR remote build
reg="$(terraform output -raw registry_name)"
az acr build --registry "$reg" --image admin-ui:latest ../app/admin-ui

# config-sync 즉시 실행
rg="$(terraform output -raw resource_group_name)"
job="$(terraform output -raw config_sync_job_name)"
az containerapp job start -g "$rg" -n "$job"
```

{% hint style="info" %}
`config_sync_job_name`은 `worker_image=""`이면 `null`이고, `admin_ui_fqdn`은 `admin_ui_image=""`이면 `null`입니다. 이미지를 빌드해 변수에 넣고 `terraform apply`한 뒤 다시 확인하세요.
{% endhint %}

## 4. 문제 해결

### 빠른 진단표

| 증상 | 가능성 높은 원인 | 먼저 할 일 |
|---|---|---|
| 첫 `terraform apply`가 오래 걸림 | APIM VNet 주입 구성 | 중단하지 말고 대기. 약 45분 소요 가능 |
| APIM OpenAPI import 400 | APIM provisioning 직후 race | `terraform apply` 재실행 |
| 모델 호출 403 | `allowed_models` 차단 또는 deployment 이름 불일치 | 요청 모델과 tfvars deployment key 확인 |
| 모델 호출 429 | rate tier 또는 token quota 초과 | Admin UI에서 tier 상향 또는 quota 조정 |
| 요청 모델과 응답 모델이 다름 | budget 기반 모델 전환 | `x-ai-gateway-*` 응답 헤더 확인 |
| partner 모델만 배포/호출 실패 | Marketplace 약관 미동의 | Azure Portal에서 모델 약관 동의 |
| apply 직후 401/403 | Private Endpoint DNS 또는 RBAC 전파 지연 | 3~5분 후 재시도 |
| `terraform destroy`가 멈춤 | VNet 주입 APIM Named Value 삭제 지연 | 데모 환경이면 RG 삭제 고려 |

### 403 Forbidden

요청한 모델이 consumer의 허용 모델 목록에 없거나, `allowed_models`와 실제 deployment 이름이 일치하지 않을 때 발생합니다.

```text
allowed_models = ["gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro"]
```

확인 순서:

1. 클라이언트가 보낸 `model` 값 확인
2. `allowed_models`에 해당 값 포함 여부 확인
3. `openai_deployments` 또는 `foundry_deployments`의 key와 실제 deployment 이름 일치 여부 확인
4. 변경 후 `terraform apply` 또는 config-sync worker 실행

### 429 Too Many Requests

consumer의 TPM 또는 quota가 초과된 상태입니다. Admin UI에서 consumer의 rate tier를 조정하거나, `rate_tiers` 기본값을 변경한 뒤 적용합니다.

```text
rate_tiers = {
  small  = { tpm = 500,   quota = 20000,  period = "Daily" }
  medium = { tpm = 2000,  quota = 100000, period = "Daily" }
  large  = { tpm = 10000, quota = 500000, period = "Monthly" }
}
```

### 모델 전환 확인

budget 정책이 발동하면 요청한 모델과 실제 호출 모델이 달라질 수 있습니다. 응답 헤더로 확인합니다.

```text
x-ai-gateway-requested-model: gpt-5.4
x-ai-gateway-effective-model: gpt-5.4-mini
x-ai-gateway-downgrade-level: 1
```

`downgrade-level`이 `0`이면 전환 없음, `1`이면 80% 임계값, `2`이면 100% 임계값에 도달한 상태입니다.

### APIM 첫 apply 지연

Developer/Premium SKU의 VNet 주입 모드는 Azure 내부 구성 시간이 길어 첫 apply가 약 45분 걸릴 수 있습니다. 이는 정상 동작입니다.

{% hint style="warning" %}
중간에 apply를 끊으면 APIM provisioning이 애매한 상태로 남을 수 있습니다. 타임아웃이 아니라면 완료될 때까지 기다리세요.
{% endhint %}

### OpenAPI import 400

첫 apply에서 APIM API import가 400으로 실패하면 APIM provisioning 직후의 일시적 race일 가능성이 큽니다.

```bash
cd infra
terraform apply
```

두 번째 apply에서 정상 완료되는지 확인합니다.

### 기존 Foundry 계정 재사용 precondition

`reuse_foundry=true`에서 기존 계정의 local auth 또는 public access 설정이 맞지 않으면 plan/apply가 실패합니다.

```bash
az resource show --ids <aiservices-account-id> \
  --query "properties.{disableLocalAuth:disableLocalAuth, publicNetworkAccess:publicNetworkAccess}" \
  -o jsonc
```

기대값:

```text
disableLocalAuth: true
publicNetworkAccess: "Disabled"
```

### Partner model 약관

`grok-4.3`, `DeepSeek-V4-Pro` 같은 partner 모델은 테넌트에서 Azure Marketplace 약관 동의가 필요할 수 있습니다. 해당 모델만 실패하면 Azure Portal에서 모델 배포 플로우를 열어 약관 동의 상태를 확인하세요.

### PE/RBAC 전파 지연

Private Endpoint DNS와 RBAC 역할 할당은 apply 직후 몇 분 동안 전파 중일 수 있습니다. apply 직후 401/403이 나오지만 잠시 후 성공한다면 정상적인 전파 지연일 가능성이 높습니다.

### destroy 중단

VNet 주입 APIM은 `terraform destroy` 중 Named Value 삭제 단계에서 오래 멈출 수 있습니다. 운영 절차와 주의사항은 [운영의 리소스 정리](06-operate.md#6-리소스-정리)를 따르세요.

## 5. 관련 페이지

| 목적 | 이동 |
|---|---|
| 배포 경로 선택 | [배포](03-deploy.md) |
| 기존 Foundry 계정 연결 | [모델 백엔드 기존 계정 재사용](04-reuse-foundry.md) |
| consumer와 policy 운영 | [운영](06-operate.md) |
| 클라이언트 설정 | [클라이언트 온보딩](07-connect-clients.md) |
