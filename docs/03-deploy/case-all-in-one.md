---
description: "All-in-one 배포 — 신규 환경에 APIM, 모델 백엔드, Admin UI, config-sync worker를 함께 배포"
---

# All-in-one 배포

이 페이지는 신규 데모/검증 환경에서 **APIM 게이트웨이, 모델 백엔드, Admin UI, config-sync worker**를 한 흐름으로 배포하는 greenfield 경로를 설명합니다. 이름은 All-in-one이지만, ACR과 컨테이너 이미지의 순환 의존성 때문에 신규 환경에서는 보통 **최소 2번의 Terraform apply**가 필요합니다.

## 1. 선택 기준

{% hint style="success" %}
**이 경로가 맞는 경우**

- 새 Azure OpenAI/AIServices 계정과 모델 deployment를 만들 수 있다.
- Admin UI와 config-sync worker까지 한 흐름으로 준비하고 싶다.
- 기존 운영 Foundry 계정을 보존해야 하는 제약이 없다.
- 데모, 랩, PoC처럼 전체 스택을 빠르게 띄우는 환경이다.
{% endhint %}

{% hint style="info" %}
운영 환경에서는 All-in-one보다 모델 백엔드 결정 → APIM 게이트웨이 배포 → Admin UI 배포 순서로 나누는 단계적 배포가 더 안전합니다.
{% endhint %}

기존 AIServices(Foundry) 계정을 재사용해야 하면 [모델 백엔드 기존 계정 재사용](../04-reuse-foundry.md)을 먼저 따르세요. APIM 게이트웨이만 먼저 검증하려면 [APIM 게이트웨이 배포](case-apim-core-first.md)가 더 적합합니다.

## 2. 배포 전 결정

| 결정 | 선택지 | 기준 |
|---|---|---|
| 모델 백엔드 | 신규 생성 | 이 페이지는 `reuse_foundry=false` 경로 |
| APIM 공개 여부 | `apim_public=true/false` | 외부 개발 도구가 붙으면 public |
| Admin UI 공개 여부 | `admin_ui_public=true/false` | 브라우저에서 public FQDN으로 접속해야 하면 true |
| Admin 그룹 | 새 그룹 생성 / 기존 그룹 재사용 | 데모는 새 그룹, 운영 조직은 기존 그룹 |
| config-sync worker | 함께 배포 | All-in-one에서는 함께 배포 |

{% hint style="warning" %}
`apim_public`, `admin_ui_public`, 모델 deployment 설정은 첫 배포 전에 확정하세요. 나중에 변경하면 APIM 또는 Container Apps 환경이 재구성될 수 있습니다.
{% endhint %}

## 3. 전체 순서

| 단계 | 하는 일 | 결과 |
|---|---|---|
| Backend bootstrap | Terraform state 저장소 준비 | `infra/providers.tf` backend 설정 |
| 1차 tfvars | 모델, APIM, 기본값 입력 / 이미지 변수 비움 | APIM과 ACR을 만들 준비 |
| 1차 apply | APIM, 모델 백엔드, Cosmos, ACR 생성 | gateway와 ACR 준비 |
| Image build | Admin UI와 worker 이미지를 ACR에 push | 이미지 URI 확보 |
| Entra 준비 | 새 admin 그룹 또는 기존 그룹, BFF/SPA 앱 준비 | Admin UI 인증값 확보 |
| 2차 tfvars/apply | 이미지와 Entra 값을 입력하고 apply | Admin UI와 worker 배포 |
| Redirect/seed/sync | SPA redirect URI, Cosmos seed, worker 실행 | UI 로그인과 동적 정책 활성화 |
| Verify | gateway와 Admin UI 확인 | 배포 완료 |

## 4. 1차 tfvars

`infra/` 디렉터리의 `terraform.tfvars` 파일에 기본 배포값과 모델 backend 설정을 입력합니다. 모델 deployment 예시는 [모델 백엔드 신규 생성](case-foundry-greenfield.md)을 기준으로 채웁니다.

``` 
prefix                = "aigw"
env                   = "dev"
location              = "eastus2"
owner                 = "<team-or-owner>"
cost_center           = "<cost-center>"
apim_publisher_name   = "<publisher-name>"
apim_publisher_email  = "<publisher-email>"
apim_public           = true

# Admin UI 환경 모드. Container Apps 환경의 internal/external은 immutable이라
# 1차 apply에서 확정해야 함. 나중에 뒤집으면 환경 전체가 destroy+recreate 됨.
# Admin UI를 공개 FQDN으로 쓸 계획이면 지금 true로 둔다(이미지는 2차에서 채움).
admin_ui_public       = true

reuse_foundry = false
allowed_models = ["gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro"]

monthly_budget_amount = 200
budget_alert_email    = "<email>"
budget_start_date     = "2026-07-01"   # 과거 날짜 금지(첫 apply 시점 기준 당월 1일)

# 1차 apply에서는 ACR이 아직 없으므로 비워 둠
worker_image   = ""
admin_ui_image = ""
```

> Container Apps 환경의 `internal_load_balancer_enabled`(= `!admin_ui_public`)는 생성 후 변경할 수 없습니다. 환경은 1차 apply에서 무조건 만들어지므로, Admin UI를 public으로 쓸 계획이면 `admin_ui_public`을 **1차 tfvars에서** `true`로 두어야 2차 apply 때 환경이 통째로 재생성되는 낭비를 피할 수 있습니다. internal(VNet 전용)로 운영할 계획이면 생략하거나 `false`로 둡니다.

## 5. 1차 apply

처음 배포하는 구독이나 새 테스트 스택이면 `terraform init` 전에 state backend를 먼저 만듭니다. 이 단계는 Terraform이 관리하는 gateway 리소스가 아니라, Terraform state를 저장할 운영자용 저장소를 준비하는 작업입니다.

아래 값은 파일이 아니라 **터미널에 그대로 입력**합니다. 스크립트가 storage account를 만들고 `infra/providers.tf`의 backend 블록을 자동으로 채웁니다. 이 블록은 **레포 루트**(`./scripts/...` 경로 기준)에서 실행합니다. (여기 `location`은 backend 저장소 리전이며, gateway 리전은 `terraform.tfvars`의 `location`에서 정합니다.)

```bash
# 레포 루트에서 실행
location="eastus2"                              # backend 저장소 리전
backend_rg="rg-aigw-tfstate-dev-eastus2"        # state용 리소스 그룹
storage_prefix="staigwtfstate"                  # storage 계정 접두사(<=18자, 소문자+숫자)
state_key="ai-gateway-eus2.tfstate"             # state blob 이름

./scripts/bootstrap-backend.sh \
  --location "$location" \
  --backend-rg "$backend_rg" \
  --storage-prefix "$storage_prefix" \
  --state-key "$state_key"
```

같은 워킹카피에서 backend 리소스 그룹이나 storage account를 삭제한 뒤 다시 bootstrap했다면, 로컬 `.terraform` 디렉터리에 이전 backend 설정이 남아 있을 수 있습니다. 이 경우 첫 초기화는 `terraform init -reconfigure`로 실행합니다.

그 다음 Terraform을 실행합니다.

```bash
cd infra
terraform init
terraform plan
terraform apply
```

`reuse_foundry=true`이면 이 plan에서 기존 AIServices 계정과 모델 deployment가 생성 또는 변경 대상이 아닌지 확인합니다. 기존 계정 재사용 경로의 확인 항목은 [모델 백엔드 기존 계정 재사용](../04-reuse-foundry.md#5-plan-검증)을 따릅니다.

1차 apply는 APIM VNet 주입 때문에 약 45분 걸릴 수 있습니다. 완료 후 주요 출력값을 확인합니다.

```bash
terraform output apim_gateway_url
terraform output registry_name
terraform output registry_login_server
terraform output resource_group_name
```

## 6. 이미지 빌드

ACR이 준비되면 `infra/` 디렉터리에서 Admin UI와 config-sync worker 이미지를 빌드합니다.

```bash
reg="$(terraform output -raw registry_name)"
acr="$(terraform output -raw registry_login_server)"

az acr build --registry "$reg" --image config-sync-worker:latest ../app/config-sync-worker
az acr build --registry "$reg" --image admin-ui:latest ../app/admin-ui
```

## 7. Entra ID 객체 준비

Admin UI 배포 전에 새 Admin 그룹을 만들지, 기존 그룹을 재사용할지 결정합니다. 상세 기준은 [Admin UI 배포](case-admin-ui.md)를 따릅니다.

| 방식 | 준비값 |
|---|---|
| 새 그룹 생성 | `../scripts/app-registration.sh` 출력값 사용 |
| 기존 그룹 재사용 | 기존 그룹 Object ID + BFF/SPA 앱 등록값 사용 |

신규 데모/검증 환경에서는 아래 스크립트를 사용할 수 있습니다.

```bash
../scripts/app-registration.sh
```

필요한 출력값:

``` 
entra_tenant_id       = "<tenant guid>"
admin_group_object_id = "<admin group object id>"
bff_api_audience      = "api://<bff app id>"
spa_client_id         = "<spa app id>"
```

## 8. 2차 tfvars와 apply

1차 apply에서 만들어진 ACR login server와 Entra 값을 tfvars에 입력합니다.

``` 
worker_image          = "<registry_login_server>/config-sync-worker:latest"
admin_ui_image        = "<registry_login_server>/admin-ui:latest"
admin_ui_public       = true   # Step 4에서 이미 설정했다면 값 유지(변경 금지 — 재생성 유발)
entra_tenant_id       = "<tenant guid>"   # 누락 시 Admin UI 로그인이 AADSTS900023(tenant 'undefined')로 실패
admin_group_object_id = "<entra security group object id>"
bff_api_audience      = "api://<bff app id>"
spa_client_id         = "<spa app id>"
```

2차 apply를 실행합니다.

```bash
terraform apply
```

완료 후 Admin UI와 worker 출력값을 확인합니다.

```bash
terraform output admin_ui_fqdn
terraform output config_sync_job_name
terraform output config_store_endpoint
```

## 9. Redirect, seed, sync

Admin UI FQDN을 SPA redirect URI에 등록합니다.

```bash
spa_app_id="<spa_client_id>"
admin_ui_fqdn="$(terraform output -raw admin_ui_fqdn)"
spa_object_id="$(az ad app show --id "$spa_app_id" --query id -o tsv)"

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${spa_object_id}" \
  --headers "Content-Type=application/json" \
  --body "{\"spa\":{\"redirectUris\":[\"https://${admin_ui_fqdn}\"]}}"
```

Cosmos DB 초기 문서를 주입하고 config-sync worker를 즉시 실행합니다.

seed 스크립트는 jumpbox의 관리 ID(IMDS)와 Cosmos **private endpoint**를 사용하므로 반드시 **jumpbox 안에서** 실행해야 합니다. 로컬에서 `../scripts/seed-*.sh`를 직접 실행하면 `169.254.169.254`(IMDS)에 접속하지 못해 실패합니다. `az vm run-command`로 jumpbox에서 실행합니다.

```bash
cosmos_endpoint="$(terraform output -raw config_store_endpoint)"
resource_group_name="$(terraform output -raw resource_group_name)"
config_sync_job_name="$(terraform output -raw config_sync_job_name)"
jumpbox_vm="vm-jump-${prefix}-${env}-<region-abbrev>"   # 예: vm-jump-aigw-dev-eus2

az vm run-command invoke -g "$resource_group_name" -n "$jumpbox_vm" \
  --command-id RunShellScript --scripts @../scripts/seed-cosmos-jumpbox.sh \
  --parameters "$cosmos_endpoint"
az vm run-command invoke -g "$resource_group_name" -n "$jumpbox_vm" \
  --command-id RunShellScript --scripts @../scripts/seed-pricing-jumpbox.sh \
  --parameters "$cosmos_endpoint"
az containerapp job start -g "$resource_group_name" -n "$config_sync_job_name"
```

{% hint style="info" %}
Seed 작업은 VNet 내부에서 실행되어야 합니다. `enable_jumpbox=true` + `run_seed=true`로 배포하면 **1차 apply 때 Terraform run-command(`seed-cosmos-config`)로 자동 seed**되므로 위 seed 단계는 재실행/검증용입니다(idempotent upsert). 값을 바꿔 다시 주입할 때만 수동 실행하면 됩니다.
{% endhint %}

## 10. 검증

| 확인 항목 | 기대 결과 |
|---|---|
| APIM gateway | `/openai`, `/vscode/models`, `/foundry` 호출 성공 |
| Admin UI | `https://<admin_ui_fqdn>`에서 Entra 로그인 표시 |
| Admin 그룹 | 그룹 멤버만 consumer/key/policy 쓰기 가능 |
| config-sync worker | Cosmos 설정이 APIM named value로 반영 |
| Downgrade/metrics | 요청·토큰·모델 전환 이벤트가 관측 데이터에 기록 |

## 11. 다음 단계

| 목적 | 이동 |
|---|---|
| 직접 HTTP 호출 | [직접 API 호출](../07-connect-clients/direct-api.md) |
| consumer와 정책 운영 | [운영](../06-operate.md) |
| VS Code / Copilot CLI 연결 | [클라이언트 온보딩](../07-connect-clients.md) |
