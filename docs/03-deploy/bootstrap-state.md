---
description: 운영자·DevOps 엔지니어를 위한 페이지 · 선행: 배포 개요
---

# Terraform 원격 state 백엔드 부트스트랩

Terraform은 배포 상태를 원격 저장소에 보관해야 팀 협업과 잠금(locking)이 가능합니다. 이 스크립트는 **구독당 1회**만 실행하면 됩니다. 이미 state 백엔드가 존재한다면 이 단계를 건너뛰십시오.

[Azure Blob Storage 원격 백엔드](https://learn.microsoft.com/ko-kr/azure/developer/terraform/store-state-in-azure-storage)는 Entra ID 인증과 공용 Blob 액세스 차단을 기본값으로 사용합니다. 키 기반 접근 없이 Terraform이 스토리지 계정에 액세스하도록 구성됩니다.

## 환경 변수 설정

아래 값을 먼저 쉘 환경에 내보내십시오. `<...>` 부분은 실제 값으로 교체합니다.

```bash
export location=eastus2
export backend-rg=rg-aigw-tfstate-dev-eastus2
export storage-prefix=staigwtfstate
export state-key=ai-gateway-eus2.tfstate
```

| 변수 | 기본값 | 설명 |
|---|---|---|
| `location` | `eastus2` | 백엔드 스토리지를 배포할 Azure 리전 |
| `backend-rg` | `rg-aigw-tfstate-dev-eastus2` | 백엔드 전용 리소스 그룹 이름 |
| `storage-prefix` | `staigwtfstate` | 스토리지 계정 이름 접두사(전역 고유) |
| `state-key` | `ai-gateway-eus2.tfstate` | state 파일 블롭 이름 |

{% hint style="info" %}
**리전 선택:** `location`은 이후 `terraform.tfvars`의 `location` 값과 같은 리전으로 맞추는 것을 권장합니다.
{% endhint %}

## 부트스트랩 실행

```bash
./scripts/bootstrap-backend.sh --location $location --backend-rg $backend-rg --storage-prefix $storage-prefix --state-key $state-key
```

스크립트가 완료되면 다음이 생성됩니다.

- 리소스 그룹 `$backend-rg`
- 스토리지 계정 (`$storage-prefix` + 랜덤 접미사, 전역 고유)
- Blob 컨테이너 `tfstate`
- 공용 Blob 액세스 차단 설정
- [Entra ID 인증](https://learn.microsoft.com/ko-kr/azure/storage/common/storage-auth-aad) 기반 접근 — 스토리지 계정 키 없이 동작

## 보안 설계

| 항목 | 설정 |
|---|---|
| 인증 | Entra ID (DefaultAzureCredential / `az login`) |
| 공용 Blob 액세스 | **비활성화** |
| 스토리지 계정 키 | 사용 안 함 |
| state 잠금 | Azure Blob 임대(lease) 기반 자동 잠금 |

## 다음 단계

백엔드가 준비되면 [tfvars 구성](configure-tfvars.md)으로 이동하십시오.
