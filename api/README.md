# TH.IDR.ClaimSelection.Api

ASP.NET minimal API behind the Claim Selection UI (`ui/`, a separate folder / repository). Independent service: it shares no project with the Worker.
It reads the Claim Selection tables (schema `idr_core`), edits the `config_*` tables (audited), inserts 837 + 835 test records, shows exceptions / cases / job history and
clears claim data. **It does not run jobs**: the Worker service does. The Run buttons in the UI stay visible but disabled (the endpoint answers 409 with that message).
There is no authentication: use it in a protected environment only.

```
src/
  TH.IDR.ClaimSelection.Api          the API (Program.cs endpoints, Support.cs queries, RecordWriter.cs, ConfigApi.cs, Database/ = database access)
  TH.Common.AuroraPostgreSql         common library: Npgsql connections to Aurora PostgreSQL with IAM authentication
```

## Database access
`Database:AuthenticationMode` chooses how it connects:

| Mode | When | Settings |
|---|---|---|
| `Iam` (default, `appsettings.json`) | deployed on AWS (role attached to the task / instance / pod) | section `AuroraPostgreSql`: `Host`, `Database`, `DbUser`, `Region`. No password. |
| `ConnectionString` (`appsettings.Development.json`) | local testing | `ConnectionStrings:ClaimSelection` |

* Local settings files are git-ignored and excluded from `dotnet publish`: `appsettings.Development.json` (local db) and `appsettings.Remote.json` (Aurora with IAM; set `AuroraPostgreSql:AwsProfile` to a profile of `~/.aws` for your own credentials). The Visual Studio launch profiles come in pairs (`Development` / `Remote`).
* Environment variables override the files, for example `AuroraPostgreSql__Host`.
* The database user needs the `rds_iam` role; the role running the API needs `rds-db:connect` for that user.
* On start-up the API checks that its tables / views exist in schema `idr_core` and stops with the list of missing ones.

## Run
```
dotnet run --project src/TH.IDR.ClaimSelection.Api        (profile with the local connection string: http://localhost:5080/api/health)
```
Visual Studio: open `TH.IDR.ClaimSelection.Api.sln`, startup project `TH.IDR.ClaimSelection.Api`.

## Deployment folder (`deployment/`)
| File | Purpose |
|---|---|
| `Dockerfile` | the image (built from the published folder) |
| `docker-compose.yml`, `api.env.example` | local run with the IAM role of an AWS profile; copy the example to `api.env` (git-ignored) |
| `deployment.yaml`, `service.yaml`, `serviceaccount.yaml` | Kubernetes: Deployment (2 replicas, Istio sidecar, health probes), Service (port 80 -> 8080) and the service account that carries the IAM role. Edit the namespace, the Aurora settings and the IAM role ARN |

Local Docker (run from this folder):
```
dotnet publish src/TH.IDR.ClaimSelection.Api -c Release -o publish
copy deploymentpi.env.example deploymentpi.env             (fill in; git-ignored)
docker compose -f deployment/docker-compose.yml up --build       (http://localhost:5080/api/health)
```
Local Kubernetes (containerd, no registry): `nerdctl -n k8s.io build -t claim-selection-api:v1 -f deployment/Dockerfile .` then
`kubectl apply -f deployment/serviceaccount.yaml -f deployment/deployment.yaml -f deployment/service.yaml`.
The image is built from the published folder because the container can not reach the NuGet feed behind the company proxy. In AWS use the same image without the `~/.aws` mount and without `AuroraPostgreSql__AwsProfile`.
