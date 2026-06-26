---
description: 운영자·DevOps 엔지니어를 위한 페이지 · 선행: Greenfield vs Brownfield 결정
---

# 배포 개요

이 챕터는 llm-gateway를 Azure에 처음 배포하는 전체 흐름을 안내합니다. 배포는 크게 두 경로로 나뉩니다.

## 1. 배포 경로 선택

***

| 경로 | 설명 | 언제 선택? |
|---|---|---|
| **Greenfield** | Azure OpenAI 계정과 모델 배포를 Terraform이 새로 생성 | 신규 구독 또는 기존 AIServices 계정 재사용 불필요 |
| **Brownfield** | 기존 AIServices(Foundry) 계정을 `data`로 읽어 재사용, PE·RBAC만 신규 생성 | 이미 운영 중인 Azure OpenAI/Foundry 계정이 있는 경우 |

Brownfield 경로를 선택했다면 이 챕터의 절차를 따른 뒤 [기존 Foundry 재사용](../04-reuse-foundry/overview.md) 챕터의 추가 준비 단계를 반드시 먼저 완료하십시오.

## 2. 전체 배포 단계

***

{% columns %}
{% column width="50%" %}
{% content-ref url="bootstrap-state.md" %}
[상태 백엔드 부트스트랩](bootstrap-state.md)
{% endcontent-ref %}

{% content-ref url="configure-tfvars.md" %}
[tfvars 구성](configure-tfvars.md)
{% endcontent-ref %}

{% content-ref url="first-apply.md" %}
[첫 번째 terraform apply](first-apply.md)
{% endcontent-ref %}
{% endcolumn %}

{% column width="50%" %}
{% content-ref url="build-push-images.md" %}
[이미지 빌드·푸시](build-push-images.md)
{% endcontent-ref %}

{% content-ref url="app-registration-second-apply.md" %}
[앱 등록 및 두 번째 apply](app-registration-second-apply.md)
{% endcontent-ref %}

{% content-ref url="seed-and-finalize.md" %}
[Seed 및 최종 설정](seed-and-finalize.md)
{% endcontent-ref %}
{% endcolumn %}
{% endcolumns %}

## 3. 전제 조건 확인

***

배포를 시작하기 전에 다음이 준비되어 있어야 합니다.

- `az login` 완료 및 대상 구독 활성화
- Terraform ≥ 1.7 설치 (Docker 불필요 — ACR remote build 사용)
- Azure CLI 최신 버전
- [사전 준비 챕터](../02-prerequisites/azure-requirements.md)의 모든 항목 완료

{% hint style="warning" %}
**Brownfield 경로:** `reuse_foundry = true`를 설정하기 전에 [기존 Foundry 재사용 — 계정 잠금 준비](../04-reuse-foundry/prepare-account.md)를 먼저 완료하십시오.
{% endhint %}

{% content-ref url="../04-reuse-foundry/overview.md" %}
[기존 Foundry 재사용](../04-reuse-foundry/overview.md)
{% endcontent-ref %}
