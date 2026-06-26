---
description: 게이트웨이 운영자·인프라 담당자를 위한 페이지 · 선행: 06-operate/cost-management.md
---

# 스케일링 및 SKU 변경

배포 이후 트래픽 증가나 SLA 요건 변경 시 APIM SKU와 모델 capacity(TPM)를 조정해야 합니다. 이 페이지는 Developer_1 → Premium_1 SKU 전환, 모델 TPM 조정, APIM 모드 변경 시 주의사항을 다룹니다.

---

## 1. APIM SKU 변경 (Developer_1 → Premium_1)

***

기본 배포는 `apim_sku_name = "Developer_1"` 을 사용합니다. Developer SKU는 **SLA가 없으며** 개발·데모 목적으로만 적합합니다. 프로덕션 환경에서는 **Premium_1** 이상으로 전환해야 합니다.

### SKU 변경 절차

#### Step 1. tfvars 값 변경

`infra/terraform.tfvars` 에서 SKU 값을 변경합니다.

```hcl
apim_sku_name = "Premium_1"
```

#### Step 2. 변경 사항 plan 검토

```bash
cd infra
terraform plan
```

#### Step 3. 적용

```bash
terraform apply
```

{% hint style="warning" %}
SKU 변경은 APIM 서비스 재구성을 동반하며 수십 분이 소요될 수 있습니다. 프로덕션 환경에서는 유지보수 윈도우를 잡고 진행하십시오.
{% endhint %}

### SKU별 비교

| SKU | SLA | VNet 주입 | 용도 |
|---|---|---|---|
| Developer_1 | 없음 | 지원 | 개발·데모 |
| Premium_1 | 99.95% | 지원 | 프로덕션 |

VNet 주입은 Developer와 Premium SKU에서만 지원됩니다. 참고: [Azure API Management SKU 비교](https://learn.microsoft.com/en-us/azure/api-management/api-management-features).

---

## 2. 모델 Capacity(TPM) 조정

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
`capacity` 값은 Azure AI Foundry 포털에서 표시되는 단위(보통 1k TPM)를 기준으로 설정합니다. 쿼터가 부족한 경우 Azure 포털 또는 Azure AI Foundry 포털에서 쿼터 증가 요청을 제출하십시오.
{% endhint %}

capacity 변경 후:

```bash
cd infra
terraform apply
```

brownfield 재사용 모드(`reuse_foundry = true`)에서는 모델 배포를 Terraform이 관리하지 않으므로 포털 또는 `az` CLI에서 직접 capacity를 조정해야 합니다.

---

## 3. APIM 모드 변경 주의 (Internal ↔ External)

***

`apim_public` 변수는 APIM 게이트웨이를 인터넷에 노출할지 여부를 제어합니다.

| 값 | 모드 | 설명 |
|---|---|---|
| `true` | External (Public) | 인터넷에서 직접 호출 가능 |
| `false` | Internal (VNet 전용) | VNet 내부 또는 VPN/ExpressRoute 경유만 가능 |

{% hint style="warning" %}
`apim_public` 을 변경하면 APIM의 VNet 통합 모드가 재구성됩니다. 이는 단순 설정 변경이 아니라 **APIM 서비스 재구성**으로, 첫 apply 시와 동일하게 **~45분**이 소요될 수 있습니다. 프로덕션 환경에서 Internal → External로 전환할 때는 보안 검토를 선행하십시오.
{% endhint %}

```hcl
# 인터넷 공개 활성화
apim_public = true
```

---

## 4. 참고 링크

***

- [Azure API Management SKU 및 기능 비교](https://learn.microsoft.com/en-us/azure/api-management/api-management-features)
- [Azure API Management 스케일링](https://learn.microsoft.com/en-us/azure/api-management/upgrade-and-scale)
- [Azure AI Foundry 모델 배포 capacity](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/deploy-models-openai)
- [Azure API Management VNet 통합](https://learn.microsoft.com/en-us/azure/api-management/virtual-network-concepts)
