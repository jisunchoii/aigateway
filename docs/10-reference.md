---
description: "레퍼런스 — 변수 전체 목록, 출력, 비용·정리, Gotcha 모음"
---

# 레퍼런스

- [1. 변수 전체 목록](#1-변수-전체-목록)
- [2. 출력 전체 목록](#2-출력-전체-목록)
- [3. 비용 및 정리](#3-비용-및-정리)
- [4. Gotcha 모음](#4-gotcha-모음)

## 1. 변수 전체 목록

***

`infra/variables.tf` 기준 전체 변수 목록입니다. `terraform.tfvars`에서 재정의할 수 있으며, `*`가 붙은 변수는 **기본값이 없어 반드시 제공**해야 합니다.

### 1. 코어 (Core)

***

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `prefix` | `string` | `"aigw"` | 리소스 이름 프리픽스. 라이브 dev 스택은 `llmgw` 고정. |
| `env` | `string` | `"dev"` | 환경 식별자. `dev` \| `test` \| `prod` |
| `location` | `string` | `"koreacentral"` | Azure 리전. `koreacentral` \| `koreasouth` \| `eastus` \| `eastus2` \| `westeurope` |
| `owner` * | `string` | — | 리소스 태그 `owner` (이메일 또는 팀명) |
| `cost_center` * | `string` | — | 리소스 태그 `costCenter` |

### 2. APIM

***

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `apim_publisher_name` * | `string` | — | APIM 게시자 표시 이름 |
| `apim_publisher_email` * | `string` | — | APIM 게시자 연락 이메일 |
| `apim_sku_name` | `string` | `"Developer_1"` | APIM SKU. `Developer_1` = SLA 없음(dev/demo용). 프로덕션은 `Premium_1`. VNet 주입은 Developer/Premium SKU 필요. |
| `apim_public` | `bool` | `false` | `true` = EXTERNAL VNet 모드(공개 VIP). `false` = Internal(VNet 전용). 스모크 테스트 전 `true` 권장. |

### 3. 모델 배포

***

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `openai_deployments` | `map(object)` | `{gpt-5.4, gpt-5.4-mini}` | Azure OpenAI 모델 배포 맵. 키 = 배포 이름 = 실제 모델 이름. |
| `foundry_deployments` | `map(object)` | `{grok-4.3, DeepSeek-V4-Pro}` | AIServices OSS/파트너 모델 배포 맵. 키는 클라이언트 facing 별칭. |
| `allowed_models` | `list(string)` | `["gpt-5.4","gpt-5.4-mini","grok-4.3","DeepSeek-V4-Pro"]` | 호출자가 요청할 수 있는 모델 목록. 이 외 모델 요청은 403. |
| `openai_api_version` | `string` | `"2025-01-01-preview"` | 클라이언트가 `?api-version=`으로 보내는 Azure OpenAI API 버전. |

#### `openai_deployments` 기본값

```hcl
{
  "gpt-5.4" = {
    model_name    = "gpt-5.4"
    model_version = "2026-03-05"
    sku_name      = "GlobalStandard"
    capacity      = 10
  }
  "gpt-5.4-mini" = {
    model_name    = "gpt-5.4-mini"
    model_version = "2026-03-17"
    sku_name      = "GlobalStandard"
    capacity      = 10
  }
}
```

#### `foundry_deployments` 기본값

```hcl
{
  "grok-4.3" = {
    model_name    = "grok-4.3"
    model_format  = "xAI"
    model_version = "1"
    sku_name      = "GlobalStandard"
    capacity      = 10
  }
  "DeepSeek-V4-Pro" = {
    model_name    = "DeepSeek-V4-Pro"
    model_format  = "DeepSeek"
    model_version = "2026-04-23"
    sku_name      = "GlobalStandard"
    capacity      = 500
  }
}
```

### 4. Brownfield 재사용 (reuse_foundry)

***

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `reuse_foundry` | `bool` | `false` | `true` = 기존 AIServices 계정을 data source로 읽기(생성 안 함). 상세: [04-reuse-foundry](04-reuse-foundry.md). |
| `existing_foundry_name` | `string` | `""` | 재사용할 AIServices 계정 이름. `reuse_foundry = true` 시 필수. |
| `existing_foundry_rg` | `string` | `""` | 기존 AIServices 계정의 리소스 그룹. `reuse_foundry = true` 시 필수. 게이트웨이 RG와 달라도 됨(동일 구독). |

{% hint style="info" %}
`reuse_foundry = true` 사용 시 `existing_foundry_name`과 `existing_foundry_rg`를 반드시 함께 지정해야 합니다. 어느 하나라도 비어 있으면 `terraform plan`에서 precondition 오류가 발생합니다.
{% endhint %}

### 5. 인증 (client_auth_mode / Entra ID)

***

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `client_auth_mode` | `string` | `"subscription-key"` | 클라이언트→게이트웨이 인증 방식. `subscription-key` \| `entra-id`. |
| `entra_tenant_id` | `string` | `""` | Entra ID 테넌트(GUID 또는 도메인). `client_auth_mode = entra-id` 시 필수. |
| `entra_api_audience` | `string` | `""` | JWT `aud` 클레임 기대값(게이트웨이 앱 등록 URI). `entra-id` 모드 필수. |
| `entra_team_claim` | `string` | `"groups"` | teamId 도출에 쓰이는 JWT 클레임. `groups` 클레임은 >150 그룹 멤버에서 누락될 수 있음. 프로덕션에서는 단일 값 custom app-role 권장. |

### 6. 이미지 / Admin UI

***

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `worker_image` | `string` | `""` | config-sync 워커 이미지 전체 참조(`<registry_login_server>/config-sync-worker:latest`). 빌드 전 비워두면 Container Apps Job이 생성되지 않음. |
| `config_sync_cron` | `string` | `"*/5 * * * *"` | config-sync 잡의 UTC cron 표현식. 기본: 5분마다. |
| `admin_ui_image` | `string` | `""` | Admin UI(SPA+BFF) 이미지. 빌드 전 비워두면 Container App이 생성되지 않음. |
| `admin_ui_public` | `bool` | `false` | `true` = Container Apps 환경 EXTERNAL(공개 FQDN). 첫 배포 후 변경 시 환경 재생성. |
| `bff_api_audience` | `string` | `""` | Admin UI BFF JWT `aud`. `admin_ui_image` 설정 시 필수. |
| `spa_client_id` | `string` | `""` | Admin UI SPA 앱 등록 client ID(사전 준비 P3). |
| `admin_group_object_id` | `string` | `""` | Entra ID 관리자 보안 그룹 object ID(사전 준비 P1). |

### 7. 예산 (Budget)

***

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `monthly_budget_amount` | `number` | `200` | Cost Management 월 예산(구독 통화). 알림 전용, 하드 스톱 아님. |
| `budget_alert_email` * | `string` | — | 예산 임계값 알림 이메일. |
| `budget_start_date` | `string` | `"2026-06-01T00:00:00Z"` | 예산 시작일(UTC, ISO 8601). 과거 날짜로 첫 apply 시 오류. |

{% hint style="warning" %}
`budget_start_date`는 첫 `terraform apply` 시점보다 과거 날짜이면 오류가 발생합니다. 현재 날짜 이후의 월 초 날짜를 사용하세요.
{% endhint %}

### 8. 레이트 리밋 (rate_tiers)

***

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `rate_tiers` | `map(object)` | `{small, medium, large}` | 팀별 레이트 리밋 티어 맵. APIM Named Values + Admin UI에 공급. |
| `tokens_per_minute` | `number` | `1000` | 팀당 분당 토큰 한도(정적). |
| `token_quota` | `number` | `50000` | 팀당 쿼터 기간 내 토큰 총량. |
| `token_quota_period` | `string` | `"Daily"` | 쿼터 리셋 주기. `Hourly` \| `Daily` \| `Weekly` \| `Monthly` \| `Yearly` |

#### `rate_tiers` 기본값

```hcl
{
  small  = { tpm = 500,   quota = 20000,  period = "Daily"   }
  medium = { tpm = 2000,  quota = 100000, period = "Daily"   }
  large  = { tpm = 10000, quota = 500000, period = "Monthly" }
}
```

### 9. 점프박스 (Jumpbox)

***

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `enable_jumpbox` | `bool` | `false` | `true` = Bastion + jumpbox VM 배포(백엔드 격리 진단용). |
| `jumpbox_admin_password` | `string` (sensitive) | `null` | jumpbox VM 관리자 패스워드(최소 12자). `enable_jumpbox = true` 시 필수. |
| `jumpbox_vm_size` | `string` | `"Standard_B2s_v2"` | jumpbox VM 크기. koreacentral 기본. eastus2 등에서는 `Standard_D2s_v7` 권장. |

## 2. 출력 전체 목록

***

`infra/outputs.tf` 기준 전체 Terraform 출력 목록입니다. `terraform output -raw <이름>` 으로 값을 직접 확인할 수 있습니다.

### 1. 출력 목록

***

| 이름 | 조건 | 설명 |
|---|---|---|
| `apim_gateway_url` | 항상 | APIM 게이트웨이 URL. VNet 내부에서 private IP로 해석. 클라이언트 base URL로 사용. |
| `apim_private_ip` | 항상 | APIM 내부 게이트웨이 사설 IP. VNet 내부 도구(`smoke-gateway`)에서 `--resolve` 옵션과 함께 사용. |
| `vscode_base_url` | 항상 | VS Code BYOK `chatLanguageModels.json` 의 `url` 프리픽스. |
| `openai_endpoint` | greenfield만 | Azure OpenAI 계정 엔드포인트. **`reuse_foundry = true` 면 `null`** (전용 Azure OpenAI 계정 없음). |
| `registry_name` | 항상 | ACR(Container Registry) 이름. `az acr build --registry $(terraform output -raw registry_name)` 형태로 사용. |
| `registry_login_server` | 항상 | ACR 로그인 서버. `worker_image` / `admin_ui_image` 변수 값 구성에 사용(`<registry_login_server>/image:tag`). |
| `config_store_endpoint` | 항상 | Cosmos DB 문서 엔드포인트. `scripts/seed-cosmos-jumpbox.sh` 등에 전달. |
| `config_store_account_name` | 항상 | Cosmos DB 계정 이름. `az cosmosdb` CLI 또는 포털 Data Explorer에서 사용. |
| `config_sync_job_name` | `worker_image` 설정 후 | config-sync Container Apps Job 이름. `az containerapp job start` 에 사용. **`worker_image` 미설정 시 `null`.** |
| `admin_ui_fqdn` | `admin_ui_image` 설정 후 | Admin UI 내부 FQDN. jumpbox 또는 EXTERNAL 모드 시 브라우저에서 `https://<this>` 접속. **`admin_ui_image` 미설정 시 `null`.** |
| `resource_group_name` | 항상 | 게이트웨이 워크로드의 기본 리소스 그룹 이름. |

### 2. 자주 쓰는 출력 조합

***

#### 클라이언트 설정용 URL

```bash
# APIM 게이트웨이 URL
terraform output -raw apim_gateway_url

# VS Code BYOK base URL
terraform output -raw vscode_base_url
```

#### 이미지 빌드 후 push

```bash
acr=$(terraform output -raw registry_login_server)
reg=$(terraform output -raw registry_name)
az acr build --registry $reg --image config-sync-worker:latest ../app/config-sync-worker
az acr build --registry $reg --image admin-ui:latest ../app/admin-ui
```

#### config-sync 잡 수동 트리거

```bash
job=$(terraform output -raw config_sync_job_name)
rg=$(terraform output -raw resource_group_name)
az containerapp job start -g $rg -n $job
```

#### Admin UI FQDN 확인

```bash
terraform output -raw admin_ui_fqdn
```

### 3. null 출력에 대하여

***

| 출력 | null이 되는 조건 |
|---|---|
| `openai_endpoint` | `reuse_foundry = true` (전용 Azure OpenAI 계정이 생성되지 않음) |
| `config_sync_job_name` | `worker_image = ""` (이미지 빌드 전) |
| `admin_ui_fqdn` | `admin_ui_image = ""` (이미지 빌드 전) |

{% hint style="info" %}
null 출력을 스크립트에서 참조할 경우 빈 문자열로 처리되므로, 해당 단계 완료 후 재확인하세요.
{% endhint %}

## 3. 비용 및 정리

***

### 1. APIM SKU와 비용

***

[Azure API Management 가격 책정](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-features)

| SKU | SLA | VNet 주입 | 용도 |
|---|---|---|---|
| `Developer_1` | **없음** | 지원 (Developer/Premium 필요) | dev / demo |
| `Premium_1` | 있음 | 지원 | 프로덕션 권장 |

{% hint style="warning" %}
`Developer_1`은 SLA가 없습니다. 프로덕션 환경에서는 반드시 `apim_sku_name = "Premium_1"` 로 설정하세요.
{% endhint %}

VNet 주입(Internal/External 모드)은 Developer 또는 Premium SKU에서만 지원됩니다. Consumption 또는 Basic SKU는 VNet 주입을 지원하지 않습니다.

### 2. 모델 과금

***

모델 호출은 **토큰당 과금**입니다. Azure OpenAI(gpt-5.4, gpt-5.4-mini) 및 Azure AI Foundry OSS/파트너 모델(grok-4.3, DeepSeek-V4-Pro) 모두 입력+출력 토큰 기준으로 청구됩니다.

- [Azure OpenAI 가격 책정](https://learn.microsoft.com/ko-kr/azure/ai-services/openai/concepts/models)
- [Azure AI Foundry 파트너 모델 가격](https://learn.microsoft.com/ko-kr/azure/ai-foundry/concepts/models-overview)

### 3. Cost Management 월 예산

***

[Azure Cost Management 예산](https://learn.microsoft.com/ko-kr/azure/cost-management-billing/costs/tutorial-acm-create-budgets)

```hcl
monthly_budget_amount = 200        # 구독 통화, 기본값
budget_alert_email    = "<이메일>"
budget_start_date     = "2026-06-01T00:00:00Z"
```

{% hint style="warning" %}
Cost Management 예산은 **알림(alert)** 만 발송합니다. 예산 초과 시 **자동 차단(하드 스톱)은 발생하지 않습니다.** 예산은 비용 모니터링과 이상 감지 용도입니다.
{% endhint %}

예산 임계값(50%, 75%, 100%, 120%)에서 `budget_alert_email`로 이메일 알림이 발송됩니다.

### 4. 리소스 정리 (terraform destroy)

***

개발/데모 환경을 삭제할 때는 다음 명령을 실행합니다.

```bash
cd infra && terraform destroy
```

#### VNet 주입 APIM 환경 정리 시 주의 (gotcha #3)

Developer 또는 Premium SKU로 VNet에 주입된 APIM을 `terraform destroy`로 삭제하면 **Named Value 삭제 단계에서 멈출 수 있습니다.** 이 경우 리소스 그룹 전체를 삭제하는 것이 더 안정적입니다.

```bash
az group delete -n <resource_group_name> --yes
```

`<resource_group_name>`은 `terraform output -raw resource_group_name`으로 확인합니다.

{% hint style="warning" %}
`az group delete`는 RG 내 모든 리소스를 삭제합니다. Terraform state와 동기화가 깨질 수 있으므로, 이후 같은 스택을 재배포할 때는 `terraform init`부터 다시 시작하세요.
{% endhint %}

자세한 내용은 아래 [Gotcha 모음 #3](#gotcha-3--vnet-주입-apim-terraform-destroy-중단) 절을 참고하세요.

## 4. Gotcha 모음

***

배포 및 운영 중 마주칠 수 있는 알려진 이슈와 해결 방법 모음입니다.

### 1. Gotcha 목록

***

#### Gotcha 1 — APIM VNet 주입 첫 apply ~45분

**증상:** `terraform apply`가 APIM 리소스 생성에 오랜 시간 소요되며 타임아웃처럼 보임.

**원인:** Developer 또는 Premium SKU의 VNet 주입 모드(Internal/External) 활성화는 Azure 내부에서 약 45분이 걸립니다. 이는 정상 동작입니다.

{% hint style="warning" %}
기다립니다. 타임아웃 없이 apply가 완료될 때까지 대기합니다. 중단하지 마세요.
{% endhint %}

---

#### Gotcha 2 — APIM OpenAPI import 400 오류 (첫 apply 레이스)

**증상:** 첫 `terraform apply` 시 APIM API import 단계에서 400 오류 발생.

**원인:** APIM 게이트웨이 프로비저닝이 완료되기 전에 OpenAPI spec import가 시도되는 일시적 레이스 컨디션. Foundry API는 wildcard 라우팅이므로 별도 import가 없어 영향받지 않습니다.

{% hint style="info" %}
`terraform apply`를 다시 실행합니다. 두 번째 apply에서 정상 완료됩니다.
{% endhint %}

---

#### Gotcha 3 — VNet 주입 APIM `terraform destroy` 중단

**증상:** `terraform destroy`가 Named Value 삭제 단계에서 멈추거나 오류 발생.

**원인:** VNet 주입 APIM 환경에서 Terraform이 Named Value 삭제 순서를 처리하지 못하는 경우가 있습니다.

**해결:** 리소스 그룹 전체를 직접 삭제합니다.

```bash
az group delete -n <resource_group_name> --yes
```

`<resource_group_name>`은 `terraform output -raw resource_group_name`으로 확인합니다. 이후 Terraform state와 동기화가 필요하면 state를 초기화하세요.

{% hint style="warning" %}
`az group delete`는 RG 내 모든 리소스를 영구 삭제합니다. 이후 같은 스택을 재배포할 때는 `terraform init`부터 다시 시작하세요.
{% endhint %}

---

#### Gotcha 4 — `data.azurerm_cognitive_account` `local_auth_enabled` 미노출

**증상:** `reuse_foundry = true` 모드에서 `terraform plan/apply` 시 `local_auth_enabled` 속성 관련 오류 또는 precondition 실패.

**원인:** `azurerm` provider 버전에 따라 `data.azurerm_cognitive_account`가 `local_auth_enabled` 속성을 노출하지 않을 수 있습니다.

{% hint style="info" %}
provider 업그레이드를 검토하거나, `az` CLI로 사전 점검하여 precondition을 대체합니다.

```bash
az resource show --ids <aiservices-account-id> \
  --query "properties.{disableLocalAuth:disableLocalAuth, publicNetworkAccess:publicNetworkAccess}" -o jsonc
# 기대값: disableLocalAuth: true, publicNetworkAccess: "Disabled"
```
{% endhint %}

---

#### Gotcha 5 — 파트너 모델 마켓플레이스 약관 동의 필요

**증상:** grok-4.3 또는 DeepSeek-V4-Pro 배포 시 오류 발생. 또는 스모크 테스트에서 해당 모델만 실패.

**원인:** xAI(grok), DeepSeek 등 파트너 모델은 테넌트에서 Azure Marketplace 약관에 동의해야 배포할 수 있습니다.

{% hint style="info" %}
Azure Portal에서 해당 모델의 배포 플로우를 진행하여 약관에 동의한 후 `terraform apply`를 재실행합니다.
{% endhint %}

### 2. 트러블슈팅 — HTTP 오류별 대응

***

#### 403 Forbidden — allowed-models 차단

**증상:** 특정 모델 호출 시 HTTP 403.

**원인:** 요청한 모델이 `allowed_models` 변수에 포함되어 있지 않아 APIM 정책이 차단.

**해결:**

1. `allowed_models` 변수에 해당 모델 이름이 포함되어 있는지 확인합니다.
   ```hcl
   allowed_models = ["gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro"]
   ```
2. `foundry_deployments` 또는 `openai_deployments` 맵의 키가 실제 배포 이름과 일치하는지 확인합니다.
3. 변경 후 `terraform apply`로 APIM Named Values를 업데이트합니다.

---

#### 429 Too Many Requests — 레이트 리밋 초과

**증상:** HTTP 429 오류. Retry-After 헤더가 포함될 수 있음.

**원인:** 소비자(팀)의 분당 토큰(TPM) 또는 쿼터 기간 토큰 한도 초과.

**해결:**

1. `rate_tiers` 변수에서 해당 팀의 tier 확인 및 상향 조정.
   ```hcl
   rate_tiers = {
     small  = { tpm = 500,   quota = 20000,  period = "Daily" }
     medium = { tpm = 2000,  quota = 100000, period = "Daily" }
     large  = { tpm = 10000, quota = 500000, period = "Monthly" }
   }
   ```
2. Admin UI에서 해당 소비자의 tier를 변경합니다.
3. 일시적 급증이라면 `tokens_per_minute` 기본값(`1000`) 상향을 고려합니다.

참고: [Azure API Management 레이트 리밋 정책](https://learn.microsoft.com/ko-kr/azure/api-management/rate-limit-by-key-policy)

---

#### 모델 전환 확인 — x-ai-gateway-* 응답 헤더

**증상:** 요청한 모델과 다른 모델이 실제로 응답하는 것 같음. 또는 예산 소진이 예상보다 빠름.

**원인:** 예산 기반 모델 전환(`downgrade_ladder`)이 발동하여 더 저렴한 모델로 전환.

**해결:** `curl -v` 또는 클라이언트 헤더 로그에서 다음 헤더를 확인합니다.

```
x-ai-gateway-requested-model: gpt-5.4
x-ai-gateway-effective-model: gpt-5.4-mini
x-ai-gateway-downgrade-level: 1
```

- `x-ai-gateway-requested-model`: 클라이언트가 요청한 모델
- `x-ai-gateway-effective-model`: 실제로 라우팅된 모델
- `x-ai-gateway-downgrade-level`: 현재 모델 전환 단계 (0 = 전환 없음)

이 헤더는 정상 동작입니다. 모델 전환이 발동하지 않게 하려면 예산 한도를 높이거나 소비자의 사용량을 줄이세요.

---

#### PE/RBAC 전파 지연

**증상:** `terraform apply` 직후 스모크 테스트 또는 백엔드 직접 테스트에서 401/403 발생. 잠시 후 재시도하면 성공.

**원인:** Azure Private Endpoint DNS 전파 또는 RBAC 역할 할당 전파에 수 분이 소요됩니다.

{% hint style="info" %}
첫 apply 완료 후 3~5분 기다린 뒤 스모크를 재실행합니다. 지속적으로 실패한다면 [05-verify.md](05-verify.md) 백엔드 격리 진단 절차로 격리 진단합니다.
{% endhint %}

참고:
- [Azure Private Endpoint DNS 구성](https://learn.microsoft.com/ko-kr/azure/private-link/private-endpoint-dns)
- [Azure RBAC 역할 할당 전파](https://learn.microsoft.com/ko-kr/azure/role-based-access-control/role-assignments-steps)
