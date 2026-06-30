---
description: "게이트웨이 운영 — 설정 변경, 모니터링, 비용 관리, 스케일/SKU, 정리"
---

# 운영

이 페이지는 배포 이후 플랫폼팀이 반복적으로 수행하는 **consumer/API key 운영, 정책 반영, 모니터링, 비용 제어, 스케일 변경, 리소스 정리** 절차를 정리합니다. 배포 직후 호출 확인은 각 배포 페이지의 검증 절에서 처리하고, 이 페이지는 운영 중 변경과 진단에 집중합니다.

## 1. 운영 범위

{% hint style="success" %}
**이 페이지가 다루는 것**

- Admin UI에서 consumer 등록, API key 발급, 모델 권한·티어·예산 정책 변경
- config-sync worker로 Cosmos DB 설정을 APIM Named Value에 반영
- Admin UI Monitoring과 Application Insights로 요청·차단·모델 전환 이벤트 확인
- 예산 기반 모델 전환, 가격 데이터 갱신, 월 예산 알림 운영
- APIM SKU, 모델 capacity, 공개 모드 변경과 리소스 정리
{% endhint %}

| 운영 작업 | 주로 사용하는 위치 |
|---|---|
| consumer 등록 / API key 발급 | Admin UI → Consumers |
| 모델 허용 목록 / rate tier / budget 변경 | Admin UI → Policies |
| 변경 즉시 반영 | Azure Container Apps Job `config-sync` |
| 요청·차단·모델 전환 확인 | Admin UI → Monitoring, Application Insights |
| 인프라 규모 변경 | `infra/terraform.tfvars` + `terraform apply` |

{% hint style="info" %}
Admin UI는 Entra ID 로그인과 admin 보안 그룹으로 보호됩니다. public FQDN을 노출하더라도 그룹 권한을 통과하지 못하면 쓰기 작업을 수행할 수 없습니다.
{% endhint %}

## 2. 설정 변경

### Admin UI 접속

```bash
cd infra
terraform output -raw admin_ui_fqdn
```

브라우저에서 출력된 URL을 열고 admin 보안 그룹에 속한 계정으로 로그인합니다. `admin_ui_public=false`인 환경은 VNet 내부, VPN, jumpbox 등 조직 네트워크 경로에서 접근해야 합니다.

### Consumer와 API key 운영

Admin UI의 **Consumers** 탭에서 팀·서비스 단위 consumer를 등록하고 APIM subscription key를 발급합니다.

| 작업 | 위치 | 결과 |
|---|---|---|
| consumer 등록 | Consumers → New Consumer | 정책 적용 대상 생성 |
| API key 발급 | Consumers → Keys → Generate | 클라이언트 호출용 subscription key 생성 |
| consumer 비활성화 | Consumers → Disable | 해당 consumer 호출 차단 |

발급된 key는 클라이언트가 `Ocp-Apim-Subscription-Key` 또는 `api-key` 헤더로 전달합니다. 클라이언트별 헤더와 base URL은 [클라이언트 온보딩](07-connect-clients.md)을 참고하세요.

### 정책 변경

Admin UI의 **Policies** 탭에서 consumer별 운영 정책을 조정합니다.

| 정책 | 의미 | 운영 영향 |
|---|---|---|
| Allowed models | 호출 가능한 모델 목록 | 목록 밖 모델은 `403 Forbidden` |
| Rate tier | 분당 토큰과 일별 토큰 쿼터 | 초과 시 `429 Too Many Requests` |
| Daily budget | consumer별 일별 USD 예산 | 임계값 도달 시 모델 전환 |
| Active downgrade | 예산 기반 모델 전환 활성화 | 꺼두면 예산 임계값에도 모델 유지 |

### 변경 반영

Admin UI에서 저장한 설정은 Cosmos DB config 문서에 기록되고, config-sync worker가 APIM Named Value로 동기화합니다.

| 단계 | 동작 |
|---|---|
| 1 | Admin UI가 Cosmos DB에 consumer/policy 저장 |
| 2 | config-sync worker가 설정 읽기 |
| 3 | APIM Named Value 업데이트 |
| 4 | 이후 요청부터 APIM 정책에 반영 |

기본 스케줄은 `config_sync_cron = "*/5 * * * *"`입니다. 바로 반영해야 하면 job을 수동 실행합니다.

```bash
cd infra
config_sync_job_name="$(terraform output -raw config_sync_job_name)"
resource_group_name="$(terraform output -raw resource_group_name)"

az containerapp job start \
  -g "$resource_group_name" \
  -n "$config_sync_job_name"
```

{% hint style="warning" %}
`worker_image`가 비어 있으면 config-sync job이 배포되지 않습니다. Admin UI에서 정책을 바꿔도 APIM에 자동 반영되지 않으므로, 운영 환경에서는 worker 이미지를 함께 배포하세요.
{% endhint %}

## 3. 모니터링

### Admin UI Monitoring

운영자는 Admin UI의 **Monitoring** 페이지에서 최근 요청, 차단 이벤트, 모델 전환 이벤트를 확인합니다.

| 화면 | 확인할 내용 |
|---|---|
| Recent Requests | consumer, model, status code, token usage |
| Blocked Events | `403`, `429`와 차단 사유 |
| Model Downgrade Events | 요청 모델, 실제 사용 모델, 전환 단계 |

{% hint style="info" %}
문서와 UI에서는 **모델 전환**이라고 표현합니다. 코드와 APIM 헤더의 `downgrade` 식별자는 구현 이름이므로 그대로 유지됩니다.
{% endhint %}

### 모델 전환 헤더

예산 임계값 때문에 모델이 바뀌면 응답 헤더로 전환 상태를 확인할 수 있습니다.

| 헤더 | 설명 |
|---|---|
| `x-ai-gateway-requested-model` | 클라이언트가 요청한 원래 모델 |
| `x-ai-gateway-effective-model` | 실제로 호출된 모델 |
| `x-ai-gateway-downgrade-level` | `0` 전환 없음, `1` 80% 임계, `2` 100% 임계 |

### Application Insights 쿼리

APIM 정책은 토큰 사용량을 Application Insights custom metric으로 기록합니다.

```kusto
customMetrics
| where name == "llm_total_tokens"
| summarize total_tokens=sum(value) by tostring(customDimensions.consumerId), tostring(customDimensions.model), bin(timestamp, 1h)
| order by timestamp desc
```

운영 중 자주 보는 메트릭은 아래 세 가지입니다.

| 메트릭 | 의미 |
|---|---|
| `llm_total_tokens` | 전체 토큰 수 |
| `llm_prompt_tokens` | 입력 토큰 수 |
| `llm_completion_tokens` | 출력 토큰 수 |

## 4. 비용 관리

### 예산 기반 모델 전환

consumer별 일별 예산은 Admin UI Policies 탭에서 설정합니다. 사용량이 임계값에 도달하면 APIM 정책이 더 저렴한 모델로 요청을 전환합니다.

| 임계값 | 동작 |
|---|---|
| 80% | `downgrade_level=1`, 1단계 모델 전환 |
| 100% | `downgrade_level=2`, 2단계 모델 전환 |

전환 순서는 Cosmos DB config의 `downgrade_ladder` 배열로 정의합니다.

```text
gpt-5.4 -> gpt-5.4-mini -> DeepSeek-V4-Pro
```

### 가격 데이터 갱신

모델 단가가 바뀌면 jumpbox에서 pricing seed를 다시 실행합니다.

```bash
./scripts/seed-pricing-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
```

갱신 후 config-sync worker를 실행하면 Admin UI의 가격 라벨과 예산 계산에 반영됩니다.

### Azure Cost Management 예산

Terraform은 월 예산 알림을 생성할 수 있습니다.

```text
monthly_budget_amount = 200
budget_alert_email    = "<your-email@example.com>"
budget_start_date     = "2025-01-01"
```

{% hint style="warning" %}
Azure Cost Management 예산은 알림 전용입니다. 예산 초과 시 Azure가 리소스를 자동 중지하거나 APIM 호출을 차단하지 않습니다. 실제 호출 제어는 gateway의 일별 budget과 모델 전환 정책으로 운영하세요.
{% endhint %}

## 5. 스케일과 SKU 변경

### APIM SKU 변경

기본 배포는 `Developer_1`을 사용합니다. 프로덕션 SLA가 필요하면 `Premium_1` 이상으로 전환합니다.

```text
apim_sku_name = "Premium_1"
```

```bash
cd infra
terraform plan
terraform apply
```

{% hint style="warning" %}
APIM SKU 변경은 수십 분이 걸릴 수 있습니다. 프로덕션에서는 유지보수 창을 잡고 변경하세요.
{% endhint %}

| SKU | SLA | VNet 주입 | 용도 |
|---|---|---|---|
| Developer_1 | 없음 | 지원 | 개발·데모 |
| Premium_1 | 99.95% | 지원 | 프로덕션 |

### 모델 capacity 조정

greenfield 배포에서는 `infra/` 디렉터리의 `terraform.tfvars` 파일에서 deployment map의 capacity를 조정합니다.

```text
openai_deployments = {
  "gpt-5.4"      = { capacity = 50 }
  "gpt-5.4-mini" = { capacity = 100 }
}

foundry_deployments = {
  "grok-4.3"        = { capacity = 30 }
  "DeepSeek-V4-Pro" = { capacity = 30 }
}
```

brownfield 재사용 모드(`reuse_foundry=true`)에서는 Terraform이 기존 모델 deployment를 소유하지 않으므로 Azure AI Foundry 포털 또는 `az` CLI에서 직접 capacity를 조정합니다.

### 모델 추가·제거

게이트웨이에 모델을 추가하거나 빼려면 두 곳을 갱신합니다.

| 위치 | 무엇 | 효과 |
|---|---|---|
| `infra/terraform.tfvars`의 `allowed_models`(+ `openai_deployments`/`foundry_deployments`) | 허용 모델 목록과 deployment 정의 | `terraform apply` 후 APIM이 호출을 허용하고, Admin UI Models 페이지에 자동 표시 |
| `scripts/seed-pricing-jumpbox.sh`의 `models` 맵 | 모델별 per-1k 단가 | 시드 재실행 후 Admin UI 단가 표시와 budget 비용 계산 반영 |

Admin UI 모델 목록은 `allowed_models`에서 자동 생성되므로 별도 코드 수정은 필요 없습니다. 단, 가격은 운영자 소유 Cosmos `pricing` 문서라 시드를 갱신하지 않으면 신규 모델은 단가가 표시되지 않고 budget 비용이 0으로 잡힙니다.

```text
"models": {
  "gpt-5.4":         { "prompt": 0.0025,  "completion": 0.015 },
  "Kimi-K2.6-1":     { "prompt": 0.00095, "completion": 0.004 }
}
```

per-1k 단가는 모델별 per-1M 가격을 1000으로 나눈 값입니다. 예를 들어 Kimi K2.6은 Azure AI Foundry Models 공식 가격 기준 input $0.95/M, output $4.00/M이므로 per-1k 단가는 prompt 0.00095, completion 0.004입니다.

### APIM 공개 모드 변경

`apim_public`은 gateway를 인터넷에서 호출할 수 있게 할지 결정합니다.

| 값 | 모드 | 설명 |
|---|---|---|
| `true` | External | 인터넷에서 직접 호출 가능 |
| `false` | Internal | VNet 내부 또는 VPN/ExpressRoute 경유 |

{% hint style="warning" %}
`apim_public` 변경은 단순 토글이 아니라 APIM 네트워크 재구성입니다. 첫 배포와 비슷하게 오래 걸릴 수 있으므로 보안 검토와 유지보수 창을 먼저 잡으세요.
{% endhint %}

## 6. 리소스 정리

### 기본 정리

```bash
cd infra
terraform destroy
```

Terraform이 관리하는 APIM, Container Apps, Cosmos DB, VNet, Private Endpoint, ACR 등을 삭제합니다.

### destroy가 멈출 때

VNet 주입 APIM은 destroy 중 Named Value 삭제 단계에서 오래 멈출 수 있습니다. 데모·검증 환경이라면 리소스 그룹 삭제가 더 깔끔합니다.

```bash
resource_group_name="$(terraform output -raw resource_group_name)"
az group delete -n "$resource_group_name" --yes
```

{% hint style="warning" %}
`az group delete`는 해당 리소스 그룹의 모든 리소스를 삭제합니다. 같은 RG에 수동으로 만든 리소스가 있으면 먼저 옮기거나 백업하세요.
{% endhint %}

### brownfield 재사용 모드

`reuse_foundry=true`인 경우 기존 Azure AI Foundry 계정은 별도 리소스 그룹에 있으므로 gateway RG를 삭제해도 보존됩니다. 단, gateway VNet에서 만든 Private Endpoint와 APIM managed identity 역할 할당은 함께 제거됩니다.

| 리소스 | 정리 결과 |
|---|---|
| Gateway RG의 APIM, Container Apps, Cosmos DB, ACR | 삭제 |
| 기존 Foundry 계정 | 보존 |
| Gateway VNet에서 만든 Private Endpoint | 삭제 |
| APIM managed identity의 기존 Foundry RBAC | 삭제 |

### Entra ID 객체 수동 정리

`scripts/app-registration.sh`로 만든 SPA 앱, BFF API 앱, admin 보안 그룹은 Terraform 관리 대상이 아닙니다. 더 이상 필요 없으면 Entra ID에서 수동 삭제합니다.

```bash
spa_app_id="$(az ad app list --display-name "AI Gateway SPA" --query "[].appId" -o tsv)"
az ad app delete --id "$spa_app_id"

bff_app_id="$(az ad app list --display-name "AI Gateway BFF" --query "[].appId" -o tsv)"
az ad app delete --id "$bff_app_id"
```

## 7. 다음 단계

| 목적 | 이동 |
|---|---|
| 클라이언트 연결 | [클라이언트 온보딩](07-connect-clients.md) |
| 변수·출력 전체 목록 | [부록: 변수·출력·문제 해결](10-reference.md) |
| 향후 지원 계획 | [향후 지원 계획](09-future.md) |
