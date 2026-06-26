---
description: 인프라·플랫폼 엔지니어를 위한 페이지 · 선행: Azure 요구사항
---

# Entra ID 객체

Terraform은 대부분의 Azure 리소스를 자동 생성하지만, **Entra ID 객체 3종은 Terraform이 생성할 수 없습니다**. 첫 배포 전 한 번만 수동으로 생성하면 됩니다. `./scripts/app-registration.sh` 스크립트가 이 과정을 자동화합니다.

---

## 왜 Terraform이 생성하지 못하는가

`azurerm` provider는 Entra ID(구 Azure AD) 앱 등록과 그룹 생성을 직접 지원하지 않습니다. `azuread` provider를 별도로 구성해야 하며, 권한 분리 원칙상 IaC 실행자에게 디렉터리 쓰기 권한을 주지 않는 조직도 많습니다. 따라서 Entra ID 객체는 스크립트로 먼저 생성하고, 생성된 ID를 tfvars에 입력하는 방식을 취합니다.

{% hint style="info" %}
**📸 [스크린샷 자리]** — Azure Portal — Entra ID 보안 그룹 생성 화면
{% endhint %}

---

## 3종 객체 상세

### ① Admin 보안 그룹

Admin UI에 접근할 수 있는 사용자 그룹입니다. Entra ID 보안 그룹의 Object ID를 tfvars에 전달합니다.

| 속성 | 값 |
|---|---|
| 유형 | Entra ID 보안 그룹 |
| 목적 | Admin UI 접근 제어 (그룹 멤버만 관리 기능 접근 가능) |
| tfvars 변수 | `admin_group_object_id` |

```hcl
# infra/terraform.tfvars
admin_group_object_id = "<entra security group object id>"
```

참고: [Microsoft Entra 보안 그룹 관리](https://learn.microsoft.com/ko-kr/entra/fundamentals/how-to-manage-groups)

---

### ② BFF API 앱등록

Admin UI의 FastAPI BFF(Backend For Frontend)가 사용하는 앱 등록입니다. SPA가 이 API에 접근할 때 Bearer 토큰을 발급받는 대상(audience)이 됩니다.

| 속성 | 값 |
|---|---|
| 유형 | Entra ID 앱 등록 (웹 API) |
| 노출 스코프 | `access_as_user` |
| 토큰 버전 | `requestedAccessTokenVersion=2` (v2.0 토큰) |
| tfvars 변수 | `bff_api_audience` |

```hcl
# infra/terraform.tfvars
bff_api_audience = "api://<bff app id>"
```

`bff_api_audience` 형식은 반드시 `api://` 접두사를 포함합니다. 앱 등록 생성 후 **앱 ID URI**를 확인하세요.

참고: [앱 등록에 API 범위 노출](https://learn.microsoft.com/ko-kr/entra/identity-platform/quickstart-configure-app-expose-web-apis)

---

### ③ SPA public-client 앱등록

Admin UI React SPA가 사용하는 public-client 앱 등록입니다. 시크릿이 없고 PKCE 흐름으로 인증합니다.

| 속성 | 값 |
|---|---|
| 유형 | Entra ID 앱 등록 (SPA, public client) |
| 인증 흐름 | Authorization Code + PKCE (시크릿 없음) |
| redirect URI | Admin UI FQDN (`https://<admin-ui-fqdn>`) — 두 번째 apply 후 등록 |
| tfvars 변수 | `spa_client_id` |

```hcl
# infra/terraform.tfvars
spa_client_id = "<spa app id>"
```

redirect URI는 두 번째 `terraform apply` 이후 `admin_ui_fqdn` 출력값이 확정되면 등록합니다. 자동화된 등록 명령은 [배포 — Seed 및 최종 설정](../03-deploy/seed-and-finalize.md)을 참고하세요.

참고: [단일 페이지 앱 등록](https://learn.microsoft.com/ko-kr/entra/identity-platform/scenario-spa-app-registration)

---

## app-registration.sh 스크립트

위 3종 객체를 한 번에 생성하는 스크립트입니다.

```bash
# 사전 조건: az login 완료, 구독 설정 완료
./scripts/app-registration.sh
```

스크립트 실행 후 출력되는 값을 `infra/terraform.tfvars`에 입력합니다.

```hcl
admin_group_object_id = "<출력된 그룹 Object ID>"
bff_api_audience      = "api://<출력된 BFF App ID>"
spa_client_id         = "<출력된 SPA App ID>"
```

---

## 객체 → tfvars 변수 매핑 요약

| Entra ID 객체 | tfvars 변수 | 예시 값 |
|---|---|---|
| Admin 보안 그룹 | `admin_group_object_id` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| BFF API 앱등록 | `bff_api_audience` | `api://yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy` |
| SPA public-client | `spa_client_id` | `zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz` |

---

## 다음 단계

- [Greenfield vs Brownfield 결정](decide-greenfield-vs-brownfield.md)
