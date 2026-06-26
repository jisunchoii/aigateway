---
description: 배포 담당자 / 비용 담당자를 위한 페이지 · 선행: 첫 번째 terraform apply
---

# 비용 및 정리

---

## APIM SKU와 비용

[Azure API Management 가격 책정](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-features)

| SKU | SLA | VNet 주입 | 용도 |
|---|---|---|---|
| `Developer_1` | **없음** | 지원 (Developer/Premium 필요) | dev / demo |
| `Premium_1` | 있음 | 지원 | 프로덕션 권장 |

{% hint style="warning" %}
`Developer_1`은 SLA가 없습니다. 프로덕션 환경에서는 반드시 `apim_sku_name = "Premium_1"` 로 설정하세요.
{% endhint %}

VNet 주입(Internal/External 모드)은 Developer 또는 Premium SKU에서만 지원됩니다. Consumption 또는 Basic SKU는 VNet 주입을 지원하지 않습니다.

---

## 모델 과금

모델 호출은 **토큰당 과금**입니다. Azure OpenAI(gpt-5.4, gpt-5.4-mini) 및 Azure AI Foundry OSS/파트너 모델(grok-4.3, DeepSeek-V4-Pro) 모두 입력+출력 토큰 기준으로 청구됩니다.

- [Azure OpenAI 가격 책정](https://learn.microsoft.com/ko-kr/azure/ai-services/openai/concepts/models)
- [Azure AI Foundry 파트너 모델 가격](https://learn.microsoft.com/ko-kr/azure/ai-foundry/concepts/models-overview)

---

## Cost Management 월 예산

[Azure Cost Management 예산](https://learn.microsoft.com/ko-kr/azure/cost-management-billing/costs/tutorial-acm-create-budgets)

```hcl
monthly_budget_amount = 200        # 구독 통화, 기본값
budget_alert_email    = "<이메일>"
budget_start_date     = "2026-06-01T00:00:00Z"
```

{% hint style="warning" %}
Cost Management 예산은 **알림(alert)** 만 발송합니다. 예산 초과 시 **자동 차단(하드 스톱)은 발생하지 않습니다.** 예산은 비용 모니터링과 이상 감지 용도입니다.
{% endhint %}

예산 임계값(50%, 75%, 100%, 120%)에서 `budget_alert_email`로 이메일 알림이 발송됩니다.

---

## 리소스 정리 (terraform destroy)

개발/데모 환경을 삭제할 때는 다음 명령을 실행합니다.

```bash
cd infra && terraform destroy
```

### VNet 주입 APIM 환경 정리 시 주의 (gotcha #3)

Developer 또는 Premium SKU로 VNet에 주입된 APIM을 `terraform destroy`로 삭제하면 **Named Value 삭제 단계에서 멈출 수 있습니다.** 이 경우 리소스 그룹 전체를 삭제하는 것이 더 안정적입니다.

```bash
az group delete -n <resource_group_name> --yes
```

`<resource_group_name>`은 `terraform output -raw resource_group_name`으로 확인합니다.

{% hint style="warning" %}
`az group delete`는 RG 내 모든 리소스를 삭제합니다. Terraform state와 동기화가 깨질 수 있으므로, 이후 같은 스택을 재배포할 때는 `terraform init`부터 다시 시작하세요.
{% endhint %}

자세한 내용은 [gotchas.md](gotchas.md) gotcha #3을 참고하세요.

---

## 관련 문서

- 변수 레퍼런스 (`apim_sku_name`, `monthly_budget_amount`) → [variables.md](variables.md)
- 출력 레퍼런스 (`resource_group_name`) → [outputs.md](outputs.md)
- Gotchas → [gotchas.md](gotchas.md)
- [Azure API Management 가격 및 SKU 비교](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-features)
- [Azure Cost Management 예산 만들기](https://learn.microsoft.com/ko-kr/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
