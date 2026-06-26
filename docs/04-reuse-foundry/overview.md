---
description: 기존 Azure AI Foundry 계정을 보유한 플랫폼 엔지니어를 위한 페이지 · 선행: 없음 (챕터 진입점)
---

# 기존 Foundry 재사용 개요

이 챕터는 이미 구독에 Azure AIServices(Foundry) 계정이 존재하는 **brownfield** 시나리오를 다룹니다.
게이트웨이는 기존 계정과 그 안의 모델 배포를 **전혀 건드리지 않고**, Private Endpoint와 RBAC만 새로 추가해 붙습니다.

## 1. 핵심 원리: "data로 읽기 + PE/RBAC만 신규"

***

재사용 모드(`reuse_foundry=true`)에서 Terraform은 기존 AIServices 계정을 `data` 소스로 참조합니다.
계정 생성(`azurerm_cognitive_account`)도 모델 배포(`azurerm_cognitive_deployment`)도 없습니다.
대신 게이트웨이 VNet에서 기존 계정 쪽으로 새 Private Endpoint를 뻗고, APIM의 Managed Identity에 필요한 RBAC 역할을 부여합니다.

고객 계정은 수정되지 않으며, 이미 서비스 중인 모델 배포는 그대로 유지됩니다.
게이트웨이는 그 위에 얹히는 거버넌스 레이어일 뿐입니다.

## 2. Greenfield vs Brownfield 리소스 비교

***

| 리소스 | greenfield (기본) | brownfield (`reuse_foundry=true`) |
|---|---|---|
| 게이트웨이 RG | 생성 (별도 RG) | 생성 (별도 RG, 변경 없음) |
| AIServices 계정 | `azurerm_cognitive_account` 생성 | **data로 읽기** (생성 안 함) |
| 모델 배포 | `azurerm_cognitive_deployment` 생성 | **생성 안 함** (`for_each={}`) |
| 계정 속성(local\_auth off·public block) | Terraform이 설정 | **배포 전 `az` 토글 + precondition 검증** |
| Private Endpoint | 생성 | **생성** (게이트웨이 VNet → 기존 계정) |
| APIM MI RBAC | 부여 | **부여** |

단일 AIServices 계정이 gpt 계열과 OSS 모델(grok-4.3, DeepSeek-V4-Pro)을 함께 호스팅합니다.
재사용 모드에서는 `modules/openai`의 `count=0`이 되어 별도 OpenAI 리소스를 만들지 않으며, gpt 요청도 동일한 AIServices 계정의 `/openai/v1` 엔드포인트로 라우팅됩니다.

## 3. 같은 구독 제약

***

재사용 모드는 **동일 Azure 구독** 내에서만 동작합니다.
기존 Foundry 계정이 다른 구독에 있는 경우에는 재사용 모드를 사용할 수 없으며, 별도 구독 간 시나리오는 현재 지원 범위 밖입니다.

## 4. Foundry가 다른 RG/VNet에 있어도 괜찮은 이유

***

게이트웨이는 기존 Foundry의 VNet 안에 들어가는 게 아니라, **게이트웨이 전용 VNet에서 기존 계정을 향해 새 Private Endpoint를 뻗는** 방식을 취합니다.
따라서 Foundry가 완전히 다른 리소스 그룹이나 별도 VNet에 있어도 문제없습니다.
Private Endpoint는 구독 내에서 계정 resource ID만 알면 생성할 수 있습니다.

## 5. 왜 이 방식이 안전한가

***

- **고객 계정 무수정**: `az` 명령으로 `disableLocalAuth`와 `publicNetworkAccess`를 잠그는 것은 고객이 직접 사전 작업으로 수행하며, Terraform이 계정 속성을 변경하지 않습니다.
- **모델 무수정**: 기존 모델 배포에 대한 `create/update/delete` 동작이 전혀 없습니다.
- **최소 권한 RBAC**: APIM Managed Identity에는 `Cognitive Services OpenAI User` 등 필요한 역할만 부여되며, 키 기반 접근은 비활성화 상태를 유지합니다.
- **격리된 네트워크 경로**: 새 PE는 게이트웨이 VNet에 귀속되므로, 기존 Foundry의 네트워크 구성을 바꾸지 않습니다.

## 6. 참고 문서

***

- [Azure AI Services (Cognitive Services) 개요](https://learn.microsoft.com/ko-kr/azure/ai-services/what-are-ai-services)
- [Azure Private Endpoint란?](https://learn.microsoft.com/ko-kr/azure/private-link/private-endpoint-overview)
- [Azure RBAC란?](https://learn.microsoft.com/ko-kr/azure/role-based-access-control/overview)
- [Azure AI Foundry에서 관리 ID 사용](https://learn.microsoft.com/ko-kr/azure/ai-foundry/how-to/managed-identity)

## 7. 이 챕터의 구성

***

{% content-ref url="prepare-account.md" %}
[계정 잠금 사전 준비](prepare-account.md)
{% endcontent-ref %}

{% content-ref url="configure-tfvars.md" %}
[tfvars 설정](configure-tfvars.md)
{% endcontent-ref %}

{% content-ref url="plan-and-apply.md" %}
[plan & apply](plan-and-apply.md)
{% endcontent-ref %}
