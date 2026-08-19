# Naming Conventions

One rule underneath all of them: **a name should tell you what kind of thing it
is and where it belongs, without opening it.**

Names are the cheapest documentation in the repo and the most expensive thing to
change later. CI enforces the patterns marked ✅ **enforced**.

---

## Quick reference

| Thing | Pattern | Example | Enforced |
| --- | --- | --- | --- |
| Service folder | `xplg-<name>` | `services/xplg-service/` | ✅ |
| Service descriptor | fixed names | `stack.yaml` `plugin.yaml` `params.yaml` | ✅ |
| Vessel folder | `compose` `helm` `kustomize` `ansible` `terraform` | `services/xplg-service/helm/` | ✅ |
| Platform overlay | `platforms/<platform>.<ext>` | `helm/platforms/openshift.yaml` | ✅ |
| Terraform target | `targets/<cloud>-<service>/` | `terraform/targets/aws-eks/` | ✅ |
| Feature overlay | `docker-compose.<feature>.yml` | `docker-compose.traefik.yml` | ✅ |
| Profile — file | `<shape>.<ext>` | `compose/profiles/ha.env` | ✅ |
| Profile — folder | `<shape>/` | `compose/profiles/ha/` | ✅ |
| Base compose | `docker-compose.yml` | — | ✅ |
| Compose overlay | `docker-compose.<concern>.yml` | `docker-compose.traefik.yml` | ✅ |
| Helm profile | `profiles/<shape>.yaml` | `helm/profiles/ha.yaml` | ✅ |
| Env var | `XPLG_<AREA>_<THING>` | `XPLG_TRAEFIK_UI_SERVERS` | ✅ |
| Port var | `<ROLE>_<KIND>_PORT` | `MASTER_HTTP_PORT` | ✅ |
| Node alias | `xplg-seed-<n>` | `xplg-seed-2` | |
| Node name | `<alias>-<role>` | `xplg-seed-2-ui` | |
| Container name | `<project>-<alias>-<role>` | `xplg-service-xplg-seed-1-ui` | |
| Image | `<registry>/<name>:<version>-<branch>` | `docker.xplg.com/xplg:8.2.0-Main` | |
| Git tag | `<service>/v<semver>` | `xplg-service/v1.0.0` | ✅ |
| Branch | `<type>/<short-desc>` | `fix/traefik-sticky-cookie` | |
| Doc file | `NN-kebab-title.md` | `03-docker-deploy.md` | ✅ |
| Shell script | `xplg-<verb>-<object>.sh` | `xplg-open-ports.sh` | |
| Ansible role | `<verb>_<object>` | `configure_nfs_client` | |
| Terraform module | `<cloud>-<resource>` | `aws-vpc` | |

---

## Services

```
✅  services/xplg-service/
✅  services/xplg-ai-services/
❌  services/XPLGService/          not kebab-case
❌  services/service/              not prefixed, not specific
❌  services/xplg-service-v2/      version belongs in VERSION, not the name
```

Lowercase, kebab-case, always `xplg-` prefixed. The folder name **is** the
service ID — it appears in `stack.yaml`, in CLI commands, in release artifact
names and in git tags. Renaming one is a breaking change.

`_template/` is the only exception; the underscore sorts it to the top and marks
it as not-a-service.

---

## Vessels

A vessel is one way of delivering the service. The folder name is fixed
vocabulary, not free text:

```
✅  compose/     packaging    docker + podman
✅  helm/        packaging    kubernetes via helm
✅  kustomize/   packaging    raw manifests + overlays
✅  ansible/     packaging    host configuration + deploy
✅  terraform/   provisioning creates the infrastructure

❌  docker/      ambiguous — compose or plain run?
❌  kubernetes/  use helm/ or kustomize/, whichever you ship
❌  iac/         a bucket, not a vessel — split it
❌  openshift/   a PLATFORM, not a vessel — see below
```

Vessels come in two kinds, and `stack.yaml` says which:

| Kind | Vessels | Second axis |
| --- | --- | --- |
| **packaging** — expresses the app | `compose` `helm` `kustomize` `ansible` | `platforms/` |
| **provisioning** — builds what it runs on | `terraform` | `targets/` |

A vessel folder exists **only if supported**. Absence is the support signal; an
empty folder is a bug.

---

## Platforms

Where the packaged app lands. A platform overlay adjusts the package for that
runtime's rules — it never forks it.

```
✅  compose/platforms/docker.yml       the baseline (no-op)
✅  compose/platforms/podman.yml       rootless uid mapping
✅  helm/platforms/vanilla.yaml        the baseline
✅  helm/platforms/openshift.yaml      Route, SCC, no pinned runAsUser
✅  helm/platforms/gke.yaml            Workload Identity, GCE ingress
✅  helm/platforms/eks.yaml            IRSA, ALB controller, EBS CSI
✅  helm/platforms/aks.yaml  tanzu.yaml  rancher.yaml

❌  helm-openshift/                    a fork, not an overlay
❌  helm/values-openshift-ha.yaml      two axes fused into one filename
```

**Platform and profile compose — that is why they are separate directories:**

```bash
helm install xplg ./helm   -f helm/profiles/ha.yaml   -f helm/platforms/openshift.yaml
```

Objects that exist **only** on one platform (an OpenShift `SecurityContextConstraints`,
say) are not values — they go in `extras/<platform>/`.

### Terraform uses `targets/`, not `platforms/`

Terraform *creates* the platform, so its second axis is the cloud landing zone:

```
✅  terraform/targets/aws-ec2/         VMs for the compose path
✅  terraform/targets/aws-eks/         a cluster for the helm path
✅  terraform/targets/gcp-gke/  azure-aks/  onprem-vsphere/

❌  terraform/platforms/aws/           it builds the platform; it isn't one
```

Name them `<cloud>-<service>` so the pairing with a packaging vessel is obvious:
`aws-ec2` feeds `compose/`, `aws-eks` feeds `helm/`.

---

## Overlay kinds — three different things, three names

These currently all look alike. They are not alike:

| Kind | Answers | Lives in | Example |
| --- | --- | --- | --- |
| **Feature** | "also give me X" | vessel root, `docker-compose.<feature>.yml` | `docker-compose.traefik.yml` |
| **Platform** | "adapt to runtime Y" | `platforms/` | `platforms/podman.yml` |
| **Profile** | "make it shape Z" | `profiles/` | `profiles/ha.env` |

> `docker-compose.podman.yml` in today's repo is misfiled by this rule — it is a
> **platform** overlay and belongs at `compose/platforms/podman.yml`.
> `docker-compose.traefik.yml` is genuinely a feature overlay and stays put.

---

## Profiles

A profile is a **shape**, not a place. Name it after the topology — never after a
customer, a datacentre, or an environment tier.

```
✅  compose/profiles/local.env         one host, loopback, no LB
✅  compose/profiles/single-node.env   one real server + Traefik
✅  compose/profiles/ha/               multi-server + shared storage
✅  compose/profiles/airgap.env        mirrored registry, no egress

❌  compose/profiles/prod.env          "prod" is a place, not a shape
❌  compose/profiles/acme-corp.env     customer instance → environments/
❌  compose/profiles/ha-v2.env         version the service, not the profile
```

> **Why this matters.** "prod" means something different to every reader, and it
> invites a `dev` / `staging` / `prod` set that silently diverges. A shape name is
> unambiguous and reusable: your prod *is* `ha`, and so is your staging —
> differing only in instance data.

### The same name, in each type's native format

Profiles live inside their deployment type because a compose profile and a Helm
profile are different artifacts that cannot be substituted for one another. They
share the **name**, not the directory:

```
services/xplg-service/compose/profiles/ha.env         env file
services/xplg-service/helm/profiles/ha.yaml           values file
services/xplg-service/terraform/profiles/ha.tfvars    tfvars file
services/xplg-service/ansible/profiles/ha/            inventory + group_vars
```

`ha` is the same topology in all four. Keeping them in one directory would force
disambiguating names (`ha.compose.env`, `ha.helm.yaml`) and invite passing the
wrong one.

### File or folder

Both are first-class. Use a file until you need more than one.

```
profiles/local.env            file    → replaces the default .env
profiles/ha/                  folder  → overlay tree
├── .env
├── conf/dynamic/tls.yml
└── conf/registry/xplg-seed-2-ui.node
```

**A folder profile is an overlay rooted at its deployment type folder.** Its
paths mirror the paths one level up, so applying it is a copy:

```bash
cd services/xplg-service/compose
cp -r profiles/ha/. .
```

Nothing new to learn — if you know where a file lives in `compose/`, you know
where it lives in `profiles/ha/`.

### There is always a default

Every deployment type ships something that runs with no profile selected:

| Type | Default |
| --- | --- |
| `compose/` | `docker-compose.yml` + `.env` |
| `helm/` | `values.yaml` |
| `terraform/` | `terraform.tfvars` |
| `ansible/` | `inventory.ini` (localhost) |
| `k8s/` | `base/` |

The default is **not** an entry in `profiles/`. It is what you get when you pick
nothing, and `git clone && docker compose up -d` must work on it.

---

## Compose files

```
✅  docker-compose.yml               the base — the roles themselves
✅  docker-compose.traefik.yml       adds the edge
✅  docker-compose.podman.yml        adds podman rootless uid mapping

❌  docker-compose.override.yml      implicit; auto-loaded and easy to forget
❌  compose-traefik.yaml             inconsistent prefix and extension
❌  docker-compose.prod.yml          environment in a filename → use a profile
```

The rule: **an overlay is named after the concern it adds**, and adding the file
to the command *is* the switch. No hidden profiles, no auto-loaded overrides.

```bash
docker compose -f docker-compose.yml up -d                              # roles only
docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d  # + edge
```

Use `.yml` (not `.yaml`) for compose files, matching Docker's own default.

---

## Environment variables

```
XPLG_<AREA>_<THING>
│    │      └─ what it configures
│    └─ subsystem: TRAEFIK, IGNITE, SEED, JAVA, …
└─ namespace — always, so `env | grep XPLG_` finds everything
```

```
✅  XPLG_TRAEFIK_UI_SERVERS
✅  XPLG_SEED_1_IP
✅  XPLG_BASE_HOST_PATH

❌  UI_SERVERS                       unnamespaced; collides with the host env
❌  XPLG_TRAEFIK_UI_SERVER_LIST      redundant suffix
❌  xplg_traefik_ui_servers          lowercase
```

Two deliberate exceptions, because they are consumed by third-party software
that defines the name:

| Exception | Owner |
| --- | --- |
| `COMPOSE_PROFILES`, `COMPOSE_PROJECT_NAME` | Docker Compose |
| `IGNITE_CMG_NODES`, `IGNITE_META_STORAGE_NODES` | Apache Ignite |

> **Every variable must exist in `params.yaml` with the exact same spelling.** CI
> fails the build otherwise. This is not hypothetical: `params.yaml` once
> declared `XPLG_IGNITE_CMG_NODES` while the compose read `IGNITE_CMG_NODES`, so
> setting it through the UI silently did nothing.

### Port variables

```
<ROLE>_<KIND>_PORT
```

```
✅  MASTER_HTTP_PORT=30308
✅  UI_HAZELCAST_PORT=11474
✅  PROCESSOR_1_IGNITE_NET_PORT=13348

❌  XPLG_MASTER_PORT                 which port? http? ssl? ignite?
❌  MASTER_PORT_HTTP                 kind and suffix transposed
```

Unprefixed by `XPLG_` because they are a dense, self-evident block and are
always read together.

---

## Nodes, aliases and containers

Three related names, each with a job:

| Name | Pattern | Example | Used for |
| --- | --- | --- | --- |
| **Seed alias** | `xplg-seed-<n>` | `xplg-seed-2` | A *server*. Maps to an IP in the seed map. |
| **Node name** | `<alias>-<role>` | `xplg-seed-2-ui` | A *process*. Ignite/Hazelcast identity. |
| **Container** | `<project>-<alias>-<role>` | `xplg-service-xplg-seed-2-ui` | The runtime object. |

The layering is deliberate: the alias is the only thing tied to an IP, so
re-addressing a server is a one-line change, and node names stay stable.

```
❌  server1, node-a, prod-ui-01      not derivable, not sortable, not unique
```

### Route paths follow the node model

```
/ui                 the ui pool
/ui-1  /ui-2        the Nth member of that pool
/xplg-seed-2-ui     that exact node
/processor1         the processor-1 ROLE  (no dash — see below)
```

> **The one deliberate irregularity.** `/processor-1` would be ambiguous: it
> could mean "the processor-1 role" or "the first processor". The role is served
> at `/processor1` so that `/processor-1` always means *first member of the
> processor pool*, whichever roles a cluster happens to run.

---

## Images and versions

```
<registry>/<name>:<version>-<branch>

docker.xplg.com/xplg:8.2.0-Main
docker.xplg.com/x8-fire-starter:1.0.0
```

```
❌  :latest                          never in a profile or a compose default
❌  :8.2                             floating; not reproducible
```

Every image reference in a committed file is fully pinned. `latest` is
acceptable only in throwaway local experiments.

### Git tags and branches

```
✅  xplg-service/v1.0.0              service release
✅  tools/x8fire/v1.0.0              tool release

❌  v1.0.0                           which of the eight services?
❌  release-1.0.0                    inconsistent with the path-prefixed scheme
```

```
✅  feat/registry-self-registration
✅  fix/traefik-sticky-cookie
✅  docs/podman-rootless-guide
✅  chore/bump-traefik-3.7

❌  haim-branch  temp  test2         tells nobody anything
```

Types: `feat` `fix` `docs` `chore` `refactor` `test` — matching Conventional
Commits, so the changelog can be generated.

---

## Documentation files

```
docs/<kind>/NN-kebab-title.md
```

```
✅  docs/deploy/03-docker-deploy.md
✅  docs/runbooks/upgrade-minor-version.md
✅  docs/adr/0007-host-network-for-the-edge.md

❌  docs/DockerDeploy.md
❌  docs/deploy/docker.md            unordered; reader can't tell what's next
```

Numeric prefixes only where **order matters** (tutorials, ADRs). Runbooks and
concepts are looked up by name, so they are unnumbered and alphabetical.

The `<kind>` directory carries meaning — see the four-document model in
[CONTRIBUTING.md](CONTRIBUTING.md):

| Directory | Contains | Never contains |
| --- | --- | --- |
| `docs/concepts/` | why it works this way | step-by-step commands |
| `docs/deploy/` | numbered install steps | design rationale |
| `docs/runbooks/` | emergency checklists | tutorials |
| `docs/reference/` | generated tables | prose (it is regenerated) |
| `docs/adr/` | one decision, immutable | anything edited after merge |

---

## Scripts, roles and modules

```
scripts/<area>/xplg-<verb>-<object>.sh

✅  scripts/preflight/xplg-preflight.sh
✅  scripts/network/xplg-open-ports.sh
✅  scripts/storage/xplg-prepare-filesystem.sh

❌  scripts/check.sh                 check what?
❌  scripts/setup2.sh                
```

```
common/ansible/roles/<verb>_<object>/        ✅  install_container_engine
                                             ✅  configure_nfs_client
                                             ❌  docker  (noun, ambiguous)

common/terraform/modules/<cloud>-<resource>/ ✅  aws-vpc
                                             ✅  azure-storage-account
```

Ansible roles use `snake_case` (Galaxy convention); everything else is
kebab-case.

---

## When you're unsure

Ask in this order:

1. **What kind of thing is it?** The prefix or directory should say so.
2. **Is this a shape or a place?** Shapes go in `profiles/`. Places go in
   `environments/`.
3. **Would a stranger guess this name?** If they'd have to open the file to find
   out what it does, rename it.
4. **Is there an existing name for this?** Consistency beats a marginally better
   new pattern. Grep before you invent.
