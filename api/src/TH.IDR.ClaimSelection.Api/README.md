# API - demo backend for the UI

ASP.NET minimal API on http://localhost:5080. Independent application: it references only the core libraries in `../src`
(Domain, Application, Infrastructure) and does **not** reference the Worker. The React app in `../ui` is its only client.

What it does: lists cases / unmatched remits / job history from the Claim Selection tables, edits `config_*` tables (audited),
inserts 837 + 835 records, runs the jobs in-process (same code and run lock as the Worker), clears claim/remit/case data.
There is no authentication: use it locally only.

## Run
```
export ConnectionStrings__ClaimSelection="Host=localhost;Port=5432;Database=idr_demo;Username=postgres;Password=<password>"
# PowerShell: $env:ConnectionStrings__ClaimSelection = "..."
dotnet run --project Api          # from the repository root;  or  cd Api && dotnet run
```
Check: http://localhost:5080/api/health. The connection string can also be set in `Api/appsettings.json`.
Open everything in Visual Studio with `Api/TH.IDR.ClaimSelection.All.sln`.

## Move it out
Delete the `Api/` folder (and `ui/`); the root solution `TH.IDR.ClaimSelection.sln` does not include it and nothing else references it.
To keep it in another repository, copy `Api/` together with `src/` (the api project references `../src/...`).
