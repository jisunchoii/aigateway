---
description: "시나리오 E — 신규 환경에 전체 스택을 Terraform으로 한 번에 배포합니다."
---

# 시나리오 E — All-in-one Terraform 배포


이 시나리오는 **Greenfield** 경로입니다. Azure 구독에 아무것도 없는 상태에서 APIM·AI 모델·Admin UI·config-sync worker 전체를 한 번의 Terraform 설정으로 배포합니다. `reuse_foundry = false`가 기본값이므로 Azure OpenAI 계정과 모델 배포도 Terraform이 새로 생성합니다.

기존 리소스(운영 중인 AIServices 계정, 이미 올라간 게이트웨이 코어 등)가 있다면 이 시나리오보다 [시나리오 A~D](#관련-시나리오)가 더 적합합니다.

***

## 1. 왜 최소 2번의 apply가 필요한가

***

{% hint style="info" %}
**ACR-이미지 chicken-and-egg 문제:** [Azure Container Registry](https://learn.microsoft.com/ko-kr/azure/container-registry/container-registry-intro)(ACR)는 Terraform이 1차 apply에서 생성합니다. 하지만 Container Apps(worker·Admin UI)가 이미지를 pull하려면 이미지가 ACR에 이미 있어야 합니다. 즉, 이미지가 존재하기 전에 ACR을 만들어야 하고, ACR이 만들어지기 전에 이미지를 push할 수 없습니다. 이 순환 의존성 때문에 완전한 신규 환경에서는 **최소 2번의 apply**가 필요합니다.

단, ACR과 이미지가 이미 존재하는 재배포(환경 재생성) 상황에서는 단일 apply가 가능합니다.
{% endhint %}

***

## 2. 1차 apply — 코어 인프라 및 ACR 생성

***

먼저 이미지 변수를 비워 두고 코어 인프라를 배포합니다.

### 상태 백엔드 부트스트랩 (구독당 1회)

```bash
export location=eastus2
export backend-rg=rg-aigw-tfstate-dev-eastus2
export storage-prefix=staigwtfstate
export state-key=ai-gateway-eus2.tfstate

./scripts/bootstrap-backend.sh --location $location --backend-rg $backend-rg --storage-prefix $storage-prefix --state-key $state-key
```

이미 state 백엔드가 있다면 이 단계를 건너뛰세요.

### tfvars 기본 설정

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
```

`infra/terraform.tfvars`에서 아래 항목을 먼저 채우세요.

```hcl
prefix                 = "aigw"
env                    = "dev"
location               = "eastus2"
owner                  = "<팀 또는 담당자>"
cost_center            = "<비용 센터>"
apim_publisher_name    = "<게시자 이름>"
apim_publisher_email   = "<게시자 이메일>"
apim_public            = true
monthly_budget_amount  = 200
budget_alert_email     = "<알림 수신 이메일>"
budget_start_date      = "2026-07-01"

# 이미지 변수는 1차 apply에서 비워 두세요
worker_image   = ""
admin_ui_image = ""
```

{% hint style="warning" %}
**`apim_public`은 첫 apply 전에 확정하세요.** 배포 후 변경하면 [Azure API Management](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-key-concepts) VNet 재구성으로 추가 시간(~45분)이 발생합니다.
{% endhint %}

### 1차 apply 실행

```bash
cd infra
terraform init
terraform apply
```

APIM VNet 주입으로 인해 **약 45분** 소요됩니다. 정상이므로 프로세스를 중단하지 마세요.

1차 apply 완료 후 생성되는 주요 리소스:

- APIM + 3개 API(`/openai`, `/vscode/openai`, `/foundry`) + 정책
- Azure OpenAI 계정 및 모델 배포(`gpt-5.4`, `gpt-5.4-mini`)
- Azure AI Foundry 모델 배포(`grok-4.3`, `DeepSeek-V4-Pro`)
- [Azure Container Registry](https://learn.microsoft.com/ko-kr/azure/container-registry/container-registry-intro)
- [Azure Cosmos DB](https://learn.microsoft.com/ko-kr/azure/cosmos-db/introduction)(Private Endpoint, 로컬 인증 비활성화)
- [Azure Virtual Network](https://learn.microsoft.com/ko-kr/azure/virtual-network/virtual-networks-overview) 및 서브넷

***

## 3. 이미지 빌드·푸시

***

1차 apply가 완료되면 ACR이 준비된 상태입니다. `infra/` 디렉터리에서 이미지를 빌드하세요.

```bash
acr=$(terraform output -raw registry_login_server)
reg=$(terraform output -raw registry_name)
az acr build --registry $reg --image config-sync-worker:latest ../app/config-sync-worker
az acr build --registry $reg --image admin-ui:latest ../app/admin-ui
```

[ACR 원격 빌드](https://learn.microsoft.com/ko-kr/azure/container-registry/container-registry-tutorial-quick-task)는 Docker 로컬 설치 없이 Azure 클라우드에서 실행됩니다.

***

## 4. Entra ID 앱 등록 및 2차 apply

***

### Entra ID 앱 등록

```bash
./scripts/app-registration.sh
```

스크립트가 완료되면 세 값(`admin_group_object_id`, `bff_api_audience`, `spa_client_id`)을 출력합니다.

### tfvars 업데이트

`infra/terraform.tfvars`에 아래 변수를 추가하세요.

```hcl
worker_image          = "<registry_login_server>/config-sync-worker:latest"
admin_ui_image        = "<registry_login_server>/admin-ui:latest"
admin_ui_public       = true
admin_group_object_id = "<entra security group object id>"
bff_api_audience      = "api://<bff app id>"
spa_client_id         = "<spa app id>"
```

### 2차 apply 실행

```bash
terraform apply
```

이 apply는 APIM을 재구성하지 않으므로 1차보다 빠르게 완료됩니다. 완료되면 전체 스택이 배포됩니다.

- config-sync-worker Container Apps Job
- Admin UI Container App
- Entra ID RBAC 바인딩

***

## 5. Seed 및 최종 설정

***

배포 완료 후 Cosmos DB에 초기 설정 데이터를 주입하고 config-sync를 즉시 트리거합니다.

```bash
./scripts/seed-cosmos-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
./scripts/seed-pricing-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
az containerapp job start -g <rg> -n <config_sync_job_name>
```

`<cosmos-account>`는 `terraform output config_store_account_name`, `<rg>`는 `terraform output resource_group_name`, `<config_sync_job_name>`은 `terraform output config_sync_job_name`으로 확인합니다.

SPA redirect URI도 업데이트해야 합니다. 상세 절차는 [배포 공통 절차](../03-deploy.md#8-seed-및-최종-설정) 절을 참고하세요.

{% hint style="info" %}
Seed 작업은 VNet 내부에서 실행해야 합니다. `enable_jumpbox = true`로 배포했다면 2차 apply 완료 시 자동으로 실행됩니다.
{% endhint %}

***

## 관련 시나리오

***

| 상황 | 권장 시나리오 |
|---|---|
| 기존 AIServices(Foundry) 계정 재사용 | [기존 Foundry 재사용](../04-reuse-foundry.md) |
| 코어만 먼저 올리고 Admin UI는 나중에 | [시나리오 D — Admin UI 추가 배포](case-admin-ui.md) |
| Entra 그룹이 이미 있는 경우 | [기존 Entra 그룹 재사용](case-entra-group.md) |

전체 배포 각 단계의 상세 설명은 [배포 공통 절차](../03-deploy.md)를 참고하세요.
