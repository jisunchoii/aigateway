---
description: 아키텍트·플랫폼 엔지니어·개발자를 위한 페이지 · 선행: 동작 방식
---

# 핵심 개념

이 페이지는 문서 전체에서 반복 등장하는 용어를 정의합니다. 헷갈리는 단어가 있을 때 돌아와 참고하세요.

---

## 1. consumer (소비자)

***

게이트웨이를 통해 AI 모델에 접근하는 **논리적 단위**입니다. 개인·팀·애플리케이션 어느 수준으로도 정의할 수 있습니다. Cosmos DB의 소비자 문서에 `allowed_models`, `rate_tier`, 예산 등 모든 정책이 저장됩니다.

`consumerId`는 요청마다 APIM 정책이 결정하는 식별자입니다. 구독 키 모드에서는 APIM 구독에서 파생되고, Entra ID 모드에서는 JWT 클레임에서 추출됩니다.

## 2. allowed-models (허용 모델)

***

소비자 문서에 기록된 **접근 가능한 모델 목록**입니다. 요청한 모델이 목록에 없으면 APIM 정책이 `403 Forbidden`을 반환합니다. 허용 모델은 Admin UI 또는 Cosmos DB 문서를 직접 수정해 변경합니다.

예시 설정:
```json
{
  "consumerId": "team-a",
  "allowed_models": ["gpt-5.4", "gpt-5.4-mini"]
}
```

## 3. rate-tier (속도 등급)

***

소비자에게 적용되는 **토큰 속도 제한 등급**입니다. Terraform 변수 `rate_tiers`로 small·medium·large 등 이름별 분당 토큰 상한을 정의하고, 소비자 문서의 `rate_tier` 필드로 등급을 지정합니다.

초과 요청에는 `429 Too Many Requests`가 반환됩니다.

## 4. 모델 전환 (budget-driven model swap)

***

월 예산(`monthly_budget_amount`)이 소진되면 APIM 정책이 요청 body의 `"model"` 값을 **자동으로 더 저렴한 모델로 교체**하는 기능입니다. 클라이언트는 동일한 엔드포인트·모델 이름으로 요청하지만, 실제로는 다른 모델이 응답합니다.

{% hint style="info" %}
**용어 주의:** 코드 식별자(`downgrade_ladder`, `active_downgrade`, `downgrade_level`)와 응답 헤더(`x-ai-gateway-downgrade-level`)는 영문 원형 그대로 사용합니다. 한국어 설명에서는 **"모델 전환"**이라고 표현합니다("강등"이 아님).
{% endhint %}

전환 단계는 `downgrade_ladder` 설정에 정의됩니다. 예:

```hcl
downgrade_ladder = ["gpt-5.4", "gpt-5.4-mini"]
```

위 설정에서 `gpt-5.4`를 요청했는데 예산이 소진된 경우, 정책은 `"model": "gpt-5.4-mini"`로 교체해 전달합니다.

응답 헤더로 전환 여부를 확인할 수 있습니다.

| 헤더 | 예시 값 | 의미 |
|---|---|---|
| `x-ai-gateway-requested-model` | `gpt-5.4` | 클라이언트 원 요청 |
| `x-ai-gateway-effective-model` | `gpt-5.4-mini` | 실제 처리 모델 |
| `x-ai-gateway-downgrade-level` | `1` | 전환 단계 (0=전환 없음) |

## 5. Private Endpoint / Passwordless

***

**Private Endpoint**는 Azure 리소스(여기서는 AIServices 계정)를 VNet 내부의 사설 IP로 노출하는 기능입니다. APIM VNet에서 AIServices로 가는 트래픽은 공인 인터넷을 통하지 않습니다.

**Passwordless(키 없는 인증)**는 API 키 대신 [Managed Identity](https://learn.microsoft.com/ko-kr/entra/identity/managed-identities-azure-resources/overview)와 RBAC을 사용해 백엔드에 인증하는 방식입니다. APIM의 시스템 할당 관리 ID에 `Cognitive Services OpenAI User` 역할을 부여하고, AIServices 계정의 `disableLocalAuth=true`로 키 인증을 차단합니다.

## 6. named values (명명된 값)

***

[APIM Named Values](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-howto-properties)는 정책 XML에서 `{{변수명}}` 형태로 참조하는 설정 저장소입니다. 이 게이트웨이에서는 백엔드 URL, Cosmos DB 연결 정보, 예산 임계값 등을 Named Values에 저장합니다. Terraform `apply` 때 자동으로 설정됩니다.

## 7. Cosmos DB 소비자 문서

***

소비자별 정책(allowed_models, rate_tier, 예산, 전환 설정 등)은 [Azure Cosmos DB](https://learn.microsoft.com/ko-kr/azure/cosmos-db/introduction) 컨테이너에 JSON 문서로 저장됩니다. APIM 정책은 요청마다 이 문서를 참조합니다. 초기 seed는 `seed-cosmos-jumpbox.sh`·`seed-pricing-jumpbox.sh` 스크립트로 수행하고, 이후 Admin UI나 config-sync-worker를 통해 관리합니다.

## 8. greenfield / brownfield

***

| 용어 | 의미 |
|---|---|
| **greenfield** | AIServices 계정을 포함해 모든 리소스를 Terraform이 신규 생성하는 배포 경로 |
| **brownfield** | 구독 내에 이미 존재하는 AIServices(Foundry) 계정을 `data`로 읽어 게이트웨이에 연결하는 경로 (`reuse_foundry=true`) |

어느 경로를 선택할지는 [Greenfield vs Brownfield 결정](../02-prerequisites/decide-greenfield-vs-brownfield.md) 페이지를 참고하세요.
