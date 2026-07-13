# 단계별 배포 가이드 (Step-by-Step Deployment Guide)

> **Legacy runbook notice (historical reference):** 이 문서는 단일 문서 형식의 예전 배포 가이드를 보존한 것입니다. 현재 배포 절차와 기준값은 [`03-deploy.md`](03-deploy.md) 및 하위 runbook을 우선하세요. 아래의 split-topology 용어(`openai_deployments`, `foundry_deployments` 등)는 historical 설명으로 남아 있을 수 있습니다.

이 문서는 `aigateway`(Azure APIM 기반 AI 게이트웨이)를 **사용자 본인의 Azure 환경**에 처음부터
끝까지 배포하기 위한 단계별 가이드입니다. 두 가지 배포 경로를 다룹니다.

| 경로 | 언제 쓰나 | 모델 백엔드 |
|---|---|---|
| **경로 A. 모델까지 배포 (provision)** (기본) | 빈 구독에서 모델 배포부터 게이트웨이까지 전부 새로 만들 때 | Terraform이 AIServices 계정 + 모델 배포를 **새로 생성**. |
| **경로 B. 기존 모델 endpoint 재사용 (reuse)** | 이미 모델이 배포된 AIServices 계정이 있고, 게이트웨이만 그 앞에 둘 때 | 기존 계정을 `data` 소스로 참조. 모델 계정/배포를 **새로 만들지 않음**. |

> **이 저장소의 기본은 경로 A(모델까지 배포)** 입니다. `infra/main.tf`가 `module "openai"` /
> `module "foundry"`로 모델 계정과 배포를 직접 생성합니다. 클론한 그대로 배포하면 경로 A입니다.
>
> **경로 B(기존 모델 재사용)** 로 가려면 `infra/main.tf`를 로컬에서 수정해(두 모듈을 제거하고
> 기존 AIServices 계정을 참조하는 `data` 소스로 교체) 배포합니다. 자세한 수정 방법은
> [부록 B](#부록-b-경로-b로-전환기존-모델-재사용)에 있습니다. **이 변경은 커밋하지 않아도 됩니다**
> (`infra/terraform.tfvars`와 로컬 `main.tf` 편집만으로 동작).

아키텍처 개요는 [`README.md`](../README.md)를 참고하세요. 이 가이드는 "어떤 파일의 어떤 부분을
고쳐서 실행하는가"에 집중합니다.

---

## 0. 공통 사전 준비

### 0.1 도구

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.7
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- Docker는 **불필요** (컨테이너 이미지는 ACR에서 원격 빌드)

```powershell
az login
az account set --subscription "<구독 ID>"
az account show --query "{sub:name, id:id, tenant:tenantId}" -o table
```

### 0.2 구독 기능 등록 (APIM VNet Public IP, 한 번만)

APIM(stv2)을 Internal VNet 모드로 띄우려면 **자체 Public IP**를 붙여야 하고, 이를 위해 구독에
`Microsoft.Network/AllowBringYourOwnPublicIpAddress` 기능이 등록돼 있어야 합니다. 등록돼 있지
않으면 1차 apply가 다음 오류로 실패합니다:

```
Error: updating Public IP Address ... SubscriptionNotRegisteredForFeature:
... Microsoft.Network/AllowBringYourOwnPublicIpAddress required ...
```

배포 **전에** 등록하세요(등록 전파에 시간이 걸릴 수 있음):

```powershell
az feature register --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress
# 상태가 Registered가 될 때까지 확인
az feature show --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress --query "properties.state" -o tsv
# Registered가 되면 provider에 전파
az provider register -n Microsoft.Network
```

### 0.3 필요한 권한

| 작업 | 필요 권한 |
|---|---|
| 게이트웨이 리소스 그룹 생성/배포 | 구독 또는 RG `Contributor` |
| APIM 관리 ID에 RBAC 부여 | RBAC를 부여할 스코프에서 `User Access Administrator` 또는 `Owner` |
| **경로 B 한정**: 기존 모델 계정에 APIM MI RBAC 부여 | **기존 계정의 RG**에서 `User Access Administrator`/`Owner` |
| Entra 객체 생성 (Admin UI용) | 디렉터리에서 앱 등록·보안 그룹 생성 가능한 권한 |

> 경로 B에서 기존 모델 계정이 **다른 팀/다른 RG** 소유라면, 그 RG에 role assignment를 만들 권한이
> 있어야 합니다. APIM은 `Cognitive Services OpenAI User` + `Cognitive Services User`만 **추가로**
> 받으며, 계정의 네트워크/인증 설정은 변경하지 않습니다.

### 0.4 Terraform 상태 백엔드 부트스트랩 (구독당 1회)

```bash
cd /path/to/llm-gateway
./scripts/bootstrap-backend.sh \
  --location eastus2 \
  --backend-rg rg-aigw-tfstate-dev-eastus2 \
  --storage-prefix staigwtfstate \
  --state-key ai-gateway-eus2.tfstate
```

스크립트가 Terraform state용 리소스 그룹, storage account, `tfstate` 컨테이너를 만들고 `infra/providers.tf`의 `backend "azurerm"` 블록을 자동으로 갱신합니다. 사용자가 `providers.tf` 값을 손으로 복사해 넣을 필요는 없습니다.

```hcl
# infra/providers.tf (bootstrap 스크립트가 자동 갱신)
backend "azurerm" {
  resource_group_name  = "rg-aigw-tfstate-dev-eastus2"   # ← 부트스트랩 출력값
  storage_account_name = "staigwtfstatexxxxxx"           # ← 부트스트랩 출력값
  container_name       = "tfstate"
  key                  = "llm-gateway.tfstate"
  use_azuread_auth     = true
}
```

같은 워킹카피에서 backend 리소스 그룹이나 storage account를 삭제한 뒤 다시 bootstrap했다면, 로컬 `.terraform` 디렉터리에 이전 backend 설정이 남아 있을 수 있습니다. 이 경우 첫 초기화는 `terraform init -reconfigure`로 실행합니다.

---

## 1. 경로 선택 후 인프라 설정

여기서 두 경로가 갈립니다. 본인 시나리오에 맞는 절을 따르세요.

### 1.A 경로 A. 모델까지 배포 (provision, 기본)

저장소 기본 상태가 이 경로입니다. `infra/main.tf`는 모델 계정 + 배포를 직접 생성합니다
(**수정 불필요**):

```hcl
# infra/main.tf: 모델 계정 + 배포 생성 (저장소 기본)
module "openai"  { source = "./modules/openai"  ... deployments = var.openai_deployments  }
module "foundry" { source = "./modules/foundry" ... deployments = var.foundry_deployments }
```

**고쳐야 할 부분 (본인 구독의 쿼터/리전에 맞게 변경):**

1. **배포할 모델 스펙**: `infra/variables.tf`의 `openai_deployments` / `foundry_deployments`
   기본값을 **본인이 배포할 모델로 교체**하세요.
   - `openai_deployments`: Azure OpenAI 스타일 모델. 각 항목의 **값**
     (`model_name`, `model_version`, `sku_name`, `capacity`)이 **실제 배포에 사용**됩니다.
   - `foundry_deployments`: OSS/파트너 모델. 값에 `model_format`(모델 공급자, 예: `OpenAI`,
     `Meta`, `Mistral` 등) 포함.
   - map의 **키**가 게이트웨이가 노출하는 client-facing 배포 이름(= alias)이 됩니다.
   - `capacity`는 Azure 모델 deployment의 `sku.capacity`로 적용되며, APIM default TPM 계산에도
     `capacity * 1000` 형태로 사용됩니다. 다만 consumer에 `small`/`medium`/`large` tier가
     지정되어 있으면 `rate_tiers` 값이 우선합니다.

   예시 형태(실제 모델명/버전/SKU/용량은 아래 명령으로 확인한 값으로 채우세요):

   ```hcl
   openai_deployments = {
     "<alias>" = { model_name = "<model>", model_version = "<version>", sku_name = "<sku>", capacity = <n> }
   }
   foundry_deployments = {
     "<alias>" = { model_name = "<model>", model_format = "<format>", model_version = "<version>", sku_name = "<sku>", capacity = <n> }
   }
   ```

   본인 리전에서 배포 가능한 모델/쿼터 확인:

   ```powershell
   az cognitiveservices usage list -l <region> -o table
   az cognitiveservices model list -l <region> --query "[].{model:model.name, format:model.format, version:model.version}" -o table
   ```

2. **허용 모델 목록**: `infra/variables.tf`의 `allowed_models` 기본값을 위 배포 키 집합과 동일하게.

3. **Admin UI/대시보드 라벨**: `infra/main.tf`의 `control_plane` 모듈 `alias_models_json`
   (배포 이름을 사람이 읽는 라벨로 매핑). 본인 모델에 맞게.

4. **단가표(선택, 비용 기반 예산용)**: `scripts/seed-pricing-jumpbox.ps1`의 모델별 prompt/
   completion 요율을 본인 모델로 수정(나중에 6단계에서 시드).

> `existing_model_account_name` / `existing_model_account_rg` 변수는 경로 A에서는 **무시**됩니다.

이제 [2. 게이트웨이 코어 배포](#2-게이트웨이-코어-1차-apply)로 이동.

### 1.B 경로 B. 기존 모델 endpoint 재사용 (reuse)

이미 모델이 배포된 AIServices 계정을 그대로 쓰려면, `infra/main.tf`를 **로컬에서 수정**해 모델 생성
모듈을 제거하고 기존 계정을 참조하는 `data` 소스로 교체합니다. 정확한 수정 절차는
[부록 B](#부록-b-경로-b로-전환기존-모델-재사용)에 있습니다. 수정 후 다시 이 가이드의
[2단계](#2-게이트웨이-코어-1차-apply)로 돌아오세요.

핵심 차이만 요약:
- `infra/main.tf`를 편집해야 합니다(`module "openai"`/`module "foundry"`를 `data "azurerm_cognitive_account"`로 교체).
- `infra/terraform.tfvars`에 기존 계정 좌표를 넣습니다:
  ```hcl
  existing_model_account_name = "<기존 AIServices 계정 이름>"
  existing_model_account_rg   = "<그 계정의 리소스 그룹>"
  ```
- `openai_deployments` / `foundry_deployments`의 **키**(map key)만 기존 계정의 실제 배포 이름과
  일치시키면 됩니다. 재사용 모드에서 값(capacity/version 등)은 사용되지 않고 **키만** alias
  라우팅에 쓰입니다. 기존 배포 이름 확인:
  ```powershell
  az cognitiveservices account deployment list -g <기존 계정 RG> -n <기존 계정 이름> --query "[].name" -o tsv
  ```
- APIM MI에 기존 계정 RG 스코프로 RBAC가 부여됩니다(0.3 권한 표 참고). 기존 계정의 네트워크/인증
  설정은 변경하지 않습니다.

---

## 2. 게이트웨이 코어 (1차 apply)

첫 apply에서는 `worker_image`와 `admin_ui_image`를 **비워둡니다**(기본값 `""`). 이미지가 아직 없고,
워커 Job/Admin UI 앱은 이 변수로 카운트 게이트되어 있어 자동으로 건너뜁니다.

`infra/terraform.tfvars` 최소 구성:

```hcl
prefix               = "aigw"
env                  = "dev"
location             = "eastus2"
owner                = "you@example.com"
cost_center          = "CC-DEMO"
apim_publisher_name  = "Platform Team"
apim_publisher_email = "you@example.com"
apim_sku_name        = "Developer_1"       # Internal VNet 지원 SKU (또는 Premium_1)

# 경로 B(기존 모델 재사용)일 때만, 경로 A에서는 생략/무시
# existing_model_account_name = "<기존 계정 이름>"
# existing_model_account_rg   = "<기존 계정 RG>"

monthly_budget_amount = 200
budget_alert_email    = "you@example.com"
budget_start_date     = "2026-07-01T00:00:00Z"   # 과거 날짜 금지(첫 apply 시점 기준 당월 1일)
```

```powershell
cd infra
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply -input=false tfplan
```

> **APIM Internal VNet 모드는 첫 apply에서 약 30~45분 걸립니다. 정상입니다.**
> plan에서 `openai_endpoint`가 경로 A면 **새로 만들 계정 호스트**, 경로 B면 **기존 계정 호스트**로
> 나오는지 확인하세요.

apply 완료 후 주요 출력값 확인:

```powershell
terraform output
# registry_name, registry_login_server, apim_gateway_url, config_sync_job_name 등
```

> **APIM 이름 충돌(409 soft-delete)**: APIM 서비스 이름은 전역 고유이며 삭제 후에도 최대 48시간
> soft-delete 상태로 남습니다. `ServiceAlreadyExistsInSoftDeletedState` 오류가 나면 같은 이름의
> soft-deleted APIM을 purge한 뒤 재apply하세요:
> ```powershell
> az apim deletedservice list -o table
> az apim deletedservice purge --service-name <apim 이름> --location <region>
> ```

---

## 3. Entra 객체 생성 (Admin UI용)

Terraform으로 만들 수 없는 디렉터리 객체입니다. 게이트웨이 코어가 떠 있는 동안 병행 생성 가능합니다.
세 가지를 만듭니다.

### 3.1 관리자 보안 그룹 (`admin_group_object_id`)

```powershell
$me  = az ad signed-in-user show --query id -o tsv
$grp = az ad group create --display-name "aigw-admins" --mail-nickname "aigw-admins" --query id -o tsv
az ad group member add --group $grp --member-id $me
Write-Host "admin_group_object_id = $grp"
```

### 3.2 BFF API 앱 등록 (`bff_api_audience`)

`access_as_user` 스코프 노출 + `api.requestedAccessTokenVersion = 2` + `api://<app-id>` 설정.

```powershell
$bff = az ad app create --display-name "aigw-admin-bff" --sign-in-audience AzureADMyOrg | ConvertFrom-Json
$bffAppId = $bff.appId; $bffObjId = $bff.id

$scopeId = [guid]::NewGuid().ToString()
$body = @{
  identifierUris = @("api://$bffAppId")
  api = @{
    requestedAccessTokenVersion = 2
    oauth2PermissionScopes = @(@{
      id = $scopeId
      adminConsentDescription = "Access the gateway admin API as the signed-in user."
      adminConsentDisplayName = "Access gateway admin API"
      userConsentDescription  = "Access the gateway admin API on your behalf."
      userConsentDisplayName  = "Access gateway admin API"
      value = "access_as_user"; type = "User"; isEnabled = $true
    })
  }
} | ConvertTo-Json -Depth 6
Set-Content -Path bff_patch.json -Value $body -Encoding utf8
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$bffObjId" `
  --headers "Content-Type=application/json" --body `@bff_patch.json
Write-Host "bff_api_audience = api://$bffAppId"
```

### 3.3 SPA 퍼블릭 클라이언트 앱 등록 (`spa_client_id`)

PKCE, 시크릿 없음. 리디렉션 URI는 Admin UI FQDN이 나오는 **2차 apply 이후**에 추가합니다.

```powershell
$spa = az ad app create --display-name "aigw-admin-spa" --sign-in-audience AzureADMyOrg `
  --is-fallback-public-client true | ConvertFrom-Json
$spaAppId = $spa.appId

# SPA->BFF 위임 권한 부여 + 관리자 동의
$scopeId = az ad app show --id $bffAppId --query "api.oauth2PermissionScopes[?value=='access_as_user'].id | [0]" -o tsv
az ad app permission add --id $spaAppId --api $bffAppId --api-permissions "$scopeId=Scope"
az ad sp create --id $spaAppId 2>$null; az ad sp create --id $bffAppId 2>$null
az ad app permission grant --id $spaAppId --api $bffAppId --scope "access_as_user"
Write-Host "spa_client_id = $spaAppId"
```

세 출력값(`admin_group_object_id`, `bff_api_audience`, `spa_client_id`)을 기록해 둡니다.

---

## 4. 컨테이너 이미지 빌드 (ACR 원격 빌드)

1차 apply로 레지스트리가 생성된 뒤:

```powershell
cd infra
$acr = terraform output -raw registry_login_server
$reg = terraform output -raw registry_name
az acr build --registry $reg --image config-sync-worker:latest ../app/config-sync-worker
az acr build --registry $reg --image admin-ui:latest ../app/admin-ui
Write-Host "image base = $acr"
```

> **한글(cp949) 콘솔 주의:** `az acr build`가 로그 스트리밍 중 `UnicodeEncodeError: 'cp949'
> codec can't encode character '\u2713'`로 죽을 수 있습니다. **빌드 자체는 서버에서 성공**하므로
> 무시하고, 결과만 확인하면 됩니다:
>
> ```powershell
> az acr task list-runs --registry $reg --top 5 -o table          # Status=Succeeded 확인
> az acr repository show-tags --name $reg --repository admin-ui -o tsv
> ```

---

## 5. 워커 + Admin UI 활성화 (2차 apply)

`infra/terraform.tfvars`에 이미지 참조와 Entra 변수 3개를 추가하고 다시 apply:

```hcl
worker_image          = "<registry_login_server>/config-sync-worker:latest"
admin_ui_image        = "<registry_login_server>/admin-ui:latest"
admin_ui_public       = true                       # 외부 FQDN(여전히 Entra 게이트). false=VNet 전용
admin_group_object_id = "<3.1 출력값>"
bff_api_audience      = "api://<3.2 출력값>"
spa_client_id         = "<3.3 출력값>"
```

```powershell
terraform apply
$fqdn = terraform output -raw admin_ui_fqdn
Write-Host "Admin UI = https://$fqdn"
```

> **CAE 교체(replace) 안내:** `admin_ui_public = true`는 Container Apps Environment의
> `internal_load_balancer_enabled`를 `true`에서 `false`로 바꿔 **환경 자체가 재생성(replace)**됩니다.
> 1차 apply에서는 앱이 아직 없으므로(이미지 빈 값) 안전합니다. 이미 앱이 떠 있는 환경에서
> 이 값을 바꾸면 다운타임이 생기므로, 이 2단계 흐름대로 1차에서 비워두고 2차에서 채우세요.

### 5.1 SPA 리디렉션 URI 추가 (FQDN 확정 후)

```powershell
$spaObjId = az ad app show --id <spa_client_id> --query id -o tsv
$redirect = "https://$fqdn"
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$spaObjId" `
  --headers "Content-Type=application/json" `
  --body (@{ spa = @{ redirectUris = @($redirect) } } | ConvertTo-Json -Depth 5)
```

---

## 6. 설정 시드 (VNet 내부에서)

Cosmos는 프라이빗 + 키 인증 비활성화라, 초기 설정은 **VNet 내부 점프박스**에서 시드합니다.

점프박스 모듈(`enable_jumpbox = true`)은 **Windows VM(시스템 할당 관리 ID) + Bastion**을 만듭니다.
VM의 관리 ID가 IMDS 토큰으로 Cosmos 데이터 평면에 직접 upsert하므로, 별도 키·Python·외부 egress가
필요 없습니다.

1. `infra/terraform.tfvars`에 점프박스를 켜고, 관리자 암호는 파일이 아닌 **환경 변수**로 전달
   (시크릿을 파일/커밋에 두지 않기). 암호는 일회용이며, 아래 `run-command` 방식에서는 로그인에
   쓰이지 않습니다:

   ```hcl
   enable_jumpbox  = true
   jumpbox_vm_size = "Standard_D2s_v7"   # eastus2: D2s_v5/v4 등은 capacity 제한, v7 계열 사용
   ```

   ```powershell
   # 12자 이상 랜덤 암호를 환경 변수로만 생성(파일에 기록하지 않음)
   $bytes = New-Object byte[] 18
   [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
   $env:TF_VAR_jumpbox_admin_password = "Jb!" + [Convert]::ToBase64String($bytes).Replace('/','_').Replace('+','-') + "9z"
   terraform apply
   ```

2. 점프박스 VM의 관리 ID에 **Cosmos DB Built-in Data Contributor**(데이터 평면 역할) 부여
   (전파에 수 분 소요):

   ```powershell
   $rg     = terraform output -raw resource_group_name
   $cosmos = terraform output -raw config_store_account_name
   $vmMi   = az vm show -g $rg -n "vm-jump-<name_suffix>" --query "identity.principalId" -o tsv
   az cosmosdb sql role assignment create -g $rg --account-name $cosmos `
     --role-definition-id "00000000-0000-0000-0000-000000000002" `
     --principal-id $vmMi --scope "/"
   ```

3. 시드 실행. 두 스크립트는 `-Endpoint` 필수 매개변수를 받습니다. **Bastion 대화형 접속** 대신
   `az vm run-command`로 비대화형 실행하면 편리합니다(매개변수 프롬프트를 피하려면 스크립트에
   endpoint를 박은 임시본을 만들어 실행):

   ```powershell
   $ep = terraform output -raw config_store_endpoint
   foreach ($f in 'seed-cosmos-jumpbox','seed-pricing-jumpbox') {
     $body = (Get-Content "../scripts/$f.ps1" -Raw) -replace '(?s)param\(.*?\)\r?\n',''
     Set-Content "../scripts/_run-$f.ps1" ("`$Endpoint='$ep'; `$Database='gateway'; `$Container='config'`n" + $body)
     az vm run-command invoke -g $rg -n "vm-jump-<name_suffix>" --command-id RunPowerShellScript `
       --scripts "@../scripts/_run-$f.ps1" --query "value[].message" -o tsv
     Remove-Item "../scripts/_run-$f.ps1"
   }
   ```

   > Bastion으로 직접 접속해 `./scripts/seed-*.ps1 -Endpoint https://<cosmos>.documents.azure.com:443/`
   > 를 실행해도 됩니다.

4. config-sync 워커가 다음 주기에 APIM named value로 발행합니다. 즉시 트리거 + 확인:

   ```powershell
   az containerapp job start -g $rg -n (terraform output -raw config_sync_job_name)
   # 잠시 후 실행 결과(Succeeded)와 반영된 named value 확인
   az apim nv show -g $rg --service-name <apim 이름> --named-value-id tokens-per-minute --query value -o tsv
   ```

---

## 7. 검증 (smoke test)

- **Admin UI**: `https://<admin_ui_fqdn>` 접속 후 관리자 그룹 멤버로 로그인하고, 컨슈머 등록, 키 발급,
  허용 모델·티어·예산 설정.
- **게이트웨이 호출** (VNet 내부, 컨슈머 구독 키 사용):

  ```http
  POST https://<apim-host>/openai/v1/chat/completions    # 본문 "model"에 배포이름
  POST https://<apim-host>/openai/v1/responses           # Codex proxy 활성화 시
  ```

> **내 노트북의 Claude Code / Codex CLI에서 호출하려면?** 기본(Internal) 모드에서는 게이트웨이
> 호스트명이 공개 DNS로 풀리지 않습니다. 외부 노출(External) / VPN 두 가지 접근 방법과
> 클라이언트 도구 연결 방법은 [부록 C](#부록-c-클라이언트-도구claude-code--codex-cli에서-게이트웨이-접근)를 참고하세요.
> 예산을 설정하지 않았을 때의 호출 허용/차단 동작은 [부록 D](#부록-d-예산을-설정하지-않으면-모델-호출이-막히나-예산레이트리밋-동작)에 정리되어 있습니다.

---

## 8. 정리

```powershell
cd infra
terraform destroy
```

위 명령은 Terraform이 관리하는 게이트웨이 리소스 그룹(APIM, VNet, Cosmos DB, ACR, Container Apps 등)을 삭제합니다. Terraform state를 저장하는 backend 리소스 그룹은 `terraform destroy` 대상이 아니므로, 완전한 데모/검증 환경 정리가 필요하면 마지막에 별도로 삭제합니다.

먼저 state가 비었고 같은 storage account에 보존해야 할 다른 state blob이 없는지 확인합니다. backend 리소스 그룹과 storage account 이름은 `infra/providers.tf`의 `backend "azurerm"` 블록에서 확인합니다.

```powershell
terraform state list
az storage blob list --account-name <storage_account_name> --container-name tfstate --auth-mode login -o table
```

`terraform state list` 출력이 비어 있고, `tfstate` 컨테이너에 삭제해도 되는 state blob만 남아 있으면 backend 리소스 그룹을 삭제합니다.

```powershell
az group delete -n <backend_resource_group_name> --yes
az group exists -n <backend_resource_group_name>
```

{% hint style="warning" %}
backend 리소스 그룹을 삭제하면 해당 backend로 더 이상 `terraform init`, `plan`, `destroy`를 실행할 수 없습니다. 모든 workload 삭제와 확인이 끝난 뒤 마지막 단계로만 수행하세요. 나중에 같은 워킹카피에서 새 backend를 bootstrap하면 첫 초기화는 `terraform init -reconfigure`로 실행합니다.
{% endhint %}

> 경로 B(재사용)에서는 기존 모델 계정은 **삭제되지 않습니다**(`data` 소스라 Terraform 관리 대상
> 아님). APIM에 부여했던 RBAC role assignment만 함께 제거됩니다. 경로 A(배포)에서는 새로 만든 모델
> 계정·배포도 함께 삭제됩니다.

---

## 부록 A: 변수 빠른 참조

| 변수 | 경로 | 의미 |
|---|---|---|
| `openai_deployments` | A·B | OpenAI 스타일 모델. **A=값으로 배포 생성** / B=키만 alias로 사용 |
| `foundry_deployments` | A·B | OSS/파트너 모델. **A=값으로 배포 생성** / B=키만 alias로 사용 |
| `allowed_models` | A·B | 호출 허용 배포 이름 목록(그 외 403) |
| `existing_model_account_name` / `existing_model_account_rg` | B | 재사용할 기존 AIServices 계정 좌표(경로 A에서는 무시) |
| `worker_image` / `admin_ui_image` | A·B | 2차 apply에서 채움(1차는 빈 값) |
| `admin_ui_public` | A·B | Admin UI 외부 FQDN 노출 여부 |
| `admin_group_object_id` / `bff_api_audience` / `spa_client_id` | A·B | Entra 연동 3종 |
| `enable_jumpbox` / `jumpbox_admin_password` / `jumpbox_vm_size` | A·B | Cosmos 시드용 점프박스(Windows VM+Bastion). eastus2는 `Standard_D2s_v7` 권장 |

---

## 부록 B: 경로 B로 전환(기존 모델 재사용)

저장소 기본(경로 A)은 모델을 직접 배포합니다. 기존 모델 계정을 재사용하려면 `infra/main.tf`에서
모델 생성 모듈 두 개를 제거하고, 기존 계정을 참조하는 `data` 소스 + `locals`로 교체합니다.

**1) `infra/main.tf`: `module "openai"` / `module "foundry"` 블록을 삭제하고 아래로 교체:**

```hcl
data "azurerm_cognitive_account" "models" {
  name                = var.existing_model_account_name
  resource_group_name = var.existing_model_account_rg
}

locals {
  # 제어 엔드포인트는 *.cognitiveservices.azure.com, 추론 호스트는 *.openai.azure.com
  model_openai_host = trimsuffix(replace(data.azurerm_cognitive_account.models.endpoint, ".cognitiveservices.azure.com", ".openai.azure.com"), "/")
  model_openai_path = "${local.model_openai_host}/openai"      # /openai API용 (AOAI 호환)
  model_openai_v1   = "${local.model_openai_host}/openai/v1"   # /foundry API용 (OpenAI v1)
}
```

**2) `infra/main.tf`: `module "apim"`의 백엔드 배선을 `data`/`locals` 참조로 변경:**

```hcl
  openai_account_id  = data.azurerm_cognitive_account.models.id
  openai_endpoint    = local.model_openai_host
  foundry_account_id = data.azurerm_cognitive_account.models.id
  foundry_endpoint   = local.model_openai_v1
  # ...
  openai_path_base   = local.model_openai_path
  foundry_v1_base    = local.model_openai_v1
```

**3) `infra/outputs.tf`: `openai_endpoint` 출력을 `local.model_openai_host`로 변경:**

```hcl
output "openai_endpoint" {
  value = local.model_openai_host
}
```

**4) `infra/terraform.tfvars`: 기존 계정 좌표 설정:**

```hcl
existing_model_account_name = "<기존 AIServices 계정 이름>"
existing_model_account_rg   = "<기존 계정 RG>"
```

**5) `infra/variables.tf`: `openai_deployments`/`foundry_deployments`의 키를 기존 계정의 실제 배포
이름과 일치**시키고, `allowed_models`도 동일하게. 재사용 모드에서 값은 사용되지 않으므로 키만 맞으면
됩니다.

이후 [2. 게이트웨이 코어](#2-게이트웨이-코어-1차-apply)부터 동일하게 진행합니다.

> 이 `main.tf`/`outputs.tf` 편집은 **로컬 배포용**이며 PR(문서 전용)에는 포함되지 않습니다.

---

## 부록 C: 클라이언트 도구(Claude Code / Codex CLI)에서 게이트웨이 접근

이 저장소의 기본값은 APIM이 **Internal VNet** 모드입니다
(`infra/modules/apim/main.tf`의 `virtual_network_type = "Internal"`).
이 모드에서는 게이트웨이 호스트명 `https://<apim>.azure-api.net`이 **사설 IP**(예: `10.40.1.4`)로만
풀리고 **공개 DNS에 노출되지 않으므로**, 내 노트북에서 실행하는 Claude Code / Codex CLI는
APIM에 직접 도달할 수 없습니다. 도달하려면 아래 두 가지 중 하나가 필요합니다.

> 개발자에게 "점프박스에 접속해서 쓰라"고 요구하는 방식은 실사용성이 없어 제외합니다. 점프박스는
> [6. 설정 시드](#6-설정-시드-vnet-내부에서)의 **운영자용 일회성 시드 도구**일 뿐, 일상적인 모델
> 호출 경로가 아닙니다.

### 옵션 1. APIM을 External로 노출 (가장 간단, dev/test 권장)

게이트웨이가 공인 IP/공개 DNS로 노출됩니다. 보안은 여전히 **구독 키 + APIM 정책**(레이트리밋·허용
모델·예산)으로 유지됩니다. 두 가지 방법이 있습니다.

**(a) Terraform: 새 환경을 처음부터 External로 (권장, 영구):**

```hcl
# infra/modules/apim/main.tf
virtual_network_type = "External"
```

```hcl
# infra/modules/network/main.tf: NSG "in-client-https" 규칙
source_address_prefix = "Internet"   # 기본값 "VirtualNetwork", External은 공개 인바운드 필요
```

> **주의:** azurerm 프로바이더는 `virtual_network_type`을 **ForceNew**로 취급합니다. 이미 배포된 APIM에
> 위 변경으로 `terraform apply`를 하면 APIM이 **삭제 후 재생성**됩니다(~45분, 동일 이름 소프트 삭제
> 충돌 위험). 따라서 **새 환경은 처음부터 External로 시작**하는 것이 가장 깔끔하고, **기존 인스턴스를
> 무중단 전환**하려면 아래 (b) az CLI 방식을 쓰세요.

**(b) az CLI: 기존 인스턴스를 in-place 전환 (무중단):**

플랫폼이 blue/green 재배포를 수행하므로 **기존 것과 다른 새 공인 IP**가 필요합니다.

```powershell
$RG="<RG>"; $APIM="<APIM 이름>"; $ENV="<env>"; $REGION="<region>"
# 1) External 전용 새 공인 IP (Standard / Static / DNS 라벨 필수)
az network public-ip create -g $RG -n "pip-apim-$ENV-ext" --sku Standard `
  --allocation-method Static --dns-name "apim-$ENV-ext" --location $REGION
# 2) NSG: 클라이언트 인바운드(443)를 Internet 소스로 허용
az network nsg rule update -g $RG --nsg-name "nsg-apim-$ENV" -n in-client-https `
  --source-address-prefixes Internet
# 3) APIM을 External로 전환 (새 IP 지정). 비동기, 15~45분 소요
$rid = az apim show -g $RG -n $APIM --query id -o tsv
$pip = az network public-ip show -g $RG -n "pip-apim-$ENV-ext" --query id -o tsv
az rest --method PATCH `
  --uri "https://management.azure.com$rid`?api-version=2023-05-01-preview" `
  --headers "Content-Type=application/json" `
  --body (@{properties=@{virtualNetworkType='External';publicIpAddressId=$pip}} | ConvertTo-Json -Compress)
# 4) 상태 폴링 (Updating에서 Succeeded로, vnetType가 External로 바뀜)
az apim show -g $RG -n $APIM --query "{vnet:virtualNetworkType,state:provisioningState}" -o json
```

전환 완료 후 `Resolve-DnsName <apim>.azure-api.net`이 공인 IP로 풀리고, 외부에서 호출 가능합니다.

### 옵션 2. VPN으로 VNet에 연결 (Internal 유지, 가장 안전)

APIM은 Internal 그대로 두고, VNet에 **VPN Gateway**(Point-to-Site 또는 Site-to-Site)를 만들어
클라이언트 머신을 VNet에 연결합니다. Internal 모드에서는 `*.azure-api.net`이 공개 DNS에 없으므로,
호스트명으로 호출하려면 VNet에 **Private DNS Zone `azure-api.net`**(A 레코드가 APIM 사설 IP를 가리킴)을
두고 VPN 클라이언트가 그 DNS를 쓰게 해야 합니다(또는 사설 IP + `Host` 헤더로 직접 호출).

```powershell
$RG="<RG>"; $VNET="<VNET>"; $APIM_PRIV_IP="10.40.1.4"; $ENV="<env>"
# GatewaySubnet (없으면 추가) + VPN Gateway (P2S, OpenVPN)
az network vnet subnet create -g $RG --vnet-name $VNET -n GatewaySubnet --address-prefixes 10.40.255.0/27
az network public-ip create -g $RG -n pip-vpngw --sku Standard --allocation-method Static
az network vnet-gateway create -g $RG -n vpngw-aigw --vnet $VNET `
  --public-ip-addresses pip-vpngw --gateway-type Vpn --vpn-type RouteBased `
  --sku VpnGw1 --address-prefixes 172.16.0.0/24 --client-protocol OpenVPN
# 호스트명 호출용 Private DNS Zone
az network private-dns zone create -g $RG -n azure-api.net
az network private-dns record-set a add-record -g $RG -z azure-api.net -n "apim-$ENV" -a $APIM_PRIV_IP
az network private-dns link vnet create -g $RG -z azure-api.net -n link-vnet `
  --virtual-network $VNET --registration-enabled false
```

클라이언트에서 VPN 연결 후 `https://<apim>.azure-api.net/...`로 호출합니다.

### 클라이언트 도구 연결 (공통)

OpenCode / Codex CLI는 **OpenAI 호환 base URL**을 게이트웨이로 향하게 하고, 인증에는 Admin UI에서
발급한 **컨슈머 구독 키**를 사용합니다.

- **base URL**: `https://<apim-host>/openai/v1`. External이면 공개 호스트, 옵션 2에서는 VNet 내부에서만 유효합니다.
- **인증 헤더**: `api-key: <키>`.

```powershell
$base = "https://<apim-host>"
$key  = "<consumer-subscription-key>"
curl "$base/openai/v1/chat/completions" `
  -H "api-key: $key" -H "Content-Type: application/json" `
  -d '{"model":"FW-GLM-5.2","messages":[{"role":"user","content":"ping"}]}'
```

> 검증됨(External): 위 호출이 외부 인터넷에서 **HTTP 200**으로 모델 응답을 반환합니다(백엔드 모델
> 계정은 APIM 관리 ID로 인증). 키 없이 호출하면 **401**(`missing subscription key`).

---

## 부록 D: 예산을 설정하지 않으면 모델 호출이 막히나? (예산·레이트리밋 동작)

**막히지 않습니다. 다만 "무제한"도 아닙니다.** 게이트웨이에는 서로 독립적인 세 가지 제어가 있습니다.

| 제어 | 위치 | 미설정 시 동작 |
|---|---|---|
| **토큰 레이트리밋** (`llm-token-limit`) | `policies/*-pipeline.xml.tftpl` | **항상 적용.** 컨슈머별 설정이 없으면 글로벌 기본값으로 제한합니다. `tokens_per_minute`(기본 1000), `token_quota`(기본 50000) / `token_quota_period`(기본 Daily). 초과 시 **429**. 절대 무제한이 아닙니다. |
| **USD 예산 다운그레이드** (`evaluate_downgrades`) | `app/config-sync-worker/budget.py` | **선택.** 컨슈머에 `daily_budget_usd`와 `downgrade_ladder`가 **둘 다** 있을 때만 동작. 없으면 다운그레이드/차단 없이 요청한 모델 그대로 통과. |
| **Cost Management 월 예산** (`monthly_budget_amount`, 기본 200) | Azure 구독 예산 | **알림 전용.** 이메일 경고만 보냄, API 트래픽은 **차단하지 않음**. |

추가로 **허용 모델 게이트**가 항상 적용됩니다: 호출 대상 배포가 `allowed_models`(또는 컨슈머별
allowed_models)에 없으면 예산과 무관하게 **403**입니다.

**결론**: 예산(USD)을 설정하지 않아도 호출은 **통과**하지만, 글로벌 토큰 레이트리밋
(기본 1000 TPM / 50000 토큰·일)이 항상 상한으로 작동합니다. 진짜로 제한을 풀려면
`tokens_per_minute`/`token_quota`를 크게 잡고, 비용 보호를 원하면 컨슈머에 `daily_budget_usd` +
`downgrade_ladder`를 설정하세요.

---

## 부록 E: 인증·거버넌스 모드 (consumer-key vs Entra ID)

게이트웨이의 거버넌스(레이트리밋·예산·허용모델)는 모두 **`consumerId`** 축으로 적용됩니다. 이
`consumerId`를 무엇으로 도출하느냐가 `client_auth_mode`(기본값 `subscription-key`)로 갈립니다.

### 현재 기본 = `subscription-key` (이 예제 구현의 전제)

`client_auth_mode`의 기본값은 `subscription-key`이고 `terraform.tfvars`에서 별도로 바꾸지 않으면
그대로 동작합니다. 이 저장소의 **전체 파이프라인이 컨슈머 키(APIM 구독) 발급을 전제로** 구성돼
있습니다.

- **Admin UI**: 컨슈머를 등록하고 각 컨슈머에 **APIM 구독(consumer key)** 을 발급/폐기합니다
  (`POST /api/keys`, 키는 발급 순간 1회만 표시). 호출 시 `api-key` 헤더에 이 키를 넣습니다.
- **정책**: `consumerId = context.Subscription.Name`(구독 표시 이름 = 컨슈머 이름).
- **워커**: Cosmos의 `consumer_config` 문서를 **컨슈머 이름**을 키로 `consumer-config-json` 번들에
  담습니다(`build_consumer_bundle`). 정책이 `consumerId`(=컨슈머 이름)로 조회하면 **컨슈머별
  allowed_models / tier / 예산 다운그레이드가 정상 작동**합니다.

### `entra-id` 모드의 현재 구현 형태

`client_auth_mode = "entra-id"`로 두면 클라이언트가 **Entra ID Bearer 토큰**으로 인증하고
(`validate-jwt`), APIM 구독 키는 비활성됩니다(`subscription_required = false`). 이때
`consumerId = JWT claim(entra_team_claim, 기본 "groups") 값`(보통 그룹 object-id GUID)입니다.

**현재 구현 형태**: 워커의 `build_consumer_bundle`은 번들을 **컨슈머 이름**을 키로 구성합니다
(`entra_group_id`, 즉 토큰 claim 값을 키로 쓰지는 않습니다). 그래서 `entra-id` 모드에서 정책이
`consumerId`(= 그룹 GUID)로 번들을 조회하면 매칭되는 항목이 없어 `consumerCfg = null`이 되고,
**글로벌 정책으로 폴백**합니다:

- 허용 모델 = **글로벌** `allowed-models`만 적용 (컨슈머별 좁히기/넓히기 안 됨)
- 레이트 tier = `default` (글로벌 tpm/quota)
- USD 예산 다운그레이드 = **미적용**

Admin UI의 **Entra 그룹 GUID 필드**는 현재 **대시보드 표시용 매핑**(그룹 GUID를 보기 좋은 컨슈머
이름으로 변환)으로 쓰입니다. UI에도 *"Entra 그룹 ID는 선택 사항이며 Entra ID 인증 모드에서만
사용됩니다(현재는 구독 키 모드)"* 라고 표기되며, 거버닝 번들에는 아직 반영되지 않습니다.

**정리**: 이 예제 구현은 **consumer-key 발급을 전제**로 설계된 거버넌스입니다. `entra-id`로 전환하면
모델 접근이 **글로벌 정책 기준으로** 동작하므로, **Entra ID 기반의 컨슈머별 거버넌스로 확장하려면**
다음 정도의 추가 구현을 얹으면 됩니다.

1. 워커가 컨슈머 레지스트리의 `consumer`와 `entra_group_id` 매핑을 사용해 **번들 키를 claim 값(그룹
   GUID 등)으로 구성**하도록 확장,
2. 토큰 claim 설계 정렬(`groups`는 GUID이고 150그룹 초과 시 누락되므로 단일값 app-role/extension
   claim 권장, 부록 C의 `entra_team_claim` 참고).

### `entra-id` 모드에서의 호출 방법 (참고)

`client_auth_mode = "entra-id"`로 배포한 경우, 클라이언트는 구독 키 대신 **Entra ID 액세스 토큰**을
`Authorization: Bearer` 헤더로 보냅니다. BFF API 앱(3.2)의 audience를 `--resource`로 지정해 토큰을
받습니다.

```powershell
$token = az account get-access-token --resource "api://<bff_api_audience>" --query accessToken -o tsv
$base  = "https://<apim-host>"
curl "$base/openai/v1/chat/completions" `
  -H "Authorization: Bearer $token" -H "Content-Type: application/json" `
  -d '{"model":"FW-GLM-5.2","messages":[{"role":"user","content":"ping"}]}'
```

토큰의 `entra_team_claim`(기본 `groups`) 값이 정책의 `consumerId`로 쓰입니다. 컨슈머별 설정 매칭에는
위에서 설명한 추가 구현이 필요하며, 그 전까지는 글로벌 정책이 적용됩니다.
