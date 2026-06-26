# 설계: 기존 Foundry 재사용(brownfield) + 백엔드 v1 통일 + 고객 배포용 GitBook

- **날짜**: 2026-06-26
- **대상 레포/브랜치**: `llm-gateway`, 작업 브랜치 `feat/brownfield-reuse-and-gitbook` (기준: `english`)
- **상태**: 설계 합의 완료, 구현 대기

---

## 1. 개요 & 범위

### 목표
`llm-gateway`(english 브랜치)를 **고객 배포용 레퍼런스**로 다듬는다. 두 갈래:

- **(IaC)** 고객이 **이미 떠 있는 단일 AIServices(Foundry) 계정 + 모델 배포**를 게이트웨이가 새로 만들지 않고 **재사용(brownfield)** 하도록 경로를 추가한다.
- **(문서)** 고객 플랫폼팀이 **배포~운영 end-to-end**로 따라올 수 있는 **한국어 GitBook**을 레포 내 `docs/` 서브트리로 만든다.

### 변하지 않는 전제 (게이트웨이의 정체성)
- 클라이언트는 **public APIM**(`apim_public=true`)에 붙는다 — GHCP CLI / opencode / Copilot 같은 개발 툴 연동이 목적.
- 백엔드(모델)는 **항상 Private Endpoint + `local_auth_enabled=false`**, APIM이 **관리 ID + RBAC**로만 접근. 모델 키는 어디에도 없다.
- 집계 축은 **`consumerId` 하나** — 인증 방식이 무엇이든 rate limit·budget·토큰 메트릭이 이 축으로 돈다.

### 핵심 결정 요약
| # | 결정 | 비고 |
|---|---|---|
| D1 | 같은 구독, **게이트웨이 전용 별도 RG** | 현재 `azurerm_resource_group.rg` 코드 변경 없음 |
| D2 | Foundry **계정+모델은 `data`로 재사용**, PE+RBAC만 신규 | brownfield 핵심 |
| D3 | 계정 속성(local_auth off·public block)은 **배포 전 `az` 토글 + TF precondition 검증** | TF가 고객 계정을 소유/수정하지 않음 |
| D4 | reuse 시 **단일 AIServices로 통합** (gpt+OSS 한 계정), `modules/openai`는 `count=0` | 다운그레이드 단순화 |
| D5 | 백엔드 경로 **`/openai/v1` 통일** (dated api-version 종속 제거) | gpt path→body 변환은 스모크 검증 후 확정 |
| D6 | 클라이언트 **입구는 chat completions(v1) 유지** | 대상 클라이언트가 보내는 형식이므로 불변 |
| D7 | **한국어 GitBook**, 레포 내 `docs/` 서브트리 + `SUMMARY.md` | 고객 플랫폼팀 대상 end-to-end |
| D8 | Admin UI **한국어화**(별도 Phase): i18n 문자열만 main에서 되돌리고 Copilot 기능 보존 | main = 한국어 SOT |

### 이번 범위 (IN)
1. brownfield 재사용 (D1~D4)
2. 백엔드 경로 v1 통일 (D5, D6)
3. 한국어 GitBook (D7)
4. Admin UI 한국어화 (D8, 별도 Phase)

### 이번 범위 밖 — 설계 문서에 "향후 확장"으로만 명시 (OUT)
- **확장 A**: Claude Code용 Anthropic Messages(`/v1/messages`) 입구 → Foundry Claude 배포(`/anthropic`)
- **확장 B**: gpt 전용 Responses API(`/openai/v1/responses`) 입구 (stateful)
- **확장 C**: 클라이언트 Entra ID 인증 — JWT claim(단일값 app-role/extension-attribute)으로 consumerId 집계, **구독키 미사용**

권장 구현 순서: **C → A → B** (C는 토글이 이미 구현됨, A는 수요 큼, B는 클라이언트 대기).

---

## 2. brownfield 재사용 IaC

### 2.1 무엇을 재사용하고 무엇을 새로 만드나
고객의 기존 **단일 AIServices(Foundry) 계정 + 모델 배포**(gpt-5.4 + grok + DeepSeek 등이 한 계정에)를 전제로:

| 리소스 | greenfield (기본) | brownfield (`reuse=true`) |
|---|---|---|
| 게이트웨이 RG | 생성 (별도 RG) | 생성 (별도 RG, 변경 없음) |
| AIServices 계정 | `azurerm_cognitive_account` 생성 | **`data`로 읽기** (생성 안 함) |
| 모델 배포 | `azurerm_cognitive_deployment` 생성 | **생성 안 함** (`for_each={}`) |
| 계정 속성 (local_auth off·public block) | TF가 설정 | **배포 전 `az` 토글 + precondition 검증** |
| **Private Endpoint** | 생성 | **생성** (게이트웨이 VNet → 기존 계정) |
| **APIM MI RBAC** (Cognitive Services OpenAI User 등) | 부여 | **부여** |

핵심 원리: **"data로 읽기 + PE/RBAC만 신규"**. 기존 계정·모델은 건드리지 않고, 게이트웨이가 자기 VNet에서 그 계정으로 사설 연결만 새로 뻗는다. 같은 구독이면 Foundry가 다른 RG·다른 VNet에 있어도 게이트웨이 VNet에서 새 PE를 만들 수 있다.

### 2.2 모듈 구조 — 접근법 A (호출부·outputs 계약 불변)
`modules/foundry`에 토글 추가:

```hcl
variable "reuse_existing"        { type = bool,   default = false }
variable "existing_account_name" { type = string, default = "" }
variable "existing_account_rg"   { type = string, default = "" }  # 같은 구독, 기존 계정의 RG

# 생성 경로 (greenfield)
resource "azurerm_cognitive_account" "foundry" {
  count = var.reuse_existing ? 0 : 1
  # ... 기존 코드 그대로
}

# 참조 경로 (brownfield)
data "azurerm_cognitive_account" "existing" {
  count               = var.reuse_existing ? 1 : 0
  name                = var.existing_account_name
  resource_group_name = var.existing_account_rg
}

locals {
  account_id       = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].id       : azurerm_cognitive_account.foundry[0].id
  account_endpoint = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].endpoint : azurerm_cognitive_account.foundry[0].endpoint
}

# 모델: reuse면 안 만듦
resource "azurerm_cognitive_deployment" "models" {
  for_each = var.reuse_existing ? {} : var.deployments
  # ...
}

# PE + RBAC: 항상 생성, 대상은 local.account_id
resource "azurerm_private_endpoint" "foundry" {
  # ... private_connection_resource_id = local.account_id
}
```

- 모든 `output`은 `local.*`을 참조 → `apim`·`control_plane` 등 **하류 모듈 무수정**.
- `foundry_deployments` 맵은 **reuse여도 유지** — `allowed_models`·다운그레이드 라우팅·Admin UI 라벨을 구동하므로 "이미 존재하는 모델을 선언"하는 용도로 계속 쓴다. 키는 실제 배포된 deployment 이름과 정확히 일치해야 한다.

### 2.3 단일 AIServices 통합 (D4)
reuse 시 gpt도 같은 AIServices 계정에 있으므로 별도 OpenAI 계정이 불필요하다.

- `modules/openai` 호출을 `count = var.reuse_foundry ? 0 : 1`로 게이트.
- gpt도 foundry(AIServices) 계정의 `/openai/v1`로 라우팅.
- 이 통합이 cross-backend 다운그레이드 분기를 제거한다(섹션 3 참조).

### 2.4 계정 속성 검증 (passwordless 강제)
reuse 시 TF는 계정을 읽기만 하므로(수정 불가), 게이트웨이 표준을 precondition으로 강제:

```hcl
data "azurerm_cognitive_account" "existing" {
  count = var.reuse_existing ? 1 : 0
  # ...
  lifecycle {
    postcondition {
      condition     = self.local_auth_enabled == false
      error_message = "기존 계정의 키 인증이 켜져 있음. 배포 전 local-auth를 끄세요. (GitBook 04장 참조)"
    }
  }
}
```

> **검증 항목**: `azurerm_cognitive_account` data 소스가 `local_auth_enabled`를 노출하는지는 provider 버전에 따라 다르다. **plan 단계에서 실제 노출 여부를 확인**하고, 노출 안 되면 `az` CLI 사전 점검 스크립트로 대체한다.

배포 전 고객이 실행할 `az` 명령(GitBook에 명시):
```bash
az resource update --ids <account-id> \
  --set properties.disableLocalAuth=true \
        properties.publicNetworkAccess=Disabled
```

### 2.5 변수 인터페이스 (tfvars)
```hcl
# 신규 — 기본값은 greenfield라 기존 사용자 영향 없음
reuse_foundry         = true
existing_foundry_name = "ais-customer-prod"
existing_foundry_rg   = "rg-customer-ai"

# 기존 모델을 "선언"(생성 아님): 실제 배포된 deployment 이름과 일치해야 함
foundry_deployments = {
  "gpt-5.4"         = { model_name = "gpt-5.4", model_format = "OpenAI", model_version = "...", sku_name = "GlobalStandard", capacity = 10 }
  "grok-4.3"        = { model_name = "grok-4.3", model_format = "xAI", model_version = "1", sku_name = "GlobalStandard", capacity = 10 }
  "DeepSeek-V4-Pro" = { model_name = "DeepSeek-V4-Pro", model_format = "DeepSeek", model_version = "...", sku_name = "GlobalStandard", capacity = 500 }
}
```

---

## 3. 백엔드 v1 통일 & 정책 단순화 & 스모크 검증

### 3.1 단일 계정이 cross-backend 분기를 없앤다
현재 정책의 가장 복잡한 부분은 cross-backend 다운그레이드다. 백엔드가 둘이라 gpt(OpenAI path-route)와 OSS(AIServices v1 body-route)를 동시에 분기한다(`dgIsGpt`, 두 base-url, path↔body 변환).

| | 현재 (2계정) | 단일 계정 + v1 |
|---|---|---|
| 백엔드 base-url | gpt용 / OSS용 2개 | **`/openai/v1` 하나** |
| 다운그레이드 | cross-backend 분기 | **전부 same-backend** — body의 `"model"` 필드만 rewrite |
| api-version | gpt 경로에 박힘 | **불필요** (v1) |
| 모델 위치 | gpt=path, OSS=body | **전부 body** |

→ 다운그레이드가 "body의 model 값만 바꾸기" 하나로 통일된다. 정책이 짧아지고 검증이 쉬워진다.

### 3.2 입구(ingress)는 그대로 — 클라이언트 형식 유지 (D6)
백엔드를 v1 body-route로 통일해도 클라이언트가 보내는 입구는 바꾸지 않는다:

| 입구 (APIM API) | 클라이언트 | 들어오는 형식 | 백엔드로 나갈 때 |
|---|---|---|---|
| `/openai`, `/vscode/openai` | GHCP CLI, VS Code | path-route (model in URL) + `api-version` | URL에서 model 추출 → **body로 주입** → `/openai/v1/chat/completions` |
| `/foundry` | opencode 등 | body-route (model in body) | 거의 그대로 → `/openai/v1/chat/completions` |

→ **유일한 신규 위험**: path-route 입구(gpt를 쓰는 Copilot/VS Code)를 v1 body-route로 변환하는 로직. ① URL에서 deployment 추출 → ② `/openai/v1/chat/completions`로 rewrite → ③ body에 `"model"` 주입. OSS는 이미 body라 문제없지만 **gpt의 path→body 변환은 신규**.

### 3.3 스모크 검증 항목 (구현 전 게이트)
설계 확정 전에 테스트 스크립트로 확인:

1. **gpt path→body 변환**: `POST /openai/deployments/gpt-5.4/chat/completions?api-version=...`가 APIM에서 `/openai/v1/chat/completions` + `{"model":"gpt-5.4",...}`로 변환돼 단일 AIServices에서 200?
2. **OSS v1 body**: grok/DeepSeek가 같은 `/openai/v1/chat/completions`로 200?
3. **same-backend 다운그레이드**: grok→gpt, gpt→gpt-mini 강등이 body model rewrite만으로 동작?
4. **reasoning 모델 파라미터**: gpt-5 계열이 `max_tokens` 거부 → `max_completion_tokens` 변환이 v1에서도 필요/유지되는지?
5. **APIM known issue**: v1 관련 OpenAPI 3.1 import 문제가 이 경로에 영향 있는지? (Foundry API는 이미 OpenAPI import 없이 wildcard 운영 중 — 동일 패턴 사용)

검증 통과 → 설계 확정. 실패/제약 발견 → 해당 부분만 "현행 유지(혼합)"로 후퇴 + 문서화.

### 3.4 스모크 스크립트 위치 & 실행 지점
**핵심**: APIM이 `apim_public=true`면 게이트웨이 입구는 인터넷에서 접근 가능 → **로컬에서 검증**. 백엔드 모델 계정만 PE 전용(VNet 안).

| 스크립트 | 위치 | 실행 위치 | 목적 |
|---|---|---|---|
| `smoke-v1-gateway.sh` | `scripts/` | **로컬** (APIM public) | 입구→정책 변환→백엔드 end-to-end (5개 항목 主) |
| `smoke-v1-backend.sh` | `scripts/` | jumpbox | 백엔드 계정 직접 (격리 디버깅, 선택) |

`smoke-v1-gateway.sh`가 200을 받으려면 PE + APIM MI RBAC이 붙어 있어야 하므로, 이 테스트가 곧 brownfield 재사용(PE+RBAC 신규 생성)까지 한 번에 검증한다.

### 3.5 검증용 테스트 스택 구성 (별도 스택)
현재 eastus2 스택은 greenfield(2계정)이라 거기서 변경하면 "재사용"이 아닌 "생성"을 테스트하게 된다. brownfield를 정확히 검증하려면 별도 스택:

1. **"고객 기존 Foundry" 모사**: 단일 AIServices + gpt-5.4/grok/DeepSeek, 처음엔 public+키인증 ON으로 생성 → `az`로 local_auth off·public block 토글(2.4 절차 자체 검증).
2. **게이트웨이 reuse 배포**: 별도 RG, `reuse_foundry=true`, `existing_foundry_name/rg` 지정, `modules/openai` `count=0`. `terraform plan`으로 "계정·모델 생성 0, PE/RBAC만 추가" 확인.
3. **로컬에서 `smoke-v1-gateway.sh`**: APIM public 호스트로 5개 항목 검증.
4. 통과 → 설계 확정 / 제약 발견 → 후퇴 + 문서화.
5. **정리**: 테스트 스택 RG + 모사 Foundry RG 각각 destroy. (별도 RG의 깔끔함이 여기서 증명됨)

> 비용 메모: 테스트 APIM은 `Developer_1`(SLA 없음). VNet 주입 첫 apply ~45분 소요를 일정에 반영. 모델은 PAYG. 끝나면 destroy.

---

## 4. 향후 확장 (설계 명시, 이번 구현 제외)

### 확장 A — Claude Code 지원 (Anthropic Messages 입구)
- **왜**: Claude Code는 `/v1/messages`(Anthropic Messages)만 보냄. 현재 OpenAI/chat-completions 입구엔 못 붙음.
- **무엇**: APIM 신규 API `path=anthropic`(또는 `/v1/messages` 매칭), 백엔드 service_url = Foundry Claude 배포의 `…/anthropic`. 전제: 그 AIServices 계정에 Claude(Opus/Sonnet/Haiku) 배포 존재.
- **클라이언트**: `ANTHROPIC_BASE_URL=https://<apim-host>` + `ANTHROPIC_AUTH_TOKEN`.
- **거버넌스 재사용**: consumerId 축·rate limit·budget·메트릭 그대로. 단 토큰 메트릭 추출이 Messages 응답 스키마(`usage.input_tokens`/`output_tokens`)에 맞게 별도 매핑 필요.
- **주의**: gateway protocol이 `anthropic-beta`/`anthropic-version` 헤더 **그대로 전달(forward unchanged)** 요구 → 정책에서 strip 금지. 모델 discovery(`/v1/models`)는 선택.
- **공식 문서**: [Gateway protocol — API formats](https://code.claude.com/docs/en/llm-gateway-protocol), [Claude Code on Microsoft Foundry](https://code.claude.com/docs/en/microsoft-foundry)

### 확장 B — Responses API 입구 (gpt 전용, stateful)
- **왜**: Responses는 최신 stateful API. 단 요청 모양이 다름(`input` vs `messages`), OSS(grok/DeepSeek) 미지원, 현재 대상 클라이언트가 안 보냄.
- **무엇**: APIM 신규 경로 `/openai/v1/responses` 입구, 백엔드 동일 AIServices v1. 클라이언트가 `input`을 보내기 시작하면 활성화.
- **거버넌스**: allowed-models·budget 동일 적용. stateful(`previous_response_id`, 30일 저장)은 정책에서 손대지 않고 통과.
- **공식 문서**: [Responses API](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/responses), [v1 API lifecycle](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/api-version-lifecycle)

### 확장 C — 클라이언트 Entra ID 인증 (구독키 미사용)
- **왜**: 키 배포·회수 부담 제거, 사용자 신원 기반 거버넌스.
- **무엇**: `client_auth_mode="entra-id"` 토글이 **이미 구현됨**(validate-jwt → consumerId = JWT claim). 운영 검증 전이라 확장으로.
- **핵심 권고**: consumerId 도출 claim을 `groups`(object-ID GUID, 150그룹 초과 시 누락)가 **아니라** 단일값 **custom app-role 또는 extension-attribute**로. production 안정성의 관건이며 코드 주석도 동일 권고.
- **구독키 미사용**: `subscription_required=false`(entra 모드에서 이미 그렇게 분기됨). 집계는 JWT claim의 consumerId만으로.
- **검증 항목(확장 시)**: app-role claim이 토큰에 단일값으로 실리는 앱 등록 구성, validate-jwt openid-config URL, 토큰 만료/캐시.

---

## 5. GitBook 구조 (한국어, `docs/` 서브트리, 고객 플랫폼팀 end-to-end)

### 5.1 위치 & 동기화
- 레포 내 **`docs/`** 아래 GitBook 호환 마크다운 + **`docs/SUMMARY.md`**(목차). GitBook이 이 폴더를 Git 동기화.
- 기존 `docs/images/`(architecture.png, aigateway.gif) 재사용.
- 역할 분리: `README.md`(영문, 개발자/기여자) vs GitBook(한국어, 고객 플랫폼팀 운영).
- `internal/`(DEVELOPMENT-HISTORY, demo-guide)는 **GitBook 비포함**.

### 5.2 목차 (★ = 이번 작업 핵심/신규 페이지)
```
docs/
├── README.md                       # 표지 (1p)
├── SUMMARY.md                      # 목차
│
├── 01-overview/
│   ├── what-is-this.md             # governance endpoint, 아키텍처 그림
│   ├── how-it-works.md             # 요청 흐름: 클라이언트→APIM(정책)→private 백엔드
│   └── concepts.md                 # consumer/allowed-models/rate-tier/budget-downgrade
│
├── 02-prerequisites/
│   ├── azure-requirements.md       # 구독·쿼터·지역, 도구
│   ├── entra-objects.md            # Admin 그룹·BFF API·SPA 앱등록 (3종)
│   └── decide-greenfield-vs-brownfield.md   # ★ 결정 가이드
│
├── 03-deploy/
│   ├── 01-backend-state.md
│   ├── 02-variables.md             # apim_public 등
│   ├── 03-greenfield.md
│   ├── 04-brownfield-reuse.md      # ★ reuse 토글
│   ├── 05-first-apply.md           # ~45분 주의
│   ├── 06-images-second-apply.md
│   └── 07-seed-config.md           # Cosmos seed (jumpbox)
│
├── 04-reuse-existing-foundry/      # ★ brownfield 전용 독립 챕터
│   ├── overview.md                 # data 참조 + PE/RBAC만 신규 원리
│   ├── prepare-account.md          # az로 local_auth off·public block (검증 절차)
│   ├── single-aiservices.md        # gpt+OSS 한 계정 통합, openai 모듈 off
│   └── verify-plan.md              # terraform plan "생성 0, PE/RBAC만"
│
├── 05-verify/
│   ├── smoke-local.md              # ★ APIM public → 로컬 curl (v1 5개 항목)
│   ├── smoke-jumpbox.md            # 백엔드 직접 (선택)
│   └── troubleshooting.md          # 403/429/downgrade/PE/RBAC
│
├── 06-operate/
│   ├── consumers-keys.md
│   ├── models-limits-budget.md
│   └── monitoring.md
│
├── 07-connect-clients/             # ★ 4개 클라이언트
│   ├── overview.md                 # 비교표 (입구·형식·model 위치)
│   ├── ghcp-cli.md                 # COPILOT_PROVIDER_*
│   ├── vscode-byok.md              # chatLanguageModels.json
│   ├── opencode.md                 # opencode.json provider
│   └── claude-code.md              # ※ 현재 미지원, 확장 A 예정
│
├── 08-architecture/
│   ├── policy-pipeline.md          # 정책 단계 (consumerId→allowed→limit→downgrade→metric)
│   ├── api-versions.md             # ★ dated vs v1, chat-completions vs responses
│   └── security-model.md           # passwordless, PE, Key Vault, RBAC
│
├── 09-future/                      # ★ 향후 확장 (섹션 4)
│   ├── A-claude-code-anthropic-messages.md
│   ├── B-responses-api.md
│   └── C-entra-id-client-auth.md
│
└── 10-reference/
    ├── variables.md
    ├── scripts.md
    └── cost-cleanup.md
```

### 5.3 작성 원칙
- ★ 페이지 우선 작성. 나머지는 기존 README를 한국어로 재구성·분할.
- **Azure 규칙 준수**: 모든 Azure 서비스 설명에 `learn.microsoft.com` 링크 첨부, 인증은 Entra ID/MI 기본.
- 각 페이지 상단에 "이 페이지를 읽어야 하는 사람 / 선행 페이지" 한 줄.
- 코드 블록은 복붙 가능하게(플레이스홀더 `<...>` 명확히).

### 5.4 클라이언트 비교표 (07-connect-clients/overview.md에 들어갈 내용)
| | GitHub Copilot (IDE) | GHCP CLI | opencode | Claude Code |
|---|---|---|---|---|
| API 형식 | OpenAI chat completions | OpenAI chat completions | OpenAI chat completions (`/v1/chat/completions`) | **Anthropic Messages** (`/v1/messages`) |
| base URL 변수 | — | `COPILOT_PROVIDER_BASE_URL` | `baseURL` | `ANTHROPIC_BASE_URL` / `ANTHROPIC_FOUNDRY_BASE_URL` |
| model 위치 | body | body (azure면 경로) | body | body |
| 이 게이트웨이 입구 | `/vscode/openai`·`/openai` | `/openai` | `/foundry` | ❌ 현재 미지원 (확장 A) |

공식 문서:
- GHCP CLI: https://docs.github.com/en/copilot/concepts/agents/about-copilot-cli
- opencode: https://opencode.ai/docs/providers/
- Claude Code: https://code.claude.com/docs/en/llm-gateway , https://code.claude.com/docs/en/llm-gateway-protocol

---

## 6. 작업 순서 · 리스크 · 완료 기준

### 6.1 작업 순서
```
브랜치: feat/brownfield-reuse-and-gitbook (기준 english)

Phase 0 — 검증 스택 (구현 전 게이트)
  0.1 "고객 기존 Foundry" 모사: 단일 AIServices + gpt-5.4/grok/DeepSeek, public+키인증 ON
  0.2 az로 local_auth off · public block 토글 (2.4 절차 검증)
  0.3 게이트웨이 reuse 배포 (별도 RG, reuse_foundry=true, openai 모듈 count=0)
  0.4 terraform plan: "계정·모델 생성 0, PE/RBAC만 추가" 확인
  0.5 smoke-v1-gateway.sh (로컬, APIM public) — 5개 항목
  → 통과: Phase 1 / 실패: 해당 부분 현행유지 후퇴 + 문서화 → 재설계

Phase 1 — IaC brownfield 경로
  1.1 modules/foundry: reuse 토글 (data + local.account_id + 모델 for_each={})
  1.2 modules/openai: reuse 시 count=0 (단일 계정 통합)
  1.3 PE + APIM RBAC: 항상 생성, 대상 local.account_id
  1.4 data 계정 속성 precondition (local_auth_enabled 노출 여부 plan에서 확인)
  1.5 variables/tfvars 인터페이스 + .example 갱신

Phase 2 — 정책 v1 통일 & 단순화
  2.1 백엔드 service_url → /openai/v1 (gpt도 동일 계정)
  2.2 입구 path-route → body-route 변환 (gpt path→body 주입)
  2.3 cross-backend 다운그레이드 분기 제거 → same-backend body model rewrite
  2.4 max_tokens→max_completion_tokens 처리 v1에서 유지 확인

Phase 3 — GitBook (한국어)
  3.1 SUMMARY.md + 10개 챕터 (★ 페이지 우선)
  3.2 기존 README 내용 한국어 재구성·분할
  3.3 learn.microsoft.com 링크·플레이스홀더 정리

Phase 4 — Admin UI 한국어화 (별도 Phase)
  4.1 main을 한국어 문자열 SOT로 참조
  4.2 i18n 4개 커밋이 바꾼 표시 문자열만 한국어로 치환
  4.3 c4a8afc(Copilot 클라이언트 기능)는 보존; 기능+번역 섞인 파일(Monitoring.tsx)은 수동 적용
  4.4 acr build → 이미지 재배포

Phase 5 — 정리
  5.1 검증 스택 destroy (게이트웨이 RG + 모사 Foundry RG)
  5.2 변경 커밋
```
> Phase 1·2는 짝(IaC가 단일계정 만들고 정책이 그 경로로 라우팅). 둘이 같이 검증돼야 의미. Phase 3는 1·2 확정 후 병행 가능. Phase 4는 독립.

### 6.2 핵심 리스크 & 완화
| 리스크 | 영향 | 완화 |
|---|---|---|
| **gpt path→body 변환 실패** | Copilot/VS Code가 gpt 못 씀 | **Phase 0에서 먼저 검증**. 실패 시 gpt만 path-route 백엔드 유지(혼합)로 후퇴 |
| `data` 계정이 `local_auth_enabled` 미노출 | precondition 검증 불가 | plan에서 확인, 미노출 시 `az` 사전점검 스크립트로 대체 |
| APIM known issue (v1 OpenAPI 3.1 import) | API 정의 import 실패 | Foundry API의 wildcard(OpenAPI import 없음) 패턴 사용 |
| 단일 계정 쿼터 부족 | gpt+OSS 합산 TPM 초과 | 재사용이라 고객 기존 쿼터 사용. 검증 스택은 capacity 작게 |
| reasoning 모델 파라미터(`max_tokens`) | gpt-5 계열 400 | 현재 정책 처리 v1에서 유지 검증(Phase 0 항목 4) |
| 정책 단순화 중 회귀 | 기존 greenfield 깨짐 | reuse 토글 기본 false → greenfield 경로 무변경이 원칙 |
| Admin UI main 통째 가져오기 | Copilot 기능 손실 | 파일별 선별(i18n만), c4a8afc 보존 |

### 6.3 완료 기준 (Definition of Done)
- [ ] Phase 0 스모크 5개 항목 통과(또는 후퇴 결정 문서화)
- [ ] `reuse_foundry=true` plan 시 **계정·모델 생성 0, PE/RBAC만**
- [ ] `reuse_foundry=false`(기본)에서 **기존 greenfield 동작 무변경**
- [ ] 로컬에서 gpt·grok·DeepSeek 전부 `/openai/...` 입구로 200
- [ ] same-backend 다운그레이드 동작(헤더 `x-ai-gateway-*` 확인)
- [ ] `terraform fmt` / `validate` 통과
- [ ] GitBook 10개 챕터, ★ 페이지 완성, SUMMARY.md 동기화
- [ ] Admin UI 한국어 표시, Copilot 기능 유지, 빌드 통과
- [ ] 검증 스택 destroy 완료

### 6.4 영향 받는 파일 (예상)
- `infra/modules/foundry/main.tf` (reuse 토글), `infra/modules/openai/main.tf` (count gate)
- `infra/main.tf` (모듈 호출 인자), `infra/variables.tf`, `infra/terraform.tfvars.example`
- `policies/openai-pipeline.xml.tftpl`, `policies/foundry-pipeline.xml.tftpl`
- `scripts/smoke-v1-gateway.sh` (신규), `scripts/smoke-v1-backend.sh` (신규)
- `docs/**` (신규 GitBook)
- `app/admin-ui/spa/src/**` (Phase 4 한국어화)

> 참고: 브랜치 분기 시점에 `infra/providers.tf`에 미커밋 변경(remote state storage account 이름)이 있었다. 이는 본 설계와 무관한 환경별 backend 설정이므로 이 작업 범위에서 다루지 않는다.

---

## 부록: 확인된 공식 문서 사실 (근거)
- **v1 GA API는 `api-version` 쿼리 불필요**, OpenAI client 호환, DeepSeek·Grok도 v1 chat completions 지원. base_url은 `…openai.azure.com/openai/v1/` 와 `…services.ai.azure.com/openai/v1/` 둘 다 허용. [v1 lifecycle](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/api-version-lifecycle)
- **단일 AIServices(Foundry) 계정에 gpt(Azure 직판) + 파트너(grok/DeepSeek) 동시 배포 가능**, 통합 엔드포인트. [Foundry models overview](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/foundry-models-overview)
- **chat completions는 레거시 아님** — Responses와 함께 둘 다 GA. Responses는 stateful(`input`, `previous_response_id`), OSS 미지원. [Responses API](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/responses)
- **Claude Code는 Anthropic Messages(`/v1/messages`)만** 사용. Foundry의 Claude 배포는 `/anthropic` 경로, Entra ID 인증 가능. [Gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol), [CC on Foundry](https://code.claude.com/docs/en/microsoft-foundry)
- **APIM known issue**: 2025-04-01-preview Azure OpenAI 스펙은 OpenAPI 3.1을 쓰며 APIM이 완전 지원하지 않음. [v1 lifecycle](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/api-version-lifecycle)
