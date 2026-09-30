SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help scan-secrets scan-iac test-policies plan-dev check-all

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

scan-secrets: ## Scan filesystem strictly for leaked secrets, API keys, and credentials
	trivy fs --scanners secret --exit-code 1 .

scan-iac: ## Run Checkov static analysis across raw HCL definitions
	checkov -d terraform/ --framework terraform --compact --quiet

plan-dev: ## Initialize and compile Terraform execution plan to JSON
	cd terraform/environments/dev && \
	terraform init && \
	terraform plan -out=tfplan.binary && \
	terraform show -json tfplan.binary > tfplan.json

test-policies: ## Evaluate custom Conftest/Rego rules against compiled execution plan
	conftest test terraform/environments/dev/tfplan.json -p policies/

check-all: scan-secrets scan-iac plan-dev test-policies ## Execute full local validation sequence
