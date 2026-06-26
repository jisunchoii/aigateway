> 읽는 사람: 기존 AIServices 계정의 소유자 또는 플랫폼 엔지니어 · 선행: [재사용 개요](overview.md)

# 계정 잠금 사전 준비

게이트웨이는 APIM Managed Identity와 RBAC만으로 AIServices 계정에 접근한다.
키 기반 인증이 활성화되어 있거나 공용 네트워크 접근이 열려 있으면, 보안 태세가 약해지고 게이트웨이의 설계 전제가 무너진다.
따라서 **Terraform apply 전에** 고객이 직접 기존 AIServices 계정을 passwordless 상태로 잠가야 한다.

> **왜 Terraform이 직접 하지 않나?**
> 재사용 모드에서 Terraform은 기존 계정을 `data` 소스로만 읽는다. 기존 계정의 속성을 Terraform이 관리하기 시작하면 상태 파일에 계정이 들어오고, 이후 `terraform destroy` 시 계정이 삭제될 위험이 있다. 고객이 직접 `az` 명령으로 잠그는 방식이 훨씬 안전하다.

## 사전 확인: 계정 resource ID 조회

```bash
az resource list \
  --resource-type "Microsoft.CognitiveServices/accounts" \
  --query "[].{name:name, id:id, rg:resourceGroup}" \
  -o table
```

`existing_foundry_name`과 `existing_foundry_rg`에 사용할 이름을 확인한다.
계정 resource ID(`<aiservices-account-id>`)는 아래 명령에서 `--ids` 인수로 사용한다.

## 계정 잠금

```bash
az resource update --ids <aiservices-account-id> \
  --set properties.disableLocalAuth=true properties.publicNetworkAccess=Disabled
```

- `disableLocalAuth=true`: API 키 기반 인증을 비활성화한다. Entra ID(관리 ID 포함)만 허용된다.
- `publicNetworkAccess=Disabled`: 공용 인터넷에서의 직접 접근을 차단한다. Private Endpoint 경유만 허용된다.

## 잠금 확인

```bash
az resource show --ids <aiservices-account-id> \
  --query "properties.{disableLocalAuth:disableLocalAuth, publicNetworkAccess:publicNetworkAccess}" -o jsonc
```

기대 출력:

```jsonc
{
  "disableLocalAuth": true,
  "publicNetworkAccess": "Disabled"
}
```

두 값이 모두 올바르면 Terraform 배포를 진행해도 된다.

## 주의 사항

### 기존 직접 접근이 끊길 수 있다

`publicNetworkAccess=Disabled`로 설정하면 공용 인터넷에서 해당 계정의 엔드포인트에 직접 붙는 모든 클라이언트가 즉시 차단된다.
게이트웨이 배포가 완료되어 Private Endpoint가 생성되기 전까지는 계정이 사실상 고립된다.
**잠금 → apply → 검증** 순서를 한 번에 진행하거나, 유지보수 창(maintenance window)을 잡고 진행할 것을 권장한다.

### `disableLocalAuth` 되돌리기

필요한 경우 아래 명령으로 원복할 수 있다. 단, 게이트웨이가 운영 중인 상태에서는 키 기반 접근을 다시 여는 것이 보안 규정 위반이 될 수 있으므로 주의한다.

```bash
az resource update --ids <aiservices-account-id> \
  --set properties.disableLocalAuth=false
```

---

> **[각주] 파트너 모델 marketplace 약관 (gotcha 5)**
> grok-4.3, DeepSeek-V4-Pro 같은 파트너 모델은 테넌트에서 marketplace 약관 동의가 필요할 수 있다.
> 기존 계정에 이미 해당 모델 배포가 있다면 약관은 이미 동의된 상태다.
> 그러나 새 테넌트에서 처음 사용하는 경우, Azure 포털의 배포 플로우에서 약관에 동의한 뒤 재시도해야 한다.
> 자세한 내용은 [10-reference/gotchas.md](../10-reference/gotchas.md)를 참고한다.

## 참고 문서

- [Cognitive Services 로컬 인증 비활성화](https://learn.microsoft.com/ko-kr/azure/ai-services/disable-local-auth)
- [Azure Cognitive Services에서 Private Link 사용](https://learn.microsoft.com/ko-kr/azure/ai-services/cognitive-services-virtual-networks)
- [Azure AI Services용 관리 ID](https://learn.microsoft.com/ko-kr/azure/ai-services/cognitive-services-virtual-networks#use-private-endpoints)

## 다음 단계

계정 잠금을 확인했으면 [tfvars 설정](configure-tfvars.md)으로 넘어간다.
