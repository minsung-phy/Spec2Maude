.PHONY: help check-tools build translate run-fib run-main validate-invalid test-smoke test-official test-all clean

DUNE ?= dune
SPEC2MAUDE ?= ./spec2maude
MAUDE_BIN ?= maude
OUTPUT ?= output.maude
FIB_N ?= 5
FILE ?= wat_examples/global-get.wat
EXPORT ?= main
LIMIT ?= 20
TIMEOUT ?= 10
ARTIFACT_DIR ?=

help:
	@printf '%s\n' \
	  'Spec2Maude make targets:' \
	  '' \
	  '  make check-tools        Check dune, maude, and optional spec-test tools' \
	  '  make build              Build OCaml executables and create ./spec2maude' \
	  '  make translate          Generate output.maude from wasm-3.0/*.spectec' \
	  '  make run-fib            Run wat_examples/fib.wat with FIB_N=5 by default' \
	  '  make run-main FILE=...  Run exported/main function from a WAT/Wasm file' \
	  '  make validate-invalid   Show official validator rejection on invalid-result-type.wat' \
	  '  make test-smoke         Run local smoke tests' \
	  '  make test-official      Run official WebAssembly spec tests subset' \
	  '  make test-all           Run all configured benchmark roots' \
	  '' \
	  'Useful variables:' \
	  '  MAUDE_BIN=maude OUTPUT=output.maude FIB_N=5 LIMIT=20 TIMEOUT=10'

check-tools:
	@command -v $(DUNE) >/dev/null || { echo 'missing dune'; exit 1; }
	@command -v $(MAUDE_BIN) >/dev/null || { echo 'missing maude; set MAUDE_BIN=/path/to/maude'; exit 1; }
	@command -v wast2json >/dev/null || echo 'optional: missing wast2json; official .wast tests need WABT'
	@echo 'tool check ok'

build:
	$(DUNE) build ./main.exe ./wasm_to_maude.exe ./spec2maude.exe
	install -m 755 _build/default/spec2maude.exe $(SPEC2MAUDE)

translate: build
	$(SPEC2MAUDE) translate -o $(OUTPUT)

run-fib: build
	$(SPEC2MAUDE) run wat_examples/fib.wat --fib $(FIB_N)

run-main: build
	$(SPEC2MAUDE) run $(FILE) --export $(EXPORT)

validate-invalid: build
	! $(SPEC2MAUDE) validate wat_examples/invalid-result-type.wat
	@echo 'invalid input rejected as expected'

test-smoke: build
	$(SPEC2MAUDE) test smoke --timeout $(TIMEOUT) $(if $(ARTIFACT_DIR),--artifact-dir $(ARTIFACT_DIR),)

test-official: build
	$(SPEC2MAUDE) test official --limit $(LIMIT) --timeout $(TIMEOUT) $(if $(ARTIFACT_DIR),--artifact-dir $(ARTIFACT_DIR),)

test-all: build
	$(SPEC2MAUDE) test all --limit $(LIMIT) --timeout $(TIMEOUT) $(if $(ARTIFACT_DIR),--artifact-dir $(ARTIFACT_DIR),)

clean:
	$(DUNE) clean
