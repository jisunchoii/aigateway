# Azure AI Gateway

Azure API Management(APIM)을 중심으로 Azure OpenAI와 Microsoft Foundry 모델을 하나의 거버넌스 엔드포인트 뒤에 두는 예제/데모용 AI Gateway입니다.

클라이언트는 APIM만 호출하고, APIM은 정책으로 consumer 식별, 모델 허용 목록, 토큰 제한, 예산 기반 모델 전환, 메트릭 기록을 처리한 뒤 Private Endpoint와 Managed Identity로 백엔드 AIServices 계정을 호출합니다.

![Architecture](docs/images/architecture.png)

## 주요 기능

| 기능 | 설명 |
|---|---|
| 단일 게이트웨이 | VS Code, GitHub Copilot CLI, REST client가 APIM gateway URL 하나를 사용 |
| 모델 거버넌스 | consumer별 allowed models, rate tier, token quota, daily budget 관리 |
| 예산 기반 전환 | 일별 USD 예산 사용량에 따라 `gpt-5.6-sol -> FW-GLM-5.2 -> DeepSeek-V4-Pro -> grok-4.3` 같은 downgrade ladder 적용 |
| 셀프서비스 Admin UI | Entra ID 로그인과 admin group 기반으로 consumer 등록, key 발급, 정책 변경 |
| 관측성 | App Insights/Log Analytics에 consumer, requested model, effective model, token metric 기록 |
| Passwordless backend | Foundry/Azure OpenAI 계정은 key auth를 끄고 APIM Managed Identity + RBAC으로 호출 |

## 현재 지원 클라이언트 경로

| 클라이언트 | APIM 경로 | 인증 헤더 | 비고 |
|---|---|---|---|
| GitHub Copilot CLI | `/openai/deployments/<model>/chat/completions` | `api-key` | CLI는 `COPILOT_PROVIDER_TYPE=azure` 사용 |
| VS Code BYOK | `/vscode/models/deployments/<model>/chat/completions` | `Ocp-Apim-Subscription-Key` | VS Code provider는 **Custom Endpoint** 사용 |
| OpenCode | `/openai/deployments/<model>/chat/completions` 또는 `/foundry/chat/completions` | `api-key` 또는 `Ocp-Apim-Subscription-Key` | custom OpenAI-compatible provider를 APIM 경로별로 분리 |
| 직접 API 호출 | `/openai` 또는 `/foundry` | `api-key` 또는 `Ocp-Apim-Subscription-Key` | 앱/스크립트 검증용 |

`api-key`와 `Ocp-Apim-Subscription-Key`는 서로 다른 credential이 아니라, 같은 APIM subscription key를 어떤 헤더 이름으로 보내는지만 다릅니다.

## 저장소 구조

| 경로 | 설명 |
|---|---|
| `infra/` | Terraform 루트. 네트워크, APIM, Foundry/OpenAI 연결, Cosmos DB, Key Vault, Log Analytics, ACR, Container Apps, jumpbox |
| `policies/` | Terraform이 렌더링하는 APIM policy template |
| `app/admin-ui/` | React SPA + FastAPI BFF. 하나의 Admin UI 컨테이너 이미지로 배포 |
| `app/config-sync-worker/` | Cosmos consumer config와 pricing 정보를 읽어 APIM named value/active downgrade를 동기화하는 Container Apps Job |
| `scripts/` | 배포/운영 보조 스크립트 |
| `docs/` | GitBook 배포·운영 가이드 |

### 주요 스크립트

| 파일 | 용도 |
|---|---|
| `scripts/bootstrap-backend.sh` | Terraform remote state용 Storage Account/Container 생성 및 `infra/providers.tf` backend block 갱신 |
| `scripts/app-registration.sh` | Admin UI용 Entra admin group, BFF API app, SPA app 생성. `entra_tenant_id`, `admin_group_object_id`, `bff_api_audience`, `spa_client_id` 출력 |
| `scripts/seed-pricing-jumpbox.sh` | Cosmos `pricing` 문서 업서트. Admin UI 가격 표시와 budget 계산에 사용 |
| `scripts/seed-cosmos-jumpbox.sh` | 선택적 global config seed. Terraform 기본값 대신 Cosmos global doc으로 APIM named value를 덮어쓰려는 경우에만 사용 |
| `scripts/smoke-v1-gateway.sh` | public APIM gateway end-to-end smoke test |
| `scripts/smoke-v1-backend.sh` | jumpbox/VNet 내부에서 backend AIServices 직접 호출 검증 |

## 배포 개요

자세한 절차는 [GitBook 배포](docs/03-deploy.md)을 기준으로 합니다. README는 흐름만 요약합니다. 기존 단일 문서 형식의 상세 runbook이 필요하면 [단계별 배포 가이드](docs/step-by-step-deployment-guide.md)도 참고할 수 있습니다.

### 1. Terraform state backend 준비

레포 루트에서 1회 실행합니다.

```bash
location="eastus2"
backend_rg="rg-aigw-tfstate-dev-eastus2"
storage_prefix="staigwtfstate"
state_key="ai-gateway-eus2.tfstate"

./scripts/bootstrap-backend.sh \
  --location "$location" \
  --backend-rg "$backend_rg" \
  --storage-prefix "$storage_prefix" \
  --state-key "$state_key"
```

같은 워킹카피에서 Terraform backend 리소스 그룹이나 storage account를 삭제한 뒤 다시 bootstrap했다면, 로컬 `.terraform` 디렉터리에 이전 backend 설정이 남아 있을 수 있습니다. 이 경우 첫 초기화는 `terraform init -reconfigure`로 실행합니다.

### 2. `terraform.tfvars` 작성

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
```

먼저 아래 값을 결정합니다.

| 변수 | 의미 |
|---|---|
| `location` | 배포 리전 |
| `apim_public` | VS Code/Copilot CLI 같은 외부 도구에서 APIM을 호출해야 하면 `true` |
| `reuse_foundry` | 기존 AIServices/Foundry 계정을 재사용할지 |
| `model_deployments` | canonical AIServices account에 둘 deployment 이름/모델/sku/capacity |
| `monthly_budget_amount`, `budget_alert_email` | Azure Cost Management 알림 예산 |

이전 버전을 `reuse_foundry=true`로 이미 적용한 state를 업그레이드한다면 첫 plan 전에 [기존 reuse state의 APIM RBAC 주소 전환](docs/06-operate.md#기존-reuse-state의-apim-rbac-주소-전환)을 수행합니다. `reuse_foundry=false`였던 managed 이력에는 이 state move를 적용하지 않습니다.

### 3. 게이트웨이 core 배포

처음에는 `worker_image`와 `admin_ui_image`를 비워 둔 상태로 APIM, 네트워크, Cosmos, ACR 등을 먼저 만듭니다.

```bash
cd infra
terraform init
terraform plan
terraform apply
```

APIM VNet 주입은 첫 배포에 오래 걸릴 수 있습니다.

### 4. 컨테이너 이미지 빌드

ACR이 생성된 뒤 Azure Container Registry 원격 빌드를 사용합니다. 로컬 Docker는 필요 없습니다.

```bash
cd infra
reg=$(terraform output -raw registry_name)
acr=$(terraform output -raw registry_login_server)

az acr build --registry "$reg" --image config-sync-worker:latest ../app/config-sync-worker
az acr build --registry "$reg" --image admin-ui:latest ../app/admin-ui
```

### 5. Admin UI용 Entra 객체 준비

신규 데모/검증 환경에서는 스크립트를 실행합니다.

```bash
./scripts/app-registration.sh
```

출력된 네 값을 `infra/terraform.tfvars`에 넣습니다.

```hcl
entra_tenant_id       = "<tenant id>"
admin_group_object_id = "<created admin group object id>"
bff_api_audience      = "api://<bff app id>"
spa_client_id         = "<spa app id>"
```

조직 정책상 admin consent가 자동 부여되지 않으면 tenant admin이 아래 URL로 동의해야 합니다.

```text
https://login.microsoftonline.com/<tenant id>/adminconsent?client_id=<spa app id>
```

### 6. Worker/Admin UI 활성화

`terraform.tfvars`에 이미지와 Admin UI 값을 넣습니다.

```hcl
worker_image          = "<registry_login_server>/config-sync-worker:latest"
admin_ui_image        = "<registry_login_server>/admin-ui:latest"
admin_ui_public       = true
```

적용합니다.

```bash
cd infra
terraform apply
```

Admin UI FQDN을 확인하고 SPA redirect URI에 등록합니다.

```bash
admin_ui_fqdn="$(terraform output -raw admin_ui_fqdn)"
```

자세한 redirect URI 명령은 [Admin UI 배포 가이드](docs/03-deploy/case-admin-ui.md)를 따릅니다.

### 7. Pricing seed와 config-sync

모델 가격은 Cosmos `pricing` 문서가 source of truth입니다. Admin UI 가격 표시와 budget 계산에 사용합니다.
`global` 문서의 `allowed_models`/quota 계열 값도 config-sync worker가 APIM named value로 반영하는 런타임 소유 데이터입니다. Terraform은 초기 seed만 만들고 이후 값은 의도적으로 되돌리지 않으므로, 운영 중 catalog를 바꾸려면 Cosmos 문서를 갱신한 뒤 config-sync를 실행/대기해야 합니다.

```bash
cosmos_endpoint="$(terraform output -raw config_store_endpoint)"
resource_group_name="$(terraform output -raw resource_group_name)"
config_sync_job_name="$(terraform output -raw config_sync_job_name)"

# jumpbox/VNet 내부 경로에서 실행되어야 합니다.
../scripts/seed-pricing-jumpbox.sh "$cosmos_endpoint"

# 즉시 반영
az containerapp job start -g "$resource_group_name" -n "$config_sync_job_name"
```

2026-07-10 기준 Azure Retail Prices에는 GPT-5.6 meter가 없어서 `gpt-5.6-sol` 공식 단가를 seed할 수 없습니다. 가격이 아직 없는 canonical 모델은 운영자가 공식 per-1K rate를 넣기 전까지 budget 계산에서 `$0`으로 집계됩니다.

운영 중 Admin UI에서 consumer 정책을 저장하면 BFF가 config-sync job을 best-effort로 즉시 시작합니다. 실패하더라도 worker cron(`config_sync_cron`, 기본 5분)이 보완합니다.

## Admin UI에서 하는 일

Admin UI는 Entra ID 로그인과 admin group 검사 후 사용할 수 있습니다.

| 작업 | 결과 |
|---|---|
| consumer 등록 | APIM subscription 대상 consumer 생성 |
| key 발급 | 클라이언트가 사용할 APIM subscription key 발급 |
| allowed models 변경 | consumer별 호출 가능 모델 제한 |
| rate tier 변경 | consumer별 TPM/quota 제한 |
| daily budget / downgrade ladder 설정 | 예산 임계값에 따른 실제 serving model 전환 |
| monitoring 확인 | 요청, 토큰, 차단, downgrade 이벤트 확인 |

## 클라이언트 설정 요약

### VS Code BYOK

VS Code는 **Custom Endpoint** provider를 사용합니다. 예시는 [VS Code BYOK 가이드](docs/07-connect-clients/vscode-byok.md)를 따릅니다.

```json
{
  "name": "LLM Gateway APIM",
  "vendor": "customendpoint",
  "apiType": "chat-completions",
  "models": [
    {
      "id": "gpt-5.6-sol",
      "name": "GPT-5.6 Sol via APIM",
      "url": "https://<apim-host>/vscode/models/deployments/gpt-5.6-sol/chat/completions?api-version=2025-01-01-preview",
      "toolCalling": true,
      "vision": true,
      "maxInputTokens": 128000,
      "maxOutputTokens": 16000,
      "requestHeaders": {
        "Ocp-Apim-Subscription-Key": "<APIM subscription key>"
      }
    }
  ]
}
```

### GitHub Copilot CLI

Copilot CLI는 **Azure provider**로 설정합니다. `COPILOT_PROVIDER_BASE_URL`에는 APIM host만 넣고 `/openai`를 붙이지 않습니다.

```bash
export COPILOT_PROVIDER_TYPE=azure
export COPILOT_PROVIDER_BASE_URL=https://<apim-host>
export COPILOT_PROVIDER_API_KEY="<APIM subscription key>"
export COPILOT_PROVIDER_AZURE_API_VERSION=2025-01-01-preview
export COPILOT_PROVIDER_WIRE_API=completions
export COPILOT_PROVIDER_MODEL_ID=gpt-5.6-sol
export COPILOT_PROVIDER_WIRE_MODEL=gpt-5.6-sol
export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=128000
export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=16000
```

### OpenCode

OpenCode는 **OpenAI-compatible custom provider**를 APIM 경로별로 나눠 사용합니다. gpt 계열은 `/openai/deployments/<model>`, partner/OSS 모델은 `/foundry`로 연결합니다. 자세한 설정은 [OpenCode 가이드](docs/07-connect-clients/opencode.md)를 따릅니다.

## 관측과 검증

모델별 호출 여부는 Log Analytics의 `AppMetrics`에서 확인합니다.

```bash
WS=$(az monitor log-analytics workspace show \
  -g <resource-group> \
  -n <workspace-name> \
  --query customerId -o tsv)

az monitor log-analytics query -w "$WS" --analytics-query "
AppMetrics
| where TimeGenerated > ago(24h)
| where Name == 'Total Tokens'
| extend p=parse_json(Properties)
| summarize
    calls=sum(ItemCount),
    tokens=sum(Sum),
    lastSeen=max(TimeGenerated)
  by
    consumer=tostring(p.consumer),
    requested=tostring(p.deployment),
    effective=tostring(p.effectiveModel),
    api=tostring(p['API ID'])
| order by lastSeen desc
" -o table
```

## 비용과 정리

- APIM `Developer_1`은 SLA가 없으므로 데모/개발용입니다. 운영 SLA가 필요하면 `Premium_1` 이상을 검토하세요.
- Azure Cost Management 예산은 알림 전용입니다. 실제 호출 제어는 APIM policy의 token limit과 budget downgrade가 수행합니다.
- 사용하지 않는 데모 환경은 `infra/`에서 `terraform destroy`로 정리합니다.

## 보안 모델

- 백엔드 모델 계정은 Private Endpoint와 Managed Identity 기반 RBAC으로만 접근합니다.
- 클라이언트는 APIM subscription key 또는 Entra ID JWT를 사용합니다.
- Admin UI와 config-sync worker는 managed identity로 Cosmos, APIM, Log Analytics에 접근합니다.
- APIM subscription key, API token, credential은 Git에 커밋하지 않습니다.

## 전체 문서

GitBook 문서는 `docs/`에 있습니다.

| 목적 | 문서 |
|---|---|
| 전체 개요 | [docs/01-overview.md](docs/01-overview.md) |
| 거버넌스 모델 | [docs/02-governance.md](docs/02-governance.md) |
| 배포 경로 선택 | [docs/03-deploy.md](docs/03-deploy.md) |
| Admin UI 배포 | [docs/03-deploy/case-admin-ui.md](docs/03-deploy/case-admin-ui.md) |
| 클라이언트 온보딩 | [docs/07-connect-clients.md](docs/07-connect-clients.md) |
| 운영 | [docs/06-operate.md](docs/06-operate.md) |
