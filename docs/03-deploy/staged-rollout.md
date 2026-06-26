---
description: 운영자·DevOps 엔지니어를 위한 페이지 · worker_image/admin_ui_image count-gate를 활용한 단계적 배포 전략
---

# 단계적 배포 (Staged Rollout)

이 스택은 `worker_image`/`admin_ui_image` 변수가 빈 문자열이면 해당 리소스를 만들지 않는(count-gate) 구조라, 게이트웨이를 단계적으로 올릴 수 있습니다. 모든 컴포넌트를 한꺼번에 배포할 필요 없이 필요한 시점에 각 레이어를 추가할 수 있습니다.

***

## 1. 전체 3단계 구조

<!-- diagram: staged-rollout -->
<div style="display:flex; align-items:stretch; gap:10px; font-family:'Segoe UI','Noto Sans KR',sans-serif; margin:16px 0;">
  <div style="flex:1; background:#EEF6FC; border-left:4px solid #0078D4; border-radius:4px; padding:14px;">
    <div style="font-size:11px; letter-spacing:1px; color:#0078D4; font-weight:700;">STAGE 1 · 코어</div>
    <div style="font-size:15px; font-weight:700; color:#0a2540; margin:6px 0;">게이트웨이 코어</div>
    <div style="font-size:12px; color:#1a1a2e; line-height:1.7;">▸ APIM + 3개 API<br>▸ 정적 거버넌스<br>▸ 구독 키 발급<br>▸ 모델 호출 가능</div>
  </div>
  <div style="display:flex; align-items:center; color:#0078D4; font-weight:700; font-size:12px; padding:0 4px;">+</div>
  <div style="flex:1; background:#F4F6FA; border-left:4px solid #556677; border-radius:4px; padding:14px;">
    <div style="font-size:11px; letter-spacing:1px; color:#556677; font-weight:700;">STAGE 2 · UI</div>
    <div style="font-size:15px; font-weight:700; color:#0a2540; margin:6px 0;">Admin UI 추가</div>
    <div style="font-size:12px; color:#1a1a2e; line-height:1.7;">▸ Entra 앱 등록 3종<br>▸ 셀프서비스 관리<br>▸ 소비자·키·정책 UI<br>▸ (worker 없음)</div>
  </div>
  <div style="display:flex; align-items:center; color:#0078D4; font-weight:700; font-size:12px; padding:0 4px;">+</div>
  <div style="flex:1; background:#EEF7F0; border-left:4px solid #107C41; border-radius:4px; padding:14px;">
    <div style="font-size:11px; letter-spacing:1px; color:#107C41; font-weight:700;">STAGE 3 · WORKER</div>
    <div style="font-size:15px; font-weight:700; color:#0a2540; margin:6px 0;">config-sync worker 추가</div>
    <div style="font-size:12px; color:#1a1a2e; line-height:1.7;">▸ Cosmos→APIM 동기화<br>▸ 소비자별 동적 설정<br>▸ 예산 기반 모델 전환<br>▸ 전체 기능 활성</div>
  </div>
</div>
<!-- /diagram -->

***

## 2. Stage 1 — 게이트웨이 코어

***

`worker_image`와 `admin_ui_image`를 모두 빈 문자열로 두고 첫 번째 apply를 실행합니다.

```hcl
# infra/terraform.tfvars
worker_image   = ""
admin_ui_image = ""
```

**첫 번째 apply로 완전히 동작하는 항목:**

- **APIM** + 3개 API(`/openai`, `/vscode/openai`, `/foundry`) + 정책 + 백엔드 (greenfield 신규 생성 또는 brownfield 재사용)
- **거버넌스는 정적** — `terraform.tfvars`의 `allowed_models`/`rate_tiers`/`tokens_per_minute`가 전역 적용되고, `consumer-config-json`은 빈 번들(`e30=`)이라 모든 소비자가 전역 기본값을 사용합니다.
- 구독 키는 Azure 포털 또는 `az apim subscription create`로 발급합니다.
- 클라이언트가 구독 키를 헤더에 포함해 모델을 호출할 수 있습니다(완전한 게이트웨이).

{% content-ref url="first-apply.md" %}
[첫 번째 terraform apply](first-apply.md)
{% endcontent-ref %}

***

## 3. Stage 2 — Admin UI 추가

***

이미지를 빌드한 뒤 `admin_ui_image` 변수를 설정하고, Entra ID 앱 등록 3종을 완료한 다음 두 번째 apply를 실행합니다.

**준비 순서:**

1. ACR이 첫 번째 apply에서 이미 생성되어 있어야 합니다.
2. `az acr build`로 `admin-ui` 이미지를 빌드·푸시합니다.
3. `./scripts/app-registration.sh`로 Entra 앱 등록을 완료합니다 — **Admin UI 배포보다 먼저** 실행해야 합니다.
4. `terraform.tfvars`에 아래 값을 채웁니다.

```hcl
admin_ui_image        = "<registry_login_server>/admin-ui:latest"
admin_ui_public       = true
admin_group_object_id = "<entra security group object id>"
bff_api_audience      = "api://<bff app id>"
spa_client_id         = "<spa app id>"
```

**이 단계 이후 활성화되는 기능:**

- 셀프서비스 소비자·키·정책 관리 UI
- Admin UI를 통한 소비자 등록 및 구독 키 발급

**아직 비활성 (worker 없음):**

- Cosmos→APIM 동기화 없음 → 소비자별 동적 설정 미반영
- 예산 기반 **모델 전환**(`active_downgrade.level`) 비활성

{% content-ref url="build-push-images.md" %}
[이미지 빌드·푸시](build-push-images.md)
{% endcontent-ref %}

{% content-ref url="app-registration-second-apply.md" %}
[앱 등록 및 두 번째 apply](app-registration-second-apply.md)
{% endcontent-ref %}

***

## 4. Stage 3 — config-sync worker 추가

***

`worker_image` 변수를 설정하고 apply를 재실행한 뒤 Cosmos DB seed를 완료합니다.

**준비 순서:**

1. `az acr build`로 `config-sync-worker` 이미지를 빌드·푸시합니다.
2. `terraform.tfvars`에 아래 값을 채웁니다.

```hcl
worker_image = "<registry_login_server>/config-sync-worker:latest"
```

3. `terraform apply`를 다시 실행합니다(두 번째 또는 세 번째 apply).
4. apply 완료 후 Cosmos DB seed를 실행합니다 — **worker 배포보다 먼저** seed를 완료해야 초기 동기화가 올바르게 수행됩니다.

**이 단계 이후 활성화되는 기능:**

- Cosmos DB → APIM Named Values 동기화(약 5분 cron)
- 소비자별 `allowed_models`/tier override
- 예산 기반 **모델 전환**(`active_downgrade.level`) 활성
- 전체 기능 완전 운영

{% content-ref url="seed-and-finalize.md" %}
[Seed 및 최종 설정](seed-and-finalize.md)
{% endcontent-ref %}

***

## 5. 단계별 기능 비교표

***

| 기능 | Stage 1 | Stage 2 | Stage 3 |
|---|:---:|:---:|:---:|
| APIM 라우팅 (`/openai`, `/vscode/openai`, `/foundry`) | ✓ | ✓ | ✓ |
| 정적 거버넌스 (`allowed_models`/`rate_tiers`/`tokens_per_minute`) | ✓ | ✓ | ✓ |
| 구독 키 기반 모델 호출 | ✓ | ✓ | ✓ |
| Brownfield Foundry 재사용 | ✓ | ✓ | ✓ |
| Admin UI 셀프서비스 관리 | — | ✓ | ✓ |
| 소비자별 동적 설정 (Cosmos→APIM 동기화) | — | — | ✓ |
| 예산 기반 모델 전환 (`active_downgrade`) | — | — | ✓ |
| 소비자별 `allowed_models`/tier override | — | — | ✓ |

***

## 6. 의존 순서 정리

***

```
첫 번째 apply (ACR 포함)
    ↓
az acr build (worker + admin-ui 이미지)
    ↓
./scripts/app-registration.sh  ← Admin UI 배포 전 필수
    ↓
tfvars 업데이트 (admin_ui_image + Entra 값)
    ↓
두 번째 apply (Admin UI + worker 동시 또는 순차)
    ↓
Cosmos DB seed  ← worker 동기화 전 필수
    ↓
az containerapp job start (config-sync 즉시 트리거)
```

{% hint style="warning" %}
**순서 중요:** Entra 앱 등록(`app-registration.sh`)은 Admin UI 배포보다 먼저 완료해야 합니다. Cosmos seed는 config-sync worker가 첫 번째 동기화를 수행하기 전에 완료해야 합니다.
{% endhint %}

Brownfield 경로(기존 Foundry 재사용)를 선택한 경우 Stage 1 이전에 계정 잠금 준비가 선행되어야 합니다.

{% content-ref url="../04-reuse-foundry/overview.md" %}
[기존 Foundry 재사용](../04-reuse-foundry/overview.md)
{% endcontent-ref %}
