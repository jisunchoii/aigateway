---
description: "시나리오 A — 기존 Entra 보안 그룹을 Admin UI 접근 제어에 연결하는 배포 가이드"
---

# 시나리오 A: 기존 Entra 그룹 연동


이 페이지는 조직에 이미 존재하는 [Microsoft Entra ID](https://learn.microsoft.com/ko-kr/entra/fundamentals/whats-new) 보안 그룹을 Admin UI 접근 제어에 그대로 연결하는 방법을 안내합니다. Terraform은 Entra 객체를 직접 만들지 않으므로, 그룹 Object ID를 조회해 `terraform.tfvars`에 직접 입력하면 됩니다.

## 1. 이 시나리오가 적합한 경우

***

아래 조건에 해당하면 이 시나리오를 선택하세요.

- 이미 "AI 관리자" 또는 이에 준하는 Entra 보안 그룹이 운영 중이다.
- 기존 그룹 멤버십을 그대로 Admin UI 접근 제어에 활용하고 싶다.
- `app-registration.sh`가 자동으로 만드는 "AI Gateway Admins" 그룹이 **불필요**하다.

이 시나리오에서 핵심은 단순합니다. `admin_group_object_id` 변수는 **기존 그룹의 Object ID를 그대로 받아 전달(pass-through)하는 문자열**이며, Terraform은 Entra 객체를 새로 생성하지 않습니다.

## 2. 기존 그룹 Object ID 확인

***

Azure CLI로 기존 그룹의 Object ID를 조회합니다.

```bash
az ad group show --group "<그룹-이름-또는-ID>" --query id -o tsv
```

예시 출력:

```
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

이 값을 복사해 두세요. 다음 단계에서 `terraform.tfvars`에 입력합니다.

{% hint style="info" %}
그룹 이름 대신 기존 Object ID를 직접 `--group` 인수로 사용해도 됩니다.
{% endhint %}

## 3. app-registration.sh 실행 — 그룹 생성 단계 건너뛰기

***

{% hint style="warning" %}
**주의 — 스크립트가 그룹을 무조건 생성합니다:** `scripts/app-registration.sh`는 "AI Gateway Admins"라는 새 그룹을 **항상** 생성합니다. "이미 그룹이 있으면 건너뛰기" 로직이 없습니다. 기존 그룹이 있는 경우 스크립트 전체를 그대로 실행하면 불필요한 그룹이 추가로 만들어집니다.
{% endhint %}

기존 그룹을 쓰는 경우 스크립트에서 **BFF API 앱 등록**과 **SPA 앱 등록** 두 객체만 생성하면 됩니다. 방법은 두 가지입니다.

**방법 1: 스크립트를 분리 실행** — 그룹 생성 블록을 건너뛰고 BFF·SPA 등록 부분만 실행합니다. 스크립트를 편집하거나 해당 `az ad group create` 명령을 주석 처리한 뒤 실행합니다.

**방법 2: 수동으로 BFF·SPA 객체 생성** — 이미 BFF API 앱과 SPA 앱이 존재한다면 해당 Object ID를 직접 조회해 아래 tfvars에 입력합니다.

```bash
# BFF API 앱 audience 조회 (이미 있는 경우)
az ad app show --id "<bff-app-id>" --query "identifierUris[0]" -o tsv

# SPA 앱 클라이언트 ID 조회 (이미 있는 경우)
az ad app show --id "<spa-app-id>" --query appId -o tsv
```

{% hint style="info" %}
`entra_tenant_id`는 `client_auth_mode=entra-id`로 설정한 경우에만 필요합니다. 기본값인 `subscription-key` 모드에서는 입력하지 않아도 됩니다.
{% endhint %}

## 4. terraform.tfvars 구성

***

`infra/terraform.tfvars`에 아래 값을 추가·업데이트합니다.

```hcl
# Entra ID — 기존 그룹 연동
admin_group_object_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # 2단계에서 조회한 값

# Admin UI 이미지 및 공개 설정
admin_ui_image  = "<registry_login_server>/admin-ui:latest"
admin_ui_public = true

# BFF API 및 SPA (app-registration.sh 또는 기존 앱에서 조회)
bff_api_audience = "api://<bff-app-id>"
spa_client_id    = "<spa-app-id>"
```

변수별 설명:

| 변수 | 설명 |
|---|---|
| `admin_group_object_id` | 기존 Entra 보안 그룹의 Object ID. Admin UI BFF가 런타임에 이 값(`ADMIN_GROUP_OBJECT_ID` env var)으로 그룹 멤버십을 검증합니다 |
| `bff_api_audience` | BFF API 앱 등록의 `api://` 형식 audience URI |
| `spa_client_id` | SPA public-client 앱 등록의 클라이언트 ID |
| `admin_ui_image` | admin-ui 컨테이너 이미지 전체 URI |
| `admin_ui_public` | `true`이면 Admin UI가 인터넷에서 직접 접근 가능 |

## 5. 배포 실행

***

tfvars 구성이 완료되면 `terraform apply`를 실행합니다.

```bash
cd infra
terraform apply
```

Admin UI와 BFF가 배포되면 `ADMIN_GROUP_OBJECT_ID` 환경 변수에 입력한 Object ID가 주입됩니다. BFF는 런타임에 로그인한 사용자가 이 그룹의 멤버인지 확인하고, 그룹 멤버에게만 admin 쓰기 작업을 허용합니다.

## 6. 검증

***

배포가 완료되면 Admin UI에서 그룹 연동을 확인합니다.

1. `terraform output admin_ui_fqdn`으로 Admin UI URL을 확인합니다.
2. 브라우저에서 해당 URL을 열고 Entra ID 로그인을 진행합니다.
3. **기존 그룹 멤버 계정**으로 로그인하면 admin 기능(소비자 등록, 키 발급 등)이 활성화됩니다.
4. 그룹에 속하지 않은 계정으로 로그인하면 읽기 전용 뷰 또는 접근 거부 화면이 표시됩니다.

{% hint style="success" %}
그룹 멤버 계정으로 admin 쓰기 작업이 정상적으로 동작하면 기존 Entra 그룹 연동이 완료된 것입니다.
{% endhint %}

Admin UI 전체 기능에 대한 안내는 [시나리오 B: Admin UI 배포](case-admin-ui.md)를 참고하세요.
Entra ID 객체 상세(BFF API 앱 등록 설정, SPA PKCE 설정 등)는 [사전 준비](../02-prerequisites.md)를 참고하세요.
