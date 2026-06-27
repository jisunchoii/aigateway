---
description: "Azure AI Gateway 배포 — 단계적 배포, 부트스트랩부터 seed까지"
---

# 배포

이 챕터는 llm-gateway를 Azure에 처음 배포하는 전체 흐름을 안내합니다. 배포는 크게 두 경로(Greenfield / Brownfield)로 나뉘며, 아래 순서대로 진행합니다.

- [1. 배포 개요](#1-배포-개요)
- [2. 단계적 배포 (Staged Rollout)](#2-단계적-배포-staged-rollout)
- [3. 상태 백엔드 부트스트랩](#3-terraform-원격-state-백엔드-부트스트랩)
- [4. tfvars 구성](#4-tfvars-구성)
- [5. 첫 번째 `terraform apply`](#5-첫-번째-terraform-apply)
- [6. 이미지 빌드·푸시](#6-이미지-빌드푸시)
- [7. 앱 등록 및 두 번째 apply](#7-앱-등록-및-두-번째-apply)
- [8. Seed 및 최종 설정](#8-seed-및-최종-설정)

## 1. 배포 개요

***

이 챕터는 llm-gateway를 Azure에 처음 배포하는 전체 흐름을 안내합니다. 배포는 크게 두 경로로 나뉩니다.

### 1. 배포 경로 선택

***

| 경로 | 설명 | 언제 선택? |
|---|---|---|
| **Greenfield** | Azure OpenAI 계정과 모델 배포를 Terraform이 새로 생성 | 신규 구독 또는 기존 AIServices 계정 재사용 불필요 |
| **Brownfield** | 기존 AIServices(Foundry) 계정을 `data`로 읽어 재사용, PE·RBAC만 신규 생성 | 이미 운영 중인 Azure OpenAI/Foundry 계정이 있는 경우 |

Brownfield 경로를 선택했다면 이 챕터의 절차를 따른 뒤 [기존 Foundry 재사용](04-reuse-foundry.md) 챕터의 추가 준비 단계를 반드시 먼저 완료하세요.

### 2. 전체 배포 단계

***

아래 절(## 3. ~ ## 8.)에서 각 단계를 순서대로 안내합니다.

- [상태 백엔드 부트스트랩](#3-terraform-원격-state-백엔드-부트스트랩)
- [tfvars 구성](#4-tfvars-구성)
- [첫 번째 terraform apply](#5-첫-번째-terraform-apply)
- [이미지 빌드·푸시](#6-이미지-빌드푸시)
- [앱 등록 및 두 번째 apply](#7-앱-등록-및-두-번째-apply)
- [Seed 및 최종 설정](#8-seed-및-최종-설정)

### 3. 전제 조건 확인

***

배포를 시작하기 전에 다음이 준비되어 있어야 합니다.

- `az login` 완료 및 대상 구독 활성화
- Terraform ≥ 1.7 설치 (Docker 불필요 — ACR remote build 사용)
- Azure CLI 최신 버전
- [사전 준비 챕터](02-prerequisites.md)의 모든 항목 완료

{% hint style="warning" %}
**Brownfield 경로:** `reuse_foundry = true`를 설정하기 전에 [기존 Foundry 재사용](04-reuse-foundry.md) 챕터의 계정 잠금 준비 절을 먼저 완료하세요.
{% endhint %}

각 단계를 한꺼번에 배포하지 않아도 됩니다. `worker_image`/`admin_ui_image` 변수를 비워 두면 해당 컴포넌트가 생성되지 않으므로 게이트웨이 코어만 먼저 운영할 수 있습니다. 자세한 방법은 아래 [단계적 배포](#2-단계적-배포-staged-rollout) 절을 참고하세요.

## 2. 단계적 배포 (Staged Rollout)

***

이 스택은 `worker_image`/`admin_ui_image` 변수가 빈 문자열이면 해당 리소스를 만들지 않는(count-gate) 구조라, 게이트웨이를 단계적으로 올릴 수 있습니다. 모든 컴포넌트를 한꺼번에 배포할 필요 없이 필요한 시점에 각 레이어를 추가할 수 있습니다.

### 1. 전체 3단계 구조

<figure><img src="images/diagram-staged-rollout.png" alt="단계적 배포 — Stage 1 게이트웨이 코어 → Stage 2 Admin UI → Stage 3 config-sync worker"><figcaption>🖼️ 단계적 배포 — Stage 1 게이트웨이 코어 → Stage 2 Admin UI → Stage 3 config-sync worker <em>(다이어그램 이미지 추가 예정)</em></figcaption></figure>

***

### 2. Stage 1 — 게이트웨이 코어

***

`worker_image`와 `admin_ui_image`를 모두 빈 문자열로 두고 첫 번째 apply를 실행합니다.

```hcl
# infra/terraform.tfvars
worker_image   = ""
admin_ui_image = ""
```

**첫 번째 apply로 완전히 동작하는 항목:**

- **APIM** + 3개 API(`/openai`, `/vscode/openai`, `/foundry`) + 정책 + 백엔드 (greenfield 신규 생성 또는 brownfield 재사용)
- **거버넌스는 정적** — `terraform.tfvars`의 `allowed_models`/`rate_tiers`/`tokens_per_minute`가 전역 적용되고, `consumer-config-json`은 빈 번들(`e30=`)이라 모든 소비자가 전역 기본값을 사용합니다.
- 구독 키는 Azure 포털 또는 `az apim subscription create`로 발급합니다.
- 클라이언트가 구독 키를 헤더에 포함해 모델을 호출할 수 있습니다(완전한 게이트웨이).

자세한 절차는 아래 [첫 번째 terraform apply](#5-첫-번째-terraform-apply) 절을 참고하세요.

***

### 3. Stage 2 — Admin UI 추가

***

이미지를 빌드한 뒤 `admin_ui_image` 변수를 설정하고, Entra ID 앱 등록 3종을 완료한 다음 두 번째 apply를 실행합니다.

**준비 순서:**

1. ACR이 첫 번째 apply에서 이미 생성되어 있어야 합니다.
2. `az acr build`로 `admin-ui` 이미지를 빌드·푸시합니다.
3. `./scripts/app-registration.sh`로 Entra 앱 등록을 완료합니다 — **Admin UI 배포보다 먼저** 실행해야 합니다.
4. `terraform.tfvars`에 아래 값을 채웁니다.

```hcl
admin_ui_image        = "<registry_login_server>/admin-ui:latest"
admin_ui_public       = true
admin_group_object_id = "<entra security group object id>"
bff_api_audience      = "api://<bff app id>"
spa_client_id         = "<spa app id>"
```

**이 단계 이후 활성화되는 기능:**

- 셀프서비스 소비자·키·정책 관리 UI
- Admin UI를 통한 소비자 등록 및 구독 키 발급

**아직 비활성 (worker 없음):**

- Cosmos→APIM 동기화 없음 → 소비자별 동적 설정 미반영
- 예산 기반 **모델 전환**(`active_downgrade.level`) 비활성

자세한 절차는 아래 [이미지 빌드·푸시](#6-이미지-빌드푸시) 및 [앱 등록 및 두 번째 apply](#7-앱-등록-및-두-번째-apply) 절을 참고하세요.

***

### 4. Stage 3 — config-sync worker 추가

***

`worker_image` 변수를 설정하고 apply를 재실행한 뒤 Cosmos DB seed를 완료합니다.

**준비 순서:**

1. `az acr build`로 `config-sync-worker` 이미지를 빌드·푸시합니다.
2. `terraform.tfvars`에 아래 값을 채웁니다.

```hcl
worker_image = "<registry_login_server>/config-sync-worker:latest"
```

3. `terraform apply`를 다시 실행합니다(두 번째 또는 세 번째 apply).
4. apply 완료 후 Cosmos DB seed를 실행합니다 — **worker 배포보다 먼저** seed를 완료해야 초기 동기화가 올바르게 수행됩니다.

**이 단계 이후 활성화되는 기능:**

- Cosmos DB → APIM Named Values 동기화(약 5분 cron)
- 소비자별 `allowed_models`/tier override
- 예산 기반 **모델 전환**(`active_downgrade.level`) 활성
- 전체 기능 완전 운영

자세한 절차는 아래 [Seed 및 최종 설정](#8-seed-및-최종-설정) 절을 참고하세요.

***

### 5. 단계별 기능 비교표

***

| 기능 | Stage 1 | Stage 2 | Stage 3 |
|---|:---:|:---:|:---:|
| APIM 라우팅 (`/openai`, `/vscode/openai`, `/foundry`) | ✓ | ✓ | ✓ |
| 정적 거버넌스 (`allowed_models`/`rate_tiers`/`tokens_per_minute`) | ✓ | ✓ | ✓ |
| 구독 키 기반 모델 호출 | ✓ | ✓ | ✓ |
| Brownfield Foundry 재사용 | ✓ | ✓ | ✓ |
| Admin UI 셀프서비스 관리 | — | ✓ | ✓ |
| 소비자별 동적 설정 (Cosmos→APIM 동기화) | — | — | ✓ |
| 예산 기반 모델 전환 (`active_downgrade`) | — | — | ✓ |
| 소비자별 `allowed_models`/tier override | — | — | ✓ |

***

### 6. 의존 순서 정리

***

```
첫 번째 apply (ACR 포함)
    ↓
az acr build (worker + admin-ui 이미지)
    ↓
./scripts/app-registration.sh  ← Admin UI 배포 전 필수
    ↓
tfvars 업데이트 (admin_ui_image + Entra 값)
    ↓
두 번째 apply (Admin UI + worker 동시 또는 순차)
    ↓
Cosmos DB seed  ← worker 동기화 전 필수
    ↓
az containerapp job start (config-sync 즉시 트리거)
```

{% hint style="warning" %}
**순서 중요:** Entra 앱 등록(`app-registration.sh`)은 Admin UI 배포보다 먼저 완료해야 합니다. Cosmos seed는 config-sync worker가 첫 번째 동기화를 수행하기 전에 완료해야 합니다.
{% endhint %}

Brownfield 경로(기존 Foundry 재사용)를 선택한 경우 Stage 1 이전에 계정 잠금 준비가 선행되어야 합니다. 자세한 내용은 [기존 Foundry 재사용](04-reuse-foundry.md) 챕터를 참고하세요.

## 3. Terraform 원격 state 백엔드 부트스트랩

***

Terraform은 배포 상태를 원격 저장소에 보관해야 팀 협업과 잠금(locking)이 가능합니다. 이 스크립트는 **구독당 1회**만 실행하면 됩니다. 이미 state 백엔드가 존재한다면 이 단계를 건너뛰세요.

[Azure Blob Storage 원격 백엔드](https://learn.microsoft.com/ko-kr/azure/developer/terraform/store-state-in-azure-storage)는 Entra ID 인증과 공용 Blob 액세스 차단을 기본값으로 사용합니다. 키 기반 접근 없이 Terraform이 스토리지 계정에 액세스하도록 구성됩니다.

### 환경 변수 설정

아래 값을 먼저 쉘 환경에 내보내세요. `<...>` 부분은 실제 값으로 교체합니다.

```bash
export location=eastus2
export backend-rg=rg-aigw-tfstate-dev-eastus2
export storage-prefix=staigwtfstate
export state-key=ai-gateway-eus2.tfstate
```

| 변수 | 기본값 | 설명 |
|---|---|---|
| `location` | `eastus2` | 백엔드 스토리지를 배포할 Azure 리전 |
| `backend-rg` | `rg-aigw-tfstate-dev-eastus2` | 백엔드 전용 리소스 그룹 이름 |
| `storage-prefix` | `staigwtfstate` | 스토리지 계정 이름 접두사(전역 고유) |
| `state-key` | `ai-gateway-eus2.tfstate` | state 파일 블롭 이름 |

{% hint style="info" %}
**리전 선택:** `location`은 이후 `terraform.tfvars`의 `location` 값과 같은 리전으로 맞추는 것을 권장합니다.
{% endhint %}

### 부트스트랩 실행

```bash
./scripts/bootstrap-backend.sh --location $location --backend-rg $backend-rg --storage-prefix $storage-prefix --state-key $state-key
```

스크립트가 완료되면 다음이 생성됩니다.

- 리소스 그룹 `$backend-rg`
- 스토리지 계정 (`$storage-prefix` + 랜덤 접미사, 전역 고유)
- Blob 컨테이너 `tfstate`
- 공용 Blob 액세스 차단 설정
- [Entra ID 인증](https://learn.microsoft.com/ko-kr/azure/storage/common/storage-auth-aad) 기반 접근 — 스토리지 계정 키 없이 동작

{% hint style="info" %}
**📸 [스크린샷 자리]** — Azure Portal — Terraform 원격 state Storage 계정 + tfstate 컨테이너
{% endhint %}

### 보안 설계

| 항목 | 설정 |
|---|---|
| 인증 | Entra ID (DefaultAzureCredential / `az login`) |
| 공용 Blob 액세스 | **비활성화** |
| 스토리지 계정 키 | 사용 안 함 |
| state 잠금 | Azure Blob 임대(lease) 기반 자동 잠금 |

### 다음 단계

백엔드가 준비되면 아래 [tfvars 구성](#4-tfvars-구성) 절로 이동하세요.

## 4. tfvars 구성

***

Terraform 변수 파일을 준비합니다. 예제 파일을 복사한 뒤 필요한 값을 채우세요.

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
```

{% hint style="info" %}
`infra/terraform.tfvars`는 `.gitignore`에 포함되어 있습니다. 이 파일을 git에 커밋하지 마세요.
{% endhint %}

### 핵심 변수

아래 변수들을 우선적으로 설정하세요. 전체 변수 목록과 기본값은 [레퍼런스 — 변수 전체 목록](10-reference.md)을 참고하세요.

#### 식별·비용 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `prefix` | `aigw` | 모든 리소스 이름에 붙는 접두사 |
| `env` | `dev` | 환경 구분자 (`dev`, `staging`, `prod`) |
| `location` | `koreacentral` | 배포 대상 Azure 리전 |
| `owner` | — | 리소스 태그 `owner` 값 (팀 또는 개인) |
| `cost_center` | — | 리소스 태그 `costCenter` 값 |

#### APIM 설정

| 변수 | 기본값 | 설명 |
|---|---|---|
| `apim_sku_name` | `Developer_1` | APIM SKU. 프로덕션은 `Premium_1` |
| `apim_publisher_name` | — | APIM 게시자 표시 이름 |
| `apim_publisher_email` | — | APIM 게시자 이메일 |
| `apim_public` | `false` | **첫 apply 전에 반드시 결정** (아래 참고) |

{% hint style="warning" %}
**`apim_public` 중요:** 이 값은 첫 `terraform apply` 실행 전에 확정해야 합니다. `true`로 설정하면 게이트웨이가 인터넷에서 직접 접근 가능해집니다. `false`이면 Private Endpoint 또는 VNet 경유만 허용됩니다. 배포 후 변경하면 APIM VNet 재구성으로 인해 추가 apply 시간(~45분)이 발생할 수 있습니다.
{% endhint %}

#### 예산·알림 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `monthly_budget_amount` | `200` | 월간 예산 (USD). 초과 시 알림만 (하드 차단 아님) |
| `budget_alert_email` | — | 예산 알림 수신 이메일 |
| `budget_start_date` | — | [Azure Cost Management](https://learn.microsoft.com/ko-kr/azure/cost-management-billing/costs/tutorial-acm-create-budgets) 예산 시작일 (`YYYY-MM-01` 형식) |

#### 모델 배포 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `openai_deployments` | `gpt-5.4`, `gpt-5.4-mini` | Azure OpenAI 모델 배포 목록 (Greenfield만) |
| `foundry_deployments` | `grok-4.3`, `DeepSeek-V4-Pro` | Azure AI Foundry 모델 배포 목록 |

#### 이미지 변수 (두 번째 apply용)

첫 번째 apply에서는 아래 변수를 **비워 두세요**. 코어 인프라만 먼저 배포합니다.

| 변수 | 기본값 | 설명 |
|---|---|---|
| `worker_image` | `""` | config-sync-worker 컨테이너 이미지 URI |
| `admin_ui_image` | `""` | admin-ui 컨테이너 이미지 URI |
| `admin_ui_public` | `false` | Admin UI를 공개 접근 가능하게 할지 여부 |

이미지 URI 및 Entra ID 값은 아래 [앱 등록 및 두 번째 apply](#7-앱-등록-및-두-번째-apply) 절에서 채웁니다.

### Brownfield(재사용) 경로

기존 AIServices 계정을 재사용한다면 아래 변수를 추가로 설정하세요. 상세 절차는 [기존 Foundry 재사용](04-reuse-foundry.md) 챕터를 참고하세요.

```hcl
reuse_foundry         = true
existing_foundry_name = "ais-customer-prod"
existing_foundry_rg   = "rg-customer-ai"
# foundry_deployments의 키는 실제 배포 이름과 일치해야 합니다
```

### 다음 단계

변수 설정이 완료되면 아래 [첫 번째 apply](#5-첫-번째-terraform-apply) 절로 이동하세요.

## 5. 첫 번째 `terraform apply`

***

이 단계에서는 코어 인프라를 배포합니다. `worker_image`와 `admin_ui_image`는 아직 비워 둔 상태에서 실행합니다. 컨테이너 앱 이미지는 ACR 빌드 후 두 번째 apply에서 배포합니다.

### 1. 배포 대상 (첫 번째 apply)

***

- [Azure API Management](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-key-concepts) — VNet 주입 포함
- [Azure Virtual Network](https://learn.microsoft.com/ko-kr/azure/virtual-network/virtual-networks-overview) 및 서브넷
- [Azure Container Registry](https://learn.microsoft.com/ko-kr/azure/container-registry/container-registry-intro)
- [Azure Cosmos DB](https://learn.microsoft.com/ko-kr/azure/cosmos-db/introduction) — Private Endpoint, 로컬 인증 비활성화
- Azure OpenAI / AIServices 계정 및 모델 배포 (Greenfield 경로)
- Jumpbox VM (선택, `enable_jumpbox = true`일 때)

### 2. 실행

***

```bash
cd infra
terraform init
terraform apply
```

`terraform init`은 provider 플러그인과 원격 state 백엔드를 초기화합니다. 이미 초기화된 환경에서는 생략 가능하지만, 재실행해도 무방합니다.

`terraform apply`를 실행하면 계획이 출력되고 `yes`를 입력하면 배포가 시작됩니다.

### 3. 소요 시간

***

**약 45분.** [APIM VNet 주입](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-using-with-vnet)은 Developer 및 Premium SKU에서 상당한 시간이 걸립니다. 이는 정상 동작입니다. 터미널이 오랫동안 응답하지 않는 것처럼 보여도 프로세스를 중단하지 마세요.

{% hint style="warning" %}
**VNet 주입 시간 (Gotcha 1):** APIM Developer/Premium SKU의 VNet 주입은 첫 apply에서 최대 45분 소요됩니다. 정상입니다. 중단하면 일부 리소스가 불완전한 상태로 남을 수 있습니다.
{% endhint %}

### 4. 완료 후 확인

***

{% hint style="info" %}
**📸 [스크린샷 자리]** — Terminal — terraform apply 완료 출력 (Apply complete, 리소스 수)
{% endhint %}

apply가 성공하면 다음 출력 값을 확인합니다.

```bash
terraform output apim_gateway_url
terraform output registry_name
terraform output registry_login_server
terraform output resource_group_name
```

`config_sync_job_name`과 `admin_ui_fqdn`은 두 번째 apply 전까지 `null`을 반환합니다. 이는 정상입니다.

### 5. 재-apply가 필요한 경우

***

{% hint style="warning" %}
**OpenAPI import 400 오류 (Gotcha 2):** 첫 apply에서 APIM OpenAPI import 단계가 400 오류를 낼 수 있습니다. 일시적인 레이스 컨디션으로 발생하며, `terraform apply`를 다시 실행하면 해결됩니다.[^1]
{% endhint %}

[^1]: Foundry API는 wildcard 경로 방식이라 OpenAPI import가 없습니다. `/openai` API만 해당합니다.

### 6. 다음 단계

***

코어 인프라 배포가 완료되면 아래 [이미지 빌드·푸시](#6-이미지-빌드푸시) 절로 이동하세요.

## 6. 이미지 빌드·푸시

***

첫 번째 apply로 ACR이 생성되었으면 컨테이너 이미지를 빌드합니다. **Docker 로컬 설치는 필요 없습니다.** [ACR 원격 빌드](https://learn.microsoft.com/ko-kr/azure/container-registry/container-registry-tutorial-quick-task)(`az acr build`)를 사용하므로 빌드가 Azure 클라우드에서 실행됩니다.

### ACR 원격 빌드

```bash
acr=$(terraform output -raw registry_login_server)
reg=$(terraform output -raw registry_name)
az acr build --registry $reg --image config-sync-worker:latest ../app/config-sync-worker
az acr build --registry $reg --image admin-ui:latest ../app/admin-ui
```

{% hint style="info" %}
`infra/` 디렉터리에서 실행해야 `terraform output` 명령이 올바른 state를 읽습니다.
{% endhint %}

### 빌드 과정 설명

| 명령 | 설명 |
|---|---|
| `terraform output -raw registry_login_server` | ACR 로그인 서버 주소 조회 (예: `<prefix>acr.azurecr.io`) |
| `terraform output -raw registry_name` | ACR 리소스 이름 조회 |
| `az acr build ... config-sync-worker` | config-sync-worker 이미지를 ACR에서 원격 빌드·푸시 |
| `az acr build ... admin-ui` | admin-ui 이미지를 ACR에서 원격 빌드·푸시 |

ACR 빌드는 Entra ID 인증 기반으로 동작합니다. `az login`이 완료된 상태라면 별도 키나 비밀번호 없이 실행됩니다.

### 완료 후 이미지 URI 확인

빌드가 완료되면 다음 형식으로 이미지 URI를 구성할 수 있습니다.

```
<registry_login_server>/config-sync-worker:latest
<registry_login_server>/admin-ui:latest
```

이 URI는 다음 단계인 [앱 등록 및 두 번째 apply](#7-앱-등록-및-두-번째-apply)에서 `terraform.tfvars`에 입력합니다.

### 다음 단계

이미지 빌드가 완료되면 아래 [앱 등록 및 두 번째 apply](#7-앱-등록-및-두-번째-apply) 절로 이동하세요.

## 7. 앱 등록 및 두 번째 apply

***

이 단계에서는 Entra ID 앱 등록을 완료하고, `terraform.tfvars`에 이미지 URI와 Entra 값을 채운 뒤 두 번째 apply를 실행합니다.

### Entra ID 앱 등록

Admin UI와 BFF(Backend for Frontend)가 Entra ID로 인증하려면 앱 등록 3종이 필요합니다. 아래 스크립트가 이를 자동으로 생성합니다.

```bash
./scripts/app-registration.sh
```

스크립트가 생성하는 항목:

| 항목 | 설명 |
|---|---|
| Admin 보안 그룹 | `admin_group_object_id` 값. Admin UI 접근 제어용 |
| BFF API 앱 등록 | `access_as_user` scope, `requestedAccessTokenVersion=2`. `bff_api_audience` 값 |
| SPA public-client 앱 등록 | PKCE, 시크릿 없음. `spa_client_id` 값 |

{% hint style="info" %}
**📸 [스크린샷 자리]** — Azure Portal — Entra ID 앱 등록 3종(Admin 그룹·BFF API·SPA) 완성 화면
{% endhint %}

스크립트 실행 후 출력된 값을 기록해 두세요.

### tfvars 업데이트

`infra/terraform.tfvars`에 다음 변수를 추가·업데이트합니다.

```hcl
worker_image          = "<registry_login_server>/config-sync-worker:latest"
admin_ui_image        = "<registry_login_server>/admin-ui:latest"
admin_ui_public       = true
admin_group_object_id = "<entra security group object id>"
bff_api_audience      = "api://<bff app id>"
spa_client_id         = "<spa app id>"
```

`<registry_login_server>`는 `terraform output -raw registry_login_server`로 확인합니다.

#### 변수 설명

| 변수 | 설명 |
|---|---|
| `worker_image` | config-sync-worker 컨테이너 이미지 전체 URI |
| `admin_ui_image` | admin-ui 컨테이너 이미지 전체 URI |
| `admin_ui_public` | `true`이면 Admin UI가 인터넷에서 접근 가능 |
| `admin_group_object_id` | Entra ID 보안 그룹 Object ID (Admin UI 접근 권한) |
| `bff_api_audience` | BFF API의 `api://` 형식 audience URI |
| `spa_client_id` | SPA 앱 등록의 클라이언트 ID |

### 두 번째 apply 실행

```bash
terraform apply
```

이 apply에서는 다음이 추가로 배포됩니다.

- config-sync-worker Container Apps Job
- admin-ui Container App
- Entra ID RBAC 바인딩

두 번째 apply는 첫 번째보다 빠르게 완료됩니다(APIM VNet 재구성 없음).

### 완료 후 확인

```bash
terraform output admin_ui_fqdn
terraform output config_sync_job_name
```

두 값이 모두 non-null로 반환되면 성공입니다.

### 다음 단계

배포가 완료되면 아래 [Seed 및 최종 설정](#8-seed-및-최종-설정) 절로 이동하세요.

## 8. Seed 및 최종 설정

***

두 번째 apply가 완료되면 Cosmos DB에 초기 설정 데이터를 주입하고 config-sync를 즉시 실행합니다.

### Cosmos DB Seed 배경

[Azure Cosmos DB](https://learn.microsoft.com/ko-kr/azure/cosmos-db/introduction) 계정은 **Private Endpoint**로만 접근 가능하고 로컬 인증(키 기반)이 비활성화되어 있습니다.

{% hint style="warning" %}
Seed 작업은 반드시 **VNet 내부**에서 실행해야 합니다. 인터넷 또는 로컬 머신에서 직접 seed를 실행할 수 없습니다.
{% endhint %}

### 방법 1: Jumpbox 자동 실행 (권장)

`enable_jumpbox = true`로 배포했다면 두 번째 `terraform apply` 완료 시 VM run-command를 통해 seed 스크립트가 **자동으로 실행**됩니다. 별도 조작이 필요 없습니다.

Jumpbox VM은 VNet 내부에 위치하고 [관리 ID(Managed Identity)](https://learn.microsoft.com/ko-kr/entra/identity/managed-identities-azure-resources/overview)를 사용해 Cosmos DB에 passwordless로 인증합니다.

### 방법 2: Jumpbox 수동 실행

자동 실행이 실패했거나 jumpbox가 나중에 추가된 경우 수동으로 실행합니다.

```bash
./scripts/seed-cosmos-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
./scripts/seed-pricing-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
```

`<cosmos-account>`는 `terraform output config_store_account_name`으로 확인합니다.

| 스크립트 | 설명 |
|---|---|
| `seed-cosmos-jumpbox.sh` | 글로벌 config 문서 upsert (소비자·모델 권한·rate-tier 초기값) |
| `seed-pricing-jumpbox.sh` | 토큰당 가격 `pricing` 문서 upsert (worker 예산 계산 + Admin UI 가격 표시용). Idempotent |

두 스크립트 모두 IMDS 토큰(jumpbox 관리 ID)을 사용해 Cosmos DB에 인증합니다. Python 설치나 키 입력이 필요 없습니다.

### Config-sync 즉시 트리거

Seed가 완료되면 config-sync 워커를 즉시 실행해 APIM Named Value를 갱신합니다. 기본 cron 주기(`*/5 * * * *`, 5분마다)를 기다리지 않아도 됩니다.

```bash
az containerapp job start -g <rg> -n <config_sync_job_name>
```

| 인수 | 값 |
|---|---|
| `-g <rg>` | `terraform output resource_group_name` |
| `-n <config_sync_job_name>` | `terraform output config_sync_job_name` |

[Azure Container Apps Job](https://learn.microsoft.com/ko-kr/azure/container-apps/jobs)은 관리 ID로 Cosmos DB와 APIM에 인증합니다.

### 완료 확인

config-sync 잡이 성공적으로 실행되면 APIM Named Value에 소비자 구성이 반영됩니다. [스모크 테스트](05-verify.md) 챕터에서 end-to-end 동작을 검증하세요.

### 다음 단계

모든 배포가 완료되었습니다. 이제 [검증 — 스모크 테스트](05-verify.md)로 이동하여 게이트웨이 동작을 확인하세요.
