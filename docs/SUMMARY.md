# Table of contents

* [소개](README.md)

## 개요

* [무엇인가](01-overview/what-is-this.md)
* [동작 방식](01-overview/how-it-works.md)
* [핵심 개념](01-overview/concepts.md)

## 사전 준비

* [Azure 요구사항](02-prerequisites/azure-requirements.md)
* [Entra ID 객체](02-prerequisites/entra-objects.md)
* [Greenfield vs Brownfield 결정](02-prerequisites/decide-greenfield-vs-brownfield.md)

## 배포

* [배포 개요](03-deploy/overview.md)
* [상태 백엔드 부트스트랩](03-deploy/bootstrap-state.md)
* [tfvars 구성](03-deploy/configure-tfvars.md)
* [첫 번째 apply](03-deploy/first-apply.md)
* [이미지 빌드·푸시](03-deploy/build-push-images.md)
* [앱 등록 및 두 번째 apply](03-deploy/app-registration-second-apply.md)
* [Seed 및 최종 설정](03-deploy/seed-and-finalize.md)

## 기존 Foundry 재사용

* [재사용 개요](04-reuse-foundry/overview.md)
* [계정 잠금 준비](04-reuse-foundry/prepare-account.md)
* [tfvars 구성](04-reuse-foundry/configure-tfvars.md)
* [Plan 검증 및 apply](04-reuse-foundry/plan-and-apply.md)

## 검증

* [스모크 테스트](05-verify/smoke-test.md)
* [백엔드 격리 테스트](05-verify/backend-isolation.md)

## 운영

* [설정 변경](06-operate/config-changes.md)
* [모니터링](06-operate/monitoring.md)
* [비용 관리](06-operate/cost-management.md)
* [스케일 및 SKU 변경](06-operate/scale-sku.md)
* [정리](06-operate/cleanup.md)

## 클라이언트 연동

* [클라이언트 개요](07-connect-clients/overview.md)
* [VS Code BYOK](07-connect-clients/vscode.md)
* [GitHub Copilot CLI](07-connect-clients/copilot-cli.md)
* [opencode](07-connect-clients/opencode.md)
* [직접 호출 (curl)](07-connect-clients/direct-call.md)

## 아키텍처 상세

* [정책 흐름](08-architecture/policy-flow.md)
* [모듈 구조](08-architecture/module-structure.md)
* [보안 설계](08-architecture/security-design.md)
* [Cosmos DB 설정 스키마](08-architecture/cosmos-schema.md)

## 향후 확장

* [확장 개요](09-future/overview.md)
* [A — Claude Code 입구](09-future/extension-a-claude-code.md)
* [B — Responses API](09-future/extension-b-responses-api.md)
* [C — Entra ID 클라이언트 인증](09-future/extension-c-entra-client-auth.md)

## 레퍼런스

* [변수 전체 목록](10-reference/variables.md)
* [출력 전체 목록](10-reference/outputs.md)
* [비용 및 정리](10-reference/cost-cleanup.md)
* [Gotcha 모음](10-reference/gotchas.md)
