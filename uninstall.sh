#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: uninstall.sh --source-dir PATH [--namespace NAME ...]

Fully remove the direct Open Data Hub installation from the current context.

Options:
  --source-dir PATH  Required: existing opendatahub-operator checkout.
  --namespace NAME   Also delete this namespace; may be repeated.
  -h, --help         Show this help.

WARNING: Deletes DSC/DSCI, ODH custom resources and CRDs, operator resources,
and discovered platform namespaces, including their workloads and PVCs.
Back up data before running. External dependency operators are not removed.
Each deletion waits up to 300s. Finalizers are never forcibly removed.
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

source_dir=''
namespaces='opendatahub-operator-system'
odh_crds=''

add_namespace() {
  local namespace=$1
  [[ -n $namespace ]] || return 0
  [[ $namespace =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "Invalid namespace: $namespace"
  case "$namespace" in
    default|kube-*|openshift-*) fail "Refusing to delete shared system namespace: $namespace" ;;
  esac
  if [[ $'\n'$namespaces$'\n' != *$'\n'"$namespace"$'\n'* ]]; then
    namespaces+=$'\n'"$namespace"
  fi
}

while (($#)); do
  option=$1
  case "$option" in
    -h|--help) usage; exit 0 ;;
    --source-dir|--namespace)
      (($# >= 2)) || fail "$option requires a value"
      [[ -n $2 && $2 != --* ]] || fail "$option requires a value"
      value=$2
      shift 2
      ;;
    --source-dir=*|--namespace=*)
      value=${option#*=}
      option=${option%%=*}
      [[ -n $value ]] || fail "$option requires a value"
      shift
      ;;
    *) fail "Unknown argument: $option. Use --help." ;;
  esac
  case "$option" in
    --source-dir) source_dir=$value ;;
    --namespace) add_namespace "$value" ;;
  esac
done

[[ -n $source_dir && -d $source_dir ]] || fail '--source-dir must name an existing checkout'
source_dir=$(cd -- "$source_dir" && pwd -P)
[[ -f $source_dir/Makefile && -f $source_dir/config/default/kustomization.yaml ]] || fail "Not an operator checkout: $source_dir"
for executable in make kubectl go; do
  command -v "$executable" >/dev/null 2>&1 || fail "Required command not found: $executable"
done
if [[ $(uname -s) == Darwin ]]; then
  command -v gsed >/dev/null 2>&1 || fail 'GNU sed is required on macOS: brew install gnu-sed'
fi

context=$(kubectl config current-context)
printf 'Context: %s\n' "$context"
kubectl cluster-info --request-timeout=30s
owner=$(kubectl get deployment opendatahub-operator-controller-manager \
  -n opendatahub-operator-system --ignore-not-found \
  -o jsonpath='{.metadata.ownerReferences[?(@.kind=="ClusterServiceVersion")].name}' --request-timeout=30s)
[[ -z $owner ]] || fail 'This operator is managed by OLM; use its OLM uninstall workflow'

make -C "$source_dir" prepare yq \
  ODH_PLATFORM_TYPE=OpenDataHub OPERATOR_NAMESPACE=opendatahub-operator-system
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/odh-uninstall.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
"$source_dir/bin/kustomize" build "$source_dir/config/default" > "$work_dir/deployment.yaml"
"$source_dir/bin/yq" eval 'select(.kind != "CustomResourceDefinition" and .kind != "Namespace")' \
  "$work_dir/deployment.yaml" > "$work_dir/operator.yaml"

# Inventory namespaces before deleting the CRs that record their configuration.
crd_inventory=$(kubectl get crd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.group}{"\n"}{end}' --request-timeout=30s)
while IFS=$'\t' read -r resource group; do
  case "$group" in
    opendatahub.io|*.opendatahub.io) odh_crds+="$resource"$'\n' ;;
  esac
done <<< "$crd_inventory"

has_crd() {
  [[ $'\n'$odh_crds == *$'\n'"$1"$'\n'* ]]
}

collect_namespaces() {
  local resource=$1
  local jsonpath=$2
  local result namespace
  if has_crd "$resource"; then
    result=$(kubectl get "$resource" -o "jsonpath=$jsonpath" --request-timeout=30s)
    while IFS= read -r namespace; do
      add_namespace "$namespace"
    done <<< "$result"
  fi
}

collect_namespaces dscinitializations.dscinitialization.opendatahub.io \
  '{range .items[*]}{.spec.applicationsNamespace}{"\n"}{.spec.monitoring.namespace}{"\n"}{end}'
collect_namespaces datascienceclusters.datasciencecluster.opendatahub.io \
  '{range .items[*]}{.spec.components.workbenches.workbenchNamespace}{"\n"}{.spec.components.modelregistry.registriesNamespace}{"\n"}{.status.components.workbenches.workbenchNamespace}{"\n"}{.status.components.modelregistry.registriesNamespace}{"\n"}{end}'
collect_namespaces aihubs.components.platform.opendatahub.io \
  '{range .items[*]}{.spec.applicationNamespace}{"\n"}{.spec.instancesNamespace}{"\n"}{end}'
collect_namespaces workbenches.components.platform.opendatahub.io \
  '{range .items[*]}{.status.applicationsNamespace}{"\n"}{.status.workbenchNamespace}{"\n"}{end}'
owned_namespaces=$(kubectl get namespace -l opendatahub.io/generated-namespace=true \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' --request-timeout=30s)
while IFS= read -r namespace; do
  add_namespace "$namespace"
done <<< "$owned_namespaces"

printf 'WARNING: Permanently deleting ODH resources and data in these namespaces:\n%s\n' "$namespaces"
printf 'ODH CRDs to delete:\n%s' "$odh_crds"

delete_instances() {
  local resource=$1
  if has_crd "$resource"; then
    kubectl delete "$resource" --all --all-namespaces --ignore-not-found=true \
      --cascade=foreground --wait=true --timeout=300s --request-timeout=30s
  fi
}

# Keep operator and module controllers alive until their finalizers finish.
delete_instances datascienceclusters.datasciencecluster.opendatahub.io
delete_instances dscinitializations.dscinitialization.opendatahub.io
delete_instances platforms.config.opendatahub.io
while IFS= read -r resource; do
  [[ -n $resource ]] || continue
  case "$resource" in
    datascienceclusters.datasciencecluster.opendatahub.io|dscinitializations.dscinitialization.opendatahub.io|platforms.config.opendatahub.io) continue ;;
  esac
  delete_instances "$resource"
done <<< "$odh_crds"

# Namespaces are removed while controllers can still finalize namespaced objects.
while IFS= read -r namespace; do
  [[ $namespace != opendatahub-operator-system ]] || continue
  kubectl delete namespace "$namespace" --ignore-not-found=true \
    --wait=true --timeout=300s --request-timeout=30s
done <<< "$namespaces"

kubectl delete -f "$work_dir/operator.yaml" -n opendatahub-operator-system \
  --ignore-not-found=true --wait=true --timeout=300s --request-timeout=30s
while IFS= read -r resource; do
  [[ -n $resource ]] || continue
  kubectl delete crd "$resource" --ignore-not-found=true \
    --wait=true --timeout=300s --request-timeout=30s
done <<< "$odh_crds"
kubectl delete namespace opendatahub-operator-system --ignore-not-found=true \
  --wait=true --timeout=300s --request-timeout=30s

printf 'Full ODH removal complete.\n'
