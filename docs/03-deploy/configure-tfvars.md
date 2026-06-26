> 읽는 사람: 운영자·DevOps 엔지니어 · 선행: [상태 백엔드 부트스트랩](bootstrap-state.md)

# tfvars 구성

Terraform 변수 파일을 준비합니다. 예제 파일을 복사한 뒤 필요한 값을 채우십시오.

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
```

> `infra/terraform.tfvars`는 `.gitignore`에 포함되어 있습니다. 이 파일을 git에 커밋하지 마십시오.

## 핵심 변수

아래 변수들을 우선적으로 설정하십시오. 전체 변수 목록과 기본값은 [레퍼런스 — 변수 전체 목록](../10-reference/variables.md)을 참고하십시오.

### 식별·비용 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `prefix` | `aigw` | 모든 리소스 이름에 붙는 접두사 |
| `env` | `dev` | 환경 구분자 (`dev`, `staging`, `prod`) |
| `location` | `koreacentral` | 배포 대상 Azure 리전 |
| `owner` | — | 리소스 태그 `owner` 값 (팀 또는 개인) |
| `cost_center` | — | 리소스 태그 `costCenter` 값 |

### APIM 설정

| 변수 | 기본값 | 설명 |
|---|---|---|
| `apim_sku_name` | `Developer_1` | APIM SKU. 프로덕션은 `Premium_1` |
| `apim_publisher_name` | — | APIM 게시자 표시 이름 |
| `apim_publisher_email` | — | APIM 게시자 이메일 |
| `apim_public` | `false` | **첫 apply 전에 반드시 결정** (아래 참고) |

> **`apim_public` 중요:** 이 값은 첫 `terraform apply` 실행 전에 확정해야 합니다. `true`로 설정하면 게이트웨이가 인터넷에서 직접 접근 가능해집니다. `false`이면 Private Endpoint 또는 VNet 경유만 허용됩니다. 배포 후 변경하면 APIM VNet 재구성으로 인해 추가 apply 시간(~45분)이 발생할 수 있습니다.

### 예산·알림 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `monthly_budget_amount` | `200` | 월간 예산 (USD). 초과 시 알림만 (하드 차단 아님) |
| `budget_alert_email` | — | 예산 알림 수신 이메일 |
| `budget_start_date` | — | [Azure Cost Management](https://learn.microsoft.com/ko-kr/azure/cost-management-billing/costs/tutorial-acm-create-budgets) 예산 시작일 (`YYYY-MM-01` 형식) |

### 모델 배포 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `openai_deployments` | `gpt-5.4`, `gpt-5.4-mini` | Azure OpenAI 모델 배포 목록 (Greenfield만) |
| `foundry_deployments` | `grok-4.3`, `DeepSeek-V4-Pro` | Azure AI Foundry 모델 배포 목록 |

### 이미지 변수 (두 번째 apply용)

첫 번째 apply에서는 아래 변수를 **비워 두십시오**. 코어 인프라만 먼저 배포합니다.

| 변수 | 기본값 | 설명 |
|---|---|---|
| `worker_image` | `""` | config-sync-worker 컨테이너 이미지 URI |
| `admin_ui_image` | `""` | admin-ui 컨테이너 이미지 URI |
| `admin_ui_public` | `false` | Admin UI를 공개 접근 가능하게 할지 여부 |

이미지 URI 및 Entra ID 값은 [앱 등록 및 두 번째 apply](app-registration-second-apply.md) 단계에서 채웁니다.

## Brownfield(재사용) 경로

기존 AIServices 계정을 재사용한다면 아래 변수를 추가로 설정하십시오. 상세 절차는 [기존 Foundry 재사용](../04-reuse-foundry/overview.md) 챕터를 참고하십시오.

```hcl
reuse_foundry         = true
existing_foundry_name = "ais-customer-prod"
existing_foundry_rg   = "rg-customer-ai"
# foundry_deployments의 키는 실제 배포 이름과 일치해야 합니다
```

## 다음 단계

변수 설정이 완료되면 [첫 번째 apply](first-apply.md)로 이동하십시오.
