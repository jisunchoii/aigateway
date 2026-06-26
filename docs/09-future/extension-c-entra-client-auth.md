---
description: 보안 담당자·플랫폼 엔지니어를 위한 페이지 · 선행: 확장 개요
---

# 확장 C — Entra ID 클라이언트 인증 (구독 키 미사용)

이 확장은 **이미 코드에 구현되어 있습니다**. `client_auth_mode="entra-id"` 변수 토글로 활성화할 수 있으며, APIM 정책이 구독 키 대신 JWT(Entra ID 토큰)로 클라이언트를 인증합니다. 운영 환경 검증이 완료되지 않아 확장 항목으로 분류합니다.

{% hint style="info" %}
토글 구현은 완료되어 있으나 운영 환경 검증 전입니다. 아래 체크리스트를 완료한 뒤 운영에 투입합니다.
{% endhint %}

---

## 1. 현재 구현 상태

***

| 항목 | 상태 |
|---|---|
| `client_auth_mode="entra-id"` 토글 | 구현 완료 |
| `validate-jwt` 정책 | 구현 완료 |
| consumerId = JWT claim 추출 | 구현 완료 |
| `subscription_required=false` | 구현 완료 |
| 운영 환경 검증 | **미완료** |

---

## 2. 동작 방식

***

`client_auth_mode="entra-id"`로 설정하면 APIM inbound 정책이 아래와 같이 바뀝니다.

#### Step 1. JWT 검증

`validate-jwt` 정책이 `Authorization: Bearer <token>` 헤더를 검증합니다.

#### Step 2. consumerId 추출

JWT의 지정된 claim 값을 `consumerId`로 추출합니다.

#### Step 3. 거버넌스 파이프라인 통과

이후 allowed-models 검사, rate limit, 예산 모델 전환 등 모든 거버넌스 파이프라인은 동일하게 동작합니다.

구독 키 검증이 없으므로 `subscription_required=false`로 설정해야 합니다.

([APIM validate-jwt 정책 공식 문서](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy))

---

## 3. consumerId 설계 — 권고 사항

***

`client_auth_mode="entra-id"` 모드에서 consumerId를 어떤 JWT claim에서 가져올지는 중요한 설계 결정입니다.

### groups claim 사용의 문제점

Azure Entra ID는 사용자가 속한 그룹을 JWT `groups` claim에 포함합니다. 그러나 이 방식에는 한계가 있습니다.

- `groups` claim에는 **GUID**가 들어옵니다 (사람이 읽기 어려움)

{% hint style="warning" %}
사용자가 **150개 초과** 그룹에 속해 있으면 `groups` claim이 누락되고 Graph API 조회 링크로 대체됩니다 (over-claim 문제). consumerId 추출이 실패하므로 대규모 조직에서 `groups` claim에 의존하면 안 됩니다.
{% endhint %}

### 권고: custom app-role 또는 extension attribute

consumerId로 사용할 단일 값을 명시적으로 표현하려면 아래 방법 중 하나를 권장합니다.

| 방법 | 설명 |
|---|---|
| **Custom app-role** | BFF API 앱 등록에 app-role 정의 → 사용자/그룹에 역할 할당 → JWT `roles` claim으로 수신 |
| **Extension attribute** | `user.extension_<appId>_consumerId` 형태로 디렉터리 확장 속성 정의 → JWT에 포함 |

두 방법 모두 단일 값으로 consumerId를 명확히 표현할 수 있고, groups over-claim 문제를 피할 수 있습니다.

([Azure Entra ID app roles 공식 문서](https://learn.microsoft.com/en-us/entra/identity-platform/howto-add-app-roles-in-apps))

---

## 4. 설정 예시

***

```hcl
# infra/terraform.tfvars
client_auth_mode = "entra-id"
entra_tenant_id  = "<your-tenant-id>"
api_audience     = "api://<bff-app-id>"
team_claim       = "roles"   # 또는 extension attribute 이름
```

`team_claim` 변수가 consumerId를 추출할 JWT claim 이름을 지정합니다.

---

## 5. 운영 투입 전 체크리스트

***

- [ ] BFF API 앱 등록에 app-role 또는 extension attribute 정의
- [ ] 테스트 사용자/서비스 주체에 역할 할당 후 JWT claim 포함 여부 확인
- [ ] `validate-jwt` 정책의 audience, issuer, claim 추출 동작 검증
- [ ] `subscription_required=false` 상태에서 무인증 요청이 401로 차단되는지 확인
- [ ] rate limit, allowed-models 검사가 JWT 기반 consumerId로 정상 동작하는지 smoke test

---

## 6. 참고 문서

***

- [APIM validate-jwt 정책](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy)
- [Azure Entra ID app roles 설정 방법](https://learn.microsoft.com/en-us/entra/identity-platform/howto-add-app-roles-in-apps)
- [정책 흐름](../08-architecture/policy-flow.md) — consumerId 도출 단계 상세
- [보안 설계](../08-architecture/security-design.md) — 전체 passwordless 아키텍처
- [확장 개요](overview.md) — 권장 구현 순서 (C → A → B)
