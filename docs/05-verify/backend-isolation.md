> 읽는 사람: 배포 담당자 / SRE · 선행: [스모크 테스트](smoke-test.md)

# 백엔드 격리 진단

게이트웨이 스모크(`smoke-v1-gateway.sh`)가 실패했을 때, 문제가 **APIM 정책**에 있는지 **백엔드(AIServices 계정)**에 있는지를 격리하는 절차입니다.

---

## 격리 원칙

```
클라이언트 → [APIM 정책] → 백엔드(AIServices, PE 전용)
```

백엔드(AIServices)는 **Private Endpoint 전용**으로 구성되어 있어 VNet 안에서만 접근할 수 있습니다. 따라서 백엔드 직접 스모크는 **jumpbox(VNet 내부)** 에서만 실행해야 합니다.

---

## 백엔드 직접 스모크 실행 (jumpbox에서)

jumpbox에 Bastion 또는 SSH로 접속한 뒤 아래 스크립트를 실행합니다.

```bash
./scripts/smoke-v1-backend.sh https://<ais>.openai.azure.com/openai/v1
```

`<ais>`는 AIServices 계정의 호스트 이름 프리픽스입니다. `config_store_endpoint` 출력값에서 계정명을 확인하거나, `terraform output -raw openai_endpoint` (greenfield 모드) 를 참고하세요.

> **reuse 모드** (`reuse_foundry = true`): `openai_endpoint` 출력이 null입니다. AIServices 계정 이름은 `existing_foundry_name` 변수 값을 사용하세요.

---

## 결과 해석

| 백엔드 스모크 결과 | 게이트웨이 스모크 결과 | 원인 | 조치 |
|---|---|---|---|
| 200 | 실패 | **APIM 정책 문제** | 정책 XML 확인, `allowed_models` 점검, [gotchas](../10-reference/gotchas.md) 참고 |
| 실패 | 실패 | **백엔드 계정/RBAC 문제** | AIServices 계정 상태, APIM MI RBAC, PE 연결 확인 |
| 200 | 200 | 양쪽 정상 | — (스모크 통과) |

### 백엔드 실패 시 주요 점검 항목

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

## jumpbox 활성화

`enable_jumpbox = false`(기본값)인 경우 jumpbox가 배포되지 않습니다. 백엔드 격리 진단이 필요하면 `terraform.tfvars`에 아래를 추가하고 재-apply합니다.

```hcl
enable_jumpbox         = true
jumpbox_admin_password = "<12자 이상 안전한 패스워드>"
```

> Bastion + jumpbox VM은 비용이 추가됩니다. 진단 후 `enable_jumpbox = false`로 되돌리는 것을 권장합니다.

---

## 관련 문서

- 스모크 테스트 (public APIM 경유) → [smoke-test.md](smoke-test.md)
- 변수 레퍼런스 (`enable_jumpbox`, `reuse_foundry`) → [../10-reference/variables.md](../10-reference/variables.md)
- Gotchas / 트러블슈팅 → [../10-reference/gotchas.md](../10-reference/gotchas.md)
- Brownfield 재사용 배포 → [../04-reuse-foundry/plan-and-apply.md](../04-reuse-foundry/plan-and-apply.md)
