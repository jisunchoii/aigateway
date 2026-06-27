---
description: "시나리오 D — 운영 중인 게이트웨이 코어에 Admin UI를 추가 배포합니다."
---

# 시나리오 D — Admin UI 추가 배포


게이트웨이 코어(`worker_image`·`admin_ui_image` 모두 비어 있는 상태)가 이미 운영 중이고, 소비자 등록·구독 키 발급·정책 관리를 위한 셀프서비스 Admin UI를 추가하고 싶을 때 이 시나리오를 따르세요.

[Azure Container Apps](https://learn.microsoft.com/ko-kr/azure/container-apps/overview)에 배포되는 Admin UI는 `admin_ui_image` 변수가 설정되어야만 생성됩니다. 아래 절차는 **2차 apply**만으로 Admin UI를 추가하는 최소 경로입니다.

***

## 1. Admin UI 이미지 빌드·푸시

***

ACR이 1차 apply에서 이미 생성되어 있어야 합니다. `infra/` 디렉터리에서 아래 명령을 실행하세요.

```bash
acr=$(terraform output -raw registry_login_server)
reg=$(terraform output -raw registry_name)
az acr build --registry $reg --image admin-ui:latest ../app/admin-ui
```

config-sync-worker도 아직 배포되지 않았다면 함께 빌드하세요.

```bash
az acr build --registry $reg --image config-sync-worker:latest ../app/config-sync-worker
```

[ACR 원격 빌드](https://learn.microsoft.com/ko-kr/azure/container-registry/container-registry-tutorial-quick-task)는 로컬 Docker 없이 Azure 클라우드에서 빌드·푸시됩니다. `az login` 완료 상태라면 키나 비밀번호가 필요 없습니다.

***

## 2. Entra ID 앱 등록 3종 준비

***

Admin UI는 [Entra ID](https://learn.microsoft.com/ko-kr/entra/fundamentals/whatis) OIDC 로그인과 Admin 그룹 게이트로 보호됩니다. 아래 스크립트가 필요한 앱 등록 객체 3종을 자동으로 생성합니다.

```bash
./scripts/app-registration.sh
```

| 출력 값 | 설명 |
|---|---|
| `admin_group_object_id` | Admin UI 접근을 허용할 Entra ID 보안 그룹 Object ID |
| `bff_api_audience` | BFF API 앱 등록의 `api://` 형식 audience URI |
| `spa_client_id` | SPA(public-client) 앱 등록의 클라이언트 ID |

{% hint style="info" %}
이미 운영 중인 Entra 그룹을 재사용하려면 스크립트 대신 [기존 Entra 그룹 재사용](case-entra-group.md) 시나리오를 참고하세요.
{% endhint %}

스크립트 실행 후 출력된 세 값을 기록해 두세요. 다음 단계 tfvars에 입력합니다.

***

## 3. tfvars에 Admin UI 변수 추가

***

`infra/terraform.tfvars`에 아래 변수를 추가하세요.

```hcl
admin_ui_image        = "<registry_login_server>/admin-ui:latest"
admin_ui_public       = true
admin_group_object_id = "<entra security group object id>"
bff_api_audience      = "api://<bff app id>"
spa_client_id         = "<spa app id>"
```

`<registry_login_server>`는 `terraform output -raw registry_login_server`로 확인합니다.

worker도 이 시점에 추가한다면 함께 설정하세요.

```hcl
worker_image = "<registry_login_server>/config-sync-worker:latest"
```

{% hint style="warning" %}
**`admin_ui_public`은 변경 불가(immutable)입니다.** 이 값은 [Azure Container Apps 환경](https://learn.microsoft.com/ko-kr/azure/container-apps/environment) 생성 시점에 결정되며, 이후 변경하면 ACA 환경과 Admin UI 앱이 **재생성**됩니다. 운영 중 변경은 다운타임을 유발하므로, 첫 Admin UI 배포 전에 반드시 확정하세요.
{% endhint %}

| 변수 | 설명 |
|---|---|
| `admin_ui_image` | admin-ui 컨테이너 이미지 전체 URI |
| `admin_ui_public` | `true`이면 인터넷에서 직접 접근 가능 (인증은 여전히 필요) |
| `admin_group_object_id` | Admin UI에 로그인할 수 있는 Entra 보안 그룹 |
| `bff_api_audience` | BFF API가 토큰 검증에 사용하는 audience |
| `spa_client_id` | SPA의 PKCE 인증 흐름에 사용하는 클라이언트 ID |

`client_auth_mode = "entra-id"`로 설정한 경우 `entra_tenant_id`도 함께 지정해야 합니다.

```hcl
entra_tenant_id = "<azure tenant id>"
```

***

## 4. 두 번째 terraform apply

***

변수가 모두 채워지면 apply를 실행합니다.

```bash
terraform apply
```

이 apply는 APIM을 재구성하지 않으므로 1차 apply보다 훨씬 빠르게 완료됩니다. 완료 후 Admin UI FQDN을 확인하세요.

```bash
terraform output admin_ui_fqdn
```

***

## 5. SPA redirect URI 업데이트 및 검증

***

Admin UI FQDN이 확정되면 Entra ID 앱 등록의 SPA redirect URI에 추가해야 합니다. 아래 명령을 실행하세요.

```bash
spa_app_id="$(az ad app list --display-name "AI Gateway SPA" --query "[].appId" -o tsv)"
fqdn=$(terraform output -raw admin_ui_fqdn)
oid=$(az ad app show --id "$spa_app_id" --query id -o tsv)
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$oid" \
  --headers 'Content-Type=application/json' \
  --body "{\"spa\":{\"redirectUris\":[\"https://$fqdn\"]}}"
```

상세 절차는 [배포 — Seed 및 최종 설정](../03-deploy.md#8-seed-및-최종-설정) 절을 참고하세요.

### 검증

브라우저에서 `https://<admin_ui_fqdn>`에 접속하면 Entra ID 로그인 화면이 나타납니다. Admin 그룹 멤버 계정으로 로그인하면 Admin UI 대시보드가 열립니다.

{% hint style="info" %}
Admin UI는 `admin_ui_public = true`여도 Entra ID 인증 없이는 접근할 수 없습니다. 공개 URL은 편의 목적(로그인 페이지 접근)이며, 인증을 우회하지 않습니다.
{% endhint %}

로그인 후 정상 동작을 확인했으면 [운영](../06-operate.md) 챕터로 이동하여 소비자 등록과 정책 설정을 진행하세요.
