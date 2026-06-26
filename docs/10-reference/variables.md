---
description: 배포 담당자 / 인프라 엔지니어를 위한 페이지 · 선행: 첫 번째 terraform apply
---

# 변수 레퍼런스

`infra/variables.tf` 기준 전체 변수 목록입니다. `terraform.tfvars`에서 재정의할 수 있으며, `*`가 붙은 변수는 **기본값이 없어 반드시 제공**해야 합니다.

---

## 코어 (Core)

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `prefix` | `string` | `"aigw"` | 리소스 이름 프리픽스. 라이브 dev 스택은 `llmgw` 고정. |
| `env` | `string` | `"dev"` | 환경 식별자. `dev` \| `test` \| `prod` |
| `location` | `string` | `"koreacentral"` | Azure 리전. `koreacentral` \| `koreasouth` \| `eastus` \| `eastus2` \| `westeurope` |
| `owner` * | `string` | — | 리소스 태그 `owner` (이메일 또는 팀명) |
| `cost_center` * | `string` | — | 리소스 태그 `costCenter` |

---

## APIM

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `apim_publisher_name` * | `string` | — | APIM 게시자 표시 이름 |
| `apim_publisher_email` * | `string` | — | APIM 게시자 연락 이메일 |
| `apim_sku_name` | `string` | `"Developer_1"` | APIM SKU. `Developer_1` = SLA 없음(dev/demo용). 프로덕션은 `Premium_1`. VNet 주입은 Developer/Premium SKU 필요. |
| `apim_public` | `bool` | `false` | `true` = EXTERNAL VNet 모드(공개 VIP). `false` = Internal(VNet 전용). 스모크 테스트 전 `true` 권장. |

---

## 모델 배포

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `openai_deployments` | `map(object)` | `{gpt-5.4, gpt-5.4-mini}` | Azure OpenAI 모델 배포 맵. 키 = 배포 이름 = 실제 모델 이름. |
| `foundry_deployments` | `map(object)` | `{grok-4.3, DeepSeek-V4-Pro}` | AIServices OSS/파트너 모델 배포 맵. 키는 클라이언트 facing 별칭. |
| `allowed_models` | `list(string)` | `["gpt-5.4","gpt-5.4-mini","grok-4.3","DeepSeek-V4-Pro"]` | 호출자가 요청할 수 있는 모델 목록. 이 외 모델 요청은 403. |
| `openai_api_version` | `string` | `"2025-01-01-preview"` | 클라이언트가 `?api-version=`으로 보내는 Azure OpenAI API 버전. |

### `openai_deployments` 기본값

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

### `foundry_deployments` 기본값

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

---

## Brownfield 재사용 (reuse_foundry)

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `reuse_foundry` | `bool` | `false` | `true` = 기존 AIServices 계정을 data source로 읽기(생성 안 함). 상세: [04-reuse-foundry](../04-reuse-foundry/plan-and-apply.md). |
| `existing_foundry_name` | `string` | `""` | 재사용할 AIServices 계정 이름. `reuse_foundry = true` 시 필수. |
| `existing_foundry_rg` | `string` | `""` | 기존 AIServices 계정의 리소스 그룹. `reuse_foundry = true` 시 필수. 게이트웨이 RG와 달라도 됨(동일 구독). |

{% hint style="info" %}
`reuse_foundry = true` 사용 시 `existing_foundry_name`과 `existing_foundry_rg`를 반드시 함께 지정해야 합니다. 어느 하나라도 비어 있으면 `terraform plan`에서 precondition 오류가 발생합니다.
{% endhint %}

---

## 인증 (client_auth_mode / Entra ID)

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `client_auth_mode` | `string` | `"subscription-key"` | 클라이언트→게이트웨이 인증 방식. `subscription-key` \| `entra-id`. |
| `entra_tenant_id` | `string` | `""` | Entra ID 테넌트(GUID 또는 도메인). `client_auth_mode = entra-id` 시 필수. |
| `entra_api_audience` | `string` | `""` | JWT `aud` 클레임 기대값(게이트웨이 앱 등록 URI). `entra-id` 모드 필수. |
| `entra_team_claim` | `string` | `"groups"` | teamId 도출에 쓰이는 JWT 클레임. `groups` 클레임은 >150 그룹 멤버에서 누락될 수 있음. 프로덕션에서는 단일 값 custom app-role 권장. |

---

## 이미지 / Admin UI

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `worker_image` | `string` | `""` | config-sync 워커 이미지 전체 참조(`<registry_login_server>/config-sync-worker:latest`). 빌드 전 비워두면 Container Apps Job이 생성되지 않음. |
| `config_sync_cron` | `string` | `"*/5 * * * *"` | config-sync 잡의 UTC cron 표현식. 기본: 5분마다. |
| `admin_ui_image` | `string` | `""` | Admin UI(SPA+BFF) 이미지. 빌드 전 비워두면 Container App이 생성되지 않음. |
| `admin_ui_public` | `bool` | `false` | `true` = Container Apps 환경 EXTERNAL(공개 FQDN). 첫 배포 후 변경 시 환경 재생성. |
| `bff_api_audience` | `string` | `""` | Admin UI BFF JWT `aud`. `admin_ui_image` 설정 시 필수. |
| `spa_client_id` | `string` | `""` | Admin UI SPA 앱 등록 client ID(사전 준비 P3). |
| `admin_group_object_id` | `string` | `""` | Entra ID 관리자 보안 그룹 object ID(사전 준비 P1). |

---

## 예산 (Budget)

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `monthly_budget_amount` | `number` | `200` | Cost Management 월 예산(구독 통화). 알림 전용, 하드 스톱 아님. |
| `budget_alert_email` * | `string` | — | 예산 임계값 알림 이메일. |
| `budget_start_date` | `string` | `"2026-06-01T00:00:00Z"` | 예산 시작일(UTC, ISO 8601). 과거 날짜로 첫 apply 시 오류. |

{% hint style="warning" %}
`budget_start_date`는 첫 `terraform apply` 시점보다 과거 날짜이면 오류가 발생합니다. 현재 날짜 이후의 월 초 날짜를 사용하세요.
{% endhint %}

---

## 레이트 리밋 (rate_tiers)

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `rate_tiers` | `map(object)` | `{small, medium, large}` | 팀별 레이트 리밋 티어 맵. APIM Named Values + Admin UI에 공급. |
| `tokens_per_minute` | `number` | `1000` | 팀당 분당 토큰 한도(정적). |
| `token_quota` | `number` | `50000` | 팀당 쿼터 기간 내 토큰 총량. |
| `token_quota_period` | `string` | `"Daily"` | 쿼터 리셋 주기. `Hourly` \| `Daily` \| `Weekly` \| `Monthly` \| `Yearly` |

### `rate_tiers` 기본값

```hcl
{
  small  = { tpm = 500,   quota = 20000,  period = "Daily"   }
  medium = { tpm = 2000,  quota = 100000, period = "Daily"   }
  large  = { tpm = 10000, quota = 500000, period = "Monthly" }
}
```

---

## 점프박스 (Jumpbox)

| 변수 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `enable_jumpbox` | `bool` | `false` | `true` = Bastion + jumpbox VM 배포(백엔드 격리 진단용). |
| `jumpbox_admin_password` | `string` (sensitive) | `null` | jumpbox VM 관리자 패스워드(최소 12자). `enable_jumpbox = true` 시 필수. |
| `jumpbox_vm_size` | `string` | `"Standard_B2s_v2"` | jumpbox VM 크기. koreacentral 기본. eastus2 등에서는 `Standard_D2s_v7` 권장. |

---

## 관련 문서

- 출력 레퍼런스 → [outputs.md](outputs.md)
- 비용 · 정리 → [cost-cleanup.md](cost-cleanup.md)
- Gotchas → [gotchas.md](gotchas.md)
- Brownfield 재사용 → [../04-reuse-foundry/plan-and-apply.md](../04-reuse-foundry/plan-and-apply.md)
