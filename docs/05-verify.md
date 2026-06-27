---
description: "배포 검증 — 스모크 테스트, 백엔드 격리 진단"
---

# 검증

이 챕터에서는 게이트웨이 배포 후 정상 동작 여부를 확인하는 두 가지 절차를 다룹니다.

- [스모크 테스트 (public APIM)](#1-스모크-테스트-public-apim)
- [백엔드 격리 진단](#2-백엔드-격리-진단)

## 1. 스모크 테스트 (public APIM)

***

{% hint style="info" %}
`apim_public = true`로 배포한 경우, 게이트웨이 VIP는 인터넷에 공개되어 있으므로 **로컬 노트북에서 바로** 스모크를 실행할 수 있습니다. jumpbox는 필요하지 않습니다.
{% endhint %}

### 1. 전제 조건

***

| 항목 | 확인 방법 |
|---|---|
| APIM 호스트 이름 | `terraform output -raw apim_gateway_url` → `https://<apim-host>` |
| 구독 키 | Admin UI 또는 Azure Portal APIM > Subscriptions 에서 발급 |
| `apim_public = true` | `terraform.tfvars` 확인 |

#### 구독 키 발급

**Admin UI 경유:** `https://<admin_ui_fqdn>` → 로그인 → Subscriptions → 새 키 생성.

**Azure Portal 경유:** APIM 리소스 → **Subscriptions** 블레이드 → **Add subscription** 또는 기존 키의 **Show/regenerate**.

---

### 2. 스모크 스크립트 실행

***

```bash
./scripts/smoke-v1-gateway.sh <apim-host> <subscription-key>
```

스크립트는 아래 **4개 체크**를 순서대로 수행하며, 각각 HTTP 200을 기대합니다.

| # | 모델 | APIM 입구 | 설명 |
|---|---|---|---|
| 1 | `gpt-5.4` | `/openai` (path-route) | path → v1 body 변환 확인 |
| 2 | `grok-4.3` | `/foundry` (body-route) | OSS 모델 엔드-투-엔드 |
| 3 | `DeepSeek-V4-Pro` | `/foundry` (body-route) | 파트너 모델 엔드-투-엔드 |
| 4 | `gpt-5.4` (max_completion_tokens) | `/openai` | `max_completion_tokens` 파라미터 통과 확인 |

{% hint style="success" %}
모든 체크가 통과하면 스크립트는 **ALL PASSED** 를 출력합니다. 이 절차는 라이브 환경에서 검증 완료되었습니다.
{% endhint %}

---

### 3. 결과 해석

***

| 결과 | 의미 | 다음 단계 |
|---|---|---|
| ALL PASSED | 게이트웨이 엔드-투-엔드 정상 | 클라이언트 연결로 이동 |
| 403 | allowed-models 정책에서 차단 | `allowed_models` 변수 확인 → [gotchas](10-reference.md) |
| 429 | 레이트 리밋 초과 | 구독 키의 rate tier 확인 → [gotchas](10-reference.md) |
| 게이트웨이 200인데 백엔드 오류 | 정책 변환 문제 | 아래 『백엔드 격리 진단』 절 참조 |
| 스크립트 자체 실패 | `<apim-host>` 미도달 | `apim_public` 값 및 NSG 규칙 확인 |

---

### 4. 응답 헤더로 모델 전환 확인

***

APIM은 요청 처리 결과를 응답 헤더로 반환합니다. `curl -v` 출력에서 확인할 수 있습니다.

```
x-ai-gateway-requested-model: gpt-5.4
x-ai-gateway-effective-model: gpt-5.4-mini
x-ai-gateway-downgrade-level: 1
```

`effective-model`이 `requested-model`과 다르면 예산 기반 모델 전환이 발동한 것입니다. 정상 동작입니다.

---

### 5. 관련 문서

***

- 백엔드 격리 진단 → 아래 『백엔드 격리 진단』 절 참조
- 변수 레퍼런스 (`apim_public`, `allowed_models`) → [10-reference.md](10-reference.md)
- 트러블슈팅 / Gotchas → [10-reference.md](10-reference.md)
- 클라이언트 연결 → [07-connect-clients.md](07-connect-clients.md)

## 2. 백엔드 격리 진단

***

게이트웨이 스모크(`smoke-v1-gateway.sh`)가 실패했을 때, 문제가 **APIM 정책**에 있는지 **백엔드(AIServices 계정)**에 있는지를 격리하는 절차입니다.

### 1. 격리 원칙

***

```
클라이언트 → [APIM 정책] → 백엔드(AIServices, PE 전용)
```

{% hint style="info" %}
백엔드(AIServices)는 **Private Endpoint 전용**으로 구성되어 있어 VNet 안에서만 접근할 수 있습니다. 따라서 백엔드 직접 스모크는 **jumpbox(VNet 내부)** 에서만 실행해야 합니다.
{% endhint %}

---

### 2. 백엔드 직접 스모크 실행 (jumpbox에서)

***

jumpbox에 Bastion 또는 SSH로 접속한 뒤 아래 스크립트를 실행합니다.

```bash
./scripts/smoke-v1-backend.sh https://<ais>.openai.azure.com/openai/v1
```

`<ais>`는 AIServices 계정의 호스트 이름 프리픽스입니다. `config_store_endpoint` 출력값에서 계정명을 확인하거나, `terraform output -raw openai_endpoint` (greenfield 모드) 를 참고하세요.

{% hint style="info" %}
**reuse 모드** (`reuse_foundry = true`): `openai_endpoint` 출력이 null입니다. AIServices 계정 이름은 `existing_foundry_name` 변수 값을 사용하세요.
{% endhint %}

---

### 3. 결과 해석

***

| 백엔드 스모크 결과 | 게이트웨이 스모크 결과 | 원인 | 조치 |
|---|---|---|---|
| 200 | 실패 | **APIM 정책 문제** | 정책 XML 확인, `allowed_models` 점검, [gotchas](10-reference.md) 참고 |
| 실패 | 실패 | **백엔드 계정/RBAC 문제** | AIServices 계정 상태, APIM MI RBAC, PE 연결 확인 |
| 200 | 200 | 양쪽 정상 | — (스모크 통과) |

#### 백엔드 실패 시 주요 점검 항목

1. **APIM Managed Identity RBAC**: APIM 시스템 할당 MI에 `Cognitive Services OpenAI User` 역할이 AIServices 계정에 부여되어 있는지 확인합니다.
   - [Azure RBAC 역할 할당 확인](https://learn.microsoft.com/ko-kr/azure/role-based-access-control/check-access)

2. **Private Endpoint 상태**: AIServices 계정의 PE가 `Approved` 상태인지, DNS가 올바르게 구성되어 있는지 확인합니다.
   - [Azure Private Endpoint 개요](https://learn.microsoft.com/ko-kr/azure/private-link/private-endpoint-overview)

3. **RBAC/PE 전파 지연**: 첫 배포 직후라면 RBAC 전파에 수 분이 걸릴 수 있습니다. 잠시 후 재시도하세요.

4. **로컬 인증 비활성화 확인** (`reuse_foundry = true` 시): AIServices 계정의 `disableLocalAuth = true`인지 확인합니다.
   ```bash
   az resource show --ids <aiservices-account-id> \
     --query "properties.{disableLocalAuth:disableLocalAuth, publicNetworkAccess:publicNetworkAccess}" -o jsonc
   ```

5. **파트너 모델 약관 동의** (grok-4.3, DeepSeek-V4-Pro): 테넌트에서 마켓플레이스 약관 동의가 필요할 수 있습니다. 포털의 모델 배포 플로우에서 동의 후 재시도하세요.

---

### 4. jumpbox 활성화

***

{% hint style="warning" %}
`enable_jumpbox = false`(기본값)인 경우 jumpbox가 배포되지 않습니다. 백엔드 격리 진단이 필요하면 `terraform.tfvars`에 아래를 추가하고 재-apply합니다.

```hcl
enable_jumpbox         = true
jumpbox_admin_password = "<12자 이상 안전한 패스워드>"
```

Bastion + jumpbox VM은 비용이 추가됩니다. 진단 후 `enable_jumpbox = false`로 되돌리는 것을 권장합니다.
{% endhint %}

---

### 5. 관련 문서

***

- 스모크 테스트 (public APIM 경유) → 위 『스모크 테스트』 절 참조
- 변수 레퍼런스 (`enable_jumpbox`, `reuse_foundry`) → [10-reference.md](10-reference.md)
- Gotchas / 트러블슈팅 → [10-reference.md](10-reference.md)
- Brownfield 재사용 배포 → [04-reuse-foundry.md](04-reuse-foundry.md)
