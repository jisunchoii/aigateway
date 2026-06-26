> 읽는 사람: 배포 담당자 / SRE / 운영자 · 선행: 없음 (트러블슈팅 레퍼런스)

# Gotchas & 트러블슈팅

배포 및 운영 중 마주칠 수 있는 알려진 이슈와 해결 방법 모음입니다.

---

## Gotcha 목록

### Gotcha 1 — APIM VNet 주입 첫 apply ~45분

**증상:** `terraform apply`가 APIM 리소스 생성에 오랜 시간 소요되며 타임아웃처럼 보임.

**원인:** Developer 또는 Premium SKU의 VNet 주입 모드(Internal/External) 활성화는 Azure 내부에서 약 45분이 걸립니다. 이는 정상 동작입니다.

**해결:** 기다립니다. 타임아웃 없이 apply가 완료될 때까지 대기합니다. 중단하지 마세요.

---

### Gotcha 2 — APIM OpenAPI import 400 오류 (첫 apply 레이스)

**증상:** 첫 `terraform apply` 시 APIM API import 단계에서 400 오류 발생.

**원인:** APIM 게이트웨이 프로비저닝이 완료되기 전에 OpenAPI spec import가 시도되는 일시적 레이스 컨디션. Foundry API는 wildcard 라우팅이므로 별도 import가 없어 영향받지 않습니다.

**해결:** `terraform apply`를 다시 실행합니다. 두 번째 apply에서 정상 완료됩니다.

---

### Gotcha 3 — VNet 주입 APIM `terraform destroy` 중단

**증상:** `terraform destroy`가 Named Value 삭제 단계에서 멈추거나 오류 발생.

**원인:** VNet 주입 APIM 환경에서 Terraform이 Named Value 삭제 순서를 처리하지 못하는 경우가 있습니다.

**해결:** 리소스 그룹 전체를 직접 삭제합니다.

```bash
az group delete -n <resource_group_name> --yes
```

`<resource_group_name>`은 `terraform output -raw resource_group_name`으로 확인합니다. 이후 Terraform state와 동기화가 필요하면 state를 초기화하세요.

---

### Gotcha 4 — `data.azurerm_cognitive_account` `local_auth_enabled` 미노출

**증상:** `reuse_foundry = true` 모드에서 `terraform plan/apply` 시 `local_auth_enabled` 속성 관련 오류 또는 precondition 실패.

**원인:** `azurerm` provider 버전에 따라 `data.azurerm_cognitive_account`가 `local_auth_enabled` 속성을 노출하지 않을 수 있습니다.

**해결:** provider 업그레이드를 검토하거나, `az` CLI로 사전 점검하여 precondition을 대체합니다.

```bash
az resource show --ids <aiservices-account-id> \
  --query "properties.{disableLocalAuth:disableLocalAuth, publicNetworkAccess:publicNetworkAccess}" -o jsonc
# 기대값: disableLocalAuth: true, publicNetworkAccess: "Disabled"
```

---

### Gotcha 5 — 파트너 모델 마켓플레이스 약관 동의 필요

**증상:** grok-4.3 또는 DeepSeek-V4-Pro 배포 시 오류 발생. 또는 스모크 테스트에서 해당 모델만 실패.

**원인:** xAI(grok), DeepSeek 등 파트너 모델은 테넌트에서 Azure Marketplace 약관에 동의해야 배포할 수 있습니다.

**해결:** Azure Portal에서 해당 모델의 배포 플로우를 진행하여 약관에 동의한 후 `terraform apply`를 재실행합니다.

---

## 트러블슈팅 — HTTP 오류별 대응

### 403 Forbidden — allowed-models 차단

**증상:** 특정 모델 호출 시 HTTP 403.

**원인:** 요청한 모델이 `allowed_models` 변수에 포함되어 있지 않아 APIM 정책이 차단.

**해결:**

1. `allowed_models` 변수에 해당 모델 이름이 포함되어 있는지 확인합니다.
   ```hcl
   allowed_models = ["gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro"]
   ```
2. `foundry_deployments` 또는 `openai_deployments` 맵의 키가 실제 배포 이름과 일치하는지 확인합니다.
3. 변경 후 `terraform apply`로 APIM Named Values를 업데이트합니다.

---

### 429 Too Many Requests — 레이트 리밋 초과

**증상:** HTTP 429 오류. Retry-After 헤더가 포함될 수 있음.

**원인:** 소비자(팀)의 분당 토큰(TPM) 또는 쿼터 기간 토큰 한도 초과.

**해결:**

1. `rate_tiers` 변수에서 해당 팀의 tier 확인 및 상향 조정.
   ```hcl
   rate_tiers = {
     small  = { tpm = 500,   quota = 20000,  period = "Daily" }
     medium = { tpm = 2000,  quota = 100000, period = "Daily" }
     large  = { tpm = 10000, quota = 500000, period = "Monthly" }
   }
   ```
2. Admin UI에서 해당 소비자의 tier를 변경합니다.
3. 일시적 급증이라면 `tokens_per_minute` 기본값(`1000`) 상향을 고려합니다.

참고: [Azure API Management 레이트 리밋 정책](https://learn.microsoft.com/ko-kr/azure/api-management/rate-limit-by-key-policy)

---

### 모델 전환 확인 — x-ai-gateway-* 응답 헤더

**증상:** 요청한 모델과 다른 모델이 실제로 응답하는 것 같음. 또는 예산 소진이 예상보다 빠름.

**원인:** 예산 기반 모델 전환(`downgrade_ladder`)이 발동하여 더 저렴한 모델로 전환.

**해결:** `curl -v` 또는 클라이언트 헤더 로그에서 다음 헤더를 확인합니다.

```
x-ai-gateway-requested-model: gpt-5.4
x-ai-gateway-effective-model: gpt-5.4-mini
x-ai-gateway-downgrade-level: 1
```

- `x-ai-gateway-requested-model`: 클라이언트가 요청한 모델
- `x-ai-gateway-effective-model`: 실제로 라우팅된 모델
- `x-ai-gateway-downgrade-level`: 현재 모델 전환 단계 (0 = 전환 없음)

이 헤더는 정상 동작입니다. 모델 전환이 발동하지 않게 하려면 예산 한도를 높이거나 소비자의 사용량을 줄이세요.

---

### PE/RBAC 전파 지연

**증상:** `terraform apply` 직후 스모크 테스트 또는 백엔드 직접 테스트에서 401/403 발생. 잠시 후 재시도하면 성공.

**원인:** Azure Private Endpoint DNS 전파 또는 RBAC 역할 할당 전파에 수 분이 소요됩니다.

**해결:** 첫 apply 완료 후 3~5분 기다린 뒤 스모크를 재실행합니다. 지속적으로 실패한다면 [backend-isolation.md](../05-verify/backend-isolation.md) 절차로 격리 진단합니다.

참고:
- [Azure Private Endpoint DNS 구성](https://learn.microsoft.com/ko-kr/azure/private-link/private-endpoint-dns)
- [Azure RBAC 역할 할당 전파](https://learn.microsoft.com/ko-kr/azure/role-based-access-control/role-assignments-steps)

---

## 관련 문서

- 스모크 테스트 → [../05-verify/smoke-test.md](../05-verify/smoke-test.md)
- 백엔드 격리 진단 → [../05-verify/backend-isolation.md](../05-verify/backend-isolation.md)
- 변수 레퍼런스 → [variables.md](variables.md)
- 비용 · 정리 → [cost-cleanup.md](cost-cleanup.md)
