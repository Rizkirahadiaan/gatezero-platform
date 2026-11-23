# gatezero-platform — task runner (lintas platform, tanpa tab)
# Install: https://github.com/casey/just

set shell := ["bash", "-cu"]

env := "dev"

default:
    @just --list

# ---------- setup ----------

install-hooks:
    pre-commit install
    pre-commit install --hook-type commit-msg

tools:
    #!/usr/bin/env bash
    for t in docker kubectl helm sops age trivy cosign kubeconform yamllint hadolint shellcheck gitleaks; do
      if command -v "$t" >/dev/null 2>&1; then echo "  ok   $t"; else echo "  MISS $t"; fi
    done

# ---------- lint ----------

lint: lint-yaml lint-docker lint-shell lint-k8s

lint-yaml:
    yamllint -c .yamllint.yaml .

lint-docker:
    #!/usr/bin/env bash
    find . -name 'Dockerfile*' -not -path './vendor/*' -print0 | xargs -0 -r hadolint

lint-shell:
    #!/usr/bin/env bash
    find ci/scripts -name '*.sh' -print0 | xargs -0 -r shellcheck

lint-k8s:
    #!/usr/bin/env bash
    find platform/gitops security -name '*.yaml' -not -name '.*' -print0 \
      | xargs -0 -r kubeconform -strict -ignore-missing-schemas -summary

# ---------- security ----------

secrets-scan:
    gitleaks detect --no-banner --redact

secrets-status:
    #!/usr/bin/env bash
    shopt -s nullglob
    files=(platform/bootstrap/*/*.enc.yaml platform/gitops/overlays/*/*.enc.yaml)
    if [ ${#files[@]} -eq 0 ]; then echo "belum ada file terenkripsi"; exit 0; fi
    sops filestatus "${files[@]}"

security: secrets-scan
    trivy config --severity HIGH,CRITICAL --exit-code 1 .
    trivy fs --scanners vuln,secret --severity HIGH,CRITICAL --exit-code 1 .

# ---------- ansible ----------

ansible-deps:
    ansible-galaxy collection install -r platform/bootstrap/ansible/requirements.yml

ansible-syntax:
    cd platform/bootstrap/ansible && ansible-playbook site.yml --syntax-check

bootstrap:
    cd platform/bootstrap/ansible && ./run.sh site.yml

cluster-verify:
    cd platform/bootstrap/ansible && ./run.sh playbooks/90-verify.yml

galaxy-build:
    cd platform/bootstrap/ansible && ansible-galaxy collection build --force

galaxy-publish:
    cd platform/bootstrap/ansible && ansible-galaxy collection publish ./gatezero-kubeadm_bootstrap-*.tar.gz

# ---------- supply chain ----------

sbom:
    syft dir:. -o cyclonedx-json=sbom-root.cdx.json

scan-image img:
    trivy image --severity HIGH,CRITICAL --exit-code 1 {{img}}

# ---------- benchmark ----------

bench:
    bash infra/benchmark/scripts/run-all.sh

# ---------- housekeeping ----------

clean:
    rm -rf bin dist sbom-*.json trivy-report.json lynis-report.dat
