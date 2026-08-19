# XPLG X8 — Fire Starter

**Deploy the XPLG X8 platform anywhere: one host, a cluster, or the cloud.**

This repository is the DevOps delivery surface for XPLG X8 — the deployable
service definitions, the `x8fire` CLI that drives them, and the documentation to
run it all in production.

```bash
# Deploy a single-node XPLG cluster in three commands
git clone https://github.com/xplg-x8/fire-starter.git
cd fire-starter/services/xplg-service/compose
docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d
```

Then open **http://localhost/**.

---

## What's inside

| | |
| --- | --- |
| 🧩 **[`services/`](services/)** | One folder per deployable service. Each is self-contained — compose files, profiles, config, docs. Download one folder, deploy it. |
| 🛠 **[`tools/x8fire/`](tools/x8fire/)** | The deployment CLI and web console. Optional — every service deploys with plain `docker compose` too. |
| 📚 **[`docs/`](docs/)** | Tutorials, concepts, runbooks, and generated reference tables. |
| 🔧 **[`scripts/`](scripts/)** | Standalone operator scripts: preflight checks, firewall, verification. No install required. |
| 🖼 **[`images/`](images/)** | Dockerfiles and build definitions for the published images. |
| ♻️ **[`common/`](common/)** | Shared Ansible roles, Terraform modules, and Helm library charts. |

---

## Start here

**New to X8?** → [docs/deploy/00-overview-and-preflight.md](docs/deploy/00-overview-and-preflight.md)

| I want to… | Go to |
| --- | --- |
| Understand what I'm deploying | [`docs/deploy/00-overview-and-preflight.md`](docs/deploy/00-overview-and-preflight.md) |
| Check my Linux host is ready | [`docs/deploy/01-preflight-linux.md`](docs/deploy/01-preflight-linux.md) · [`scripts/preflight/`](scripts/preflight/) |
| Get filesystem permissions right | [`docs/deploy/02-permissions-and-filesystem.md`](docs/deploy/02-permissions-and-filesystem.md) |
| Deploy with Docker | [`docs/deploy/03-docker-deploy.md`](docs/deploy/03-docker-deploy.md) |
| Deploy with Podman (rootless or rootful) | [`docs/deploy/04-podman-deploy.md`](docs/deploy/04-podman-deploy.md) |
| Prove it works / fix it | [`docs/deploy/05-verify-and-troubleshoot.md`](docs/deploy/05-verify-and-troubleshoot.md) |
| Look up an env var or a port | [`docs/reference/`](docs/reference/) *(generated — always current)* |
| Upgrade, back up, or scale out | [`docs/runbooks/`](docs/runbooks/) |
| Know why it's built this way | [`docs/concepts/`](docs/concepts/) · [`docs/adr/`](docs/adr/) |
| Add a service or a profile | [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`NAMING.md`](NAMING.md) |

---

## Services

Every service folder is **self-contained and independently versioned**. You can
`git clone` the repo, or download just one service from
[Releases](https://github.com/xplg-x8/fire-starter/releases).

| Service | What it is | Targets |
| --- | --- | --- |
| [`xplg-service`](services/xplg-service/) | Core XPLG cluster — master, ui, listener, processor | `compose` |
| [`xplg-enterprise`](services/xplg-enterprise/) | Multi-node enterprise topology | `compose` |
| [`xplg-ha-enterprise`](services/xplg-ha-enterprise/) | High-availability topology | `compose` `swarm` |
| [`xplg-agent`](services/xplg-agent/) | Log collection agent | `compose` |
| [`xplg-plugins`](services/xplg-plugins/) | Plugin runtime | `compose` |
| [`xplg-ai-services`](services/xplg-ai-services/) | Inference services | `compose` |
| [`xplg-storm`](services/xplg-storm/) | Shared edge / orchestration | `compose` |

The `targets` column is authoritative — it is read from each service's
`stack.yaml` `deploy_modes` and verified in CI. A target that isn't listed isn't
shipped yet.

### Anatomy of a service

Every service folder looks the same. Learn one, you know them all.

```
services/xplg-service/
├── README.md                     what it is, its ports, its topologies
├── VERSION                       1.0.0  — this service's own version
├── CHANGELOG.md
├── stack.yaml                    identity, roles, startup order, deploy_modes
├── plugin.yaml                   ports, engines, resources, verify endpoints
├── params.yaml                   every parameter: type, default, help
│
├── compose/                      ← vessel: docker / podman
│   ├── docker-compose.yml            the default — always works
│   ├── docker-compose.traefik.yml    FEATURE overlay: add a load balancer
│   ├── .env                          the default profile
│   ├── conf/                         runtime config the containers mount
│   ├── platforms/                    WHERE it lands
│   │   ├── docker.yml                    baseline
│   │   └── podman.yml                    rootless uid mapping
│   └── profiles/                     WHAT SHAPE
│       ├── local.env                     a single file…
│       ├── single-node.env
│       └── ha/                           …or a folder, when it needs more
│           ├── .env
│           └── conf/dynamic/tls.yml
│
├── helm/                         ← vessel: kubernetes   (when supported)
│   ├── Chart.yaml  values.yaml       version + appVersion; values is the default
│   ├── platforms/                    vanilla, openshift, gke, eks, aks, tanzu, rancher
│   ├── extras/openshift/scc.yaml     objects that exist only on one platform
│   └── profiles/{local,ha}.yaml
│
├── terraform/                    ← vessel: provisioning  (when supported)
│   └── targets/{aws-ec2,aws-eks,gcp-gke}/
│
└── tests/                        render + smoke tests for this service
```

Four things hold everywhere:

- **Every deployment type has a default that works with no arguments.** Run the
  default and you get a working single-node system — you only pick a profile when
  you want something else.
- **A profile is a file or a folder.** One file when an env file is enough; a
  folder when the shape also needs certificates, drop-in routes or extra
  variables. A folder profile is an overlay tree — same paths, one level down.
- **`platforms/` and `profiles/` compose.** Where it lands and what shape it is
  are independent, so `ha` on `openshift` is just two files stacked.
- **A vessel folder exists only if it is supported.** No `helm/` means Kubernetes
  is not shipped for that service yet. Absence is the answer, not an empty stub.


---

## Two ways to deploy

**Plain compose** — no tooling, no install. Everything works with the files in
the repo:

```bash
cd services/xplg-service/compose

# the default — single node, docker, no load balancer
docker compose up -d

# pick a shape, then edit your IPs and paths
cp profiles/single-node.env .env && vi .env
docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d

# on podman rootless: add the platform overlay
docker compose -f docker-compose.yml                -f platforms/podman.yml                -f docker-compose.traefik.yml up -d
```

On Kubernetes, shape and platform stack the same way:

```bash
helm install xplg ./services/xplg-service/helm   -f services/xplg-service/helm/profiles/ha.yaml   -f services/xplg-service/helm/platforms/openshift.yaml
```

**With the `x8fire` CLI** — adds a catalog browser, guided parameters, a
deployment registry, and a web console:

```bash
curl -fsSL https://x8fire.xplg.com/install.sh | sh
x8fire catalog list                       # browse the services
x8fire inspect --stack xplg-service       # ports, params, requirements
x8fire start --stack xplg-service         # deploy it
```

Override any parameter without editing files:

```bash
x8fire start --stack xplg-service --params XPLG_SEED_1_IP=10.0.0.11
```

The CLI is a convenience layer. It never does anything you can't do with
`docker compose` and the files in `services/`.

---

## Support matrix

| Target | Status |
| --- | --- |
| Docker Engine / Docker Desktop | ✅ Supported |
| Podman rootless | ✅ Supported |
| Podman rootful | ✅ Supported |
| Docker Swarm | 🟡 `xplg-ha-enterprise` only |
| Kubernetes / Helm | 🚫 Planned — [#roadmap](https://github.com/xplg-x8/fire-starter/labels/roadmap) |
| OpenShift | 🚫 Planned |
| VMware Tanzu | 🚫 Planned |

| Host OS | Status |
| --- | --- |
| RHEL / Rocky / Alma 8, 9 | ✅ |
| Ubuntu 22.04, 24.04 | ✅ |
| Windows + WSL2 (dev only) | 🟡 See podman notes |

Requirements: Docker ≥ 20.10 with `docker compose` ≥ 2.20, **or** Podman ≥ 4.7.
cgroups **v2** is required — without it memory limits are ignored.

---

## Naming conventions, in brief

Full rules and examples: **[NAMING.md](NAMING.md)**

| Thing | Pattern | Example |
| --- | --- | --- |
| Service folder | `xplg-<name>` kebab-case | `services/xplg-service/` |
| Vessel | fixed vocabulary | `compose/` `helm/` `terraform/` |
| Platform | `platforms/<name>.<ext>` | `helm/platforms/openshift.yaml` |
| Profile (file) | `<shape>.<ext>` | `compose/profiles/ha.env` |
| Profile (folder) | `<shape>/` | `compose/profiles/ha/` |
| Compose overlay | `docker-compose.<concern>.yml` | `docker-compose.traefik.yml` |
| Env var | `XPLG_<AREA>_<THING>` | `XPLG_TRAEFIK_UI_SERVERS` |
| Port var | `<ROLE>_<KIND>_PORT` | `MASTER_HTTP_PORT` |
| Node alias | `xplg-seed-<n>` | `xplg-seed-2` |
| Node name | `<alias>-<role>` | `xplg-seed-2-ui` |
| Git tag | `<service>/v<semver>` | `xplg-service/v1.0.0` |
| Doc file | `NN-kebab-title.md` | `03-docker-deploy.md` |

---

## Versioning and releases

Each service is versioned and released **independently**.

- **Version** — SemVer, in `services/<name>/VERSION`. A breaking `.env` contract
  change is a major bump.
- **Tag** — path-prefixed: `xplg-service/v1.0.0`.
- **Artifact** — `xplg-service-1.0.0.tar.gz`, exactly that one folder, attached to
  the GitHub Release and mirrored to `artifacts.xplg.com`.
- **Images** — published to `docker.xplg.com`; the tag each service is tested
  against is pinned in its `profiles/*.env`.

---

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). In short:

1. A new service starts as a copy of [`services/_template/`](services/_template/).
2. A new environment shape is **one file** in `profiles/` — never a new directory tree.
3. CI must stay green: every service × every profile must render
   (`docker compose config`, `helm template`, `terraform validate`).
4. Every fenced `bash` block in `docs/` is syntax-checked. If you document a
   command, it must parse.

## Security

Found a vulnerability? See [SECURITY.md](SECURITY.md) — please do not open a
public issue.

No secrets belong in this repository. TLS keys, registry credentials, cluster
tokens and customer hostnames live outside it; see
[docs/concepts/secrets.md](docs/concepts/secrets.md).

## License

See [LICENSE](LICENSE).
