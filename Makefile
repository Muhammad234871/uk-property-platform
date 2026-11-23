# UK Property Platform — common commands
# Run `make` or `make help` to see everything.

VENV            ?= .venv
PY              := $(VENV)/bin/python
AIRFLOW_HOME    ?= $(HOME)/airflow-uk-property
AIRFLOW_VERSION := 3.3.2
PYTHON_VERSION  := 3.12
CONSTRAINTS     := https://raw.githubusercontent.com/apache/airflow/constraints-$(AIRFLOW_VERSION)/constraints-$(PYTHON_VERSION).txt

# Load .env if it exists (export every variable while sourcing it)
LOAD_ENV := set -a; [ -f .env ] && . ./.env; set +a

.DEFAULT_GOAL := help
.PHONY: help venv install airflow lint format test check tf-fmt tf-validate clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

venv: ## Create the project venv (.venv) with Python 3.12
	uv venv $(VENV) --python $(PYTHON_VERSION)

install: ## Install Airflow, providers and the project (editable) into .venv
	uv pip install --python $(PY) \
		"apache-airflow==$(AIRFLOW_VERSION)" \
		apache-airflow-providers-amazon \
		-e ".[dev]" \
		--constraint "$(CONSTRAINTS)"

airflow: ## Start this project's Airflow on http://localhost:8082
	@# Drop AIRFLOW__* vars inherited from the shell (e.g. ~/.bashrc for other
	@# projects) so this project's airflow.cfg is the only source of config.
	@for v in $$(env | grep -oE '^AIRFLOW__[A-Z0-9_]+'); do unset $$v; done; \
	$(LOAD_ENV); \
	export AIRFLOW_HOME="$(AIRFLOW_HOME)"; \
	export PYTHONPATH="$(CURDIR)"; \
	echo "AIRFLOW_HOME=$$AIRFLOW_HOME"; \
	"$(VENV)/bin/airflow" standalone

lint: ## Check code style and lint rules (no changes)
	$(VENV)/bin/ruff check .
	$(VENV)/bin/ruff format --check .

format: ## Auto-fix lint issues and format code
	$(VENV)/bin/ruff check --fix .
	$(VENV)/bin/ruff format .

test: ## Run pytest
	$(PY) -m pytest -q

check: lint test ## Lint + test (same as CI)

tf-fmt: ## Format all Terraform files
	terraform fmt -recursive terraform/

tf-validate: ## Check Terraform formatting and validate each stack
	terraform fmt -check -recursive terraform/
	@for dir in terraform/aws/bootstrap terraform/aws/main; do \
		if [ -d "$$dir/.terraform" ]; then \
			echo "validate $$dir"; terraform -chdir=$$dir validate || exit 1; \
		else \
			echo "skip $$dir (run terraform init there first)"; \
		fi; \
	done

clean: ## Remove caches and build leftovers
	find . -type d \( -name __pycache__ -o -name .pytest_cache -o -name .ruff_cache -o -name '*.egg-info' \) -prune -exec rm -rf {} +
