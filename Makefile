# gatezero-platform — task runner
# Windows: gunakan `just` (lihat justfile) atau Git Bash.

SHELL := /bin/bash
.DEFAULT_GOAL := help

ENV ?= dev

.PHONY: help
help: ## Tampilkan daftar target
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

## ---------- setup ----------

.PHONY: install-hooks
install-hooks: ## Pasang pre-commit hook
	pre-commit install
	pre-commit install --hook-type commit-msg

.PHONY: tools
tools: ## Cek tool yang dibutuhkan
	@for t in docker kubectl helm sops age trivy cosign kubeconform yamllint hadolint shellcheck gitleaks; do \
		if command -v $$t >/dev/null 2>&1; then echo "  ok   $$t"; else echo "  MISS $$t"; fi; \
	done

## ---------- lint ----------

.PHONY: lint
lint: lint-yaml lint-docker lint-shell lint-k8s ## Semua lint

.PHONY: lint-yaml
lint-yaml: ## Lint YAML
	yamllint -c .yamllint.yaml .

.PHONY: lint-docker
lint-docker: ## Lint Dockerfile
	@find . -name 'Dockerfile*' -not -path './vendor/*' -exec hadolint {} +

.PHONY: lint-shell
lint-shell: ## Lint shell script
	@find ci/scripts -name '*.sh' -exec shellcheck {} +

.PHONY: lint-k8s
lint-k8s: ## Validasi schema manifest kubernetes
	@find platform/gitops security -name '*.yaml' -not -name '.*' \
		-exec kubeconform -strict -ignore-missing-schemas -summary {} +

## ---------- security ----------

.PHONY: secrets-scan
secrets-scan: ## Scan secret plaintext di repo
	gitleaks detect --no-banner --redact

.PHONY: secrets-status
secrets-status: ## Pastikan semua file *.enc.yaml benar-benar terenkripsi
	@shopt -s nullglob; files=(platform/bootstrap/*/*.enc.yaml platform/gitops/overlays/*/*.enc.yaml); \
	if [ $${#files[@]} -eq 0 ]; then echo "belum ada file terenkripsi"; \
	else sops filestatus "$${files[@]}"; fi

.PHONY: security
security: secrets-scan ## Trivy config + fs scan
	trivy config --severity HIGH,CRITICAL --exit-code 1 .
	trivy fs --scanners vuln,secret --severity HIGH,CRITICAL --exit-code 1 .

## ---------- ansible / bootstrap cluster ----------

.PHONY: ansible-deps
ansible-deps: ## Install koleksi Ansible
	ansible-galaxy collection install -r platform/bootstrap/ansible/requirements.yml

.PHONY: ansible-syntax
ansible-syntax: ## Syntax-check playbook bootstrap
	cd platform/bootstrap/ansible && ansible-playbook site.yml --syntax-check

.PHONY: bootstrap
bootstrap: ## Bootstrap cluster kubeadm (butuh secrets.env.enc)
	cd platform/bootstrap/ansible && ./run.sh site.yml

.PHONY: cluster-verify
cluster-verify: ## Verifikasi cluster (read-only)
	cd platform/bootstrap/ansible && ./run.sh playbooks/90-verify.yml

.PHONY: galaxy-build
galaxy-build: ## Build collection Ansible Galaxy
	cd platform/bootstrap/ansible && ansible-galaxy collection build --force

.PHONY: galaxy-publish
galaxy-publish: ## Publish ke Ansible Galaxy (butuh ANSIBLE_GALAXY_API_KEY)
	cd platform/bootstrap/ansible && ansible-galaxy collection publish ./gatezero-kubeadm_bootstrap-*.tar.gz

## ---------- supply chain ----------

.PHONY: sbom
sbom: ## Generate SBOM CycloneDX
	syft dir:. -o cyclonedx-json=sbom-root.cdx.json

.PHONY: scan-image
scan-image: ## Scan image (IMG=...)
	trivy image --severity HIGH,CRITICAL --exit-code 1 $(IMG)

## ---------- benchmark ----------

.PHONY: bench
bench: ## Benchmark baseline VM (lihat infra/benchmark)
	bash infra/benchmark/scripts/run-all.sh

## ---------- housekeeping ----------

.PHONY: clean
clean: ## Bersihkan artefak lokal
	rm -rf bin dist sbom-*.json trivy-report.json lynis-report.dat
