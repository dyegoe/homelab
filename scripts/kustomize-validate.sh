#!/usr/bin/env bash
# Validates every kustomization.yaml in the repo against the Kubernetes API + CRD schemas.
# Run directly, or via the `kubeconform` pre-commit hook in .pre-commit-config.yaml.
set -euo pipefail

mkdir -p .kubeconform-cache

status=0

while IFS= read -r -d '' dir; do
  echo "==> ${dir}"
  if ! kubectl kustomize "${dir}" | kubeconform \
    -strict \
    -summary \
    -ignore-missing-schemas \
    -cache .kubeconform-cache \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'; then
    status=1
  fi
done < <(find . -name kustomization.yaml -exec dirname {} \; | sort -u | tr '\n' '\0')

exit "${status}"
