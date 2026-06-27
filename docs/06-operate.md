---
description: "게이트웨이 운영 — 설정 변경, 모니터링, 비용 관리, 스케일/SKU, 정리"
---

# 운영

- [1. 설정 변경 — 소비자 등록·키·정책 관리](#1-설정-변경--소비자-등록키정책-관리)
- [2. 모니터링](#2-모니터링)
- [3. 비용 관리 — 예산 기반 모델 전환 운영](#3-비용-관리--예산-기반-모델-전환-운영)
- [4. 스케일링 및 SKU 변경](#4-스케일링-및-sku-변경)
- [5. 리소스 정리 (Cleanup)](#5-리소스-정리-cleanup)

## 1. 설정 변경 — 소비자 등록·키·정책 관리

***

{% hint style="info" %}
**관리자 작업 요약** — 소비자/키: **Consumers 탭** · 정책: **Policies 탭** · 반영: 약 5분 cron 또는 즉시 실행(`az containerapp job start`)
{% endhint %}

Admin UI는 React SPA + FastAPI BFF로 구성되어 있으며, Entra ID 로그인과 admin 보안 그룹(admin_group_object_id)에 의해 접근이 제한됩니다. 운영자는 이 UI를 통해 소비자 등록, API 키 발급, 모델·티어·예산 정책 편집을 모두 수행할 수 있습니다.

---

### 1. Admin UI 접근

***

1. `terraform output -raw admin_ui_fqdn` 으로 URL을 확인합니다.
2. 브라우저에서 해당 URL을 열면 Entra ID 로그인 화면이 나타납니다.
3. admin 보안 그룹에 속한 계정으로 로그인합니다. 그룹 외 사용자는 403 응답을 받습니다.

{% hint style="info" %}
Admin UI에 접근하려면 `admin_ui_public = true` 와 `admin_ui_image` 가 설정된 상태에서 `terraform apply` 가 완료되어야 합니다. 설정 방법은 [03-deploy.md](03-deploy.md)를 참조하세요.
{% endhint %}

---

### 2. 소비자 등록 및 키 발급

***

{% hint style="info" %}
**📸 [스크린샷 자리]** — Admin UI — Consumers 탭(소비자 등록·키 발급 화면)
{% endhint %}

**소비자(Consumer)** 는 게이트웨이를 사용하는 팀·서비스 단위입니다. Admin UI의 **Consumers 탭**에서 다음 작업을 수행합니다.

| 작업 | 위치 |
|---|---|
| 소비자 신규 등록 | Consumers → New Consumer |
| APIM 구독 키 발급 | Consumers → 해당 소비자 → Keys → Generate |
| 소비자 비활성화 | Consumers → 해당 소비자 → Disable |

발급된 구독 키(`Ocp-Apim-Subscription-Key`)는 소비자가 API 호출 시 헤더에 포함해야 합니다. Entra ID 클라이언트 인증 모드(`client_auth_mode="entra-id"`)를 사용하는 경우 키 대신 JWT 토큰을 사용합니다. 자세한 내용은 [09-future.md](09-future.md)를 참조하세요.

---

### 3. 모델·티어·예산 정책 편집

***

Admin UI의 **Policies 탭**에서 소비자별 정책을 편집합니다.

#### 허용 모델 변경
소비자가 호출 가능한 모델 목록을 제한합니다. 목록에 없는 모델로 요청하면 APIM 정책이 `403 Forbidden`을 반환합니다.

#### 토큰 티어(Rate Tier) 변경
`rate_tiers`(small / medium / large)별로 분당 토큰 수(TPM)와 일별 쿼터가 다르게 설정됩니다. 소비자에 적절한 티어를 부여합니다.

| 티어 | 분당 토큰(TPM) | 일별 쿼터(기본값) |
|---|---|---|
| small | 1,000 | 50,000 |
| medium | (tfvars 설정에 따라) | (tfvars 설정에 따라) |
| large | (tfvars 설정에 따라) | (tfvars 설정에 따라) |

{% hint style="info" %}
실제 TPM·쿼터 값은 `infra/terraform.tfvars`의 `tokens_per_minute`, `token_quota` 변수를 기준으로 합니다. [10-reference.md](10-reference.md)에서 전체 변수 목록을 확인하세요.
{% endhint %}

#### 예산(Budget) 정책 편집
소비자별 일별 USD 예산 한도를 설정합니다. 80% 도달 시 더 저렴한 모델로 전환(모델 전환 1단계), 100% 도달 시 추가 전환(모델 전환 2단계)됩니다. 예산 운영 상세는 아래 『3. 비용 관리』 절을 참조하세요.

{% hint style="info" %}
**📸 [스크린샷 자리]** — Admin UI — Policies 탭(소비자별 allowed-models·tier·예산 편집)
{% endhint %}

---

### 4. 변경 반영 — config-sync worker

***

Admin UI에서 저장된 설정은 **Azure Cosmos DB** 의 config 컨테이너에 기록됩니다. 이 변경이 APIM의 Named Values(정책 파라미터)로 반영되려면 **config-sync worker** 가 실행되어야 합니다.

- **자동 반영:** config-sync worker는 `config_sync_cron = "*/5 * * * *"` 스케줄(약 5분)로 Container Apps Job으로 동작합니다.
- **즉시 반영:** 아래 명령으로 worker를 수동 실행합니다.

```bash
az containerapp job start -g <rg> -n <config_sync_job_name>
```

`<config_sync_job_name>` 은 다음 명령으로 확인합니다.

```bash
terraform output -raw config_sync_job_name
```

{% hint style="info" %}
worker_image가 설정되기 전에는 `config_sync_job_name` 출력이 null입니다. 이미지 빌드·푸시 단계([03-deploy.md](03-deploy.md))가 완료된 후 실행하세요.
{% endhint %}

---

### 5. 가격 데이터 갱신

***

모델 단가(per-1k 토큰)는 Cosmos DB의 `pricing` 문서에 저장됩니다. Azure AI 가격이 변경된 경우 jumpbox에서 다음 스크립트로 갱신합니다.

```bash
./scripts/seed-pricing-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
```

이 스크립트는 idempotent하므로 반복 실행해도 안전합니다. 갱신 후 config-sync worker를 즉시 실행하면 Admin UI의 가격 라벨과 예산 계산에 바로 반영됩니다.

---

### 6. 참고 링크

***

- [Azure API Management — Named Values](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-properties)
- [Azure Container Apps Jobs](https://learn.microsoft.com/en-us/azure/container-apps/jobs)
- [Azure Cosmos DB — 문서 읽기/쓰기](https://learn.microsoft.com/en-us/azure/cosmos-db/nosql/quickstart-python)

## 2. 모니터링

***

Admin UI의 **Monitoring** 페이지와 Azure Application Insights를 통해 게이트웨이의 요청 현황, 차단 이벤트, 모델 전환 이벤트를 실시간으로 파악할 수 있습니다.

---

### 1. Admin UI Monitoring 페이지

***

{% hint style="info" %}
**📸 [스크린샷 자리]** — Admin UI — Monitoring 페이지(최근 요청·차단 이벤트·모델 전환 이벤트 3개 테이블)
{% endhint %}

Monitoring 페이지에는 세 가지 테이블이 제공됩니다.

| 테이블 | 내용 |
|---|---|
| **최근 요청(Recent Requests)** | 소비자별 API 호출 목록 (타임스탬프, 소비자 ID, 모델, 상태 코드, 사용 토큰) |
| **차단 이벤트(Blocked Events)** | 403·429 응답 목록 (차단 사유: 모델 비허용·레이트 리밋 초과) |
| **모델 전환 이벤트(Model Downgrade Events)** | 예산 기반 모델 전환이 발생한 요청 목록 |

{% hint style="info" %}
UI 상의 한국어 용어는 **"모델 전환"** 입니다. 코드 식별자(`downgrade_ladder`, `active_downgrade`, `downgrade_level`)는 원문 그대로 사용됩니다.
{% endhint %}

---

### 2. 모델 전환 이벤트 추적

***

모델 전환이 발생한 요청은 응답 헤더에 다음 세 가지 값이 포함됩니다.

- 전환 여부는 `x-ai-gateway-downgrade-level` 값으로 판단합니다 (0=전환 없음).
- Monitoring 페이지의 **모델 전환 이벤트** 테이블에서 세 헤더 값을 함께 확인할 수 있습니다.

| 헤더 | 설명 |
|---|---|
| `x-ai-gateway-requested-model` | 클라이언트가 요청한 원래 모델 |
| `x-ai-gateway-effective-model` | 실제로 호출된 모델 (전환 후 모델) |
| `x-ai-gateway-downgrade-level` | 전환 단계 (0=전환 없음, 1=80% 임계, 2=100% 임계) |

예산 설정 및 전환 사다리 상세는 아래 『3. 비용 관리』 절을 참조하세요.

---

### 3. Application Insights 토큰 메트릭

***

게이트웨이는 APIM 정책에서 처리된 토큰 수를 Application Insights로 내보냅니다. 다음 두 가지 차원으로 집계됩니다.

- **consumerId**: 소비자 단위 토큰 사용량
- **model**: 모델 단위 토큰 사용량

#### 주요 커스텀 메트릭

| 메트릭 이름 | 설명 |
|---|---|
| `llm_total_tokens` | 소비자+모델 차원의 전체 토큰 수 |
| `llm_prompt_tokens` | 입력(프롬프트) 토큰 수 |
| `llm_completion_tokens` | 출력(컴플리션) 토큰 수 |

Application Insights에서 쿼리 예시:

```kusto
customMetrics
| where name == "llm_total_tokens"
| summarize sum(value) by tostring(customDimensions.consumerId), bin(timestamp, 1h)
| order by timestamp desc
```

{% hint style="info" %}
Application Insights 리소스는 Terraform이 자동으로 생성하며, Workspace 기반(Log Analytics) 모드로 구성됩니다.
{% endhint %}

---

### 4. 알림 설정

***

Application Insights에서 임계값 기반 알림을 구성하면 레이트 리밋 초과나 오류율 급증 시 이메일·Teams 알림을 받을 수 있습니다.

- [Azure Monitor 경고 규칙](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-overview)
- [Application Insights — 커스텀 메트릭](https://learn.microsoft.com/en-us/azure/azure-monitor/app/api-custom-events-metrics)
- [Azure API Management — 분석 및 모니터링](https://learn.microsoft.com/en-us/azure/api-management/howto-use-analytics)

## 3. 비용 관리 — 예산 기반 모델 전환 운영

***

게이트웨이는 소비자별 일별 USD 예산 한도를 초과하면 자동으로 더 저렴한 모델로 전환(모델 전환)합니다. Azure Cost Management 월 예산은 경고(alert) 전용이며 하드 스톱이 아닙니다.

---

### 1. 예산 기반 모델 전환 동작 원리

***

각 소비자에게는 Admin UI에서 **일별 USD 예산 한도(per-consumer daily budget)**를 설정합니다. 하루 동안 소비된 토큰 비용이 임계값에 도달하면 APIM 정책이 요청 본문의 `model` 필드를 자동으로 교체합니다.

| 임계값 | 동작 |
|---|---|
| 80% 도달 | `downgrade_level = 1` — 모델 전환 1단계: 더 저렴한 모델로 전환 |
| 100% 도달 | `downgrade_level = 2` — 모델 전환 2단계: 추가로 더 저렴한 모델로 전환 |

{% hint style="info" %}
**📸 [스크린샷 자리]** — Admin UI — 소비자별 **일별 예산**(USD) 편집 화면
{% endhint %}

{% hint style="info" %}
전환 이후에도 클라이언트가 요청한 원래 모델은 `x-ai-gateway-requested-model` 헤더에 보존됩니다. 실제 사용 모델은 `x-ai-gateway-effective-model`, 전환 단계는 `x-ai-gateway-downgrade-level` 헤더로 확인합니다. 모니터링 상세는 위 『2. 모니터링』 절을 참조하세요.
{% endhint %}

#### 모델 전환 사다리(downgrade_ladder)

**모델 전환 사다리**는 Cosmos DB config 문서 내 **`downgrade_ladder`** 배열로 정의됩니다. 사다리 순서대로 더 저렴한 모델이 배치됩니다. 예:

```
gpt-5.4 → gpt-5.4-mini → DeepSeek-V4-Pro
```

**`active_downgrade`** 플래그가 `true`인 소비자에게만 모델 전환이 적용됩니다. Admin UI Policies 탭에서 소비자별로 활성화·비활성화할 수 있습니다.

---

### 2. 가격 데이터 관리

***

모델 단가(per-1k 토큰)는 Cosmos DB의 `pricing` 문서에 저장됩니다. Azure AI 서비스 가격이 변경된 경우 jumpbox에서 다음 스크립트를 실행하여 갱신합니다.

```bash
./scripts/seed-pricing-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
```

이 스크립트는 idempotent하므로 반복 실행이 안전합니다. 갱신 후 config-sync worker를 즉시 실행하면 Admin UI의 가격 라벨과 예산 계산에 즉시 반영됩니다.

```bash
az containerapp job start -g <rg> -n <config_sync_job_name>
```

---

### 3. Azure Cost Management 월 예산

***

Terraform은 `monthly_budget_amount`(기본값: 200 USD) 변수를 기준으로 Azure Cost Management 예산을 자동 생성하고, `budget_alert_email`로 경고 이메일을 발송하도록 구성합니다.

{% hint style="warning" %}
Azure Cost Management 예산 경고는 **알림 전용(alert only)**입니다. 예산 초과 시 Azure가 리소스를 자동으로 중단하거나 API 호출을 차단하지 않습니다. 실제 비용 제어는 위의 게이트웨이 레벨 예산 기반 모델 전환을 활용하세요.
{% endhint %}

관련 tfvars 변수:

```hcl
monthly_budget_amount = 200
budget_alert_email    = "<your-email@example.com>"
budget_start_date     = "2025-01-01"
```

---

### 4. 비용 최적화 팁

***

- **gpt-5.4-mini 우선 배치:** 저비용 작업에는 Admin UI에서 소비자 기본 모델을 `gpt-5.4-mini`로 설정합니다.
- **토큰 쿼터 조정:** `token_quota` / `token_quota_period`(기본: Daily) 값을 낮춰 소비자별 일별 토큰 상한을 제한합니다.
- **미사용 소비자 비활성화:** Admin UI에서 비사용 소비자를 Disable 처리하면 해당 구독 키로의 호출이 차단됩니다.
- **Developer SKU는 개발·데모 전용:** SLA가 없으므로 프로덕션에서는 Premium_1으로 전환하세요. SKU 변경 방법은 아래 『4. 스케일링 및 SKU 변경』 절을 참조하세요.

---

### 5. 참고 링크

***

- [Azure Cost Management — 예산 설정](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [Azure API Management — 레이트 리밋 정책](https://learn.microsoft.com/en-us/azure/api-management/rate-limit-policy)
- [Azure AI Foundry 가격](https://azure.microsoft.com/en-us/pricing/details/ai-foundry/)

## 4. 스케일링 및 SKU 변경

***

배포 이후 트래픽 증가나 SLA 요건 변경 시 APIM SKU와 모델 capacity(TPM)를 조정해야 합니다. 이 절은 Developer_1 → Premium_1 SKU 전환, 모델 TPM 조정, APIM 모드 변경 시 주의사항을 다룹니다.

---

### 1. APIM SKU 변경 (Developer_1 → Premium_1)

***

기본 배포는 `apim_sku_name = "Developer_1"` 을 사용합니다. Developer SKU는 **SLA가 없으며** 개발·데모 목적으로만 적합합니다. 프로덕션 환경에서는 **Premium_1** 이상으로 전환해야 합니다.

#### SKU 변경 절차

{% hint style="info" %}
**📸 [스크린샷 자리]** — Azure Portal — APIM SKU(Developer→Premium) 변경 화면
{% endhint %}

##### Step 1. tfvars 값 변경

`infra/terraform.tfvars` 에서 SKU 값을 변경합니다.

```hcl
apim_sku_name = "Premium_1"
```

##### Step 2. 변경 사항 plan 검토

```bash
cd infra
terraform plan
```

##### Step 3. 적용

```bash
terraform apply
```

{% hint style="warning" %}
SKU 변경은 APIM 서비스 재구성을 동반하며 수십 분이 소요될 수 있습니다. 프로덕션 환경에서는 유지보수 윈도우를 잡고 진행하세요.
{% endhint %}

#### SKU별 비교

| SKU | SLA | VNet 주입 | 용도 |
|---|---|---|---|
| Developer_1 | 없음 | 지원 | 개발·데모 |
| Premium_1 | 99.95% | 지원 | 프로덕션 |

VNet 주입은 Developer와 Premium SKU에서만 지원됩니다. 참고: [Azure API Management SKU 비교](https://learn.microsoft.com/en-us/azure/api-management/api-management-features).

---

### 2. 모델 Capacity(TPM) 조정

***

Azure AI Foundry에서 모델 배포별 분당 토큰 수(TPM)는 `infra/terraform.tfvars` 의 `openai_deployments` 및 `foundry_deployments` 맵에서 설정합니다.

```hcl
openai_deployments = {
  "gpt-5.4"      = { capacity = 50 }
  "gpt-5.4-mini" = { capacity = 100 }
}

foundry_deployments = {
  "grok-4.3"         = { capacity = 30 }
  "DeepSeek-V4-Pro"  = { capacity = 30 }
}
```

{% hint style="info" %}
`capacity` 값은 Azure AI Foundry 포털에서 표시되는 단위(보통 1k TPM)를 기준으로 설정합니다. 쿼터가 부족한 경우 Azure 포털 또는 Azure AI Foundry 포털에서 쿼터 증가 요청을 제출하세요.
{% endhint %}

capacity 변경 후:

```bash
cd infra
terraform apply
```

brownfield 재사용 모드(`reuse_foundry = true`)에서는 모델 배포를 Terraform이 관리하지 않으므로 포털 또는 `az` CLI에서 직접 capacity를 조정해야 합니다.

---

### 3. APIM 모드 변경 주의 (Internal ↔ External)

***

`apim_public` 변수는 APIM 게이트웨이를 인터넷에 노출할지 여부를 제어합니다.

| 값 | 모드 | 설명 |
|---|---|---|
| `true` | External (Public) | 인터넷에서 직접 호출 가능 |
| `false` | Internal (VNet 전용) | VNet 내부 또는 VPN/ExpressRoute 경유만 가능 |

{% hint style="warning" %}
`apim_public` 을 변경하면 APIM의 VNet 통합 모드가 재구성됩니다. 이는 단순 설정 변경이 아니라 **APIM 서비스 재구성**으로, 첫 apply 시와 동일하게 **~45분**이 소요될 수 있습니다. 프로덕션 환경에서 Internal → External로 전환할 때는 보안 검토를 먼저 완료하세요.
{% endhint %}

```hcl
# 인터넷 공개 활성화
apim_public = true
```

---

### 4. 참고 링크

***

- [Azure API Management SKU 및 기능 비교](https://learn.microsoft.com/en-us/azure/api-management/api-management-features)
- [Azure API Management 스케일링](https://learn.microsoft.com/en-us/azure/api-management/upgrade-and-scale)
- [Azure AI Foundry 모델 배포 capacity](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/deploy-models-openai)
- [Azure API Management VNet 통합](https://learn.microsoft.com/en-us/azure/api-management/virtual-network-concepts)

## 5. 리소스 정리 (Cleanup)

***

게이트웨이를 더 이상 사용하지 않을 경우 Terraform으로 리소스를 제거합니다. VNet 주입 APIM 환경에서는 `terraform destroy`가 중간에 멈출 수 있으므로 주의가 필요합니다.

---

### 1. 기본 정리 절차

***

```bash
cd infra
terraform destroy
```

`terraform destroy`는 Terraform이 관리하는 모든 리소스(APIM, Container Apps, Cosmos DB, VNet, Private Endpoint, ACR 등)를 역순으로 삭제합니다.

---

### 2. 주의: VNet 주입 APIM의 Named Value 삭제 문제

***

VNet 주입 모드(`apim_public`과 무관하게 Developer/Premium SKU는 VNet 주입)로 배포된 APIM은 `terraform destroy` 실행 중 **Named Value 삭제 단계에서 멈출 수 있습니다.** 이는 APIM 내부 의존성 처리 지연 때문이며, 일시적으로 보이더라도 수십 분 이상 멈춰 있을 수 있습니다.

이 경우 **리소스 그룹 전체를 한 번에 삭제**하는 것이 더 깔끔합니다.

{% hint style="warning" %}
`terraform destroy`가 Named Value 삭제 단계에서 멈추면 `az group delete -n <rg> --yes` 로 리소스 그룹 전체를 삭제하세요. `<rg>`는 `terraform output -raw resource_group_name` 으로 확인합니다. `az group delete`는 APIM VNet 의존성 해제도 Azure 플랫폼이 내부적으로 처리합니다.
{% endhint %}

```bash
az group delete -n <rg> --yes
```

`az group delete`는 해당 RG 내 모든 리소스를 비동기적으로 삭제하며, APIM VNet 의존성 해제도 Azure 플랫폼이 내부적으로 처리합니다.

---

### 3. Brownfield(재사용) 모드에서의 정리

***

`reuse_foundry = true` 로 배포한 경우, **고객의 기존 Azure AI Foundry 계정은 별도의 리소스 그룹에 있습니다.** `terraform destroy` 또는 `az group delete`로 게이트웨이 RG를 삭제해도 기존 Foundry 계정은 영향을 받지 않습니다.

{% hint style="info" %}
brownfield 고객의 기존 Azure AI Foundry 계정은 별도 RG에 있으므로 게이트웨이 RG 삭제 시 안전하게 보존됩니다. 단, 역할 할당과 Private Endpoint는 제거되므로 해당 Foundry 계정을 다른 서비스에서도 사용 중이라면 사전 확인이 필요합니다.
{% endhint %}

삭제 대상과 보존 대상을 정리하면 다음과 같습니다.

| 리소스 | 삭제 여부 |
|---|---|
| 게이트웨이 RG (APIM, Container Apps, Cosmos DB 등) | 삭제됨 |
| 기존 Foundry 계정 (별도 RG) | **보존됨** |
| 기존 Foundry의 Private Endpoint (게이트웨이 VNet → Foundry) | 삭제됨 |
| 기존 Foundry의 RBAC 역할 할당 (APIM MI) | 삭제됨 |

---

### 4. Entra ID 객체 수동 정리

***

`./scripts/app-registration.sh` 로 생성된 Entra ID 앱 등록(BFF API, SPA)과 관리자 보안 그룹은 Terraform 관리 범위 밖입니다. 필요한 경우 다음 명령으로 수동 삭제합니다.

```bash
# SPA 앱 등록 삭제
spa_app_id="$(az ad app list --display-name "AI Gateway SPA" --query "[].appId" -o tsv)"
az ad app delete --id "$spa_app_id"

# BFF API 앱 등록 삭제
bff_app_id="$(az ad app list --display-name "AI Gateway BFF" --query "[].appId" -o tsv)"
az ad app delete --id "$bff_app_id"
```

---

### 5. 참고 링크

***

- [Azure 리소스 그룹 삭제](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/delete-resource-group)
- [Azure API Management — VNet 통합 정리](https://learn.microsoft.com/en-us/azure/api-management/virtual-network-concepts)
- [Terraform — destroy 명령](https://developer.hashicorp.com/terraform/cli/commands/destroy)
