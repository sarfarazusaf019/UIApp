using Dapper;
using Npgsql;
using TH.IDR.ClaimSelection.Api.Database;

namespace TH.IDR.ClaimSelection.Api;

public static class DbExtensions
{
    /// <summary>Runs a query and returns each row as a dictionary (column name -> value), ready for JSON.</summary>
    public static async Task<List<IDictionary<string, object?>>> RowsAsync(this IDbConnectionFactory ds, string sql, object? args = null)
    {
        await using var connection = await ds.OpenConnectionAsync();
        var rows = await connection.QueryAsync(sql, args);
        return rows.Select(r => (IDictionary<string, object?>)r).ToList();
    }

    public static async Task<T> ScalarAsync<T>(this IDbConnectionFactory ds, string sql, object? args = null)
    {
        await using var connection = await ds.OpenConnectionAsync();
        return await connection.ExecuteScalarAsync<T>(sql, args) ?? default!;
    }
}

public static class JobCatalog
{
    /// <summary>The jobs shown in the UI (Auto Pursuit is not listed). They are run by the Worker service, so none can be started from here.</summary>
    private static readonly (string Code, string Name, string Short)[] Jobs =
    [
        ("CLAIM_REMIT_MATCHING", "Claim-remit matching", "Matching"),
        ("EXCEPTION_AGING", "Exception Status Monitoring", "Status Monitoring"),
        ("EXCLUSION_VALIDATION", "Exclusion Validation", "Exclusion Validation"),
        ("SYSTEMIC_NOT_PURSUED", "Systemic not pursued", "Systemic"),
        ("COOL_OFF_STATUS", "Cool-off status", "Cool-off"),
        ("PRELIMINARY_BATCHING", "Preliminary batching", "Batching")
    ];

    public static object[] Describe() =>
        Jobs.Select((j, i) => (object)new { code = j.Code, name = j.Name, @short = j.Short, order = i + 1, enabled = false }).ToArray();
}

public sealed class Queries
{
    public string CaseList => """
        SELECT c.idr_case_unit_id, c.client_id, c.patient_control_number, c.case_reference, c.payer_business_id,
               c.tax_id, c.entity_name, c.service_line_code, c.service_code, c.date_of_service, c.remit_payment_date,
               o.outcome_code, c.selected_for_federal_idr, c.active_in_idr_workflow, c.funding_type,
               f.allowed_amount, f.provider_offer_amount,
               s.check_status AS cool_off_status,
               b.batch_reference, b.batch_status,
               (SELECT count(*) FROM idr_core.job_case_log l
                 WHERE l.idr_case_unit_id = c.idr_case_unit_id OR l.edi_835_claim_line_payment_id = c.edi_835_claim_line_payment_id) AS job_events,
               (SELECT string_agg(r.rule_code || ': ' || COALESCE(r.exclusion_code || COALESCE(' - ' || x.exclusion_label, ''),
                                                                  r.reason_code || COALESCE(' - ' || r.configuration_value, ''), ''), '; ')
                  FROM idr_core.idr_claim_selection_rule_result r
                  LEFT JOIN idr_core.config_exclusion_reason x ON x.exclusion_code = r.exclusion_code
                 WHERE r.idr_claim_selection_evaluation_id = (SELECT max(e.idr_claim_selection_evaluation_id) FROM idr_core.idr_claim_selection_evaluation e WHERE e.idr_case_unit_id = c.idr_case_unit_id)
                   AND r.rule_outcome IN ('FAIL','MISSING_DATA')) AS failed_rules
        FROM idr_core.idr_case_unit c
        JOIN idr_core.idr_case_outcome_lookup o ON o.idr_case_outcome_id = c.current_outcome_id
        LEFT JOIN idr_core.idr_case_financial_summary f ON f.idr_case_unit_id = c.idr_case_unit_id
        LEFT JOIN idr_core.idr_cool_off_status s ON s.idr_case_unit_id = c.idr_case_unit_id
        LEFT JOIN idr_core.idr_preliminary_batch_case_unit a ON a.idr_case_unit_id = c.idr_case_unit_id
        LEFT JOIN idr_core.idr_preliminary_batch b ON b.idr_preliminary_batch_id = a.idr_preliminary_batch_id
        WHERE (@client::text IS NULL OR c.client_id = @client)
          AND (@outcome::text IS NULL OR o.outcome_code = @outcome)
          AND (@search::text IS NULL OR c.patient_control_number ILIKE @search OR c.case_reference ILIKE @search OR c.tax_id ILIKE @search)
        ORDER BY c.updated_at_utc DESC, c.idr_case_unit_id DESC
        LIMIT 500
        """;

    public string CaseHeader => """
        SELECT c.*, o.outcome_code, f.billed_amount, f.allowed_amount, f.paid_amount, f.medicare_reference_amount, f.provider_offer_amount,
               m.match_type, m.matched_837_version_sequence AS matched_version, m.matched_at_utc AS matched_at
        FROM idr_core.idr_case_unit c
        JOIN idr_core.idr_case_outcome_lookup o ON o.idr_case_outcome_id = c.current_outcome_id
        LEFT JOIN idr_core.idr_claim_remit_match m ON m.idr_claim_remit_match_id = c.idr_claim_remit_match_id
        LEFT JOIN idr_core.idr_case_financial_summary f ON f.idr_case_unit_id = c.idr_case_unit_id
        WHERE c.idr_case_unit_id = @id
        """;

    public string Source837 => """
        SELECT v.edi_837_claim_id, v.claim_type AS transaction_type, v.claim_type, v.patient_account_number, v.invoice_number, v.payer_business_id,
               v.frequency_code, v.is_void, v.version_sequence, v.tax_id AS billing_provider_tin, v.billing_provider_npi,
               v.rendering_provider_npi, v.facility_npi, v.facility_name, v.facility_state_code, v.insurance_group_number,
               v.line_number, v.service_code, v.service_line_code, v.line_charge_amount, v.units, v.date_of_service,
               v.drg_code, v.revenue_code, v.employer_group_number,
               array_to_string(v.modifiers, ',') AS modifiers
        FROM idr_core.idr_case_unit c
        JOIN idr_core.vw_837_claim_selection_source v ON v.edi_837_claim_line_id = c.edi_837_claim_line_id
        WHERE c.idr_case_unit_id = @id
        """;

    public string Source835 => """
        SELECT r.transaction_control_number, v.remit_payment_date AS payment_effective_date, v.payer_business_id, v.patient_control_number,
               v.insurance_group_number, v.line_number, v.paid_service_code, v.service_line_code, v.line_charge_amount,
               v.line_paid_amount, v.allowed_amount, v.provider_offer_amount, v.units, v.date_of_service,
               v.drg_code, v.revenue_code, v.employer_group_number,
               array_to_string(v.modifiers, ',') AS modifiers, array_to_string(v.rarc_codes, ',') AS rarc_codes
        FROM idr_core.idr_case_unit c
        JOIN idr_core.vw_835_claim_selection_source v ON v.edi_835_claim_line_payment_id = c.edi_835_claim_line_payment_id
        JOIN idr_core.remittance r ON r.remittance_id = v.edi_835_remittance_id
        WHERE c.idr_case_unit_id = @id
        """;

    public string Evaluations => """
        SELECT idr_claim_selection_evaluation_id, evaluation_type, final_outcome_code, failed_rule_count, missing_data_count,
               completed_at_utc, row_number() OVER (ORDER BY idr_claim_selection_evaluation_id) AS evaluation_no
        FROM idr_core.idr_claim_selection_evaluation WHERE idr_case_unit_id = @id ORDER BY idr_claim_selection_evaluation_id DESC
        """;

    public string RuleResults => """
        SELECT r.idr_claim_selection_evaluation_id, r.rule_code, r.rule_outcome, r.exclusion_code, x.exclusion_label,
               r.reason_code, r.source_value, r.configuration_value
        FROM idr_core.idr_claim_selection_rule_result r
        JOIN idr_core.idr_claim_selection_evaluation e ON e.idr_claim_selection_evaluation_id = r.idr_claim_selection_evaluation_id
        LEFT JOIN idr_core.config_exclusion_reason x ON x.exclusion_code = r.exclusion_code
        WHERE e.idr_case_unit_id = @id ORDER BY r.idr_claim_selection_evaluation_id DESC, r.idr_claim_selection_rule_result_id
        """;

    public string ClaimVersions => """
        SELECT v.captured_at_utc, v.version_sequence, v.edi_837_claim_id, v.edi_837_claim_line_id, v.frequency_code, v.is_void,
               v.service_code, v.line_charge_amount, v.change_type, v.note,
               (v.edi_837_claim_line_id = c.edi_837_claim_line_id) AS is_current
        FROM idr_core.idr_case_claim_version v
        JOIN idr_core.idr_case_unit c ON c.idr_case_unit_id = v.idr_case_unit_id
        WHERE v.idr_case_unit_id = @id ORDER BY v.version_sequence, v.idr_case_claim_version_id
        """;

    public string StatusHistory => """
        SELECT h.changed_at_utc, h.event_source, po.outcome_code AS prior_outcome, no.outcome_code AS new_outcome, h.reason_code, h.notes
        FROM idr_core.idr_case_status_history h
        LEFT JOIN idr_core.idr_case_outcome_lookup po ON po.idr_case_outcome_id = h.prior_outcome_id
        LEFT JOIN idr_core.idr_case_outcome_lookup no ON no.idr_case_outcome_id = h.new_outcome_id
        WHERE h.idr_case_unit_id = @id ORDER BY h.changed_at_utc, h.idr_case_status_history_id
        """;

    public string Batch => """
        SELECT b.batch_reference, b.batch_status, b.grouping_mode, b.tax_id, b.payer_business_id, b.insurance_group_number,
               b.service_line_code, b.service_code, b.earliest_dos, b.latest_dos, b.first_remit_payment_date, b.batch_open_end_date,
               (SELECT count(*) FROM idr_core.idr_preliminary_batch_case_unit x WHERE x.idr_preliminary_batch_id = b.idr_preliminary_batch_id) AS cases_in_batch
        FROM idr_core.idr_preliminary_batch_case_unit a
        JOIN idr_core.idr_preliminary_batch b ON b.idr_preliminary_batch_id = a.idr_preliminary_batch_id
        WHERE a.idr_case_unit_id = @id
        """;

    public string CaseExceptions => """
        SELECT e.idr_claim_selection_exception_id, e.exception_code, x.exception_label, e.status, e.retry_count,
               e.days_remaining_in_window, e.last_aged_on, e.opened_at_utc, e.resolved_at_utc, e.reason_text
        FROM idr_core.idr_case_unit c
        JOIN idr_core.idr_claim_selection_exception e ON e.edi_835_claim_line_payment_id = c.edi_835_claim_line_payment_id
        LEFT JOIN idr_core.config_exception_reason x ON x.exception_code = e.exception_code
        WHERE c.idr_case_unit_id = @id ORDER BY e.idr_claim_selection_exception_id
        """;

    /// <summary>Every job decision about this case, its remit line or the matching exception of that line, with the run number per job.</summary>
    public string CaseTimeline => """
        WITH c AS (SELECT idr_case_unit_id AS id, edi_835_claim_line_payment_id AS remit_line FROM idr_core.idr_case_unit WHERE idr_case_unit_id = @id),
        ex AS (SELECT e.idr_claim_selection_exception_id AS id FROM idr_core.idr_claim_selection_exception e JOIN c ON e.edi_835_claim_line_payment_id = c.remit_line)
        SELECT l.job_code, l.result, l.detail, l.logged_at_utc,
               row_number() OVER (PARTITION BY l.job_code ORDER BY l.logged_at_utc, l.job_case_log_id) AS run_no
        FROM idr_core.job_case_log l CROSS JOIN c
        WHERE l.idr_case_unit_id = c.id OR l.edi_835_claim_line_payment_id = c.remit_line OR l.exception_id IN (SELECT id FROM ex)
        ORDER BY l.logged_at_utc, l.job_case_log_id
        """;

    public string Unmatched => """
        SELECT lp.edi_835_claim_line_payment_id AS remit_line_id, lp.client_id, lp.patient_control_number, lp.payer_business_id,
               lp.paid_service_code, lp.service_line_code, lp.date_of_service, lp.remit_payment_date AS remit_payment_date,
               lp.allowed_amount, e.exception_code, x.exception_label, COALESCE(e.status, 'NOT PROCESSED YET') AS exception_status,
               e.retry_count, e.days_remaining_in_window, e.last_aged_on, e.opened_at_utc, e.resolved_at_utc, e.reason_text,
               e.missing_fields::text AS missing_fields,
               (SELECT count(*) FROM idr_core.job_case_log l WHERE l.job_code = 'CLAIM_REMIT_MATCHING' AND l.edi_835_claim_line_payment_id = lp.edi_835_claim_line_payment_id) AS match_attempts,
               (SELECT count(*) FROM idr_core.job_case_log l WHERE l.job_code = 'EXCEPTION_AGING' AND l.exception_id = e.idr_claim_selection_exception_id) AS aging_runs,
               (idr_core.fn_business_today() - lp.remit_payment_date) AS days_from_remit_payment_date,
               (SELECT l.result FROM idr_core.job_case_log l WHERE l.job_code = 'CLAIM_REMIT_MATCHING' AND l.edi_835_claim_line_payment_id = lp.edi_835_claim_line_payment_id ORDER BY l.job_case_log_id DESC LIMIT 1) AS last_match_result,
               (SELECT l.logged_at_utc FROM idr_core.job_case_log l WHERE l.job_code = 'CLAIM_REMIT_MATCHING' AND l.edi_835_claim_line_payment_id = lp.edi_835_claim_line_payment_id ORDER BY l.job_case_log_id DESC LIMIT 1) AS last_match_at
        FROM idr_core.vw_835_claim_selection_source lp
        LEFT JOIN idr_core.idr_claim_selection_exception e ON e.edi_835_claim_line_payment_id = lp.edi_835_claim_line_payment_id
        LEFT JOIN idr_core.config_exception_reason x ON x.exception_code = e.exception_code
        WHERE NOT EXISTS (SELECT 1 FROM idr_core.idr_claim_remit_match m WHERE m.edi_835_claim_line_payment_id = lp.edi_835_claim_line_payment_id)
          AND (@client::text IS NULL OR lp.client_id = @client)
        ORDER BY (e.status = 'OPEN') DESC NULLS LAST, lp.remit_payment_date DESC, lp.edi_835_claim_line_payment_id DESC
        """;

    public string UnmatchedSummary => """
        SELECT COALESCE(e.exception_code, '-') AS exception_code, COALESCE(x.exception_label, 'No exception yet') AS exception_label,
               COALESCE(e.status, 'NOT PROCESSED YET') AS exception_status, count(*) AS lines,
               COALESCE(sum((SELECT count(*) FROM idr_core.job_case_log l WHERE l.job_code = 'CLAIM_REMIT_MATCHING' AND l.edi_835_claim_line_payment_id = lp.edi_835_claim_line_payment_id)), 0) AS match_attempts,
               COALESCE(max(e.retry_count), 0) AS max_retry_count
        FROM idr_core.vw_835_claim_selection_source lp
        LEFT JOIN idr_core.idr_claim_selection_exception e ON e.edi_835_claim_line_payment_id = lp.edi_835_claim_line_payment_id
        LEFT JOIN idr_core.config_exception_reason x ON x.exception_code = e.exception_code
        WHERE NOT EXISTS (SELECT 1 FROM idr_core.idr_claim_remit_match m WHERE m.edi_835_claim_line_payment_id = lp.edi_835_claim_line_payment_id)
          AND (@client::text IS NULL OR lp.client_id = @client)
        GROUP BY 1, 2, 3 ORDER BY 1, 3
        """;

    public string RemitHistory => """
        SELECT l.job_code, l.result, l.detail, l.logged_at_utc,
               row_number() OVER (PARTITION BY l.job_code ORDER BY l.logged_at_utc, l.job_case_log_id) AS run_no
        FROM idr_core.job_case_log l
        WHERE l.edi_835_claim_line_payment_id = @id
           OR l.exception_id IN (SELECT idr_claim_selection_exception_id FROM idr_core.idr_claim_selection_exception WHERE edi_835_claim_line_payment_id = @id)
        ORDER BY l.logged_at_utc, l.job_case_log_id
        """;

    public string JobRunSummary => """
        SELECT job_code, count(*) AS runs, count(*) FILTER (WHERE status = 'SUCCEEDED') AS succeeded,
               count(*) FILTER (WHERE status = 'FAILED') AS failed, COALESCE(sum(processed_count), 0) AS total_processed,
               max(started_at_utc) AS last_run_utc,
               (SELECT r2.processed_count FROM idr_core.job_run_log r2 WHERE r2.job_code = r.job_code ORDER BY r2.job_run_log_id DESC LIMIT 1) AS last_processed
        FROM idr_core.job_run_log r GROUP BY job_code ORDER BY min(job_run_log_id)
        """;

    /// <summary>Everything that happened to one PCN: remit lines, match, exception, case, outcome and the job history of each line.</summary>
    public string Trace => """
        SELECT lp.edi_835_claim_line_payment_id AS remit_line_id, lp.line_number, lp.paid_service_code, lp.date_of_service,
               m.match_type, m.matched_837_version_sequence AS matched_version,
               c.idr_case_unit_id AS case_id, o.outcome_code, c.selected_for_federal_idr, c.active_in_idr_workflow,
               e.exception_code, e.status AS exception_status, e.retry_count, e.reason_text,
               s.check_status AS cool_off_status, b.batch_reference,
               COALESCE((SELECT json_agg(json_build_object('job', j.job_code, 'result', j.result, 'detail', j.detail, 'at', j.logged_at_utc) ORDER BY j.job_case_log_id)
                         FROM idr_core.job_case_log j
                         WHERE j.edi_835_claim_line_payment_id = lp.edi_835_claim_line_payment_id
                            OR j.idr_case_unit_id = c.idr_case_unit_id
                            OR j.exception_id = e.idr_claim_selection_exception_id), '[]'::json)::text AS history
        FROM idr_core.vw_835_claim_selection_source lp
        LEFT JOIN idr_core.idr_claim_remit_match m ON m.edi_835_claim_line_payment_id = lp.edi_835_claim_line_payment_id
        LEFT JOIN idr_core.idr_case_unit c ON c.edi_835_claim_line_payment_id = lp.edi_835_claim_line_payment_id
        LEFT JOIN idr_core.idr_case_outcome_lookup o ON o.idr_case_outcome_id = c.current_outcome_id
        LEFT JOIN idr_core.idr_claim_selection_exception e ON e.edi_835_claim_line_payment_id = lp.edi_835_claim_line_payment_id
        LEFT JOIN idr_core.idr_cool_off_status s ON s.idr_case_unit_id = c.idr_case_unit_id
        LEFT JOIN idr_core.idr_preliminary_batch_case_unit a ON a.idr_case_unit_id = c.idr_case_unit_id
        LEFT JOIN idr_core.idr_preliminary_batch b ON b.idr_preliminary_batch_id = a.idr_preliminary_batch_id
        WHERE lp.client_id = @client AND lp.patient_control_number = @pcn
        ORDER BY lp.edi_835_claim_line_payment_id
        """;
}
