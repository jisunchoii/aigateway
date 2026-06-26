> 읽는 사람: 인프라·아키텍트 · 선행: Entra ID 객체

# Greenfield vs Brownfield 결정

배포를 시작하기 전에 **AIServices(Foundry) 계정을 새로 만들 것인지, 아니면 구독 내 기존 계정을 재사용할 것인지** 결정해야 합니다. 이 결정에 따라 이어지는 배포 챕터가 달라집니다.

---

## 핵심 원칙

- **Greenfield:** Terraform이 AIServices 계정과 모델 배포를 포함한 모든 리소스를 신규 생성합니다.
- **Brownfield (reuse_foundry=true):** 기존 AIServices 계정은 `data` 소스로 읽기만 하고, Terraform은 Private Endpoint와 RBAC 할당만 신규 생성합니다. 핵심 원칙은 **"data로 읽기 + PE/RBAC만 신규"**입니다.

---

## 의사결정 플로우

```
구독 내에 기존 Azure AI Foundry(AIServices) 계정이 있는가?
│
├─ 아니오 → Greenfield → 챕터 03 배포
│
└─ 예
     │
     ├─ 기존 계정이 게이트웨이와 같은 구독에 있는가?
     │   │
     │   ├─ 아니오 → Greenfield 권장 (교차 구독 재사용 미지원)
     │   │            → 챕터 03 배포
     │   │
     │   └─ 예
     │        │
     │        ├─ 기존 계정에 이미 모델이 배포되어 있는가?
     │        │   │
     │        │   ├─ 예 → Brownfield 적합
     │        │   │        → 챕터 04 기존 Foundry 재사용
     │        │   │
     │        │   └─ 아니오 → Greenfield 권장 (모델 없는 계정 재사용 의미 없음)
     │        │               → 챕터 03 배포
     │        │
     │        └─ 계정에 대한 Contributor 권한이 있는가?
     │            (PE 생성 및 속성 변경 필요)
     │            │
     │            ├─ 예 → Brownfield 가능
     │            └─ 아니오 → Greenfield 권장
```

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

3. **foundry_deployments 키 = 실제 배포 이름.** `foundry_deployments` tfvars의 map 키가 계정에 실제로 존재하는 배포 이름과 **정확히 일치**해야 합니다. 이 값이 `allowed_models`, 라우팅, Admin UI 레이블에 모두 사용됩니다.

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

| 결정 | 이동할 챕터 |
|---|---|
| **Greenfield** — 새 AIServices 계정 포함 전체 스택 | [03 배포](../03-deploy/overview.md) |
| **Brownfield** — 기존 Foundry 계정 재사용 | [04 기존 Foundry 재사용](../04-reuse-foundry/overview.md) |
