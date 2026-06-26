---
description: 운영자·DevOps 엔지니어를 위한 페이지 · 선행: 앱 등록 및 두 번째 apply
---

# Seed 및 최종 설정

두 번째 apply가 완료되면 Cosmos DB에 초기 설정 데이터를 주입하고 config-sync를 즉시 실행합니다.

## Cosmos DB Seed 배경

[Azure Cosmos DB](https://learn.microsoft.com/ko-kr/azure/cosmos-db/introduction) 계정은 **Private Endpoint**로만 접근 가능하고 로컬 인증(키 기반)이 비활성화되어 있습니다.

{% hint style="warning" %}
Seed 작업은 반드시 **VNet 내부**에서 실행해야 합니다. 인터넷 또는 로컬 머신에서 직접 seed를 실행할 수 없습니다.
{% endhint %}

## 방법 1: Jumpbox 자동 실행 (권장)

`enable_jumpbox = true`로 배포했다면 두 번째 `terraform apply` 완료 시 VM run-command를 통해 seed 스크립트가 **자동으로 실행**됩니다. 별도 조작이 필요 없습니다.

Jumpbox VM은 VNet 내부에 위치하고 [관리 ID(Managed Identity)](https://learn.microsoft.com/ko-kr/entra/identity/managed-identities-azure-resources/overview)를 사용해 Cosmos DB에 passwordless로 인증합니다.

## 방법 2: Jumpbox 수동 실행

자동 실행이 실패했거나 jumpbox가 나중에 추가된 경우 수동으로 실행합니다.

```bash
./scripts/seed-cosmos-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
./scripts/seed-pricing-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
```

`<cosmos-account>`는 `terraform output config_store_account_name`으로 확인합니다.

| 스크립트 | 설명 |
|---|---|
| `seed-cosmos-jumpbox.sh` | 글로벌 config 문서 upsert (소비자·모델 권한·rate-tier 초기값) |
| `seed-pricing-jumpbox.sh` | 토큰당 가격 `pricing` 문서 upsert (worker 예산 계산 + Admin UI 가격 표시용). Idempotent |

두 스크립트 모두 IMDS 토큰(jumpbox 관리 ID)을 사용해 Cosmos DB에 인증합니다. Python 설치나 키 입력이 필요 없습니다.

## Config-sync 즉시 트리거

Seed가 완료되면 config-sync 워커를 즉시 실행해 APIM Named Value를 갱신합니다. 기본 cron 주기(`*/5 * * * *`, 5분마다)를 기다리지 않아도 됩니다.

```bash
az containerapp job start -g <rg> -n <config_sync_job_name>
```

| 인수 | 값 |
|---|---|
| `-g <rg>` | `terraform output resource_group_name` |
| `-n <config_sync_job_name>` | `terraform output config_sync_job_name` |

[Azure Container Apps Job](https://learn.microsoft.com/ko-kr/azure/container-apps/jobs)은 관리 ID로 Cosmos DB와 APIM에 인증합니다.

## 완료 확인

config-sync 잡이 성공적으로 실행되면 APIM Named Value에 소비자 구성이 반영됩니다. [스모크 테스트](../05-verify/smoke-test.md) 챕터에서 end-to-end 동작을 검증하세요.

## 다음 단계

모든 배포가 완료되었습니다. 이제 [검증 — 스모크 테스트](../05-verify/smoke-test.md)로 이동하여 게이트웨이 동작을 확인하세요.
