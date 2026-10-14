#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh --source-dir PATH [OPTIONS]

Install the Open Data Hub operator directly on the current kubectl context.

Options:
  --source-dir PATH  Required: existing opendatahub-operator checkout.
  --image IMAGE      Operator image (default: quay.io/opendatahub/opendatahub-operator:latest).
  --dsci-file PATH   One DSCInitialization manifest (default: checkout's DSCI sample).
  --dsc-file PATH    One DataScienceCluster manifest (default: no DSC is applied).
  -h, --help         Show this help.

File paths are resolved relative to the directory where you run this script.
Operator namespace: opendatahub-operator-system. Readiness timeout: 300s per step.
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

source_dir=''
image='quay.io/opendatahub/opendatahub-operator:latest'
dsci_file=''
dsc_file=''

while (($#)); do
  option=$1
  case "$option" in
    -h|--help)
      usage
      exit 0
      ;;
    --source-dir|--image|--dsci-file|--dsc-file)
      (($# >= 2)) || fail "$option requires a value"
      [[ -n $2 && $2 != --* ]] || fail "$option requires a value"
      value=$2
      shift 2
      ;;
    --source-dir=*|--image=*|--dsci-file=*|--dsc-file=*)
      value=${option#*=}
      option=${option%%=*}
      [[ -n $value ]] || fail "$option requires a value"
      shift
      ;;
    *) fail "Unknown argument: $option. Use --help." ;;
  esac
  case "$option" in
    --source-dir) source_dir=$value ;;
    --image) image=$value ;;
    --dsci-file) dsci_file=$value ;;
    --dsc-file) dsc_file=$value ;;
  esac
done

[[ -n $source_dir ]] || fail '--source-dir is required'
[[ -d $source_dir ]] || fail "Source directory does not exist: $source_dir"
source_dir=$(cd -- "$source_dir" && pwd -P)
[[ -f $source_dir/Makefile ]] || fail "No Makefile found in: $source_dir"

if [[ -z $dsci_file ]]; then
  dsci_file="$source_dir/config/samples/dscinitialization_v2_dscinitialization.yaml"
fi
[[ -f $dsci_file && -r $dsci_file ]] || fail "DSCI file is not readable: $dsci_file"
if [[ -n $dsc_file ]]; then
  [[ -f $dsc_file && -r $dsc_file ]] || fail "DSC file is not readable: $dsc_file"
fi

for executable in make kubectl go; do
  command -v "$executable" >/dev/null 2>&1 || fail "Required command not found: $executable"
done
if [[ $(uname -s) == Darwin ]]; then
  command -v gsed >/dev/null 2>&1 || fail 'GNU sed is required on macOS: brew install gnu-sed'
fi

context=$(kubectl config current-context)
printf 'Context: %s\nImage: %s\n' "$context" "$image"
kubectl cluster-info --request-timeout=30s

make -C "$source_dir" deploy \
  "IMG=$image" \
  ODH_PLATFORM_TYPE=OpenDataHub \
  OPERATOR_NAMESPACE=opendatahub-operator-system

kubectl rollout status deployment/opendatahub-operator-controller-manager \
  -n opendatahub-operator-system --timeout=300s --request-timeout=30s

apply_and_wait() {
  local manifest=$1
  local kind=$2
  local resource

  resource=$(kubectl create --dry-run=client --validate=false -f "$manifest" -o name --request-timeout=30s)
  [[ -n $resource && $resource != *$'\n'* ]] || fail "$manifest must contain exactly one $kind resource"
  case "$resource" in
    "$kind".*/*|"$kind"/*) ;;
    *) fail "Expected $kind in $manifest; found: $resource" ;;
  esac
  kubectl apply -f "$manifest" --request-timeout=30s
  printf 'Applied: %s\n' "$resource"
  kubectl wait --for=jsonpath='{.status.phase}'=Ready "$resource" \
    --timeout=300s --request-timeout=30s
}

apply_and_wait "$dsci_file" dscinitialization
if [[ -n $dsc_file ]]; then
  apply_and_wait "$dsc_file" datasciencecluster
fi

printf 'Installation complete. Operator and requested configuration are ready.\n'

dashboard_info=$(kubectl get datascienceclusters.datasciencecluster.opendatahub.io \
  -o jsonpath='{range .items[*]}{.spec.components.dashboard.standard.managementState}{"\t"}{.spec.components.dashboard.maasPortal.managementState}{"\t"}{.status.components.dashboard.url}{"\n"}{end}' \
  --request-timeout=30s)
IFS=$'\t' read -r dashboard_standard dashboard_maas dashboard_url <<< "$dashboard_info"

case "$dashboard_standard $dashboard_maas" in
  *Managed*|*Unmanaged*)
    if [[ -z $dashboard_url ]]; then
      gateway_domain=$(kubectl get gatewayconfigs.services.platform.opendatahub.io \
        -o jsonpath='{.items[0].status.domain}' --request-timeout=30s)
      if [[ -n $gateway_domain ]]; then
        dashboard_url="https://$gateway_domain"
      fi
    fi
    if [[ -n $dashboard_url ]]; then
      printf 'Dashboard: %s\n' "$dashboard_url"
    else
      printf 'Dashboard URL unavailable: the operator has not reported a URL yet.\n'
    fi
    ;;
  *) printf 'Dashboard URL unavailable: Dashboard is not enabled.\n' ;;
esac
