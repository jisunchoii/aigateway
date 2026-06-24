# Azure AI Gateway

Azure API Management 기반의 엔터프라이즈 **AI 게이트웨이**입니다. **Azure OpenAI**(gpt-5.4 계열)와
**Azure AI Foundry**(grok-4.3, DeepSeek-V4-Pro 등 OSS·파트너 모델)를 하나의 거버넌스 엔드포인트
뒤에 둡니다. 백엔드는 모두 패스워드리스(관리 ID), 컨슈머별 모델 권한·토큰 속도 제한·비용 기반
예산 강등을 제공하며, 셀프서비스 Admin UI에서 모두 관리합니다.

![아키텍처](docs/images/architecture.png)

## 무엇을 제공하나

- **여러 모델 백엔드(Azure OpenAI + Foundry OSS/파트너)를 하나의 거버넌스 엔드포인트로** 묶습니다.
  각 백엔드는 **프라이빗 엔드포인트**로만 접근하고 **키 인증은 비활성화**되어 있어, APIM이 자신의
  관리 ID로 인증합니다 — 게이트웨이에 모델 키가 존재하지 않습니다.
- **컨슈머별 거버넌스** — 재배포 없이 Admin UI에서 바로 수정:
  - **허용 모델** — 컨슈머는 부여받은 모델만 호출 가능(그 외는 403).
  - **속도 제한** — 컨슈머별 TPM + 토큰 쿼터 티어(small/medium/large) → 초과 시 429.
  - **비용 예산** — 하루 **USD** 지출 한도. 초과하면 요청을 설정된 사다리를 따라 더 저렴한 모델로
    **자동 강등**(백엔드를 넘나드는 강등도 지원, 예: gpt → OSS 또는 OSS → gpt).
- **셀프서비스 Admin UI**(React + FastAPI, Entra ID 로그인, 관리자 그룹 게이트) — 컨슈머 키 발급,
  모델·제한·예산 정책 설정, 사용량 대시보드 + 요청 로그 확인.
- **관측성** — 호출별 토큰 메트릭(컨슈머 + 모델 차원)을 Application Insights로 전송. Admin UI에
  사용량 대시보드와 요청/차단 이벤트 로그 제공.
- **클라이언트 인증** — 기본은 APIM 구독 키, 또는 Entra ID JWT(`client_auth_mode`).

## 데모

![AI Gateway 데모](docs/images/aigateway.gif)

## 동작 원리

- **APIM(Internal VNet)**이 게이트웨이입니다. 두 개의 API — `/openai`(Azure OpenAI),
  `/foundry`(Foundry/AIServices) — 가 거버넌스 정책(컨슈머 식별, 허용 모델, 속도 제한, 토큰
  메트릭, 예산 강등)을 공유합니다.
- **Cosmos DB**가 권위 있는 설정(전역 기본값 + 컨슈머별 문서 + 모델 단가표)을 보관합니다. 프라이빗
  + 키 인증 비활성화 상태이며, 게이트웨이는 named value를 통해 간접적으로 읽습니다.
- **config-sync 워커**(Container Apps Job, 약 5분 주기)가 Cosmos → APIM named value를 동기화하고,
  하루 사용량 × 단가를 계산해 예산 강등 레벨을 기록합니다.
- **Admin UI**(Container App)는 관리 ID로 Cosmos·Log Analytics를 읽고 씁니다. 예산을 변경하면
  즉시 재평가가 트리거됩니다.
- 모든 제어/관측 흐름은 **관리 ID + RBAC**를 사용합니다 — 소스·설정에 계정 키, 연결 문자열, 시크릿이
  없습니다. 시크릿은 **Key Vault**에 둡니다.

## 저장소 구조

| 경로 | 설명 |
|---|---|
| `infra/` | Terraform(azurerm) — 게이트웨이 전체: 네트워크, APIM, OpenAI, Foundry, Cosmos, Key Vault, 관측성, Container Apps, 점프박스. |
| `policies/` | Terraform이 렌더링하는 APIM 정책 템플릿(`openai-pipeline`, `foundry-pipeline`). |
| `app/admin-ui/` | Admin UI — FastAPI BFF(`bff/`) + React SPA(`spa/`), 단일 컨테이너 이미지. |
| `app/config-sync-worker/` | Cosmos → APIM 동기화 + 예산 평가를 수행하는 Python 워커. |
| `scripts/` | 운영 도구 — 백엔드 부트스트랩, 설정·단가 시드, VNet 내부 스모크 테스트(아래 표 참고). |

### `scripts/` 파일 설명

| 파일 | 한 줄 설명 |
|---|---|
| `bootstrap-backend.ps1` | Terraform 원격 상태(state) 백엔드(스토리지 계정 + RG)를 구독당 한 번 생성. |
| `seed-config.ps1` | 권위 있는 전역 설정 문서(`id=global`: 허용 모델·토큰 한도)를 생성 — JSON을 출력해 시드 방법을 안내(로컬 미리보기용). |
| `seed-cosmos-jumpbox.ps1` | 점프박스 관리 ID로 전역 설정 문서를 Cosmos에 직접 upsert(PowerShell만, 의존성 없음). |
| `seed_cosmos.py` | 위와 동일한 전역 설정 시드의 Python 버전(`azure-cosmos` + `DefaultAzureCredential`). |
| `seed-pricing-jumpbox.ps1` | 모델별 단가표(`id=pricing`, 1K 토큰당 prompt/completion 요율)를 점프박스에서 Cosmos에 upsert(비용 기반 예산용). |

## 사전 준비

- 모델 쿼터가 있는 **Azure 구독**(Azure OpenAI 및 선택적으로 Azure AI Foundry 모델).
- **도구:** [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.7,
  [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), 그리고 구독에 `az login`.
  컨테이너 이미지는 Azure Container Registry에서 원격 빌드되므로 **Docker는 필요 없습니다.**
- **Entra ID 객체**(한 번만, Terraform으로 만들 수 없는 디렉터리 객체). Admin UI에 필요하며,
  게이트웨이 본체를 먼저 배포한 뒤 UI를 켜기 전에 추가해도 됩니다:
  1. **관리자 보안 그룹** — 멤버가 게이트웨이 관리자 → `admin_group_object_id`.
  2. **BFF API 앱 등록** — `access_as_user` 스코프 노출, `api.requestedAccessTokenVersion = 2`
     설정 → `bff_api_audience`(`api://<app-id>`).
  3. **SPA 퍼블릭 클라이언트 앱 등록** — PKCE, 시크릿 없음, 리디렉션 URI = Admin UI 주소 →
     `spa_client_id`.

> 모든 Azure 접근은 **관리 ID / Entra ID**를 사용하며 계정 키는 절대 쓰지 않습니다.

---

## 배포

### 1. Terraform 상태 백엔드 부트스트랩 (구독당 한 번)

```powershell
./scripts/bootstrap-backend.ps1 -Location koreacentral
```

원격 상태용 리소스 그룹 + 스토리지 계정을 생성합니다(Entra 인증, 퍼블릭 blob 접근 차단). 출력값을
`infra/providers.tf`의 `backend "azurerm"` 블록에 복사합니다.

### 2. 변수 설정

```powershell
cp infra/terraform.tfvars.example infra/terraform.tfvars
# infra/terraform.tfvars 편집: prefix, location, owner, cost_center, apim_publisher_*, budget_*
```

### 3. 1차 apply — 게이트웨이 코어

첫 apply에서는 `worker_image`와 `admin_ui_image`를 비워둡니다(기본값 `""`). 이미지가 아직 없고,
워커 Job/Admin UI 앱은 이 변수로 카운트 게이트되어 있습니다.

```powershell
cd infra
terraform init
terraform apply
```

> APIM Internal VNet 모드는 첫 apply에서 약 45분 걸립니다. 정상입니다.

### 4. 컨테이너 이미지 빌드 + 푸시

레지스트리가 생성된 후, 워커와 Admin UI 이미지를 원격 빌드합니다(로컬 Docker 불필요):

```powershell
$acr = terraform output -raw registry_login_server
$reg = terraform output -raw registry_name
az acr build --registry $reg --image config-sync-worker:latest ../app/config-sync-worker
az acr build --registry $reg --image admin-ui:latest ../app/admin-ui
```

### 5. 2차 apply — 워커 + Admin UI 활성화

`infra/terraform.tfvars`에 이미지 참조와 사전 준비의 Entra 변수 3개를 넣고 다시 apply:

```hcl
worker_image          = "<registry_login_server>/config-sync-worker:latest"
admin_ui_image        = "<registry_login_server>/admin-ui:latest"
admin_ui_public       = true   # 외부 FQDN(여전히 Entra 게이트). false = VNet 전용
admin_group_object_id = "<entra 보안 그룹 object id>"
bff_api_audience      = "api://<bff app id>"
spa_client_id         = "<spa app id>"
```

```powershell
terraform apply
```

### 6. 설정 시드 (VNet 내부에서)

Cosmos는 프라이빗 + 키 인증 비활성화라, 초기 설정은 VNet 내부 **점프박스**에서 시드합니다
(`enable_jumpbox = true`로 켜고 Bastion으로 접속). 점프박스 MI에
`Cosmos DB Built-in Data Contributor` 역할을 부여한 뒤:

```powershell
# 전역 허용 모델 + 한도
./scripts/seed-cosmos-jumpbox.ps1 -Endpoint https://<cosmos-account>.documents.azure.com:443/
# 모델별 단가(비용 기반 예산용)
./scripts/seed-pricing-jumpbox.ps1 -Endpoint https://<cosmos-account>.documents.azure.com:443/
```

config-sync 워커가 다음 실행 때 APIM에 발행합니다(즉시 트리거:
`az containerapp job start -g <rg> -n <config_sync_job_name>`).

### 7. 사용

- **Admin UI** — `admin_ui_fqdn` 출력값으로 접속, 로그인(관리자 그룹 멤버여야 함). 컨슈머 등록, 키
  발급, 허용 모델·티어·예산 설정, 대시보드 + 로그 확인.
- **게이트웨이 호출** — VNet 내부에서
  `POST https://<apim-host>/openai/deployments/<model>/chat/completions`(또는 본문에 model을 넣어
  `/foundry/chat/completions`)을 컨슈머 구독 키로 호출. `scripts/smoke-*.ps1`이 점프박스에서 이를
  검증합니다.

> **단계별 상세 가이드**: 어떤 파일의 어떤 부분을 고쳐서 배포하는지 처음부터 끝까지 따라가려면
> [단계별 배포 가이드](docs/step-by-step-deployment-guide.md)를 참고하세요. 모델까지 배포(경로 A,
> 이 저장소 기본)와 기존 모델 endpoint 재사용(경로 B)을 모두 다룹니다.

## 비용 & 정리

- APIM **Developer_1**은 SLA가 없습니다(개발/데모 전용) — 프로덕션은 `Premium_1`. Internal VNet
  모드는 Developer 또는 Premium SKU가 필요합니다.
- Azure OpenAI / Foundry는 토큰당 과금되며, 월간 Cost Management 예산은 **알림만** 하고 지출을
  강제로 막지 않습니다. **유휴 시 정리:** `infra/`에서 `terraform destroy`.

## 보안 모델

- 백엔드: 프라이빗 엔드포인트 + **키 인증 비활성화**. APIM이 **관리 ID** + RBAC로 접근(Cognitive
  Services OpenAI User / Cognitive Services User).
- 제어 플레인(워커, Admin UI): 관리 ID + 최소 권한 RBAC(Cosmos 데이터 역할, Log Analytics Reader,
  스코프된 APIM·Container Apps Jobs 역할). 키나 연결 문자열을 어디에도 두지 않습니다.
- 시크릿: **Key Vault**. 비밀이 아닌 설정: IaC가 프로비저닝하는 Cosmos + APIM named value.
