> 읽는 사람: 운영자·DevOps 엔지니어 · 선행: [첫 번째 apply](first-apply.md)

# 이미지 빌드·푸시

첫 번째 apply로 ACR이 생성되었으면 컨테이너 이미지를 빌드합니다. **Docker 로컬 설치는 필요 없습니다.** [ACR 원격 빌드](https://learn.microsoft.com/ko-kr/azure/container-registry/container-registry-tutorial-quick-task)(`az acr build`)를 사용하므로 빌드가 Azure 클라우드에서 실행됩니다.

## ACR 원격 빌드

```bash
acr=$(terraform output -raw registry_login_server)
reg=$(terraform output -raw registry_name)
az acr build --registry $reg --image config-sync-worker:latest ../app/config-sync-worker
az acr build --registry $reg --image admin-ui:latest ../app/admin-ui
```

> `infra/` 디렉터리에서 실행해야 `terraform output` 명령이 올바른 state를 읽습니다.

## 빌드 과정 설명

| 명령 | 설명 |
|---|---|
| `terraform output -raw registry_login_server` | ACR 로그인 서버 주소 조회 (예: `<prefix>acr.azurecr.io`) |
| `terraform output -raw registry_name` | ACR 리소스 이름 조회 |
| `az acr build ... config-sync-worker` | config-sync-worker 이미지를 ACR에서 원격 빌드·푸시 |
| `az acr build ... admin-ui` | admin-ui 이미지를 ACR에서 원격 빌드·푸시 |

ACR 빌드는 Entra ID 인증 기반으로 동작합니다. `az login`이 완료된 상태라면 별도 키나 비밀번호 없이 실행됩니다.

## 완료 후 이미지 URI 확인

빌드가 완료되면 다음 형식으로 이미지 URI를 구성할 수 있습니다.

```
<registry_login_server>/config-sync-worker:latest
<registry_login_server>/admin-ui:latest
```

이 URI는 다음 단계인 [앱 등록 및 두 번째 apply](app-registration-second-apply.md)에서 `terraform.tfvars`에 입력합니다.

## 다음 단계

이미지 빌드가 완료되면 [앱 등록 및 두 번째 apply](app-registration-second-apply.md)로 이동하십시오.
