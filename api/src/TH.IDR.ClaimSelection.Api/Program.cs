using Dapper;
using Npgsql;
using TH.IDR.ClaimSelection.Api;
using TH.IDR.ClaimSelection.Api.Database;

var builder = WebApplication.CreateBuilder(args);
// Database access with the IAM role (default) or, for local testing, a connection string: see Database/DatabaseAccess.cs.
builder.Services.AddApiDatabase(builder.Configuration);
builder.Services.AddCors(o => o.AddDefaultPolicy(p => p.AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod()));
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.SnakeCaseLower);

var app = builder.Build();
await SchemaCheck.EnsureAsync(app.Services.GetRequiredService<IDbConnectionFactory>());
app.UseCors();
var api = app.MapGroup("/api");
var q = new Queries();

api.MapConfig();

api.MapPost("/cases/{id:long}/reevaluate", async (IDbConnectionFactory ds, long id) =>
{
    await using var conn = await ds.OpenConnectionAsync();
    await using var tx = await conn.BeginTransactionAsync();
    var prior = await conn.ExecuteScalarAsync<long?>(
        """
        UPDATE idr_core.idr_case_unit c
        SET current_outcome_id = (SELECT idr_case_outcome_id FROM idr_core.idr_case_outcome_lookup WHERE outcome_code = 'CS-PENDING-EVALUATION'),
            active_in_idr_workflow = false, updated_at_utc = now()
        FROM idr_core.idr_case_outcome_lookup o
        WHERE c.idr_case_unit_id = @id AND o.idr_case_outcome_id = c.current_outcome_id
          AND o.outcome_code IN ('CS-SUCCESS-SELECTED', 'CS-SUCCESS-EXCLUDED', 'CS-SUCCESS-EXCEPTION')
        RETURNING o.idr_case_outcome_id
        """, new { id }, tx);
    if (prior is null)
    {
        return Results.BadRequest(new { error = "Only Selected, Excluded or Exception cases can be sent back for re-evaluation." });
    }

    await conn.ExecuteAsync(
        """
        INSERT INTO idr_core.idr_case_status_history (idr_case_unit_id, prior_outcome_id, new_outcome_id, event_source, reason_code, notes, changed_by)
        SELECT @id, @prior, o.idr_case_outcome_id, 'DEMO_UI', 'REEVALUATE_REQUESTED', 'Sent back for re-evaluation after a configuration change', 'demo-ui'
        FROM idr_core.idr_case_outcome_lookup o WHERE o.outcome_code = 'CS-PENDING-EVALUATION'
        """, new { id, prior }, tx);
    await tx.CommitAsync();
    return Results.Ok(new { ok = true });
});

api.MapPost("/admin/clear-data", async (ClearRequest request, IDbConnectionFactory ds) =>
{
    if (request.Confirm != "CLEAR")
    {
        return Results.BadRequest(new { error = "Confirmation missing." });
    }

    await ds.ScalarAsync<int>(
        """
        DO $$
        DECLARE v_tables text;
        BEGIN
            SELECT string_agg(format('%I.%I', schemaname, tablename), ', ') INTO v_tables FROM pg_tables
            WHERE schemaname = 'idr_core'
              AND (tablename IN ('payer', 'remittance', 'claim_payment', 'claim_line_payment', 'claim_line_payment_modifier', 'claim_payment_adjustment', 'claim_line_payment_adjustment', 'claim_line_remark_code', 'provider_level_adjustment', 'billing_provider', 'claim', 'subscriber', 'patient', 'insurance_coverage', 'claim_line', 'claim_line_modifier', 'claim_diagnosis', 'claim_drg', 'rendering_provider', 'service_facility')
                   OR tablename LIKE 'idr\_%' OR tablename IN ('audit_event', 'job_run_log', 'job_case_log'))
              AND tablename <> 'idr_case_outcome_lookup';
            EXECUTE 'TRUNCATE TABLE ' || v_tables || ' RESTART IDENTITY CASCADE';
        END $$;
        SELECT 1
        """);
    return Results.Ok(new { ok = true });
});

api.MapGet("/health", () => new { status = "ok" });

api.MapGet("/meta", async (IDbConnectionFactory ds) => new
{
    clients = await ds.RowsAsync("SELECT client_id, client_name FROM idr_core.config_client ORDER BY client_id"),
    service_lines = await ds.RowsAsync("SELECT acronym AS code, service_line_name AS name FROM idr_core.config_service_line ORDER BY acronym"),
    payers = await ds.RowsAsync("SELECT payer_edi_id, min(payer_name) AS payer_name FROM idr_core.config_payer_insurance_group GROUP BY payer_edi_id ORDER BY (payer_edi_id LIKE 'QA%') DESC, payer_edi_id LIMIT 600"),
    jobs = JobCatalog.Describe()
});

api.MapGet("/cases", async (IDbConnectionFactory ds, string? client, string? outcome, string? q1, string? search) =>
    await ds.RowsAsync(q.CaseList, new { client, outcome, search = string.IsNullOrWhiteSpace(search ?? q1) ? null : "%" + (search ?? q1) + "%" }));

api.MapGet("/cases/{id:long}", async (IDbConnectionFactory ds, long id) =>
{
    var header = (await ds.RowsAsync(q.CaseHeader, new { id })).FirstOrDefault();
    if (header is null)
    {
        return Results.NotFound();
    }

    return Results.Ok(new
    {
        header,
        source_837 = await ds.RowsAsync(q.Source837, new { id }),
        source_835 = await ds.RowsAsync(q.Source835, new { id }),
        evaluations = await ds.RowsAsync(q.Evaluations, new { id }),
        rules = await ds.RowsAsync(q.RuleResults, new { id }),
        status_history = await ds.RowsAsync(q.StatusHistory, new { id }),
        claim_versions = await ds.RowsAsync(q.ClaimVersions, new { id }),
        cool_off = await ds.RowsAsync("SELECT * FROM idr_core.idr_cool_off_status WHERE idr_case_unit_id = @id", new { id }),
        batch = await ds.RowsAsync(q.Batch, new { id }),
        exceptions = await ds.RowsAsync(q.CaseExceptions, new { id }),
        timeline = await ds.RowsAsync(q.CaseTimeline, new { id })
    });
});

api.MapGet("/unmatched", async (IDbConnectionFactory ds, string? client) => new
{
    lines = await ds.RowsAsync(q.Unmatched, new { client }),
    summary = await ds.RowsAsync(q.UnmatchedSummary, new { client })
});

api.MapGet("/remit-lines/{id:long}/history", async (IDbConnectionFactory ds, long id) =>
    await ds.RowsAsync(q.RemitHistory, new { id }));

api.MapGet("/job-runs", async (IDbConnectionFactory ds) => new
{
    summary = await ds.RowsAsync(q.JobRunSummary),
    runs = await ds.RowsAsync("SELECT * FROM idr_core.job_run_log ORDER BY job_run_log_id DESC LIMIT 100")
});

// Jobs are run by the Worker service (scheduled / on demand). The buttons stay in the UI, disabled, for the moment a trigger is connected.
api.MapPost("/jobs/run", (RunJobRequest request) =>
    Results.Conflict(new { error = "Jobs are not run by this API: the Worker service runs them (claim-remit matching will be started through the Python matching service)." }));

api.MapPost("/records", async (NewRecordRequest request, IDbConnectionFactory ds) =>
{
    try
    {
        return Results.Ok(await RecordWriter.InsertAsync(ds, request));
    }
    catch (ArgumentException e)
    {
        return Results.BadRequest(new { error = e.Message });
    }
    catch (PostgresException e)
    {
        return Results.BadRequest(new { error = e.MessageText });
    }
});

api.MapGet("/records/trace", async (IDbConnectionFactory ds, string client, string pcn) => new
{
    lines = await ds.RowsAsync(q.Trace, new { client, pcn })
});

api.MapGet("/reference/config", async (IDbConnectionFactory ds, string client) => new
{
    batching_logic = await ds.RowsAsync("SELECT field_name, current_value FROM idr_core.config_batching_logic WHERE client_id = @client ORDER BY field_name", new { client }),
    cool_off_logic = await ds.RowsAsync("SELECT field_name, current_value FROM idr_core.config_cool_off_logic WHERE client_id = @client ORDER BY field_name", new { client }),
    timeline = await ds.RowsAsync("SELECT timer_name, COALESCE(value_number::text, value_date::text) AS value, units FROM idr_core.config_federal_timeline WHERE timer_name IN ('NSA Effective Date','Claim Selection Window') OR timer_name ILIKE '%claim selection%' ORDER BY timer_name"),
    thresholds = await ds.RowsAsync("SELECT payer_id, service_line, lower_threshold, upper_threshold FROM idr_core.config_allowed_amount_threshold WHERE client_id = @client ORDER BY payer_id, service_line LIMIT 60", new { client }),
    downcodes = await ds.RowsAsync("SELECT service_code_from_837, allowed_downcode_lower_range, allowed_downcode_upper_range FROM idr_core.config_downcoded_service_code WHERE client_id = @client ORDER BY 1", new { client }),
    rarc = await ds.RowsAsync("SELECT rarc_code, federal_idr_process_eligible, applicable_law FROM idr_core.config_rarc_code ORDER BY rarc_code"),
    claim_selection_logic = await ds.RowsAsync("SELECT payer_id, service_line, tax_id, facility_name, physician_npi, service_code FROM idr_core.config_claim_selection_logic WHERE client_id = @client ORDER BY payer_id, service_line LIMIT 60", new { client }),
    counts = (await ds.RowsAsync("""
        SELECT (SELECT count(*) FROM idr_core.config_tax_id_entity_mapping WHERE client_id = @client) AS tax_id_mappings,
               (SELECT count(*) FROM idr_core.config_systemic_exclusion WHERE client_id = @client AND NOT is_disabled) AS systemic_rules,
               (SELECT count(*) FROM idr_core.config_payer_insurance_group WHERE NOT is_disabled) AS payer_groups
        """, new { client })).FirstOrDefault()
});

app.Run();

public sealed record RunJobRequest(string Job);
public sealed record ClearRequest(string? Confirm);
