BEGIN;

-- 1) Preliminary Batching: members and the batches they were in
WITH gone AS (
    DELETE FROM idr_core.idr_preliminary_batch_case_unit
    WHERE idr_case_unit_id BETWEEN 9400001 AND 9400057
    RETURNING idr_preliminary_batch_id
)
DELETE FROM idr_core.idr_preliminary_batch b
USING (SELECT DISTINCT idr_preliminary_batch_id FROM gone) g
WHERE b.idr_preliminary_batch_id = g.idr_preliminary_batch_id;

-- 2) Cool-off Status: remove the job results, then put the two history rows back
DELETE FROM idr_core.idr_cool_off_status WHERE idr_case_unit_id BETWEEN 9400001 AND 9400057;
INSERT INTO idr_core.idr_cool_off_status (idr_case_unit_id, check_status, cool_off_start_date, cool_off_end_date, determination_reference, is_active, client_id, provider_id, created_by_user, modified_by_user) VALUES
 (9400049, 'ACTIVE', DATE '2026-09-21', DATE '2026-10-21', 'DET-MOCK-001', true, 9101, 1, 'mock-data', 'mock-data'),
 (9400054, 'ACTIVE', DATE '2026-09-21', DATE '2026-10-21', 'DET-MOCK-002', true, 9101, 1, 'mock-data', 'mock-data');

-- 3) Exclusion Validation: evaluations, rule results, selection results
DELETE FROM idr_core.idr_claim_selection_result WHERE idr_case_unit_id BETWEEN 9400001 AND 9400057;
DELETE FROM idr_core.idr_claim_selection_rule_result WHERE idr_claim_selection_evaluation_id IN
    (SELECT idr_claim_selection_evaluation_id FROM idr_core.idr_claim_selection_evaluation WHERE idr_case_unit_id BETWEEN 9400001 AND 9400057);
DELETE FROM idr_core.idr_claim_selection_evaluation WHERE idr_case_unit_id BETWEEN 9400001 AND 9400057;

-- 4) Exclusion Validation + Systemic Not Pursued: status history, audit events, job log
DELETE FROM idr_core.idr_case_status_history WHERE idr_case_unit_id BETWEEN 9400001 AND 9400057;
DELETE FROM idr_core.audit_event
WHERE client_id = 9101
  AND ((event_type = 'SYSTEMIC_NOT_PURSUED_APPLIED' AND entity_type = 'IDR_CASE' AND entity_id IN (SELECT g::text FROM generate_series(9400001, 9400057) g))
    OR (event_type = 'NEW_INSURANCE_GROUP_FLAGGED' AND entity_type = 'INSURANCE_GROUP'));
DELETE FROM idr_core.job_case_log
WHERE client_id = 9101
  AND job_code IN ('EXCEPTION_AGING', 'EXCLUSION_VALIDATION', 'SYSTEMIC_NOT_PURSUED', 'COOL_OFF_STATUS', 'PRELIMINARY_BATCHING');

-- 5) The cases go back to "waiting for evaluation" (what claim-remit matching left)
UPDATE idr_core.idr_case_unit
SET current_outcome_id = (SELECT idr_case_outcome_id FROM idr_core.idr_case_outcome_lookup WHERE outcome_code = 'CS-PENDING-EVALUATION'),
    current_stage = 'CLAIM_SELECTION',
    selected_for_federal_idr = false,
    active_in_idr_workflow = false,
    modified_timestamp = now()
WHERE idr_case_unit_id BETWEEN 9400001 AND 9400057;

-- 6) Exception Status Monitoring: the 24 exceptions go back to OPEN, retry 0
UPDATE idr_core.idr_claim_selection_exception
SET status = 'OPEN', retry_count = 0, days_remaining_in_window = NULL, last_aged_on = NULL,
    resolved_timestamp = NULL, modified_timestamp = now()
WHERE idr_claim_selection_exception_id BETWEEN 9500001 AND 9500024;

COMMIT;
