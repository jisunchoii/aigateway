---
description: 운영자·DevOps 엔지니어를 위한 페이지 · 선행: 이미지 빌드·푸시
---

# 앱 등록 및 두 번째 apply

이 단계에서는 Entra ID 앱 등록을 완료하고, `terraform.tfvars`에 이미지 URI와 Entra 값을 채운 뒤 두 번째 apply를 실행합니다.

## Entra ID 앱 등록

Admin UI와 BFF(Backend for Frontend)가 Entra ID로 인증하려면 앱 등록 3종이 필요합니다. 아래 스크립트가 이를 자동으로 생성합니다.

```bash
./scripts/app-registration.sh
```

스크립트가 생성하는 항목:

| 항목 | 설명 |
|---|---|
| Admin 보안 그룹 | `admin_group_object_id` 값. Admin UI 접근 제어용 |
| BFF API 앱 등록 | `access_as_user` scope, `requestedAccessTokenVersion=2`. `bff_api_audience` 값 |
| SPA public-client 앱 등록 | PKCE, 시크릿 없음. `spa_client_id` 값 |

스크립트 실행 후 출력된 값을 기록해 두십시오.

## tfvars 업데이트

`infra/terraform.tfvars`에 다음 변수를 추가·업데이트합니다.

```hcl
worker_image          = "<registry_login_server>/config-sync-worker:latest"
admin_ui_image        = "<registry_login_server>/admin-ui:latest"
admin_ui_public       = true
admin_group_object_id = "<entra security group object id>"
bff_api_audience      = "api://<bff app id>"
spa_client_id         = "<spa app id>"
```

`<registry_login_server>`는 `terraform output -raw registry_login_server`로 확인합니다.

### 변수 설명

| 변수 | 설명 |
|---|---|
| `worker_image` | config-sync-worker 컨테이너 이미지 전체 URI |
| `admin_ui_image` | admin-ui 컨테이너 이미지 전체 URI |
| `admin_ui_public` | `true`이면 Admin UI가 인터넷에서 접근 가능 |
| `admin_group_object_id` | Entra ID 보안 그룹 Object ID (Admin UI 접근 권한) |
| `bff_api_audience` | BFF API의 `api://` 형식 audience URI |
| `spa_client_id` | SPA 앱 등록의 클라이언트 ID |

## 두 번째 apply 실행

```bash
terraform apply
```

이 apply에서는 다음이 추가로 배포됩니다.

- config-sync-worker Container Apps Job
- admin-ui Container App
- Entra ID RBAC 바인딩

두 번째 apply는 첫 번째보다 빠르게 완료됩니다(APIM VNet 재구성 없음).

## 완료 후 확인

```bash
terraform output admin_ui_fqdn
terraform output config_sync_job_name
```

두 값이 모두 non-null로 반환되면 성공입니다.

## 다음 단계

배포가 완료되면 [Seed 및 최종 설정](seed-and-finalize.md)으로 이동하십시오.
