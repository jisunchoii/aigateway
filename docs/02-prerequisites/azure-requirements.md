---
description: 인프라·플랫폼 엔지니어를 위한 페이지 · 선행: 핵심 개념
---

# Azure 요구사항

## 구독·권한

- **Azure 구독** 1개 이상 필요. 게이트웨이 리소스(APIM, AIServices, Cosmos DB, Container Apps 등)가 모두 같은 구독에 배포됩니다.
- 배포 실행자는 해당 구독에서 **Contributor + User Access Administrator** 역할(또는 동등한 커스텀 역할)이 필요합니다. Terraform이 RBAC 역할 할당을 자동으로 수행하기 때문입니다.

---

## 모델 쿼터

배포 전에 아래 모델의 쿼터가 목표 지역에 충분히 확보되어 있는지 확인하세요.

| 모델 | 타입 | 쿼터 확인 위치 |
|---|---|---|
| gpt-5.4 | Azure OpenAI | Azure 포털 → Azure OpenAI → 쿼터 |
| gpt-5.4-mini | Azure OpenAI | 동일 |
| grok-4.3 | Azure AI Foundry (파트너) | Azure 포털 → AI Foundry 허브 |
| DeepSeek-V4-Pro | Azure AI Foundry (파트너) | 동일 |

{% hint style="info" %}
**파트너 모델 참고:** grok-4.3, DeepSeek-V4-Pro 등 파트너 모델은 테넌트에서 **마켓플레이스 약관 동의**가 필요할 수 있습니다. Azure 포털의 배포 플로우에서 약관에 동의한 뒤 재시도하세요.
{% endhint %}

기본 쿼터가 낮은 경우 [Azure OpenAI 쿼터 증설 요청](https://learn.microsoft.com/ko-kr/azure/ai-services/openai/quotas-limits)을 통해 사전에 증설하세요.

---

## 지원 지역

검증된 지역:

- `koreacentral` (기본값, Terraform 변수 `location`)
- `eastus2`

APIM Developer/Premium SKU와 AIServices VNet 통합이 지원되는 지역이면 대부분 동작합니다. 지역별 서비스 가용성은 [Azure 제품 지역별 가용성](https://azure.microsoft.com/ko-kr/explore/global-infrastructure/products-by-region/)에서 확인하세요.

---

## 필요 도구

로컬 머신에 아래 도구만 있으면 됩니다. **Docker는 불필요**합니다(컨테이너 이미지는 Azure Container Registry remote build로 처리).

| 도구 | 최소 버전 | 설치·확인 |
|---|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) | ≥ 1.7 | `terraform version` |
| [Azure CLI](https://learn.microsoft.com/ko-kr/cli/azure/install-azure-cli) | 최신 안정 | `az version` |
| az login | — | `az login` 으로 구독 인증 |

```bash
# 버전 확인
terraform version
az version

# Azure 로그인 (Entra ID 기반)
az login
az account set --subscription "<구독 ID>"
```

{% hint style="info" %}
**인증 방식:** 모든 Azure CLI 및 Terraform 작업은 `az login`으로 얻은 Entra ID 기반 토큰을 사용합니다. API 키나 서비스 주체 시크릿을 환경 변수에 노출하지 않습니다.
{% endhint %}

---

## Terraform azurerm provider

`infra/providers.tf`에서 `hashicorp/azurerm` 공급자 버전이 고정되어 있습니다. 첫 `terraform init` 시 자동 다운로드됩니다.

```bash
cd infra
terraform init
```

공급자 문서: [azurerm Terraform Registry](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)

---

## 다음 단계

- [Entra ID 객체](entra-objects.md) — Admin 그룹, BFF API 앱등록, SPA 앱등록 생성
- [Greenfield vs Brownfield 결정](decide-greenfield-vs-brownfield.md) — 어느 배포 경로를 선택할지 결정
