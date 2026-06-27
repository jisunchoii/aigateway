---
description: "시나리오 C — APIM 게이트웨이 코어만 먼저 배포해 모델 연결을 검증하는 가이드"
---

# 시나리오 C: APIM 게이트웨이 코어 먼저 배포


이 페이지는 Admin UI나 config-sync worker 없이 **APIM 게이트웨이 코어만 먼저 배포**하는 방법(Stage 1)을 안내합니다. 모델 라우팅, 정책, 거버넌스가 완전히 동작하는 상태에서 클라이언트 연결을 검증한 뒤, 이후 단계에서 UI와 worker를 추가할 수 있습니다.

## 1. 이 시나리오가 적합한 경우

***

아래 조건에 해당하면 이 시나리오를 선택하세요.

- 먼저 APIM + 모델 백엔드 연결만 확인하고 싶다.
- Admin UI나 자동화 없이 구독 키를 수동으로 발급해 팀 내부에서 먼저 테스트하고 싶다.
- 단계적 배포(Staged Rollout)의 Stage 1을 따른다.

이 시나리오에서 배포되는 컴포넌트는 다음과 같습니다.

| 컴포넌트 | Stage 1 포함 여부 |
|---|---|
| [Azure API Management](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-key-concepts) + 3개 API (`/openai`, `/vscode/openai`, `/foundry`) | ✓ |
| APIM 정책 (consumer 식별 → allowed-models → rate limit → 모델 전환 → 토큰 메트릭) | ✓ |
| 백엔드 AIServices 계정 (greenfield 신규 생성 또는 brownfield 재사용) | ✓ |
| ACR, Cosmos DB, VNet, Private Endpoint | ✓ |
| Admin UI (React SPA + BFF) | — (Stage 2) |
| config-sync worker | — (Stage 3) |

## 2. Stage 1 배포 절차

***

### 1단계: tfvars에서 이미지 변수 비워 두기

`infra/terraform.tfvars`에서 이미지 변수를 빈 문자열로 두세요. 이 값이 비어 있으면 Terraform이 해당 컨테이너 리소스를 생성하지 않습니다.

```hcl
# infra/terraform.tfvars
worker_image   = ""
admin_ui_image = ""
```

나머지 필수 변수(prefix, location, owner, cost_center, apim_publisher_name, apim_publisher_email, apim_public, budget_alert_email, budget_start_date)는 채워 두어야 합니다.

### 2단계: 첫 번째 terraform apply 실행

```bash
cd infra
terraform init
terraform apply
```

APIM VNet 주입이 포함된 첫 apply는 약 45분 소요됩니다. 터미널이 응답 없이 보여도 정상이니 중단하지 마세요.

apply가 완료되면 APIM 게이트웨이 URL을 확인합니다.

```bash
terraform output apim_gateway_url
```

### 3단계: 구독 키 발급

Stage 1에서는 Admin UI가 없으므로 구독 키를 수동으로 발급합니다.

**방법 A: Azure 포털**

[Azure 포털](https://portal.azure.com) → API Management → 해당 인스턴스 → **구독** → **+ 구독 추가**

**방법 B: Azure CLI**

```bash
az apim subscription create \
  --resource-group <resource_group_name> \
  --service-name <apim-instance-name> \
  --sid <원하는-구독-ID> \
  --display-name "<구독-표시-이름>"
```

`<resource_group_name>`과 APIM 인스턴스 이름은 `terraform output resource_group_name`으로 확인합니다.

### 4단계: 클라이언트에서 모델 호출 확인

발급한 구독 키로 스모크 테스트를 실행합니다.

```bash
./scripts/smoke-v1-gateway.sh <apim-host> <subscription-key>
```

gpt-5.4 (`/openai`), grok-4.3 (`/foundry`), DeepSeek-V4-Pro (`/foundry`) 각각 HTTP 200이 반환되면 Stage 1이 완료된 것입니다.

{% hint style="info" %}
Stage 1의 거버넌스는 **정적**입니다. `terraform.tfvars`의 `allowed_models` / `rate_tiers` / `tokens_per_minute`가 전역으로 적용되며, Cosmos DB에 소비자별 설정이 없으므로 모든 소비자가 동일한 기본값을 사용합니다.
{% endhint %}

## 3. 지원되지 않는 배포 방식

***

{% hint style="danger" %}
**아래 두 가지는 현재 지원되지 않습니다. 시도하지 마세요.**

**(a) 기존 APIM 인스턴스 재사용 불가**
이 스택은 `azurerm_api_management` 리소스를 무조건 새로 생성합니다. 기존 APIM 인스턴스를 `data` 소스로 읽거나 `reuse_apim` 토글로 선택하는 옵션이 없습니다. [기존 Foundry 재사용](../04-reuse-foundry.md)처럼 기존 APIM을 재사용하려면 인프라 코드 변경이 필요하며, 현재 버전에서는 미지원입니다.

**(b) Azure 포털(콘솔) 수동 배포 불가**
APIM 정책은 약 200줄 분량의 Terraform 템플릿(`.tftpl`) XML로 생성되며, named value 14개(`allowed-models`, `tokens-per-minute`, `tier-*-tpm` 등)와 `azapi` REST PATCH(커스텀 메트릭 활성화)에 의존합니다. 포털 UI에서 이 구성을 손으로 재현하는 것은 현실적이지 않습니다. **Terraform이 사실상 필수입니다.**
{% endhint %}

## 4. 다음 단계

***

Stage 1이 완료되면 아래 순서로 나머지 컴포넌트를 추가할 수 있습니다.

| 단계 | 내용 | 참고 페이지 |
|---|---|---|
| Stage 2 | Admin UI 추가 — 셀프서비스 소비자·키·정책 관리 | [시나리오 B: Admin UI 배포](case-admin-ui.md) |
| Stage 3 | config-sync worker 추가 — Cosmos→APIM 동기화, 소비자별 override, 모델 전환 활성 | [배포](../03-deploy.md) 챕터 Staged Rollout |

기존 AIServices(Foundry) 계정을 백엔드로 재사용하려면 Stage 1 이전에 계정 잠금 준비가 선행되어야 합니다. 자세한 내용은 [기존 Foundry 재사용](../04-reuse-foundry.md)을 참고하세요.
