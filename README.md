# ODH Operator Installer

A Bash installer that deploys Open Data Hub using an existing operator checkout and a prebuilt operator image. It installs the operator directly with `make deploy`, applies a `DSCInitialization` (DSCI), and optionally applies a `DataScienceCluster` (DSC).

## Requirements

- Bash, `make`, Go compatible with the operator checkout, and `kubectl`.
- An existing `opendatahub-operator` checkout.
- Access to an OpenShift cluster as a cluster administrator, with the intended `kubectl` context selected.
- Network access to download the tools used by the checkout's Makefile, and cluster access to pull the selected image.
- On macOS, GNU sed: `brew install gnu-sed`.
- Any external operators required by the components you enable in your DSC.

## Usage

Install the default `latest` image and the checkout's default DSCI:

```bash
./install.sh --source-dir ~/dev/opendatahub-io/opendatahub-operator
```

Select an image and custom configuration files:

```bash
./install.sh \
  --source-dir ~/dev/opendatahub-io/opendatahub-operator \
  --image quay.io/opendatahub/opendatahub-operator:latest \
  --dsci-file ./dsci.yaml \
  --dsc-file ./dsc.yaml
```

Each option accepts `--name value` or `--name=value`. Quote paths containing spaces. Run `./install.sh --help` for the full interface.

The included `dsc-example.yaml` enables Dashboard, Workbenches, and AI Pipelines. Use it explicitly:

```bash
./install.sh \
  --source-dir ~/dev/opendatahub-io/opendatahub-operator \
  --dsc-file ./dsc-example.yaml
```

The example lists every component in the checkout's v2 DSC API. The example is not applied unless you pass it with `--dsc-file`.

| Option         | Required | Default                                                                   |
|----------------|----------|---------------------------------------------------------------------------|
| `--source-dir` | Yes      | None                                                                      |
| `--image`      | No       | `quay.io/opendatahub/opendatahub-operator:latest`                         |
| `--dsci-file`  | No       | `<source-dir>/config/samples/dscinitialization_v2_dscinitialization.yaml` |
| `--dsc-file`   | No       | No DSC is applied                                                         |

File paths are resolved relative to the directory where the script is invoked. Each custom configuration file must contain exactly one resource of the corresponding kind. Use manifests compatible with the selected operator image and checkout.

The script uses the current `kubectl` context and deploys to `opendatahub-operator-system`. It prints the selected context and image, checks cluster connectivity, deploys the operator, waits for its rollout, then applies and waits for the DSCI and optional DSC in that order. Each readiness wait has a 300-second timeout. The default DSCI uses `opendatahub` for the applications and monitoring namespaces; a custom DSCI can configure them.

At the end, the script prints the Dashboard link reported in the DSC status. If the Dashboard is enabled but the DSC has no URL, it uses the gateway domain reported by GatewayConfig. If the Dashboard is not enabled or no URL has been reported, it prints that the link is unavailable. The lookup also works with an existing DSC when `--dsc-file` is omitted.

Direct installations appear under **Workloads → Deployments**, not under **Installed Operators**, which lists OLM-managed operators. This installer does not migrate an existing OLM installation.

The operator image is pulled by the cluster; the script does not build or push it. The checkout's `make deploy` may download tools and update generated files, including image overrides in `config/manager/manager.yaml`. Review the checkout's Git diff after running it.

The script stops on the first error without rolling back completed steps. Re-running it applies the requested configuration again. Omitting `--dsc-file` leaves any existing DSC in place. Applying a DSC may deploy or remove components according to its management states.

## Full removal

**Warning:** This permanently deletes the platform's custom resources, ODH CRDs, the direct operator installation, and discovered platform namespaces. Deleting namespaces also deletes their workloads and PVCs. Back up data before running.

```bash
./uninstall.sh --source-dir ~/dev/opendatahub-io/opendatahub-operator
```

The script uses the current context. It discovers namespace names from DSCI, DSC, AIHub, Workbenches, and namespaces labeled `opendatahub.io/generated-namespace=true`. It also removes `opendatahub-operator-system`. To include an additional namespace, pass `--namespace NAME`; this option can be repeated. Shared system namespaces (`default`, `kube-*`, and `openshift-*`) are rejected before any deletion.

The script prints the namespaces and ODH CRDs it will delete. It deletes DSC first, then DSCI and Platform, waiting for foreground deletion while the operator and module controllers remain available to process finalizers. It removes remaining ODH custom resources and application namespaces before deleting the operator, ODH CRDs, and operator namespace. A failure stops subsequent steps; it never forcibly strips finalizers. Each deletion can wait up to 300 seconds.

ODH CRDs are identified by API groups equal to `opendatahub.io` or ending in `.opendatahub.io`. This includes module CRDs installed after the initial operator deployment. External dependency operators and their CRDs remain installed. The script is for direct installations and rejects an operator Deployment owned by an OLM ClusterServiceVersion.

The checkout's `make prepare yq` downloads required tools and prepares the deployment manifests before deletion. If a previous partial removal has already deleted the CRs recording a custom namespace, pass that namespace explicitly with `--namespace` so it can be cleaned up too. Run `./uninstall.sh --help` for usage.
