> 읽는 사람: 배포 담당자 / 게이트웨이 운영자 · 선행: [첫 번째 `terraform apply`](../03-deploy/first-apply.md)

# 스모크 테스트 (public APIM)

`apim_public = true`로 배포한 경우, 게이트웨이 VIP는 인터넷에 공개되어 있으므로 **로컬 노트북에서 바로** 스모크를 실행할 수 있습니다. jumpbox는 필요하지 않습니다.

---

## 전제 조건

| 항목 | 확인 방법 |
|---|---|
| APIM 호스트 이름 | `terraform output -raw apim_gateway_url` → `https://<apim-host>` |
| 구독 키 | Admin UI 또는 Azure Portal APIM > Subscriptions 에서 발급 |
| `apim_public = true` | `terraform.tfvars` 확인 |

### 구독 키 발급

**Admin UI 경유:** `https://<admin_ui_fqdn>` → 로그인 → Subscriptions → 새 키 생성.

**Azure Portal 경유:** APIM 리소스 → **Subscriptions** 블레이드 → **Add subscription** 또는 기존 키의 **Show/regenerate**.

---

## 스모크 스크립트 실행

```bash
./scripts/smoke-v1-gateway.sh <apim-host> <subscription-key>
```

스크립트는 아래 **4개 체크**를 순서대로 수행하며, 각각 HTTP 200을 기대합니다.

| # | 모델 | APIM 입구 | 설명 |
|---|---|---|---|
| 1 | `gpt-5.4` | `/openai` (path-route) | path → v1 body 변환 확인 |
| 2 | `grok-4.3` | `/foundry` (body-route) | OSS 모델 엔드-투-엔드 |
| 3 | `DeepSeek-V4-Pro` | `/foundry` (body-route) | 파트너 모델 엔드-투-엔드 |
| 4 | `gpt-5.4` (max_completion_tokens) | `/openai` | `max_completion_tokens` 파라미터 통과 확인 |

모든 체크가 통과하면 스크립트는 **ALL PASSED** 를 출력합니다. 이 절차는 라이브 환경에서 검증 완료되었습니다.

---

## 결과 해석

| 결과 | 의미 | 다음 단계 |
|---|---|---|
| ALL PASSED | 게이트웨이 엔드-투-엔드 정상 | 클라이언트 연결로 이동 |
| 403 | allowed-models 정책에서 차단 | `allowed_models` 변수 확인 → [gotchas](../10-reference/gotchas.md) |
| 429 | 레이트 리밋 초과 | 구독 키의 rate tier 확인 → [gotchas](../10-reference/gotchas.md) |
| 게이트웨이 200인데 백엔드 오류 | 정책 변환 문제 | [backend-isolation](backend-isolation.md) 으로 격리 진단 |
| 스크립트 자체 실패 | `<apim-host>` 미도달 | `apim_public` 값 및 NSG 규칙 확인 |

---

## 응답 헤더로 모델 전환 확인

APIM은 요청 처리 결과를 응답 헤더로 반환합니다. `curl -v` 출력에서 확인할 수 있습니다.

```
x-ai-gateway-requested-model: gpt-5.4
x-ai-gateway-effective-model: gpt-5.4-mini
x-ai-gateway-downgrade-level: 1
```

`effective-model`이 `requested-model`과 다르면 예산 기반 모델 전환이 발동한 것입니다. 정상 동작입니다.

---

## 관련 문서

- 백엔드 격리 진단 → [backend-isolation.md](backend-isolation.md)
- 변수 레퍼런스 (`apim_public`, `allowed_models`) → [../10-reference/variables.md](../10-reference/variables.md)
- 트러블슈팅 / Gotchas → [../10-reference/gotchas.md](../10-reference/gotchas.md)
- 클라이언트 연결 → [../07-connect-clients/overview.md](../07-connect-clients/overview.md)
