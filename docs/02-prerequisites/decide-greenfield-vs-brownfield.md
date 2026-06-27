---
description: 인프라·아키텍트를 위한 페이지 · 선행: Entra ID 객체
---

# Greenfield vs Brownfield 결정

배포를 시작하기 전에 **AIServices(Foundry) 계정을 새로 만들 것인지, 아니면 구독 내 기존 계정을 재사용할 것인지** 결정해야 합니다. 이 결정에 따라 이어지는 배포 챕터가 달라집니다.

---

## 핵심 원칙

- **Greenfield:** Terraform이 AIServices 계정과 모델 배포를 포함한 모든 리소스를 신규 생성합니다.
- **Brownfield (reuse_foundry=true):** 기존 AIServices 계정은 `data` 소스로 읽기만 하고, Terraform은 Private Endpoint와 RBAC 할당만 신규 생성합니다. 핵심 원칙은 **"data로 읽기 + PE/RBAC만 신규"**입니다.

---

## 의사결정 플로우

<figure><img src="../images/diagram-greenfield-vs-brownfield.png" alt="Greenfield(신규 생성) vs Brownfield(기존 Foundry 재사용) 비교"><figcaption>🖼️ Greenfield(신규 생성) vs Brownfield(기존 Foundry 재사용) 비교 <em>(다이어그램 이미지 추가 예정)</em></figcaption></figure>

---

## 비교 표

| 리소스 | Greenfield (기본) | Brownfield (reuse_foundry=true) |
|---|---|---|
| 게이트웨이 RG | 생성 (별도 RG) | 생성 (별도 RG, 변경 없음) |
| AIServices 계정 | `azurerm_cognitive_account` 생성 | **data로 읽기** (생성 안 함) |
| 모델 배포 | `azurerm_cognitive_deployment` 생성 | **생성 안 함** (`for_each={}`) |
| 계정 속성(local_auth off·public block) | Terraform이 설정 | **배포 전 `az` 토글 + precondition 검증** |
| Private Endpoint | 생성 | **생성** (게이트웨이 VNet → 기존 계정) |
| APIM MI RBAC | 부여 | **부여** |

---

## Brownfield 제약사항

1. **같은 구독만 지원.** 게이트웨이와 기존 AIServices 계정이 **같은 Azure 구독**에 있어야 합니다. 교차 구독 재사용은 현재 지원하지 않습니다.

2. **계정 잠금 사전 준비 필요.** Brownfield 경로에서는 Terraform `apply` 전에 `az` CLI로 기존 계정의 `disableLocalAuth=true`, `publicNetworkAccess=Disabled`를 수동으로 설정해야 합니다. Terraform의 `precondition`이 이를 검증합니다.

{% hint style="warning" %}
Brownfield 경로에서는 `terraform apply` 전에 반드시 기존 AIServices 계정에 `disableLocalAuth=true`, `publicNetworkAccess=Disabled`를 설정하세요. 사전 준비 없이 apply하면 `precondition` 검증에서 실패합니다.
{% endhint %}

3. **foundry_deployments 키 = 실제 배포 이름.** `foundry_deployments` tfvars의 map 키가 계정에 실제로 존재하는 배포 이름과 **정확히 일치**해야 합니다. 이 값이 `allowed_models`, 라우팅, Admin UI 레이블에 모두 사용됩니다.

{% hint style="danger" %}
`foundry_deployments` map 키가 실제 배포 이름과 다르면 라우팅이 조용히 실패하거나 잘못된 모델로 연결됩니다. apply 전에 `az cognitiveservices account deployment list` 출력과 대조해 키를 정확히 맞추세요.
{% endhint %}

---

## 각 경로의 tfvars 핵심 차이

**Greenfield (기본값, 별도 설정 불필요):**
```hcl
reuse_foundry         = false   # 기본값
```

**Brownfield:**
```hcl
reuse_foundry         = true
existing_foundry_name = "ais-customer-prod"
existing_foundry_rg   = "rg-customer-ai"
# foundry_deployments에 기존 계정의 실제 배포 이름을 키로 선언
foundry_deployments = {
  "grok-4.3"          = { ... }
  "DeepSeek-V4-Pro"   = { ... }
}
```

---

## 결정 후 다음 단계

{% content-ref url="../03-deploy/overview.md" %}
[03 배포 — 새 AIServices 계정 포함 전체 스택 (Greenfield)](../03-deploy/overview.md)
{% endcontent-ref %}

{% content-ref url="../04-reuse-foundry/overview.md" %}
[04 기존 Foundry 재사용 — 기존 Foundry 계정 재사용 (Brownfield)](../04-reuse-foundry/overview.md)
{% endcontent-ref %}
