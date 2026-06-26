---
description: 플랫폼 엔지니어 (Terraform 담당)를 위한 페이지 · 선행: 계정 잠금 사전 준비
---

# tfvars 설정 — 재사용 모드

기존 Foundry 계정을 재사용하는 경우, `infra/terraform.tfvars`에 아래 변수들을 추가하거나 수정한다.
그린필드 배포 시 사용하는 나머지 변수(`prefix`, `location`, `owner` 등)는 [03-deploy/configure-tfvars.md](../03-deploy/configure-tfvars.md)를 참고한다.

## 핵심 스위치

```hcl
reuse_foundry         = true
existing_foundry_name = "ais-customer-prod"
existing_foundry_rg   = "rg-customer-ai"
```

| 변수 | 설명 |
|---|---|
| `reuse_foundry` | `true`로 설정하면 재사용 모드 활성화. `false`(기본)이면 새 AIServices 계정을 생성하는 greenfield 모드. |
| `existing_foundry_name` | 재사용할 AIServices 계정의 Azure 리소스 이름 (포털·`az resource list`에서 확인). |
| `existing_foundry_rg` | 해당 계정이 속한 리소스 그룹 이름. 게이트웨이 RG와 달라도 된다. |

## foundry\_deployments: 이미 존재하는 모델 선언

```hcl
foundry_deployments = {
  "grok-4.3"         = { model_name = "grok-4.3",          sku = "GlobalStandard", capacity = 1 }
  "DeepSeek-V4-Pro"  = { model_name = "DeepSeek-V4-Pro",   sku = "GlobalStandard", capacity = 1 }
}
```

{% hint style="danger" %}
**중요: 키가 실제 배포 이름과 완전히 일치해야 한다.**

`foundry_deployments`의 키(map key)는 AIServices 계정에 실제로 존재하는 배포 이름이어야 한다.
Azure 포털 → AI Foundry → 해당 계정 → "모델 배포"에서 배포 이름을 확인할 수 있다.

키가 틀리면 다음 세 곳이 **조용히(silently) 깨진다**:
- `allowed_models` 검사: 허용 목록에 없는 모델로 인식되어 403 반환
- 라우팅: 잘못된 모델 이름이 백엔드 요청 body에 들어가 404/422 반환
- Admin UI 라벨: 존재하지 않는 배포 이름이 표시되어 운영 혼란 야기
{% endhint %}

재사용 모드에서 `foundry_deployments`는 모델을 **생성하지 않는다**(`for_each={}` 처리됨).
기존 배포가 실제로 있는지 선언하는 역할만 하며, 그 값을 기반으로 allowed\_models, 라우팅, Admin UI 라벨이 구성된다.

## openai\_deployments는 무시된다

재사용 모드(`reuse_foundry=true`)에서는 `openai_deployments` 변수가 무시된다.
`modules/openai`의 `count=0`이 되어 별도 Azure OpenAI 리소스가 생성되지 않으며, gpt 계열 요청도 `existing_foundry_name` 계정의 `/openai/v1` 엔드포인트로 라우팅된다.

따라서 재사용 모드에서는 tfvars에서 `openai_deployments`를 정의하지 않거나, 정의하더라도 실제로 적용되지 않는다.

## 전체 재사용 tfvars 예시

```hcl
# -- 공통 (greenfield와 동일) --
prefix         = "aigw"
env            = "dev"
location       = "koreacentral"
owner          = "<owner>"
cost_center    = "<cost-center>"
apim_public    = true

# -- 재사용 모드 --
reuse_foundry         = true
existing_foundry_name = "ais-customer-prod"
existing_foundry_rg   = "rg-customer-ai"

# foundry_deployments: 키 = 실제 배포 이름 (대소문자 포함 정확히 일치)
foundry_deployments = {
  "grok-4.3"         = { model_name = "grok-4.3",         sku = "GlobalStandard", capacity = 1 }
  "DeepSeek-V4-Pro"  = { model_name = "DeepSeek-V4-Pro",  sku = "GlobalStandard", capacity = 1 }
}

# -- 예산·레이트 리밋 (greenfield와 동일) --
monthly_budget_amount = 200
budget_alert_email    = "<email>"
budget_start_date     = "<YYYY-MM-01>"
```

## 다음 단계

tfvars 편집을 마쳤으면 [plan & apply](plan-and-apply.md)로 넘어간다.
