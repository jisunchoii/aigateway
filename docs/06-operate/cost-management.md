---
description: 게이트웨이 운영자·재무 담당자를 위한 페이지 · 선행: 06-operate/monitoring.md
---

# 비용 관리 — 예산 기반 모델 전환 운영

게이트웨이는 소비자별 일별 USD 예산 한도를 초과하면 자동으로 더 저렴한 모델로 전환(모델 전환)합니다. Azure Cost Management 월 예산은 경고(alert) 전용이며 하드 스톱이 아닙니다.

---

## 1. 예산 기반 모델 전환 동작 원리

***

각 소비자에게는 Admin UI에서 **일별 USD 예산 한도(per-consumer daily budget)**를 설정합니다. 하루 동안 소비된 토큰 비용이 임계값에 도달하면 APIM 정책이 요청 본문의 `model` 필드를 자동으로 교체합니다.

| 임계값 | 동작 |
|---|---|
| 80% 도달 | `downgrade_level = 1` — 모델 전환 1단계: 더 저렴한 모델로 전환 |
| 100% 도달 | `downgrade_level = 2` — 모델 전환 2단계: 추가로 더 저렴한 모델로 전환 |

{% hint style="info" %}
전환 이후에도 클라이언트가 요청한 원래 모델은 `x-ai-gateway-requested-model` 헤더에 보존됩니다. 실제 사용 모델은 `x-ai-gateway-effective-model`, 전환 단계는 `x-ai-gateway-downgrade-level` 헤더로 확인합니다. 모니터링 상세는 [monitoring.md](monitoring.md)를 참조하십시오.
{% endhint %}

### 모델 전환 사다리(downgrade_ladder)

모델 전환 사다리는 Cosmos DB config 문서 내 `downgrade_ladder` 배열로 정의됩니다. 사다리 순서대로 더 저렴한 모델이 배치됩니다. 예:

```
gpt-5.4 → gpt-5.4-mini → DeepSeek-V4-Pro
```

`active_downgrade` 플래그가 `true`인 소비자에게만 모델 전환이 적용됩니다. Admin UI Policies 탭에서 소비자별로 활성화·비활성화할 수 있습니다.

---

## 2. 가격 데이터 관리

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

## 3. Azure Cost Management 월 예산

***

Terraform은 `monthly_budget_amount`(기본값: 200 USD) 변수를 기준으로 Azure Cost Management 예산을 자동 생성하고, `budget_alert_email`로 경고 이메일을 발송하도록 구성합니다.

{% hint style="warning" %}
Azure Cost Management 예산 경고는 **알림 전용(alert only)**입니다. 예산 초과 시 Azure가 리소스를 자동으로 중단하거나 API 호출을 차단하지 않습니다. 실제 비용 제어는 위의 게이트웨이 레벨 예산 기반 모델 전환을 활용하십시오.
{% endhint %}

관련 tfvars 변수:

```hcl
monthly_budget_amount = 200
budget_alert_email    = "<your-email@example.com>"
budget_start_date     = "2025-01-01"
```

---

## 4. 비용 최적화 팁

***

- **gpt-5.4-mini 우선 배치:** 저비용 작업에는 Admin UI에서 소비자 기본 모델을 `gpt-5.4-mini`로 설정합니다.
- **토큰 쿼터 조정:** `token_quota` / `token_quota_period`(기본: Daily) 값을 낮춰 소비자별 일별 토큰 상한을 제한합니다.
- **미사용 소비자 비활성화:** Admin UI에서 비사용 소비자를 Disable 처리하면 해당 구독 키로의 호출이 차단됩니다.
- **Developer SKU는 개발·데모 전용:** SLA가 없으므로 프로덕션에서는 Premium_1으로 전환하십시오. SKU 변경 방법은 [scale-sku.md](scale-sku.md)를 참조하십시오.

---

## 5. 참고 링크

***

- [Azure Cost Management — 예산 설정](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [Azure API Management — 레이트 리밋 정책](https://learn.microsoft.com/en-us/azure/api-management/rate-limit-policy)
- [Azure AI Foundry 가격](https://azure.microsoft.com/en-us/pricing/details/ai-foundry/)
