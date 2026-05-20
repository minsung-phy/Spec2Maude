# Spec2Maude 문서 안내

현재 상태를 볼 때는 아래 순서로 읽으면 된다.

1. `docs/limitation.md`
   - 현재 C1 limitation의 기준 문서.
   - isomorphic하지 않은 항목, 실행이 안 되는 항목, 아직 샘플 문제인지 미분류인 항목을 한국어로 정리한다.

2. `STATUS.md`
   - 현재 baseline 상태, 재생성/테스트 명령, 다음 작업 목록.

3. `docs/HowToTest.md`
   - 수동 Maude smoke test 모음.

## 세부 audit 증거

아래 파일들은 평소에 전부 읽을 필요는 없다. 필요할 때만 근거 확인용으로 보면 된다.

- `docs/archive/current-c1/`
  - 최근 C1 실행/limitation/debug 관련 상세 report.
- `docs/archive/c1-coverage/`
  - 전체 source-to-output coverage/isomorphism audit 증거.
- `docs/archive/c1-prelude/`
  - header/footer/prelude genericity audit 증거.
- `docs/archive/c1-validation/`
  - strict validation lowering audit 증거.
- `docs/archive/validation_281_summary.md`
  - 281/281 validation lowering 완료 요약의 historical snapshot.

## 원칙

- root와 `docs/` 루트는 짧게 유지한다.
- 상세 report는 삭제하지 않고 `docs/archive/` 아래에 보관한다.
- 현재 결론은 `docs/limitation.md`에 합쳐서 관리한다.
