# Spec2Maude Translator

<div align="middle">
  <strong> WebAssembly(Wasm) 명세 언어 SpecTec의 AST를 Maude 정형 모델로 자동 변환하는 시스템
</div>

<br> <div align="right">
  <strong>포항공과대학교 SVLab 이민성</strong><br>
  <strong>2026.02.24</strong>
</div>

---

## 1. Introduction
본 프로젝트는 SpecTec의 AST를 분석하여 Maude의Algebraic Specification으로 전이시키는 자동 변환기입니다. 

단순 텍스트 변환이 아닌 OCaml 메모리상의 AST 객체를 직접 Mapping함으로써 명세의 논리적 무결성을 보존하고 실행 가능한 정형 모델을 구축합니다.



---

## 2. Repository Structure
본 저장소는 SpecTec 프레임워크를 기반으로 하며, 핵심 작업물은 다음과 같은 구조로 관리됩니다.

```text
/
├── document/
│   └── ARCHITECTURE.md    <-- 상세 변환 로직 및 Mapping Rules 명세서
├── dsl/
│   └── pretype.maude      <-- Wasm 타입 시스템 구동을 위한 기초 Maude 환경
├── data/
│   └── *.ast              <-- 번역의 근거가 되는 SpecTec Raw AST 데이터
│   └── *.maude            <-- Spectec 명세를 손으로 직접 Maude로 번역한 코드
├── lib/
│   └── *                  <-- Spectec의 라이브러리들
├── wasm-3.0/
│   └── *.spectec          <-- 입력값으로 사용되는 원본 Wasm 명세 파일
├── output/
│   └── *.maude            <-- 번역기를 통해 생성된 최종 Maude 코드
├── translator/
│   └── *.ml               <-- 번역기 구현 과정
├── translator.ml          <-- [Core] AST 매핑 로직이 담긴 메인 번역기 소스
└── main.ml                <-- SpecTec 파이프라인 구동 및 번역기 호출 모듈
```

---

## 3. Environment Setup (환경 설정)

본 프로젝트를 빌드하고 실행하기 위해 아래의 환경 구성이 필요합니다.

### 3.1 OCaml & Build Tools

* **OCaml**: v4.14 이상 권장
* **Dune**: OCaml 빌드 시스템
* **Opam**: 패키지 매니저를 통해 아래 필수 라이브러리를 설치하십시오.
  ```bash
  opam install dune zarith ocamlfind menhir
  ```

### 3.2 Maude Engine

* 생성된 모델의 실행 및 검증을 위해 **Maude 3.x** 버전이 설치되어 있어야 합니다.

---

## 4. How to Run (실행 방법)

### 4.1 번역기 빌드 및 실행

`dune`을 통해 번역기를 실행하고, 모든 명세를 하나의 Maude 파일로 추출합니다.

```bash
# 전체 SpecTec 명세를 Maude 코드로 변환
dune exec ./main.exe -- wasm-3.0/* > output.maude
```

---

## 5. Core Logic Highlights

상세 매핑 규칙은 [Mapping_Specification.md](https://github.com/minsung-phy/Spec2Maude/blob/main/document/Mapping_Specification.md)에 기술되어 있으며, 주요 변환 특징은 다음과 같습니다.

* **TypD**: 합집합 타입(Union Types) 처리를 위한 **검증 권한 위임(ceq)** 로직 구현.
* **DecD**: 함수의 개별 Clause를 Maude의 패턴 매칭 등식(eq)으로 직렬화.
* **IfPr**: $uN(N)$ 등 파라미터화된 타입의 수치 범위($0 \le i < 2^N$)를 **산술 조건문**으로 매핑.

---

## 🎓 For Reviewers

* **로직 발전 과정**: `translator/*.ml` 파일을 통해 초기 단순 매핑에서 복합 타입 처리까지의 **고도화 과정**을 확인하실 수 있습니다.
* **데이터 무결성**: 메모리상의 AST를 직접 덤프한 `.ast` 데이터와 최종 생성된 `.maude` 코드를 대조함으로써 변환 로직의 정확성을 검증하였습니다.

---

## ⚖️ License
Copyright (c) 2026 Minsung Lee (POSTECH SVLab). 
This project is licensed under the MIT License.
