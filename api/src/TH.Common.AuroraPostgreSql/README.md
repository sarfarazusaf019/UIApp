# TH.Common.AuroraPostgreSql

A .NET reusable library for connecting to an AWS Aurora PostgreSQL cluster using IAM database
authentication instead of static passwords: it signs short-lived IAM auth tokens via the AWS RDS
SDK and hands them to Npgsql as the connection password, with Polly-based retry around connection
attempts.

## Build

```powershell
dotnet build
```

Target framework: `net10.0`, with nullable reference types and implicit usings enabled. The library has its own tests nowhere yet; the Claim Selection solution consumes it by project reference.

## Architecture

Pieces, each behind an interface so consumers can substitute or mock them:

- **`Configuration/AuroraPgOptions.cs`** — all connection/auth settings (host, port, database,
  db user, region, `UseIamAuthentication`, retry/timeout knobs). Bind it from config under the
  section named by `AuroraPgOptions.SectionName`, or populate it via the DI extension below.
- **`Authentication/IamTokenProvider.cs`** — calls `Amazon.RDS.Util.RDSAuthTokenGenerator` to sign
  an IAM auth token for the configured host/port/db user, using an injected `AWSCredentials`.
  Tokens are valid for 15 minutes; the provider caches the token and only re-signs once the cached
  copy is within `TokenExpiryBufferSeconds` of expiring (protected by a `SemaphoreSlim` so
  concurrent callers don't all re-sign at once).
- **`Connections/AuroraConnectionFactory.cs`** — builds the Npgsql connection string (fetching a
  token from `IIamTokenProvider` first, when `UseIamAuthentication` is true) and opens the
  connection. Opening is wrapped in a Polly `AsyncRetryPolicy` with exponential backoff
  (`MaxRetryAttempts` / `RetryBaseDelayMilliseconds`) that retries on `NpgsqlException` — a retry
  re-enters the token-fetch step, so a rejected/stale token gets refreshed automatically on the
  next attempt rather than needing separate invalidation logic.
- **`Extensions/ServiceCollectionExtensions.cs`** — `AddAuroraPostgreSql(configureOptions,
  credentials?)` is the intended entry point for consuming apps. It registers `AuroraPgOptions`,
  an `AWSCredentials` singleton (defaulting to `DefaultAWSCredentialsIdentityResolver`, i.e. the
  standard AWS credential chain — env vars, shared config file, attached instance/task role — so
  no credentials need to be hardcoded when running on AWS compute), `IIamTokenProvider`, and
  `IAuroraConnectionFactory`.

Typical consumer flow: `services.AddAuroraPostgreSql(o => { o.Host = ...; o.Region = ...; })` at
startup, then inject `IAuroraConnectionFactory` and call `CreateOpenConnectionAsync()` to get an
opened, disposable `NpgsqlConnection` per unit of work.

### Prerequisite on the database side

The configured `DbUser` must be a PostgreSQL role granted the `rds_iam` role in the target Aurora
cluster (see AWS docs: "Creating a database account using IAM authentication") — the IAM token
alone does not grant access.
