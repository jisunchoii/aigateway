---
description: 게이트웨이 운영자를 위한 페이지 · 선행: 05-verify/smoke-test.md
---

# 설정 변경 — 소비자 등록·키·정책 관리

Admin UI는 React SPA + FastAPI BFF로 구성되어 있으며, Entra ID 로그인과 admin 보안 그룹(admin_group_object_id)에 의해 접근이 제한됩니다. 운영자는 이 UI를 통해 소비자 등록, API 키 발급, 모델·티어·예산 정책 편집을 모두 수행할 수 있습니다.

---

## Admin UI 접근

1. `terraform output -raw admin_ui_fqdn` 으로 URL을 확인합니다.
2. 브라우저에서 해당 URL을 열면 Entra ID 로그인 화면이 나타납니다.
3. admin 보안 그룹에 속한 계정으로 로그인합니다. 그룹 외 사용자는 403 응답을 받습니다.

{% hint style="info" %}
Admin UI에 접근하려면 `admin_ui_public = true` 와 `admin_ui_image` 가 설정된 상태에서 `terraform apply` 가 완료되어야 합니다. 설정 방법은 [03-deploy/app-registration-second-apply.md](../03-deploy/app-registration-second-apply.md)를 참조하십시오.
{% endhint %}

---

## 소비자 등록 및 키 발급

**소비자(Consumer)** 는 게이트웨이를 사용하는 팀·서비스 단위입니다. Admin UI의 **Consumers** 탭에서 다음 작업을 수행합니다.

| 작업 | 위치 |
|---|---|
| 소비자 신규 등록 | Consumers → New Consumer |
| APIM 구독 키 발급 | Consumers → 해당 소비자 → Keys → Generate |
| 소비자 비활성화 | Consumers → 해당 소비자 → Disable |

발급된 구독 키(`Ocp-Apim-Subscription-Key`)는 소비자가 API 호출 시 헤더에 포함해야 합니다. Entra ID 클라이언트 인증 모드(`client_auth_mode="entra-id"`)를 사용하는 경우 키 대신 JWT 토큰을 사용합니다. 자세한 내용은 [09-future/extension-c-entra-client-auth.md](../09-future/extension-c-entra-client-auth.md)를 참조하십시오.

---

## 모델·티어·예산 정책 편집

Admin UI의 **Policies** 탭에서 소비자별 정책을 편집합니다.

### 허용 모델 변경
소비자가 호출 가능한 모델 목록을 제한합니다. 목록에 없는 모델로 요청하면 APIM 정책이 `403 Forbidden`을 반환합니다.

### 토큰 티어(Rate Tier) 변경
`rate_tiers`(small / medium / large)별로 분당 토큰 수(TPM)와 일별 쿼터가 다르게 설정됩니다. 소비자에 적절한 티어를 부여합니다.

| 티어 | 분당 토큰(TPM) | 일별 쿼터(기본값) |
|---|---|---|
| small | 1,000 | 50,000 |
| medium | (tfvars 설정에 따라) | (tfvars 설정에 따라) |
| large | (tfvars 설정에 따라) | (tfvars 설정에 따라) |

{% hint style="info" %}
실제 TPM·쿼터 값은 `infra/terraform.tfvars`의 `tokens_per_minute`, `token_quota` 변수를 기준으로 합니다. [10-reference/variables.md](../10-reference/variables.md)에서 전체 변수 목록을 확인하십시오.
{% endhint %}

### 예산(Budget) 정책 편집
소비자별 일별 USD 예산 한도를 설정합니다. 80% 도달 시 더 저렴한 모델로 전환(모델 전환 1단계), 100% 도달 시 추가 전환(모델 전환 2단계)됩니다. 예산 운영 상세는 [cost-management.md](cost-management.md)를 참조하십시오.

---

## 변경 반영 — config-sync worker

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
worker_image가 설정되기 전에는 `config_sync_job_name` 출력이 null입니다. 이미지 빌드·푸시 단계([03-deploy/build-push-images.md](../03-deploy/build-push-images.md))가 완료된 후 실행하십시오.
{% endhint %}

---

## 가격 데이터 갱신

모델 단가(per-1k 토큰)는 Cosmos DB의 `pricing` 문서에 저장됩니다. Azure AI 가격이 변경된 경우 jumpbox에서 다음 스크립트로 갱신합니다.

```bash
./scripts/seed-pricing-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
```

이 스크립트는 idempotent하므로 반복 실행해도 안전합니다. 갱신 후 config-sync worker를 즉시 실행하면 Admin UI의 가격 라벨과 예산 계산에 바로 반영됩니다.

---

## 참고 링크

- [Azure API Management — Named Values](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-properties)
- [Azure Container Apps Jobs](https://learn.microsoft.com/en-us/azure/container-apps/jobs)
- [Azure Cosmos DB — 문서 읽기/쓰기](https://learn.microsoft.com/en-us/azure/cosmos-db/nosql/quickstart-python)
