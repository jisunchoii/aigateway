> 읽는 사람: 운영자·DevOps 엔지니어 · 선행: [tfvars 구성](configure-tfvars.md)

# 첫 번째 `terraform apply`

이 단계에서는 코어 인프라를 배포합니다. `worker_image`와 `admin_ui_image`는 아직 비워 둔 상태에서 실행합니다. 컨테이너 앱 이미지는 ACR 빌드 후 두 번째 apply에서 배포합니다.

## 배포 대상 (첫 번째 apply)

- [Azure API Management](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-key-concepts) — VNet 주입 포함
- [Azure Virtual Network](https://learn.microsoft.com/ko-kr/azure/virtual-network/virtual-networks-overview) 및 서브넷
- [Azure Container Registry](https://learn.microsoft.com/ko-kr/azure/container-registry/container-registry-intro)
- [Azure Cosmos DB](https://learn.microsoft.com/ko-kr/azure/cosmos-db/introduction) — Private Endpoint, 로컬 인증 비활성화
- Azure OpenAI / AIServices 계정 및 모델 배포 (Greenfield 경로)
- Jumpbox VM (선택, `enable_jumpbox = true`일 때)

## 실행

```bash
cd infra
terraform init
terraform apply
```

`terraform init`은 provider 플러그인과 원격 state 백엔드를 초기화합니다. 이미 초기화된 환경에서는 생략 가능하지만, 재실행해도 무방합니다.

`terraform apply`를 실행하면 계획이 출력되고 `yes`를 입력하면 배포가 시작됩니다.

## 소요 시간

**약 45분.** [APIM VNet 주입](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-using-with-vnet)은 Developer 및 Premium SKU에서 상당한 시간이 걸립니다. 이는 정상 동작입니다. 터미널이 오랫동안 응답하지 않는 것처럼 보여도 프로세스를 중단하지 마십시오.

> **VNet 주입 시간 (Gotcha 1):** APIM Developer/Premium SKU의 VNet 주입은 첫 apply에서 최대 45분 소요됩니다. 정상입니다. 중단하면 일부 리소스가 불완전한 상태로 남을 수 있습니다.

## 완료 후 확인

apply가 성공하면 다음 출력 값을 확인합니다.

```bash
terraform output apim_gateway_url
terraform output registry_name
terraform output registry_login_server
terraform output resource_group_name
```

`config_sync_job_name`과 `admin_ui_fqdn`은 두 번째 apply 전까지 `null`을 반환합니다. 이는 정상입니다.

## 재-apply가 필요한 경우

> **OpenAPI import 400 오류 (Gotcha 2):** 첫 apply에서 APIM OpenAPI import 단계가 400 오류를 낼 수 있습니다. 일시적인 레이스 컨디션으로 발생하며, `terraform apply`를 다시 실행하면 해결됩니다.[^1]

[^1]: Foundry API는 wildcard 경로 방식이라 OpenAPI import가 없습니다. `/openai` API만 해당합니다.

## 다음 단계

코어 인프라 배포가 완료되면 [이미지 빌드·푸시](build-push-images.md)로 이동하십시오.
