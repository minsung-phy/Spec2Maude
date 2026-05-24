# Spec2Maude 문서 안내

현재 상태를 볼 때는 아래 순서로 읽으면 된다.

1. `../STATUS.md`
   - 현재 C1 baseline handoff 문서.
   - 새 Codex 채팅을 열 때 가장 먼저 읽힐 문서.

2. `docs/limitation.md`
   - 현재 limitation의 기준 문서.
   - non-isomorphic 항목, 실행 limitation, 교수님께 물어볼 질문을 한국어로 정리한다.

3. `docs/HowToTest.md`
   - 수동 Maude smoke test와 자주 쓰는 실행 예시.

4. 최신 evidence artifacts
   - `artifacts/rule-concrete-audit-20260525_004500/summary.md`
   - `artifacts/c1-probe-matrix-20260525_004421/probe_summary.md`

## Archive 정책

`docs/archive/` 아래 문서들은 history/evidence다. 현재 결론을 보려면 먼저
`STATUS.md`와 `docs/limitation.md`를 본다.

평소에는 아래 archive를 전부 읽을 필요 없다.

- `docs/archive/c1-coverage/`
  - 전체 source-to-output coverage/isomorphism audit 증거.
- `docs/archive/c1-prelude/`
  - header/footer/prelude genericity audit 증거.
- `docs/archive/c1-validation/`
  - strict validation lowering audit 증거.
- `docs/archive/current-c1/`
  - 최근 C1 실행/debug/detail report.

## 현재 원칙

- root와 `docs/` 루트는 짧게 유지한다.
- 상세 report는 삭제하지 않고 `docs/archive/` 아래에 둔다.
- 현재 결론은 `STATUS.md`와 `docs/limitation.md`에만 합쳐서 관리한다.
