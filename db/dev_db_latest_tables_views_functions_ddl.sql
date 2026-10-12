-- DDL extracted from dev_db_latest.sql
-- Included object types only: TABLE, VIEW/MATERIALIZED VIEW, FUNCTION
-- Excluded: data, sequences, indexes, constraints added later by ALTER TABLE,
-- triggers, grants, ownership changes, comments, and other object types.
-- Object counts: 326 tables, 3 views, 18 functions.

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET search_path = '';

CREATE FUNCTION idr_core.fn_business_today() RETURNS date
    LANGUAGE sql STABLE
    AS $$
    SELECT (now() AT TIME ZONE 'America/New_York')::date;
$$;

CREATE FUNCTION idr_core.fn_case_auto_enrich() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'idr_core', 'public'
    AS $$
BEGIN
    INSERT INTO idr_core.idr_case_financial_summary
    (
        idr_case_unit_id,
        billed_amount,
        allowed_amount,
        paid_amount,
        qpa_amount,
        medicare_reference_amount,
        provider_offer_amount,
        updated_at_utc,
        created_by_user,
        modified_by_user,
        client_id,
        provider_id
    )
    SELECT
        NEW.idr_case_unit_id,
        COALESCE(line_837.line_charge_amount, source_835.line_charge_amount),
        source_835.allowed_amount,
        source_835.line_paid_amount,
        NULL,
        (
            SELECT fee.reference_amount
            FROM idr_core.config_medicare_fee_schedule fee
            WHERE fee.service_code = NEW.service_code
              AND (fee.modifier_code IS NULL OR fee.modifier_code = NEW.qualifying_modifier)
              AND (fee.state_code IS NULL OR fee.state_code = NEW.facility_state_code)
            ORDER BY
                CASE WHEN fee.modifier_code = NEW.qualifying_modifier THEN 0 ELSE 1 END,
                CASE WHEN fee.state_code = NEW.facility_state_code THEN 0 ELSE 1 END,
                abs(fee.fee_schedule_year - EXTRACT(YEAR FROM NEW.date_of_service)::integer),
                fee.fee_schedule_year DESC
            LIMIT 1
        ),
        source_835.provider_offer_amount,
        now(),
        NEW.created_by_user,
        NEW.modified_by_user,
        NEW.client_id,
        NEW.provider_id
    FROM idr_core.vw_835_claim_selection_source source_835
    LEFT JOIN idr_core.vw_837_claim_selection_source line_837
      ON line_837.edi_837_claim_line_id = NEW.edi_837_claim_line_id
    WHERE source_835.edi_835_claim_line_payment_id = NEW.edi_835_claim_line_payment_id
    ON CONFLICT (idr_case_unit_id)
    DO UPDATE SET
        billed_amount = EXCLUDED.billed_amount,
        allowed_amount = EXCLUDED.allowed_amount,
        paid_amount = EXCLUDED.paid_amount,
        medicare_reference_amount = EXCLUDED.medicare_reference_amount,
        provider_offer_amount = EXCLUDED.provider_offer_amount,
        updated_at_utc = now(),
        modified_timestamp = now(),
        modified_by_user = EXCLUDED.modified_by_user;

    RETURN NEW;
END;
$$;

CREATE FUNCTION idr_core.fn_claim_selection_dashboard(period_type character varying DEFAULT 'DAILY'::character varying, from_date date DEFAULT NULL::date, to_date date DEFAULT NULL::date, client_ids integer[] DEFAULT NULL::integer[], p_tax_id character varying DEFAULT NULL::character varying, payer_ids text[] DEFAULT NULL::text[], service_lines text[] DEFAULT NULL::text[], npi_ids text[] DEFAULT NULL::text[], alert_type integer DEFAULT NULL::integer) RETURNS TABLE(alerts_result jsonb, kpi_result jsonb, grid_result jsonb)
    LANGUAGE plpgsql
    AS $$
BEGIN

RETURN QUERY WITH filtered_cases AS (
    SELECT *
    FROM idr_core.fn_claim_selection_dashboard_data(
        period_type, from_date, to_date, client_ids, p_tax_id,
        payer_ids, service_lines, npi_ids, alert_type
    )
),
alerts_json AS (
    SELECT jsonb_agg(jsonb_build_object('Title', title, 'Count', alert_count)) AS data
    FROM
    (
        SELECT 'On Deadlines Approaching' AS title, COUNT(*) AS alert_count
        FROM filtered_cases
        WHERE idr_core.fn_get_workingdays(payment_effective_date, 30) <= 5

        UNION ALL
        SELECT 'Exception Records Stale', COUNT(*)
        FROM filtered_cases
        WHERE outcome_code = 'CS-Success-Exception'
          AND idr_core.fn_get_workingdays(payment_effective_date, 30) = 0

        UNION ALL
        SELECT 'Extenuating Circumstances Applied', 0

        UNION ALL
        SELECT 'New 837 Received For Active IDR Cases', 0

        UNION ALL
        SELECT 'Volume Anomaly', 0

        UNION ALL
        SELECT 'Cool-Off Expiry', COUNT(*)
        FROM filtered_cases
        WHERE cool_off_end_date IS NOT NULL
          AND cool_off_end_date::date <= CURRENT_DATE
    ) x
),
kpi AS (
    SELECT
        COUNT(*) FILTER (WHERE outcome_code = 'CS-SUCCESS-SELECTED')  AS selected_cases,
        COUNT(*) FILTER (WHERE outcome_code = 'CS-SUCCESS-EXCLUDED')  AS excluded_cases,
        COUNT(*) FILTER (WHERE outcome_code = 'CS-SUCCESS-EXCEPTION') AS exception_cases,
        COUNT(*) FILTER (WHERE outcome_code LIKE 'CS-NOTPURSUED-%')   AS notpursued_cases,
        COUNT(*) FILTER (
            WHERE CURRENT_DATE BETWEEN cool_off_start_date::date AND cool_off_end_date::date
        ) AS cool_off_cases,
        COUNT(*) FILTER (
            WHERE outcome_code IN ('CS-SUCCESS-SELECTED','CS-SUCCESS-EXCLUDED','CS-SUCCESS-EXCEPTION')
               OR outcome_code LIKE 'CS-NOTPURSUED-%'
        ) AS total_cases,
        COALESCE(
            (
                SELECT ROUND(COUNT(*)::NUMERIC / 30, 2)
                FROM filtered_cases fc
                WHERE fc.outcome_code = 'CS-SUCCESS-SELECTED'
                  AND fc.created_at::DATE >= idr_core.fn_get_previous_business_date(CURRENT_DATE, 30)
            ),
            0
        ) AS daily_selected_avg
    FROM filtered_cases
),
kpi_json AS (
    SELECT jsonb_agg(jsonb_build_object('title', title, 'metrics', metrics)) AS data
    FROM
    (
        SELECT 'Selected IDR Cases' AS title,
               jsonb_agg(jsonb_build_object('label', label, 'value', value, 'suffix', suffix)) AS metrics
        FROM (
            SELECT 'Cases' AS label, k.selected_cases AS value, NULL AS suffix FROM kpi k
            UNION ALL
            SELECT 'Selection Rate',
                   COALESCE(ROUND(k.selected_cases::numeric / NULLIF(k.total_cases, 0) * 100, 2), 0.00),
                   '%'
            FROM kpi k
            UNION ALL
            SELECT '30 Day Average', k.daily_selected_avg, NULL FROM kpi k
        ) sub

        UNION ALL
        SELECT 'Excluded IDR Cases',
               jsonb_agg(jsonb_build_object('label', label, 'value', value, 'suffix', suffix))
        FROM (
            SELECT 'Cases' AS label, kpi.excluded_cases AS value, NULL AS suffix FROM kpi
            UNION ALL
            SELECT 'Exclusion Rate',
                   COALESCE(ROUND(kpi.excluded_cases::numeric / NULLIF(kpi.total_cases, 0) * 100, 2), 0.00),
                   '%'
            FROM kpi
        ) sub

        UNION ALL
        SELECT 'Exception IDR Cases',
               jsonb_agg(jsonb_build_object('label', label, 'value', value, 'suffix', suffix))
        FROM (
            SELECT 'Cases' AS label, kpi.exception_cases AS value, NULL AS suffix FROM kpi
            UNION ALL
            SELECT 'Exception Rate',
                   COALESCE(ROUND(kpi.exception_cases::numeric / NULLIF(kpi.total_cases, 0) * 100, 2), 0.00),
                   '%'
            FROM kpi
        ) sub

        UNION ALL
        SELECT 'Not Pursued IDR Cases',
               jsonb_agg(jsonb_build_object('label', label, 'value', value, 'suffix', suffix))
        FROM (
            SELECT 'Cases' AS label, kpi.notpursued_cases AS value, NULL AS suffix FROM kpi
            UNION ALL
            SELECT 'Not Pursued Rate',
                   COALESCE(ROUND(kpi.notpursued_cases::numeric / NULLIF(kpi.total_cases, 0) * 100, 2), 0.00),
                   '%'
            FROM kpi
        ) sub

        UNION ALL
        SELECT 'Total IDR Cases Under Cool-Off',
               jsonb_agg(jsonb_build_object('label', label, 'value', value, 'suffix', suffix))
        FROM (
            SELECT 'Cases' AS label, kpi.cool_off_cases AS value, NULL AS suffix FROM kpi
        ) sub
    ) kpi_sections
),
grid_json AS (
    SELECT jsonb_agg(to_jsonb(g)) AS data
    FROM
    (
        SELECT
			idr_case_unit_id AS IDRCaseID,
            threshold_amount::NUMERIC(10, 2) AS AnesthesiaThreshold,
            invoice_number AS InvoiceNo,
            client_id AS ClientID,
            claim_id AS ClaimID,
            'N/A' AS Claim_Number,
            CASE WHEN is_corrected THEN 'YES' ELSE 'NO' END AS CorrectedCase,
            payer_id AS PayerID,
            service_code AS ServiceCode,
            service_code_type AS ServiceLine,
            modifier_code AS Modifiers,
            cool_off_start_date AS CoolOffStartDate,
            cool_off_end_date AS CoolOffEndDate,
            idr_core.fn_get_workingdays(payment_effective_date, 15) AS DaysleftforON,
            tax_id AS TaxID,
            dos_date AS DOS,
            group_name AS EmployerGroupName,
            outcome_code AS Outcome,
            'N/A' AS RARC_CARCCode,
            payment_effective_date AS RemitPaymentDate,
            entity_name AS EntityName
        FROM filtered_cases
        ORDER BY payment_effective_date DESC NULLS LAST
    ) g
)
SELECT a.data, k.data, g.data
FROM kpi_json k
CROSS JOIN grid_json g
CROSS JOIN alerts_json a;

END;
$$;

CREATE FUNCTION idr_core.fn_claim_selection_dashboard_data(period_type character varying DEFAULT 'DAILY'::character varying, from_date date DEFAULT NULL::date, to_date date DEFAULT NULL::date, client_ids integer[] DEFAULT NULL::integer[], p_tax_id character varying DEFAULT NULL::character varying, payer_ids text[] DEFAULT NULL::text[], service_lines text[] DEFAULT NULL::text[], npi_ids text[] DEFAULT NULL::text[], alert_type integer DEFAULT NULL::integer) RETURNS TABLE(idr_case_unit_id bigint, client_id integer, claim_id uuid, is_corrected boolean, payer_id bigint, claim_line_id uuid, service_code character varying, service_code_type character varying, modifier_code character varying, tax_id character varying, dos_date date, payment_effective_date date, outcome_code character varying, cool_off_start_date timestamp without time zone, cool_off_end_date timestamp without time zone, group_name character varying, entity_name character varying, group_npi character varying, created_at timestamp without time zone, invoice_number character varying, threshold_amount numeric, derived_service_line character varying)
    LANGUAGE sql STABLE
    AS $$

SELECT *
FROM idr_core.vw_claim_selection_dashboard_data v
WHERE
    (client_ids IS NULL OR v.client_id = ANY(client_ids))
    AND (p_tax_id IS NULL OR v.tax_id = p_tax_id)
    AND (payer_ids IS NULL OR v.payer_id::text = ANY(payer_ids))
    AND (npi_ids IS NULL OR v.group_npi = ANY(npi_ids))
    AND
    (
        (period_type = 'DAILY'  AND v.date_of_service = CURRENT_DATE)
        OR (period_type = 'WEEKLY' AND v.date_of_service >= CURRENT_DATE - 7)
        OR (period_type = 'CUSTOM'
            AND from_date IS NOT NULL
            AND to_date IS NOT NULL
            AND v.date_of_service BETWEEN from_date AND to_date)
    )
    AND (service_lines IS NULL OR v.derived_service_line = ANY(service_lines))
    AND
	(
	    alert_type IS NULL
	    OR (alert_type = 1   -- OnDeadlineApproaching
	        AND idr_core.fn_get_workingdays(v.payment_effective_date, 30) <= 5)
	)

$$;

CREATE FUNCTION idr_core.fn_claim_selection_filters(period_type character varying DEFAULT 'CUSTOM'::character varying, from_date date DEFAULT NULL::date, to_date date DEFAULT NULL::date, client_ids integer[] DEFAULT NULL::integer[], p_tax_id character varying DEFAULT NULL::character varying, payer_ids text[] DEFAULT NULL::uuid[], service_lines text[] DEFAULT NULL::text[], npi_ids text[] DEFAULT NULL::text[]) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
 DECLARE v_result JSONB;

BEGIN WITH filtered_cases AS (
    SELECT
        *
    FROM
        idr_core.fn_claim_selection_dashboard_data (
            period_type,
            from_date,
            to_date,
            client_ids,
            p_tax_id,
            payer_ids,
            service_lines,
            npi_ids
        )
),
tax_id_values AS (
    SELECT
        COALESCE (
            jsonb_agg (
                DISTINCT jsonb_build_object (
                    'Id',
                    tax_id,
                    'Name',
                    tax_id
                )
            ) FILTER (
                WHERE
                    tax_id IS NOT NULL
            ),
            '[]' :: jsonb
        ) AS data
    FROM
        filtered_cases
),
payer_values AS (
    SELECT
        COALESCE (
            jsonb_agg (
                DISTINCT jsonb_build_object (
                    'Id',
                    payer_id::text,
                    'Name',
                    payer_id::text
                )
            ) FILTER (
                WHERE
                    payer_id IS NOT NULL
            ),
            '[]' :: jsonb
        ) AS data
    FROM
        filtered_cases
),
service_line_values AS (
    SELECT
        COALESCE (
            jsonb_agg (
                DISTINCT jsonb_build_object (
                    'Id',
                    service_line,
                    'Name',
                    service_line
                )
            ) FILTER (
                WHERE
                    service_line IS NOT NULL
            ),
            '[]' :: jsonb
        ) AS data
    FROM
        (
            SELECT
                CASE
                    WHEN service_code ~ '^[0-9]{5}$'
                    AND service_code :: INTEGER BETWEEN 100
                    AND 1999 THEN 'AN'
                    WHEN service_code IN (
                        '99281',
                        '99282',
                        '99283',
                        '99284',
                        '99285'
                    ) THEN 'EM'
                    WHEN service_code IN (
                        '99221',
                        '99222',
                        '99223',
                        '99231',
                        '99232',
                        '99233'
                    ) THEN 'HM'
                    ELSE NULL
                END AS service_line
            FROM
                filtered_cases
        ) x
),
npi_values AS (
    SELECT
        COALESCE (
            jsonb_agg (
                DISTINCT jsonb_build_object (
                    'Id',
                    group_npi,
                    'Name',
                    group_npi
                )
            ) FILTER (
                WHERE
                    group_npi IS NOT NULL
            ),
            '[]' :: jsonb
        ) AS data
    FROM
        filtered_cases
)
SELECT
    jsonb_build_object (
        'Filters',
        jsonb_build_array (
            jsonb_build_object (
                'DisplayName',
                'Tax ID',
                'Values',
                tax_id_values.data
            ),
            jsonb_build_object (
                'DisplayName',
                'Payer',
                'Values',
                payer_values.data
            ),
            jsonb_build_object (
                'DisplayName',
                'Service Line',
                'Values',
                service_line_values.data
            ),
            jsonb_build_object (
                'DisplayName',
                'NPI',
                'Values',
                npi_values.data
            )
        )
    ) INTO v_result
FROM
    tax_id_values
    CROSS JOIN payer_values
    CROSS JOIN service_line_values
    CROSS JOIN npi_values;

RETURN v_result;

END;

$_$;

CREATE FUNCTION idr_core.fn_config_audit() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'idr_core', 'public'
    AS $$
DECLARE
    field text;
    old_json jsonb;
    new_json jsonb;
    who text;
    key_column text := TG_ARGV[0];
BEGIN
    IF current_setting('idr_core.skip_audit', true) = 'on' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    who := COALESCE(NULLIF(current_setting('idr_core.user_id', true), ''), session_user::text);

    IF TG_OP = 'INSERT' THEN
        new_json := to_jsonb(NEW);
        INSERT INTO idr_core.config_version_audit (user_id, category, record_key, field_name, prior_value, new_value,
                                                    created_by_user, modified_by_user, client_id, provider_id)
        VALUES (who, TG_TABLE_NAME, new_json ->> key_column, '(record created)', NULL, new_json::text,
                who, who, COALESCE((new_json ->> 'client_id')::int4, 0), COALESCE((new_json ->> 'provider_id')::int4, 0));
    ELSIF TG_OP = 'DELETE' THEN
        old_json := to_jsonb(OLD);
        INSERT INTO idr_core.config_version_audit (user_id, category, record_key, field_name, prior_value, new_value,
                                                    created_by_user, modified_by_user, client_id, provider_id)
        VALUES (who, TG_TABLE_NAME, old_json ->> key_column, '(record deleted)', old_json::text, NULL,
                who, who, COALESCE((old_json ->> 'client_id')::int4, 0), COALESCE((old_json ->> 'provider_id')::int4, 0));
    ELSE
        old_json := to_jsonb(OLD);
        new_json := to_jsonb(NEW);
        FOR field IN SELECT jsonb_object_keys(new_json) LOOP
            IF old_json -> field IS DISTINCT FROM new_json -> field THEN
                INSERT INTO idr_core.config_version_audit (user_id, category, record_key, field_name, prior_value, new_value,
                                                    created_by_user, modified_by_user, client_id, provider_id)
                VALUES (who, TG_TABLE_NAME, new_json ->> key_column, field, old_json ->> field, new_json ->> field,
                    who, who, COALESCE((new_json ->> 'client_id')::int4, 0), COALESCE((new_json ->> 'provider_id')::int4, 0));
            END IF;
        END LOOP;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE FUNCTION idr_core.fn_get_case_activities(p_idr_case_unit_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT jsonb_build_object(
        'outcomes',                o.j,
        'notes',                   n.j,
        'selectedOutcomeDetails',  od.j
    )
    FROM idr_core.fn_get_case_outcomes_list(p_idr_case_unit_id)   AS o(j)
    CROSS JOIN idr_core.fn_get_case_notes_list(p_idr_case_unit_id)     AS n(j)
    CROSS JOIN idr_core.fn_get_case_outcome_details(p_idr_case_unit_id)         AS od(j);
$$;

CREATE FUNCTION idr_core.fn_get_case_notes_list(p_idr_case_unit_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'noteId',        h.status_history_id,
                'idrCaseUnitId', h.idr_case_unit_id,
                'noteText',      h.notes,
                'stageName',     idr_core.fn_get_stage_name_from_outcome_code(o.outcome_code),
                'activityDate',  h.changed_at
            )
            ORDER BY h.changed_at DESC, h.status_history_id DESC
        ),
        '[]'::jsonb
    )
    FROM idr_core.idr_case_unit_status_history h
    LEFT JOIN idr_core.lkp_idr_case_outcome o
      ON o.outcome_id = h.new_outcome_id
    WHERE h.idr_case_unit_id = p_idr_case_unit_id
      AND NULLIF(btrim(h.notes), '') IS NOT NULL;
$$;

CREATE FUNCTION idr_core.fn_get_case_outcome_details(p_idr_case_unit_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$

SELECT jsonb_build_object
(
    'idrCaseUnitId',        icu.idr_case_unit_id,
    'claimNumber',          c.claim_id,
    'invoiceNumber',        cui.invoice_number,
    'taxId',                tia.tax_id,
    'entityName',           tia.entity_name,
    'insuranceGroupNumber', ig.insurance_group_number,
    'disputeNumber',        dcu.dispute_id,
    'coolOffStartDate',     cos.cool_off_start_date,
    'coolOffEndDate',       cos.cool_off_end_date,
    'idrSubmitDate',        pbcu.assigned_at,
    'idrFilingBatchId',     pbcu.batch_id,
    'idrBatchCount',        COALESCE(bc.idr_batch_count, 0)
)

FROM idr_core.idr_case_unit icu

INNER JOIN idr_core.claim_line cl
    ON cl.claim_line_id = icu.edi_837_claim_line_id

INNER JOIN idr_core.claim c
    ON c.claim_id = cl.claim_id

LEFT JOIN idr_core.insurance_coverage ic
    ON ic.claim_id = c.claim_id

LEFT JOIN idr_core.insurance_group ig
    ON ig.insurance_group_number = ic.insurance_group_number

LEFT JOIN LATERAL
(
    SELECT
        x.cool_off_start_date,
        x.cool_off_end_date
    FROM idr_core.cool_off_status x
    WHERE x.idr_case_unit_id = icu.idr_case_unit_id
    ORDER BY x.created_timestamp DESC
    LIMIT 1
) cos ON TRUE

LEFT JOIN idr_core.tax_id_attribute tia
    ON tia.tax_id = icu.tax_id

LEFT JOIN idr_core.idr_case_unit_identifier cui
    ON cui.idr_case_unit_id = icu.idr_case_unit_id

LEFT JOIN idr_core.dispute_case_unit dcu
    ON dcu.idr_case_unit_id = icu.idr_case_unit_id
   AND dcu.is_active = TRUE

LEFT JOIN idr_core.preliminary_batch_case_unit pbcu
    ON pbcu.idr_case_unit_id = icu.idr_case_unit_id

LEFT JOIN LATERAL
(
    SELECT COUNT(*) AS idr_batch_count
    FROM idr_core.preliminary_batch_case_unit p2
    WHERE p2.batch_id = pbcu.batch_id
) bc ON TRUE

WHERE icu.idr_case_unit_id = p_idr_case_unit_id

LIMIT 1;

$$;

CREATE FUNCTION idr_core.fn_get_case_outcomes_list(p_idr_case_unit_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'outcomeId',     h.status_history_id,
                'idrCaseUnitId', h.idr_case_unit_id,
                'outcomeStatus', o.outcome_code,
                'stageName',     idr_core.fn_get_stage_name_from_outcome_code(o.outcome_code),
                'activityDate',  h.changed_at
            )
            ORDER BY h.changed_at DESC, h.status_history_id DESC
        ),
        '[]'::jsonb
    )
    FROM idr_core.idr_case_unit_status_history h
    JOIN idr_core.lkp_idr_case_outcome o
      ON o.outcome_id = h.new_outcome_id
    WHERE h.idr_case_unit_id = p_idr_case_unit_id
      AND h.new_outcome_id IS NOT NULL;
$$;

CREATE FUNCTION idr_core.fn_get_case_progress(p_idr_case_unit_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_result jsonb;
BEGIN

    WITH stage_master AS
    (
        SELECT *
        FROM
        (
            VALUES
            ('CS','Claim Selection',1),
            ('ON','Open Negotiation',2),
            ('II','IDR Initiation',3),
            ('IDRE','IDRE & Eligibility Review',4),
            ('OS','Offer Submission',5),
            ('DD','Decision Rendered',6),
            ('PR','Payment Reconciliation',7)
        ) s
        (
            stage_code,
            stage_name,
            stage_order
        )
    ),

    transitions AS
    (
        SELECT
            prior_stage,
            new_stage,
            entered_at::date
        FROM idr_core.idr_case_unit_stage_history
        WHERE idr_case_unit_id = p_idr_case_unit_id
        ORDER BY entered_at
    ),

    stage_dates AS
    (
        /*
            Claim Selection
            End date comes from row:
            CS -> ON
        */
        SELECT
            'Claim Selection' AS stage_name,
            NULL::date AS start_date,
            MIN(entered_at) FILTER
            (
                WHERE prior_stage = 'Claim Selection'
            ) AS end_date

        FROM transitions

        UNION ALL

        /*
            Open Negotiation
        */
        SELECT
            'Open Negotiation',
            MIN(entered_at) FILTER
            (
                WHERE new_stage = 'Open Negotiation'
            ),
            MIN(entered_at) FILTER
            (
                WHERE new_stage = 'IDR Initiation'
            )
        FROM transitions

        UNION ALL

        /*
            IDR Initiation
        */
        SELECT
            'IDR Initiation',
            MIN(entered_at) FILTER
            (
                WHERE new_stage = 'IDR Initiation'
            ),
            MIN(entered_at) FILTER
            (
                WHERE new_stage = 'IDRE & Eligibility Review'
            )
        FROM transitions

        UNION ALL

        SELECT
            'IDRE & Eligibility Review',
            MIN(entered_at) FILTER
            (
                WHERE new_stage = 'IDRE & Eligibility Review'
            ),
            MIN(entered_at) FILTER
            (
                WHERE new_stage = 'Offer Submission'
            )
        FROM transitions

        UNION ALL

        SELECT
            'Offer Submission',
            MIN(entered_at) FILTER
            (
                WHERE new_stage = 'Offer Submission'
            ),
            MIN(entered_at) FILTER
            (
                WHERE new_stage = 'Decision Rendered'
            )
        FROM transitions

        UNION ALL

        SELECT
            'Decision Rendered',
            MIN(entered_at) FILTER
            (
                WHERE new_stage = 'Decision Rendered'
            ),
            MIN(entered_at) FILTER
            (
                WHERE new_stage = 'Payment Reconciliation'
            )
        FROM transitions

        UNION ALL

        SELECT
            'Payment Reconciliation',
            MIN(entered_at) FILTER
            (
                WHERE new_stage = 'Payment Reconciliation'
            ),
            NULL::date
        FROM transitions
    ),

    current_stage AS
    (
        SELECT
            COALESCE(new_stage, prior_stage) AS stage_name
        FROM transitions
        ORDER BY entered_at DESC
        LIMIT 1
    )

    SELECT
        jsonb_agg
        (
            jsonb_build_object
            (
                'stageCode', sm.stage_code,
                'stageName', sm.stage_name,

                'startDate', sd.start_date,
                'endDate', sd.end_date,

                'isCompleted',
                    CASE
                        WHEN sd.end_date IS NOT NULL
                        THEN TRUE
                        ELSE FALSE
                    END,

                'isCurrent',
				CASE
				    WHEN sd.start_date IS NOT NULL
				         AND sd.end_date IS NULL
				    THEN TRUE
				    ELSE FALSE
				END
            )
            ORDER BY sm.stage_order
        )
    INTO v_result
    FROM stage_master sm
    LEFT JOIN stage_dates sd
           ON sd.stage_name = sm.stage_name;

    RETURN COALESCE(v_result, '[]'::jsonb);

END;
$$;

CREATE FUNCTION idr_core.fn_get_idr_case_summary(p_idr_case_unit_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
 
DECLARE v_result JSONB;

BEGIN WITH filtered_case_unit AS (
    SELECT
        idr_case_unit_id,
        edi_837_claim_line_id,
        edi_835_claim_line_payment_id,
        tax_id,
        service_line_code,
        date_of_service
    FROM
        idr_core.idr_case_unit
    WHERE
        idr_case_unit_id = p_idr_case_unit_id
)
SELECT
    jsonb_build_object(
        'Claim Information',
        jsonb_build_object(
            'idrCaseUnitId',
            icu.idr_case_unit_id,
            'claimId',
            c.claim_id,
            'taxID',
            icu.tax_id,
            'serviceLine',
            CASE
                WHEN icu.service_line_code ~ '^[0-9]{5}$'
                AND icu.service_line_code :: INTEGER BETWEEN 100
                AND 1999 THEN 'AN'
                WHEN icu.service_line_code IN (
                    '99281',
                    '99282',
                    '99283',
                    '99284',
                    '99285'
                ) THEN 'EM'
                WHEN icu.service_line_code IN (
                    '99221',
                    '99222',
                    '99223',
                    '99231',
                    '99232',
                    '99233'
                ) THEN 'HM'
                ELSE NULL
            END,
            'entityName',
            tia.entity_name,
            'payerId',
            c.payer_id,
            'insuranceGroupNumber',
            ic.insurance_group_number,
            'serviceCode',
            cl.service_code,
            'serviceCodeType',
            cl.service_code_type,
            'modifierCode',
            clm.modifier_code,
            'totalChargeAmount',
            c.total_charge_amount,
            'allowedAmount835',
            r.total_payment_amount,
            'allowedAmountThreshold',
            amt.upper_threshold_pct,
            'rarcCode',
            'N/A',
            'dosDate',
            icu.date_of_service,
            'remitPaymentDate',
            r.payment_effective_date
        ),
        'Provider Entity',
        jsonb_build_object(
            'providerTaxId',
            tia.tax_id,
            'entityName',
            tia.entity_name,
            'groupNPI',
            bp.billing_provider_npi,
            'priorContract',
            'N/A',
            'location',
            concat_ws(', ', bp.city, bp.state),
            'address1',
            bp.address_line1,
            'zipCode',
            bp.zip_code,
            'providerName',
            trim(
                concat(
                    coalesce(rp.first_name, ''),
                    ' ',
                    coalesce(rp.last_name, '')
                )
            ),
            'providerNPI',
            bp.billing_provider_npi
        ),
        'Insurance Details',
        jsonb_build_object(
            'groupName',
            ig.group_name,
            'payerId',
            c.payer_id,
            'insuranceGroupNumber',
            ig.insurance_group_number,
            'fundingTypeId',
            ig.funding_type_id,
            'payerEmail',
            'N/A'
        ),
        'Facility/Hospital Details',
        jsonb_build_object(
            'facilityName',
            sf.facility_name,
            'facilityNPI',
            sf.facility_npi,
            'priorContract',
            'N/A',
            'location',
            concat_ws(', ', sf.city, sf.state),
            'addressLine1',
            sf.address_line1,
            'zipCode',
            sf.zip_code
        ),
        'Patient Demographics',
        jsonb_build_object(
            'firstName',
            pt.first_name,
            'lastName',
            pt.last_name,
            'genderCode',
            pt.gender_code,
            'dateOfBirth',
            pt.dob,
            'patientIdentifier',
            pt.patient_identifier,
            'guarantorName',
            NULL
        )
    ) INTO v_result
FROM
    filtered_case_unit icu
    INNER JOIN idr_core.claim_line cl ON cl.claim_line_id = icu.edi_837_claim_line_id
    INNER JOIN idr_core.claim c ON c.claim_id = cl.claim_id
    LEFT JOIN idr_core.claim_line_modifier clm ON clm.claim_line_id = cl.claim_line_id
    LEFT JOIN idr_core.claim_payment cp ON cp.claim_payment_id = icu.edi_835_claim_line_payment_id
    LEFT JOIN idr_core.remittance r ON r.remittance_id = cp.remittance_id
    LEFT JOIN idr_core.insurance_coverage ic ON ic.claim_id = c.claim_id
    LEFT JOIN idr_core.insurance_group ig ON ig.insurance_group_number = ic.insurance_group_number
    LEFT JOIN idr_core.tax_id_attribute tia ON tia.tax_id = icu.tax_id
    LEFT JOIN idr_core.lkp_allowed_amount_threshold amt ON amt.payer_id = c.payer_id
    AND amt.service_line_code = icu.service_line_code
    AND CURRENT_DATE >= amt.effective_start_date
    AND (
        amt.effective_end_date IS NULL
        OR CURRENT_DATE <= amt.effective_end_date
    )
    LEFT JOIN idr_core.billing_provider bp ON bp.billing_provider_id = c.billing_provider_id
    LEFT JOIN idr_core.rendering_provider rp ON rp.claim_id = c.claim_id
    LEFT JOIN idr_core.service_facility sf ON sf.claim_id = c.claim_id
    LEFT JOIN idr_core.patient pt ON pt.claim_id = c.claim_id;

RETURN COALESCE(v_result, '{}' :: JSONB);

END;

$_$;

CREATE FUNCTION idr_core.fn_get_previous_business_date(p_input_date date, p_business_days integer) RETURNS date
    LANGUAGE plpgsql
    AS $$
 DECLARE v_date DATE := p_input_date;

v_count INTEGER := 0;

BEGIN WHILE v_count < p_business_days LOOP -- Move to previous day
v_date := v_date - 1;
IF EXTRACT(
    ISODOW
    FROM
        v_date
) BETWEEN 1
AND 5
AND NOT EXISTS (
    SELECT
        1
    FROM
        idr_core.lkp_federal_holiday_calendar fh
    WHERE
        fh.holiday_date = v_date
) THEN v_count := v_count + 1;

END IF;

END LOOP;

RETURN v_date;

END;

$$;

CREATE FUNCTION idr_core.fn_get_stage_name_from_outcome_code(p_outcome_code text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
    SELECT CASE split_part(p_outcome_code, '-', 1)
        WHEN 'CS'     THEN 'Claim Selection'
        WHEN 'ON'     THEN 'Open Negotiation'
        WHEN 'II'     THEN 'IDR Initiation'
        WHEN 'IDRE'   THEN 'IDRE Selection'
        WHEN 'ELIG'   THEN 'Eligibility Review'
        WHEN 'FEES'   THEN 'Fees'
        WHEN 'OFFSUB' THEN 'Offer Submission'
        WHEN 'DD'     THEN 'Decision Determination'
        WHEN 'CLOSED' THEN 'Closed'
    END;
$$;

CREATE FUNCTION idr_core.fn_get_workingdays(remit_payment_date date, total_business_days integer DEFAULT NULL::integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
 DECLARE elapsed_business_days INTEGER := 0;

BEGIN IF remit_payment_date IS NULL THEN RETURN NULL;

END IF;

SELECT
    COUNT(*) INTO elapsed_business_days
FROM
    generate_series(
        remit_payment_date,
        CURRENT_DATE,
        INTERVAL '1 day'
    ) d(calendar_date)
WHERE
    EXTRACT(
        ISODOW
        FROM
            d.calendar_date
    ) NOT IN (6, 7)
    AND NOT EXISTS (
        SELECT
            1
        FROM
            idr_core.lkp_federal_holiday_calendar fhc
        WHERE
            fhc.holiday_date = d.calendar_date
            AND fhc.is_active = TRUE
    );
IF total_business_days IS NULL THEN RETURN elapsed_business_days;

END IF;
RETURN GREATEST(
    total_business_days - elapsed_business_days,
    0
);

END;

$$;

CREATE FUNCTION idr_core.fn_list_is_all(list_text text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT list_text IS NULL OR btrim(list_text) = '' OR lower(btrim(list_text)) = 'all';
$$;

CREATE FUNCTION idr_core.fn_list_matches(list_text text, value text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT idr_core.fn_list_is_all(list_text)
        OR (
            value IS NOT NULL AND btrim(value) <> ''
            AND lower(btrim(value)) IN (
                SELECT lower(btrim(item))
                FROM unnest(regexp_split_to_array(list_text, '[;,|' || chr(13) || chr(10) || ']+')) AS item
            )
        );
$$;

CREATE FUNCTION idr_core.fn_set_modified_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.modified_timestamp := now();
  RETURN NEW;
END;
$$;

CREATE TABLE idr_core.ai_case_context_aggregation (
    context_id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid,
    case_id uuid,
    claim_id uuid,
    claim_metadata jsonb,
    dispute_metadata jsonb,
    payer_metadata jsonb,
    qpa_data jsonb,
    aggregation_status character varying(20) DEFAULT 'PENDING'::character varying,
    source_record_count integer,
    aggregated_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_chat_history (
    chat_history_id uuid DEFAULT gen_random_uuid() NOT NULL,
    case_id uuid,
    reviewer_id character varying(100),
    message_text text,
    message_role character varying(20),
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_claim_classification (
    classification_id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(255),
    correlation_id uuid,
    claim_id uuid,
    classification_label character varying(100),
    sub_classification character varying(100),
    classification_confidence numeric(5,4),
    classification_rationale text,
    rag_citations jsonb,
    model_id character varying(100),
    prompt_hash character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_compliance_validation (
    compliance_validation_id uuid DEFAULT gen_random_uuid() NOT NULL,
    case_id uuid,
    payment_id uuid,
    rule_set_version character varying(50),
    violated_rules jsonb,
    validation_status character varying(20),
    validated_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_confidence_scores (
    score_id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(255),
    correlation_id uuid,
    prompt_type character varying(50),
    confidence_score numeric(5,4),
    classification_confidence numeric(5,4),
    extraction_confidence numeric(5,4),
    summarization_confidence numeric(5,4),
    recommendation_confidence numeric(5,4),
    hitl_triggered boolean DEFAULT false,
    hitl_threshold numeric(5,4),
    model_id character varying(100),
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_decision_assistance (
    decision_assist_id uuid DEFAULT gen_random_uuid() NOT NULL,
    case_id uuid,
    recommendation_id uuid,
    bridging_notes text,
    final_decision_reference uuid,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_dispute_scoring (
    score_id uuid DEFAULT gen_random_uuid() NOT NULL,
    case_id uuid,
    message_id character varying(255),
    dispute_score numeric(5,4),
    comparable_case_refs jsonb,
    scoring_factors jsonb,
    cms_benchmark_amount numeric(12,2),
    settlement_range_low numeric(12,2),
    settlement_range_high numeric(12,2),
    model_id character varying(100),
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_dms_response_tracking (
    dms_response_id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid,
    draft_id uuid,
    file_id uuid,
    letter_type character varying(10),
    dms_correlation_id character varying(255),
    dispatch_status character varying(20) DEFAULT 'PENDING'::character varying,
    retry_count integer DEFAULT 0,
    acknowledged_at timestamp with time zone,
    dispatched_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    document_id uuid
);

CREATE TABLE idr_core.ai_document_analysis (
    analysis_id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(255),
    correlation_id uuid,
    document_type character varying(50),
    extracted_entities jsonb,
    summary_text text,
    source_text_hash character varying(64),
    model_id character varying(100),
    model_version character varying(50),
    prompt_type character varying(50),
    processing_duration_ms integer,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_document_chunks (
    chunk_id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_document_id uuid,
    chunk_text text,
    chunk_index integer,
    chunk_position integer,
    embedding_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_email_classification (
    email_classification_id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(255),
    correlation_id uuid,
    case_id uuid,
    subject_line_text text,
    subject_keyword_matched character varying(100),
    classified_stage character varying(50),
    classified_intent character varying(100),
    classification_confidence numeric(5,4),
    classification_source character varying(20),
    scraped_metadata jsonb,
    scraped_idr_data jsonb,
    scraped_urls jsonb,
    attachment_refs jsonb,
    attachment_extraction_method character varying(20),
    attachment_ocr_confidence numeric(5,4),
    proposed_state_transition character varying(100),
    state_transition_committed boolean DEFAULT false,
    state_transition_committed_by character varying(100),
    template_response_triggered boolean DEFAULT false,
    template_response_id uuid,
    template_populated_payload_hash character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_embeddings (
    embedding_id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_document_id uuid,
    embedding_vector public.vector(1536),
    model_name character varying(100),
    chunk_index integer,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_exception_analysis (
    exception_id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(255),
    correlation_id uuid,
    exception_type character varying(100),
    exception_stage character varying(100),
    error_detail text,
    retry_count integer DEFAULT 0,
    resolution_action character varying(100),
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_feature_store (
    feature_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_id uuid,
    case_id uuid,
    feature_name character varying(100),
    feature_value numeric,
    feature_vector jsonb,
    computed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_feedback_loop (
    feedback_id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(255),
    recommendation_id uuid,
    reviewer_id character varying(255),
    original_ai_output jsonb,
    human_correction jsonb,
    feedback_type character varying(50),
    correction_category character varying(100),
    reviewer_notes text,
    used_for_training boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_inference_logs (
    inference_log_id uuid DEFAULT gen_random_uuid() NOT NULL,
    model_id character varying(255),
    prompt_tokens integer,
    completion_tokens integer,
    latency_ms integer,
    response_hash character varying(64),
    batch_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_letter_draft_requests (
    request_id uuid DEFAULT gen_random_uuid() NOT NULL,
    case_id uuid,
    message_id character varying(255),
    letter_type character varying(10),
    request_status character varying(30) DEFAULT 'RECEIVED'::character varying,
    user_role_validated boolean DEFAULT false,
    eob_reference_key text,
    sfn_execution_arn text,
    correlation_id uuid,
    retry_count integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_letter_draft_versions (
    draft_id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid,
    template_id uuid,
    prompt_log_id uuid,
    draft_version integer DEFAULT 1,
    letter_type character varying(10),
    draft_text_hash character varying(64),
    generation_confidence numeric(5,4),
    hitl_required boolean DEFAULT false,
    hitl_decision character varying(20),
    hitl_reviewer_id character varying(255),
    is_final_approved boolean DEFAULT false,
    generated_at timestamp with time zone DEFAULT now(),
    reviewed_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    document_id uuid
);

CREATE TABLE idr_core.ai_letter_templates (
    template_id uuid DEFAULT gen_random_uuid() NOT NULL,
    template_type character varying(10),
    template_name character varying(255),
    template_version character varying(20),
    prompt_slots jsonb,
    is_active boolean DEFAULT true,
    created_by character varying(100),
    created_at timestamp with time zone DEFAULT now(),
    retired_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    document_id uuid
);

CREATE TABLE idr_core.ai_llm_invocation_log (
    invocation_id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid,
    draft_id uuid,
    prompt_log_id uuid,
    letter_type character varying(10),
    model_id character varying(100),
    input_token_count integer,
    output_token_count integer,
    invocation_latency_ms integer,
    streaming_used boolean DEFAULT false,
    guardrail_trace_id character varying(255),
    guardrail_action character varying(20) DEFAULT 'NONE'::character varying,
    invoked_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_manual_exception_review (
    review_id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid,
    case_id uuid,
    exception_trigger character varying(80),
    exception_detail text,
    assigned_to uuid,
    review_status character varying(20) DEFAULT 'PENDING'::character varying,
    resolution_action character varying(60),
    reviewer_notes text,
    sla_breach boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    resolved_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_model_execution (
    execution_id uuid DEFAULT gen_random_uuid() NOT NULL,
    model_id character varying(255),
    model_version character varying(50),
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    duration_ms integer,
    input_size_bytes integer,
    output_size_bytes integer,
    status character varying(20),
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_model_registry (
    registry_id uuid DEFAULT gen_random_uuid() NOT NULL,
    model_name character varying(255),
    model_id character varying(100),
    model_version character varying(50),
    prompt_template_version character varying(20),
    prompt_type character varying(50),
    deployment_date date,
    retired_date date,
    hitl_threshold numeric(5,4) DEFAULT 0.75,
    performance_metrics jsonb,
    is_active boolean DEFAULT true,
    created_by character varying(255),
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_ocr_extraction (
    ocr_id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(255),
    correlation_id uuid,
    textract_job_id character varying(255),
    document_type character varying(50),
    page_count integer,
    extraction_confidence_avg numeric(5,4),
    extraction_confidence_min numeric(5,4),
    forms_extracted jsonb,
    tables_extracted jsonb,
    ocr_status character varying(50) DEFAULT 'PENDING'::character varying,
    created_at timestamp with time zone DEFAULT now(),
    completed_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    document_id uuid,
    output_document_id uuid
);

CREATE TABLE idr_core.ai_processing_queue (
    queue_id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(255),
    correlation_id uuid,
    batch_id uuid,
    source_type character varying(50),
    file_type character varying(20),
    processing_status character varying(50) DEFAULT 'RECEIVED'::character varying,
    retry_count integer DEFAULT 0,
    error_message text,
    dedup_hash character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    document_id uuid,
    processed_document_id uuid
);

CREATE TABLE idr_core.ai_prompt_logs (
    prompt_log_id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(255),
    correlation_id uuid,
    prompt_type character varying(50),
    system_prompt_hash character varying(64),
    user_prompt_hash character varying(64),
    prompt_template_version character varying(20),
    input_token_count integer,
    output_token_count integer,
    model_id character varying(100),
    rag_context_ids uuid[],
    response_hash character varying(64),
    inference_latency_ms integer,
    guardrail_applied boolean DEFAULT false,
    guardrail_action character varying(50) DEFAULT 'NONE'::character varying,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_rag_context (
    rag_context_id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(255),
    correlation_id uuid,
    query_text_hash character varying(64),
    retrieved_chunk_id character varying(255),
    source_document_name character varying(500),
    source_document_section character varying(500),
    similarity_score numeric(5,4),
    chunk_text text,
    embedding_model_id character varying(100),
    retrieval_timestamp timestamp without time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_recommendations (
    recommendation_id uuid DEFAULT gen_random_uuid() NOT NULL,
    case_id uuid,
    message_id character varying(255),
    correlation_id uuid,
    recommended_action character varying(100),
    recommended_amount numeric(12,2),
    recommendation_rationale text,
    supporting_rag_citations jsonb,
    confidence_score numeric(5,4),
    model_id character varying(100),
    hitl_reviewed boolean DEFAULT false,
    hitl_reviewer_id character varying(255),
    hitl_decision character varying(50),
    final_recommendation character varying(100),
    created_at timestamp with time zone DEFAULT now(),
    reviewed_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_risk_scoring (
    risk_score_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_id uuid,
    fraud_risk_score numeric(5,4),
    anomaly_flags jsonb,
    risk_category character varying(20),
    scored_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_rpa_output (
    rpa_output_id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid,
    case_id uuid,
    rpa_task_id character varying(100),
    rpa_system_target character varying(100),
    payload_hash character varying(64),
    dispatch_status character varying(20) DEFAULT 'PENDING'::character varying,
    ack_timestamp timestamp with time zone,
    retry_count integer DEFAULT 0,
    error_detail text,
    dispatched_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    document_id uuid
);

CREATE TABLE idr_core.ai_rule_engine_results (
    rule_result_id uuid DEFAULT gen_random_uuid() NOT NULL,
    document_id uuid,
    rule_set_version character varying(50),
    rule_code character varying(50),
    pass_fail character varying(10),
    evaluation_detail jsonb,
    evaluated_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_step_functions_tracking (
    tracking_id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid,
    letter_type character varying(10),
    sfn_execution_arn text,
    sfn_state_machine_arn text,
    current_state character varying(100),
    execution_status character varying(20) DEFAULT 'RUNNING'::character varying,
    input_payload_hash character varying(64),
    output_payload_hash character varying(64),
    duration_ms integer,
    error_code character varying(100),
    error_cause text,
    started_at timestamp with time zone DEFAULT now(),
    ended_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_training_dataset (
    training_example_id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_case_id uuid,
    input_payload jsonb,
    approved_label character varying(100),
    hitl_reviewer_id character varying(100),
    approved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_validation_results (
    result_id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(255),
    correlation_id uuid,
    validation_stage character varying(50),
    phi_detected boolean DEFAULT false,
    phi_entity_count integer,
    masking_applied boolean DEFAULT false,
    hallucination_check_passed boolean,
    policy_check_passed boolean,
    guardrail_action character varying(50) DEFAULT 'NONE'::character varying,
    guardrail_trace_id character varying(255),
    validated_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_vector_metadata (
    vector_metadata_id uuid DEFAULT gen_random_uuid() NOT NULL,
    embedding_id uuid,
    document_reference character varying(255),
    embedding_model character varying(100),
    chunk_position integer,
    source_type character varying(50),
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.ai_workflow_routing (
    routing_id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid,
    draft_id uuid,
    case_id uuid,
    routing_decision character varying(60),
    confidence_at_routing numeric(5,4),
    routing_rule_version character varying(20),
    downstream_service character varying(100),
    fallback_triggered boolean DEFAULT false,
    routing_reason text,
    routed_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.approved_tin (
    approved_tin_id uuid NOT NULL,
    tax_id character varying(10),
    is_active boolean,
    effective_start_date date,
    effective_end_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.audit_detail (
    audit_detail_id uuid NOT NULL,
    detail_type character varying(40),
    detail_value jsonb,
    recorded_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.audit_event (
    audit_event_id bigint NOT NULL,
    client_id integer NOT NULL,
    entity_type character varying(100) NOT NULL,
    entity_id character varying(100) NOT NULL,
    event_type character varying(100) NOT NULL,
    actor_type character varying(30) NOT NULL,
    actor_id character varying(100),
    event_payload jsonb,
    occurred_at_utc timestamp with time zone DEFAULT now() NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.audit_log (
    audit_log_id uuid NOT NULL,
    event_type character varying(40),
    payload jsonb,
    logged_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.batch_action_history (
    batch_action_history_id uuid NOT NULL,
    event_type character varying(40),
    event_detail jsonb,
    recorded_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.batch_status_history (
    batch_status_history_id uuid NOT NULL,
    prior_status character varying(30),
    new_status character varying(30),
    changed_by_user_id uuid,
    changed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.batch_validation_result (
    batch_validation_result_id uuid NOT NULL,
    result_status character varying(20),
    result_detail jsonb,
    evaluated_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.billing_provider (
    billing_provider_id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider_name character varying(200),
    billing_provider_npi character varying(255),
    provider_tin character varying(255),
    address_line1 character varying(255),
    city character varying(255),
    state character varying(255),
    zip_code character varying(20),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.case_exception (
    case_exception_id uuid NOT NULL,
    idr_case_unit_id uuid,
    stage character varying(30),
    exception_type character varying(50),
    status character varying(15),
    opened_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.case_exception_assignment (
    case_exception_assignment_id uuid NOT NULL,
    case_exception_id uuid,
    assigned_to_user_id uuid,
    assigned_to_team character varying(50),
    assignment_status character varying(15),
    assigned_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.case_exception_detail (
    case_exception_detail_id uuid NOT NULL,
    case_exception_id uuid,
    detail_type character varying(40),
    detail_value jsonb,
    recorded_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.case_exception_resolution (
    case_exception_resolution_id uuid NOT NULL,
    case_exception_id uuid,
    resolution_type character varying(40),
    resolution_notes text,
    resolved_by_user_id uuid,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.case_exception_status_history (
    case_exception_status_history_id uuid NOT NULL,
    case_exception_id uuid,
    prior_status character varying(30),
    new_status character varying(30),
    changed_by_user_id uuid,
    changed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim (
    claim_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_type character varying(10),
    invoice_number character varying(100),
    total_charge_amount numeric(18,2),
    facility_type_code character varying(10),
    frequency_code character varying(10),
    is_corrected boolean DEFAULT false,
    is_void boolean DEFAULT false,
    latest_valid_version_flag boolean DEFAULT true,
    match_flag_status character varying(50),
    billing_provider_id uuid,
    subscriber_id uuid,
    patient_id uuid,
    created_timestamp timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by_user character varying NOT NULL,
    modified_by_user character varying NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    payer_id bigint,
    root_claim_id uuid,
    original_claim_id uuid,
    version_sequence integer DEFAULT 1 NOT NULL,
    patient_account_number character varying(100),
    provider_tin character varying(20),
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT ck_claim_type CHECK (((claim_type IS NULL) OR ((claim_type)::text = ANY ((ARRAY['837P'::character varying, '837I'::character varying])::text[]))))
);

CREATE TABLE idr_core.claim_diagnosis (
    claim_diagnosis_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_id uuid,
    diagnosis_type character varying(30),
    diagnosis_code character varying(20),
    diagnosis_sequence character varying(255),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_drg (
    claim_drg_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_id uuid,
    drg_code character varying(20),
    drg_type character varying(30),
    is_inpatient_indicator boolean,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_identifier (
    claim_identifier_id uuid NOT NULL,
    claim_id uuid,
    reference_type character varying(30),
    reference_value character varying(60),
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_line (
    claim_line_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_id uuid,
    line_number character varying(50),
    claim_type character varying(30),
    revenue_code character varying(20),
    service_code_type character varying(20),
    service_code character varying(20),
    drg_code character varying(20),
    line_charge_amount numeric(14,2),
    unit_type character varying(30),
    units character varying(255),
    date_of_service character varying(255),
    line_discriminator character varying(255),
    idr_business_key character varying(255),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    service_line_category character varying(2),
    service_line character varying(20)
);

CREATE TABLE idr_core.claim_line_modifier (
    modifier_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_line_id uuid,
    modifier_code character varying(20),
    modifier_sequence character varying(255),
    is_qualifying_modifier boolean,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_line_payment (
    claim_line_payment_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_payment_id uuid,
    service_code_type character varying(20),
    paid_service_code character varying(20),
    line_charge_amount numeric(14,2),
    line_paid_amount numeric(14,2),
    units character varying(255),
    date_of_service character varying(255),
    line_item_control_number character varying(50),
    allowed_amount numeric(14,2),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    line_number integer,
    service_line character varying(20),
    provider_offer_amount numeric(18,2),
    revenue_code character varying(20)
);

CREATE TABLE idr_core.claim_line_payment_adjustment (
    claim_line_adjustment_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_line_payment_id uuid,
    adjustment_group_code character varying(20),
    adjustment_reason_code character varying(20),
    adjustment_amount numeric(14,2),
    adjustment_quantity character varying(255),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_line_payment_modifier (
    payment_modifier_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_line_payment_id uuid,
    modifier_code character varying(20),
    modifier_sequence character varying(255),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_line_remark_code (
    remark_code_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_line_payment_id uuid,
    remark_code_qualifier character varying(20),
    remark_code character varying(20),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_payment (
    claim_payment_id uuid DEFAULT gen_random_uuid() NOT NULL,
    remittance_id uuid,
    patient_control_number character varying(50),
    claim_status_code character varying(20),
    claim_charge_amount numeric(14,2),
    claim_payment_amount numeric(14,2),
    patient_responsibility_amount numeric(14,2),
    claim_filing_indicator_code character varying(20),
    payer_claim_control_number character varying(50),
    facility_type_code character varying(20),
    claim_frequency_code character varying(20),
    previously_paid_amount numeric(14,2),
    interest_amount numeric(14,2),
    late_filing_charge_amount numeric(14,2),
    allowed_amount numeric(14,2),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    insurance_group_number character varying(100),
    employer_group_number character varying(100),
    drg_code character varying(20)
);

CREATE TABLE idr_core.claim_payment_adjustment (
    claim_payment_adjustment_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_payment_id uuid,
    adjustment_group_code character varying(20),
    adjustment_reason_code character varying(20),
    adjustment_amount numeric(14,2),
    adjustment_quantity character varying(255),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_payment_date (
    claim_payment_date_id uuid NOT NULL,
    claim_payment_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_payment_reference (
    claim_payment_reference_id uuid NOT NULL,
    claim_payment_id uuid,
    reference_type character varying(30),
    reference_value character varying(60),
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_reference (
    claim_reference_id uuid NOT NULL,
    claim_id uuid,
    reference_type character varying(30),
    reference_value character varying(60),
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_selection_exception (
    exception_id uuid NOT NULL,
    idr_case_unit_id uuid,
    claim_payment_id uuid,
    exception_reason_code uuid,
    missing_fields jsonb,
    days_remaining_in_window integer,
    status character varying(20),
    opened_at timestamp with time zone,
    resolved_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_selection_result (
    result_id uuid NOT NULL,
    evaluation_id uuid,
    idr_case_unit_id uuid,
    outcome_id uuid,
    selected_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_status_history (
    claim_status_history_id uuid NOT NULL,
    claim_id uuid,
    prior_status character varying(30),
    new_status character varying(30),
    changed_by_user_id uuid,
    changed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.claim_version (
    claim_version_id uuid NOT NULL,
    claim_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.cms_email_extraction_result (
    cms_email_extraction_result_id uuid NOT NULL,
    result_status character varying(20),
    result_detail jsonb,
    evaluated_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.cms_email_intake (
    cms_email_intake_id uuid NOT NULL,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.cms_submission_callback (
    callback_id uuid NOT NULL,
    idr_submission_id uuid,
    callback_status character varying(15),
    callback_payload jsonb,
    received_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_administrative_setting (
    client_id integer NOT NULL,
    field_name character varying(100) NOT NULL,
    setting_value character varying(60) NOT NULL,
    units character varying(30),
    is_disabled boolean DEFAULT false NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_alert_threshold (
    config_alert_threshold_id bigint NOT NULL,
    client_id integer NOT NULL,
    stage character varying(60) NOT NULL,
    alert_name character varying(80) NOT NULL,
    description character varying(500),
    alert_value character varying(30),
    units character varying(40),
    validation_rule character varying(500),
    category character varying(10),
    is_disabled boolean DEFAULT false NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_allowed_amount_threshold (
    config_allowed_amount_threshold_id bigint NOT NULL,
    client_id integer NOT NULL,
    payer_id character varying(12) NOT NULL,
    payer_name character varying(100),
    service_line character varying(20) NOT NULL,
    lower_threshold numeric(8,2) NOT NULL,
    upper_threshold numeric(8,2) NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_batch_size (
    client_id integer NOT NULL,
    service_line character varying(20) NOT NULL,
    min_size integer NOT NULL,
    max_size integer NOT NULL,
    cms_new_rule_max integer,
    notes character varying(250),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_batching_logic (
    client_id integer NOT NULL,
    field_name character varying(60) NOT NULL,
    current_value character varying(60) NOT NULL,
    description character varying(250),
    validation_rule character varying(250),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_bifurcated_state (
    state_id integer NOT NULL,
    state_name character varying(60) NOT NULL,
    state_code character varying(2) NOT NULL,
    bifurcated_state boolean NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_claim_selection_logic (
    config_claim_selection_logic_id bigint NOT NULL,
    client_id integer NOT NULL,
    payer_id character varying(12) NOT NULL,
    payer_name character varying(100),
    insurance_group character varying(60),
    tax_id character varying(400),
    service_line character varying(20) NOT NULL,
    facility_name character varying(400),
    physician_npi character varying(400),
    service_code character varying(2000),
    modifier character varying(100),
    is_disabled boolean DEFAULT false NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_client (
    client_id integer NOT NULL,
    tenant_id character varying(20),
    client_name character varying(100) NOT NULL,
    type_of_client character varying(100),
    type_of_service_or_claim character varying(30),
    contract_start_date date,
    open_negotiation_email_id character varying(100),
    rest_of_idr_operations_email_id character varying(100),
    clearing_house character varying(100),
    rcm_company character varying(100),
    sftp_url character varying(250),
    sftp_port integer,
    sftp_host_name character varying(100),
    sftp_user_name character varying(100),
    is_active boolean DEFAULT true NOT NULL,
    created_at_utc timestamp with time zone DEFAULT now() NOT NULL,
    updated_at_utc timestamp with time zone DEFAULT now() NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_cool_off_logic (
    client_id integer NOT NULL,
    field_name character varying(60) NOT NULL,
    current_value character varying(60) NOT NULL,
    description character varying(250),
    validation_rule character varying(250),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_criteria_version (
    config_criteria_version_id bigint NOT NULL,
    client_id integer NOT NULL,
    version_number integer NOT NULL,
    is_active_version boolean DEFAULT true NOT NULL,
    approved_by character varying(100),
    approved_at_utc timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_downcoded_service_code (
    config_downcoded_service_code_id bigint NOT NULL,
    client_id integer NOT NULL,
    service_code_from_837 character varying(40) NOT NULL,
    allowed_downcode_lower_range character varying(40) NOT NULL,
    allowed_downcode_upper_range character varying(40) NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_email_notification (
    client_id integer NOT NULL,
    alert_email_recipients_for character varying(100) NOT NULL,
    recipients character varying(1000) NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_entity_facility_mapping (
    config_entity_facility_mapping_id bigint NOT NULL,
    client_id integer NOT NULL,
    tax_id character varying(40) NOT NULL,
    group_npi character varying(40),
    entity_name character varying(200) NOT NULL,
    facility_id character varying(12),
    facility_name character varying(200) NOT NULL,
    address character varying(250),
    suite character varying(60),
    city character varying(60),
    state character varying(30),
    zip_code character varying(15),
    trauma_designation character varying(10),
    charity_care character varying(30),
    number_of_beds integer,
    annual_volume character varying(60),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_exception_reason (
    exception_code character varying(50) NOT NULL,
    exception_label character varying(200),
    retryable boolean NOT NULL,
    retry_window_business_days integer,
    is_active boolean DEFAULT true NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_exclusion_reason (
    exclusion_code character varying(30) NOT NULL,
    exclusion_label character varying(200),
    is_standard boolean DEFAULT true NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_federal_calendar (
    calendar_date date NOT NULL,
    day_of_week character varying(12) NOT NULL,
    is_weekend boolean NOT NULL,
    is_holiday boolean NOT NULL,
    holiday_name character varying(100),
    actual_holiday boolean DEFAULT false NOT NULL,
    observed_holiday boolean DEFAULT false NOT NULL,
    is_business_day boolean NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_federal_timeline (
    config_federal_timeline_id bigint NOT NULL,
    stage character varying(60) NOT NULL,
    timer_name character varying(100) NOT NULL,
    trigger_event character varying(250),
    description character varying(350),
    validation_rule character varying(350),
    value_date date,
    value_number integer,
    units character varying(20) NOT NULL,
    is_disabled boolean DEFAULT false NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    CONSTRAINT config_federal_timeline_check CHECK (((((units)::text = 'Date'::text) AND (value_date IS NOT NULL)) OR (((units)::text <> 'Date'::text) AND (value_number IS NOT NULL)))),
    CONSTRAINT config_federal_timeline_units_check CHECK (((units)::text = ANY ((ARRAY['Date'::character varying, 'Business Days'::character varying, 'Calendar Days'::character varying])::text[])))
);

CREATE TABLE idr_core.config_first_second_choice_idre (
    config_first_second_choice_idre_id bigint NOT NULL,
    client_id integer NOT NULL,
    payer_id character varying(12) NOT NULL,
    payer_name character varying(100),
    first_choice_idre character varying(500),
    second_choice_idre character varying(500),
    accept_payer_choice character varying(500),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_idre_fee_schedule (
    idre_id character varying(40) NOT NULL,
    fee_year integer NOT NULL,
    legal_business_name character varying(40) NOT NULL,
    fixed_fee_single_determination numeric(10,2),
    fixed_fee_batched_determination numeric(10,2),
    fixed_tiered_fee numeric(10,2),
    email_id character varying(100),
    is_disabled boolean DEFAULT false NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_lp_offer_amount (
    config_lp_offer_amount_id bigint NOT NULL,
    client_id integer NOT NULL,
    facility_id character varying(12) NOT NULL,
    facility_name character varying(200) NOT NULL,
    service_line character varying(20),
    reference_rate character varying(60) NOT NULL,
    flat_prior_contract_rate numeric(8,4),
    inpatient_cs_allowed_amt_threshold numeric(8,4),
    inpatient_on_offer numeric(8,4),
    inpatient_offsub_offer numeric(8,4),
    inpatient_add_on numeric(8,4),
    outpatient_cs_allowed_amt_threshold numeric(8,4),
    outpatient_on_offer numeric(8,4),
    outpatient_offsub_offer numeric(8,4),
    outpatient_add_on numeric(8,4),
    on_acceptance_threshold numeric(8,4),
    award_settlement_tolerance numeric(12,2),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_lp_prior_contract (
    config_lp_prior_contract_id bigint NOT NULL,
    client_id integer NOT NULL,
    state character varying(2) NOT NULL,
    facility_name character varying(200) NOT NULL,
    payer_name character varying(100) NOT NULL,
    prior_contract_exists boolean,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_medicare_fee_schedule (
    config_medicare_fee_schedule_id bigint NOT NULL,
    fee_schedule_year integer NOT NULL,
    service_code character varying(20) NOT NULL,
    modifier_code character varying(10),
    locality_code character varying(20),
    state_code character varying(2),
    reference_amount numeric(14,2) NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_offer_amount (
    config_offer_amount_id bigint NOT NULL,
    client_id integer NOT NULL,
    payer_id character varying(12) NOT NULL,
    payer_name character varying(100),
    service_line character varying(20) NOT NULL,
    tax_id character varying(400),
    facility character varying(400),
    physician_npi character varying(400),
    service_code character varying(2000),
    modifier character varying(100),
    reference_rate character varying(60) NOT NULL,
    cs_low_allowed_amt_threshold numeric(10,2),
    cs_up_allowed_amt_threshold numeric(10,2),
    on_acceptance_threshold numeric(10,2),
    on_offer numeric(12,2),
    idr_offer numeric(12,2),
    idr_add_on numeric(12,2),
    award_settlement_tolerance numeric(12,2),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_payer_insurance_group (
    config_payer_insurance_group_id bigint NOT NULL,
    payer_edi_id character varying(12) NOT NULL,
    payer_name character varying(100) NOT NULL,
    insurance_group_number character varying(60) NOT NULL,
    funding_type character varying(20),
    historic_idr_settlement_rate numeric(7,2),
    payer_contact_email character varying(100),
    tpa_indicator boolean DEFAULT false NOT NULL,
    tpa_contact_email character varying(100),
    payer_tpa_contact_phone character varying(20),
    is_disabled boolean DEFAULT false NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    CONSTRAINT config_payer_insurance_group_check CHECK (((NOT tpa_indicator) OR (tpa_contact_email IS NOT NULL))),
    CONSTRAINT config_payer_insurance_group_funding_type_check CHECK (((funding_type)::text = ANY ((ARRAY['FULLY_FUNDED'::character varying, 'SELF_FUNDED'::character varying])::text[])))
);

CREATE TABLE idr_core.config_physician (
    client_id integer NOT NULL,
    physician_npi character varying(10) NOT NULL,
    last_name character varying(100),
    first_name character varying(100),
    prefix character varying(20),
    entity_association character varying(200),
    residency character varying(250),
    undergraduate_degree character varying(100),
    years_of_experience character varying(10),
    board_certifications character varying(500),
    undergrad_university character varying(100),
    medical_school character varying(250),
    licensure_information character varying(250),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_rarc_code (
    rarc_code character varying(12) NOT NULL,
    payment_event character varying(100),
    description character varying(500),
    applicable_law character varying(100),
    federal_idr_process_eligible boolean NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_role (
    role_name character varying(60) NOT NULL,
    read_access boolean DEFAULT false NOT NULL,
    write_access boolean DEFAULT false NOT NULL,
    no_access boolean DEFAULT false NOT NULL,
    client_level_configurations boolean DEFAULT false NOT NULL,
    tenant_level_configurations boolean DEFAULT false NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_service_line (
    service_line_id character varying(12) NOT NULL,
    service_line_name character varying(100) NOT NULL,
    acronym character varying(20) NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_systemic_exclusion (
    config_systemic_exclusion_id bigint NOT NULL,
    client_id integer NOT NULL,
    payer_id character varying(12),
    payer_name character varying(100),
    insurance_group_number character varying(60),
    tax_id character varying(20),
    service_line character varying(20),
    facility_name character varying(200),
    physician_npi character varying(400),
    service_code_lower_limit character varying(20),
    service_code_upper_limit character varying(20),
    modifiers character varying(100),
    is_disabled boolean DEFAULT false NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_tax_id_entity_mapping (
    config_tax_id_entity_mapping_id bigint NOT NULL,
    client_id integer NOT NULL,
    tax_id character varying(40) NOT NULL,
    group_npi character varying(40),
    service_line character varying(20) NOT NULL,
    entity_legal_name character varying(200) NOT NULL,
    practice_size character varying(30),
    street_address_1 character varying(100),
    suite character varying(60),
    city character varying(60),
    state character varying(30),
    zip_code character varying(15),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_tenant (
    tenant_id character varying(20) NOT NULL,
    tenant_name character varying(100) NOT NULL,
    tax_id character varying(20),
    street_address character varying(100),
    city character varying(60),
    state character varying(30),
    zip_code character varying(15),
    email_id character varying(100),
    phone character varying(20),
    is_disabled boolean DEFAULT false NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_user (
    user_id character varying(50) NOT NULL,
    first_name character varying(100) NOT NULL,
    last_name character varying(100) NOT NULL,
    email_id character varying(100) NOT NULL,
    assigned_role character varying(60) NOT NULL,
    assigned_tenant character varying(100) NOT NULL,
    assigned_client character varying(100) NOT NULL,
    assigned_on date,
    is_disabled boolean DEFAULT false NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.config_version_audit (
    config_version_audit_id bigint NOT NULL,
    changed_at_utc timestamp with time zone DEFAULT now() NOT NULL,
    user_id character varying(100) NOT NULL,
    category character varying(100) NOT NULL,
    record_key character varying(200),
    field_name character varying(100) NOT NULL,
    prior_value text,
    new_value text,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.configuration_version_history (
    configuration_version_history_id uuid NOT NULL,
    event_type character varying(40),
    event_detail jsonb,
    recorded_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.cool_off_matching_criteria (
    cool_off_criteria_id uuid NOT NULL,
    entity_name character varying(100),
    insurance_group_number character varying(30),
    cpt_group jsonb,
    effective_start_date date,
    effective_end_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    payer_id character varying(5),
    CONSTRAINT chk_cool_off_matching_criteria_payer_id_5digit CHECK (((payer_id)::text ~ '^[0-9]{5}$'::text))
);

CREATE TABLE idr_core.cool_off_status (
    cool_off_status_id uuid NOT NULL,
    idr_case_unit_id bigint,
    is_in_cool_off character varying(20),
    is_active boolean,
    cool_off_start_date timestamp with time zone,
    cool_off_end_date timestamp with time zone,
    created_at timestamp with time zone,
    dispute_number character varying(50),
    batch_id uuid,
    determination_reference uuid,
    lookback_window_days integer,
    last_stacked_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.criteria_change_request (
    change_request_id uuid NOT NULL,
    requested_by_user_id uuid,
    changed_field character varying(100),
    proposed_value text,
    approval_status character varying(15),
    approved_by_user_id uuid,
    resulting_criteria_version_id uuid,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.criteria_version (
    criteria_version_id uuid NOT NULL,
    version_number integer,
    is_active_version boolean,
    effective_date date,
    created_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.decision (
    decision_id uuid NOT NULL,
    idr_case_id uuid,
    idre_id uuid,
    decision_type character varying(25),
    decision_status character varying(25),
    rendered_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.decision_detail (
    decision_detail_id uuid NOT NULL,
    decision_id uuid,
    prevailing_party character varying(10),
    awarded_amount numeric(12,2),
    rationale text,
    fee_liable_party character varying(10),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.decision_document (
    decision_document_id uuid NOT NULL,
    decision_id uuid,
    document_id uuid,
    linked_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.decision_email_extraction_result (
    decision_email_extraction_result_id uuid NOT NULL,
    decision_id uuid,
    result_status character varying(20),
    result_detail jsonb,
    evaluated_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.decision_status_history (
    decision_status_history_id uuid NOT NULL,
    decision_id uuid,
    prior_status character varying(30),
    new_status character varying(30),
    changed_by_user_id uuid,
    changed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.dispute (
    dispute_id uuid NOT NULL,
    idr_filing_batch_id uuid,
    dispute_status character varying(20),
    opened_at timestamp with time zone,
    closed_at timestamp with time zone,
    dispute_number character varying(30),
    batch_id uuid,
    requested_idre_name character varying(150),
    submission_date date,
    confirmation_pdf_document_id uuid,
    acknowledgement_email_captured boolean,
    extraction_failure_reason character varying(200),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.dispute_case_unit (
    dispute_case_unit_id bigint NOT NULL,
    dispute_id bigint,
    idr_case_unit_id bigint,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.dispute_note (
    dispute_note_id uuid NOT NULL,
    dispute_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.dispute_party (
    dispute_party_id uuid NOT NULL,
    dispute_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.dispute_status_history (
    dispute_status_history_id uuid NOT NULL,
    dispute_id uuid,
    prior_status character varying(30),
    new_status character varying(30),
    changed_by_user_id uuid,
    changed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.dispute_timeline_event (
    dispute_timeline_event_id uuid NOT NULL,
    dispute_id uuid,
    event_type character varying(40),
    payload jsonb,
    logged_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_access_audit (
    audit_id uuid DEFAULT gen_random_uuid() NOT NULL,
    document_id uuid,
    s3_key character varying(2000),
    user_id uuid,
    user_role character varying(50),
    access_type character varying(30),
    access_result character varying(20),
    denial_reason character varying(200),
    ip_address inet,
    user_agent character varying(500),
    session_id character varying(200),
    api_endpoint character varying(200),
    is_phi_access boolean DEFAULT true,
    idr_stage character varying(30),
    access_timestamp timestamp with time zone DEFAULT now(),
    s3_request_id character varying(100),
    cloudtrail_event_id character varying(100),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_entity_link (
    document_entity_link_id uuid NOT NULL,
    document_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_exchange_package (
    document_exchange_package_id uuid NOT NULL,
    document_id uuid,
    request_status character varying(20),
    requested_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_exchange_package_item (
    document_exchange_package_item_id uuid NOT NULL,
    document_exchange_package_id uuid,
    document_id uuid,
    request_status character varying(20),
    requested_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_exchange_request (
    document_exchange_request_id uuid NOT NULL,
    document_id uuid,
    request_status character varying(20),
    requested_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_file_ingestion_log (
    ingestion_id uuid DEFAULT gen_random_uuid() NOT NULL,
    document_id uuid,
    source_system character varying(50),
    ingestion_channel character varying(30),
    original_filename character varying(500),
    file_type character varying(20),
    source_sender_id character varying(100),
    file_size_bytes bigint DEFAULT 0,
    checksum_sha256 character(64),
    raw_s3_key character varying(2000),
    ingestion_status character varying(30) DEFAULT 'RECEIVED'::character varying,
    validation_result character varying(20),
    validation_errors jsonb,
    rejection_reason character varying(500),
    is_duplicate boolean DEFAULT false,
    duplicate_of_ingestion_id uuid,
    received_at timestamp with time zone DEFAULT now(),
    validated_at timestamp with time zone,
    processed_at timestamp with time zone,
    processing_duration_ms integer,
    glue_job_run_id character varying(200),
    batch_id uuid,
    record_count integer,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_lineage_dependency (
    dependency_id uuid DEFAULT gen_random_uuid() NOT NULL,
    upstream_entity_type character varying(30),
    upstream_entity_id uuid,
    downstream_entity_type character varying(30),
    downstream_entity_id uuid,
    dependency_type character varying(50),
    idr_stage character varying(30),
    dependency_strength character varying(20) DEFAULT 'REQUIRED'::character varying,
    description character varying(500),
    established_at timestamp with time zone DEFAULT now(),
    resolved_at timestamp with time zone,
    is_active boolean DEFAULT true,
    created_by character varying(100) DEFAULT 'current_user'::character varying,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_lineage_event (
    event_id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_type character varying(80),
    event_category character varying(30),
    document_id uuid,
    batch_id uuid,
    claim_id uuid,
    from_state character varying(100),
    to_state character varying(100),
    actor_type character varying(20),
    actor_id character varying(200),
    source_system character varying(50),
    target_s3_key character varying(2000),
    source_s3_key character varying(2000),
    idr_stage character varying(30),
    event_payload jsonb,
    correlation_id uuid,
    parent_event_id uuid,
    is_error_event boolean DEFAULT false,
    error_code character varying(50),
    event_timestamp timestamp with time zone DEFAULT now(),
    duration_ms integer,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_location (
    registry_id uuid DEFAULT gen_random_uuid() NOT NULL,
    document_id uuid,
    s3_bucket character varying(100),
    s3_key character varying(2000),
    s3_version_id character varying(200),
    s3_etag character varying(200),
    storage_class character varying(30) DEFAULT 'STANDARD'::character varying,
    file_size_bytes bigint DEFAULT 0,
    checksum_sha256 character(64),
    encryption_type character varying(30) DEFAULT 'SSE-KMS'::character varying,
    kms_key_id character varying(200),
    object_lock_mode character varying(20),
    object_lock_retain_until date,
    lifecycle_rule_id character varying(100),
    last_transition_at timestamp with time zone,
    zone character varying(20),
    idr_stage character varying(30),
    ingested_at timestamp with time zone DEFAULT now(),
    last_accessed_at timestamp with time zone,
    access_count integer DEFAULT 0,
    is_deleted boolean DEFAULT false,
    deleted_at timestamp with time zone,
    tags jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_master (
    document_id uuid DEFAULT gen_random_uuid() NOT NULL,
    document_code character varying(30),
    document_type character varying(50),
    document_category character varying(30),
    idr_stage character varying(30),
    batch_id uuid,
    claim_id uuid,
    s3_bucket character varying(100),
    s3_key character varying(2000),
    s3_version_id character varying(200),
    file_name character varying(500),
    file_extension character varying(10),
    file_size_bytes bigint DEFAULT 0,
    checksum_sha256 character(64),
    mime_type character varying(100),
    document_status character varying(30) DEFAULT 'PENDING'::character varying,
    document_version smallint DEFAULT 1,
    is_latest_version boolean DEFAULT true,
    source_system character varying(50),
    uploaded_by_user_id uuid,
    upload_method character varying(30),
    uploaded_at timestamp with time zone DEFAULT now(),
    processed_at timestamp with time zone,
    expires_at timestamp with time zone,
    retention_until date,
    is_phi_document boolean DEFAULT true,
    encryption_key_id character varying(200),
    tags jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(100) DEFAULT 'current_user'::character varying,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_readiness_check (
    readiness_check_id uuid NOT NULL,
    idr_filing_batch_id uuid,
    document_type character varying(40),
    document_id uuid,
    validation_result character varying(10),
    failure_reason character varying(200),
    validated_at timestamp with time zone,
    resolved_by_user_id uuid,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_version (
    version_id uuid DEFAULT gen_random_uuid() NOT NULL,
    document_id uuid,
    version_number smallint,
    s3_key character varying(2000),
    s3_version_id character varying(200),
    file_size_bytes bigint DEFAULT 0,
    checksum_sha256 character(64),
    version_status character varying(20) DEFAULT 'ACTIVE'::character varying,
    change_reason character varying(500),
    change_summary text,
    changed_by_user_id uuid,
    previous_version_id uuid,
    is_current boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    superseded_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_workflow_stage_history (
    history_id uuid DEFAULT gen_random_uuid() NOT NULL,
    entity_type character varying(30),
    entity_id uuid,
    from_stage character varying(50),
    to_stage character varying(50),
    from_status character varying(50),
    to_status character varying(50),
    transition_type character varying(30),
    triggered_by_user_id uuid,
    triggered_by_system character varying(50),
    business_rule_applied character varying(200),
    transition_timestamp timestamp with time zone DEFAULT now(),
    sla_deadline timestamp with time zone,
    sla_status character varying(20),
    notes text,
    document_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.document_workflow_transition_log (
    transition_id uuid DEFAULT gen_random_uuid() NOT NULL,
    batch_id uuid,
    claim_id uuid,
    transition_name character varying(100),
    from_stage character varying(50),
    to_stage character varying(50),
    from_status character varying(50),
    to_status character varying(50),
    business_rule character varying(200),
    pre_conditions_met jsonb,
    actor_type character varying(20),
    actor_id character varying(200),
    cms_reference character varying(200),
    documents_produced jsonb,
    documents_consumed jsonb,
    cooloff_lockout_created boolean DEFAULT false,
    sla_met boolean,
    sla_deadline timestamp with time zone,
    transitioned_at timestamp with time zone DEFAULT now(),
    notes text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_835_domain_load_status (
    edi_835_domain_load_status_id bigint NOT NULL,
    edi_835_file_tracking_id bigint NOT NULL,
    edi_835_parsed_id bigint NOT NULL,
    transaction_type character varying(10) DEFAULT '835'::character varying,
    domain_entity_name character varying(100) NOT NULL,
    records_attempted integer,
    records_loaded integer,
    records_failed integer,
    load_status character varying(50),
    load_started_on_utc timestamp with time zone,
    load_completed_on_utc timestamp with time zone,
    error_message text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by_user character varying NOT NULL,
    modified_by_user character varying NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    CONSTRAINT edi_835_domain_status_ck CHECK (((load_status IS NULL) OR ((load_status)::text = ANY ((ARRAY['PENDING'::character varying, 'IN_PROGRESS'::character varying, 'COMPLETED'::character varying, 'FAILED'::character varying])::text[]))))
);

CREATE TABLE idr_core.edi_835_file_tracking_ingestion_status (
    edi_835_file_tracking_id bigint NOT NULL,
    source_system character varying(100),
    trading_partner character varying(200),
    transaction_type character varying(10) DEFAULT '835'::character varying,
    received_on_utc timestamp with time zone,
    picked_on_utc timestamp with time zone,
    processing_started_on_utc timestamp with time zone,
    processing_completed_on_utc timestamp with time zone,
    parser_version character varying(50),
    status character varying(50),
    retry_count integer DEFAULT 0,
    last_error_code character varying(100),
    last_error_message text,
    correlation_id uuid,
    batch_id uuid,
    is_duplicate boolean DEFAULT false,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    document_id uuid,
    error_document_id uuid
);

CREATE TABLE idr_core.edi_835_header (
    header_id bigint NOT NULL,
    edi_parsed_json_staging_id bigint,
    edi_file_ingestion_id bigint,
    isa13_interchange_control_number character varying(9),
    gs06_group_control_number character varying(9),
    st01_transaction_set_id character varying(3) DEFAULT '835'::character varying,
    st02_transaction_set_control_number character varying(9),
    bpr02_total_payment_amount numeric(15,2),
    bpr04_payment_method character varying(3),
    bpr10_orig_company_identifier character varying(10),
    bpr11_orig_company_supplemental_code character varying(9),
    bpr16_eft_effective_date date,
    trn02_eft_trace_number character varying(50),
    trn03_originating_company_id character varying(10),
    ref02_receiver_id character varying(50),
    dtm02_production_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_835_ingestion_error (
    edi_835_ingestion_error_id bigint NOT NULL,
    edi_835_file_tracking_id bigint,
    edi_835_parsed_id bigint,
    transaction_type character varying(10) DEFAULT '835'::character varying,
    error_level character varying(30),
    loop_name character varying(100),
    segment_name character varying(50),
    element_name character varying(50),
    line_number integer,
    error_code character varying(100),
    error_message text,
    severity character varying(20),
    is_retryable boolean DEFAULT false,
    raw_segment text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    resolved_on_utc timestamp with time zone,
    resolved_by character varying(100),
    resolution_notes text,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_835_ingestion_retry (
    edi_835_ingestion_retry_id bigint NOT NULL,
    edi_835_file_tracking_id bigint,
    edi_835_parsed_id bigint,
    transaction_type character varying(10) DEFAULT '835'::character varying,
    retry_type character varying(50),
    retry_attempt_number integer,
    retry_status character varying(50),
    retry_requested_by character varying(100),
    retry_requested_on_utc timestamp with time zone,
    retry_started_on_utc timestamp with time zone,
    retry_completed_on_utc timestamp with time zone,
    failure_reason text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_835_ingestion_status (
    edi_835_ingestion_status_id bigint NOT NULL,
    edi_835_file_tracking_id bigint,
    edi_835_parsed_id bigint,
    transaction_type character varying(10) DEFAULT '835'::character varying,
    domain_entity_name character varying(100),
    records_attempted integer,
    records_loaded integer,
    records_failed integer,
    load_status character varying(50),
    load_started_on_utc timestamp with time zone,
    load_completed_on_utc timestamp with time zone,
    error_message text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_835_staging (
    edi_835_parsed_id bigint NOT NULL,
    edi_835_file_tracking_id bigint,
    transaction_type character varying(10) DEFAULT '835'::character varying,
    interchange_control_number character varying(50),
    functional_group_control_number character varying(50),
    transaction_set_control_number character varying(50),
    transaction_count integer,
    claim_payment_count integer,
    service_line_payment_count integer,
    parsed_payload_json jsonb,
    status character varying(50),
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_835_segmented_claim (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    client_id uuid NOT NULL,
    file_name character varying(255) NOT NULL,
    segmented_file_name character varying(255) NOT NULL,
    segmented_file_path character varying(1000) NOT NULL,
    transaction_type character varying(10) DEFAULT '835'::character varying NOT NULL,
    claim_submitter_identifier character varying(50) NOT NULL,
    normalized_claim_submitter_identifier character varying(50) NOT NULL,
    payer_claim_control_number character varying(50),
    claim_status_code character varying(10),
    total_claim_charge_amount numeric(18,2),
    claim_payment_amount numeric(18,2),
    patient_responsibility_amount numeric(18,2),
    claim_frequency_code character varying(2),
    domain_claim_payment_id uuid,
    domain_remittance_id uuid,
    payer_identifier character varying(100),
    remit_payment_date date,
    matching_window_expires_on date,
    service_line_details jsonb DEFAULT '[]'::jsonb NOT NULL,
    record_sequence_number integer NOT NULL,
    build_date date DEFAULT CURRENT_DATE NOT NULL,
    segregation_run_id uuid NOT NULL,
    segregation_status character varying(20) DEFAULT 'SEGREGATED'::character varying NOT NULL,
    error_code character varying(20),
    error_message character varying(500),
    matched_status character varying(20) DEFAULT 'NOT_MATCHED'::character varying NOT NULL,
    matching_flag smallint DEFAULT 0 NOT NULL,
    matched_837_claim_id uuid,
    matched_at timestamp with time zone,
    match_method character varying(30),
    match_rule_version character varying(30),
    match_failure_reason character varying(500),
    matched_service_line_details jsonb DEFAULT '[]'::jsonb NOT NULL,
    package_status character varying(20) DEFAULT 'NOT_PACKAGED'::character varying NOT NULL,
    package_run_id uuid,
    package_folder_name character varying(255),
    zip_file_name character varying(255),
    packaged_at timestamp with time zone,
    file_hash character varying(64) NOT NULL,
    segregated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by uuid,
    updated_by uuid,
    CONSTRAINT ck_edi_835_matching_flag CHECK ((matching_flag = ANY (ARRAY[0, 1]))),
    CONSTRAINT ck_edi_835_segmented_error_details CHECK ((((segregation_status)::text = 'ERROR'::text) OR ((matched_status)::text = 'ERROR'::text) OR ((package_status)::text = 'ERROR'::text) OR ((error_code IS NULL) AND (error_message IS NULL)))),
    CONSTRAINT ck_edi_835_segmented_frequency CHECK (((claim_frequency_code IS NULL) OR (length(TRIM(BOTH FROM claim_frequency_code)) > 0))),
    CONSTRAINT ck_edi_835_segmented_hash_format CHECK (((file_hash)::text ~ '^[A-Fa-f0-9]{64}$'::text)),
    CONSTRAINT ck_edi_835_segmented_matched_reference CHECK ((((matched_status)::text <> 'MATCHED'::text) OR ((matched_837_claim_id IS NOT NULL) AND (matched_at IS NOT NULL)))),
    CONSTRAINT ck_edi_835_segmented_matched_status CHECK (((matched_status)::text = ANY ((ARRAY['NOT_MATCHED'::character varying, 'IN_PROCESS'::character varying, 'MATCHED'::character varying, 'AMBIGUOUS'::character varying, 'ERROR'::character varying])::text[]))),
    CONSTRAINT ck_edi_835_segmented_package_details CHECK ((((package_status)::text <> 'PACKAGED'::text) OR ((package_run_id IS NOT NULL) AND (package_folder_name IS NOT NULL) AND (zip_file_name IS NOT NULL) AND (packaged_at IS NOT NULL)))),
    CONSTRAINT ck_edi_835_segmented_package_eligibility CHECK ((((package_status)::text <> ALL ((ARRAY['READY'::character varying, 'PACKAGED'::character varying])::text[])) OR ((matched_status)::text = 'MATCHED'::text))),
    CONSTRAINT ck_edi_835_segmented_package_status CHECK (((package_status)::text = ANY ((ARRAY['NOT_PACKAGED'::character varying, 'READY'::character varying, 'PACKAGED'::character varying, 'ERROR'::character varying])::text[]))),
    CONSTRAINT ck_edi_835_segmented_record_sequence CHECK ((record_sequence_number > 0)),
    CONSTRAINT ck_edi_835_segmented_segregation_status CHECK (((segregation_status)::text = ANY ((ARRAY['SEGREGATED'::character varying, 'DUPLICATE'::character varying, 'ERROR'::character varying, 'SKIPPED'::character varying])::text[]))),
    CONSTRAINT ck_edi_835_segmented_transaction_type CHECK (((transaction_type)::text = '835'::text)),
    CONSTRAINT ck_edi_835_segmented_unmatched_reference CHECK ((((matched_status)::text <> ALL ((ARRAY['NOT_MATCHED'::character varying, 'AMBIGUOUS'::character varying])::text[])) OR (matched_837_claim_id IS NULL)))
);

CREATE TABLE idr_core.edi_837_segmented_claim (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    client_id uuid NOT NULL,
    file_name character varying(255) NOT NULL,
    segmented_file_name character varying(255) NOT NULL,
    segmented_file_path character varying(1000) NOT NULL,
    transaction_type character varying(10) NOT NULL,
    patient_control_number character varying(50) NOT NULL,
    normalized_patient_control_number character varying(50) NOT NULL,
    claim_number character varying(50),
    claim_frequency_code character varying(2),
    is_corrected boolean DEFAULT false NOT NULL,
    is_void boolean DEFAULT false NOT NULL,
    latest_valid_version_flag boolean DEFAULT true NOT NULL,
    gs08_implementation_guide character varying(50),
    is_837i_implementation boolean,
    facility_type_code character varying(2),
    facility_code_qualifier character varying(2),
    type_of_bill character varying(3),
    type_of_bill_valid boolean,
    type_of_bill_validation_message character varying(255),
    domain_claim_id uuid,
    provider_tin character varying(20),
    payer_identifier character varying(100),
    drg_codes text[] DEFAULT ARRAY[]::text[] NOT NULL,
    service_line_details jsonb DEFAULT '[]'::jsonb NOT NULL,
    record_sequence_number integer NOT NULL,
    build_date date DEFAULT CURRENT_DATE NOT NULL,
    segregation_run_id uuid NOT NULL,
    segregation_status character varying(20) DEFAULT 'SEGREGATED'::character varying NOT NULL,
    matched_status character varying(20) DEFAULT 'NOT_MATCHED'::character varying NOT NULL,
    error_code character varying(20),
    error_message character varying(500),
    file_hash character varying(64) NOT NULL,
    segregated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by uuid,
    updated_by uuid,
    CONSTRAINT ck_edi_837_segmented_error_details CHECK ((((segregation_status)::text = 'ERROR'::text) OR ((matched_status)::text = 'ERROR'::text) OR ((error_code IS NULL) AND (error_message IS NULL)))),
    CONSTRAINT ck_edi_837_segmented_frequency CHECK (((claim_frequency_code IS NULL) OR (length(TRIM(BOTH FROM claim_frequency_code)) > 0))),
    CONSTRAINT ck_edi_837_segmented_hash_format CHECK (((file_hash)::text ~ '^[A-Fa-f0-9]{64}$'::text)),
    CONSTRAINT ck_edi_837_segmented_matched_status CHECK (((matched_status)::text = ANY ((ARRAY['NOT_MATCHED'::character varying, 'IN_PROCESS'::character varying, 'MATCHED'::character varying, 'AMBIGUOUS'::character varying, 'ERROR'::character varying])::text[]))),
    CONSTRAINT ck_edi_837_segmented_record_sequence CHECK ((record_sequence_number > 0)),
    CONSTRAINT ck_edi_837_segmented_segregation_status CHECK (((segregation_status)::text = ANY ((ARRAY['SEGREGATED'::character varying, 'DUPLICATE'::character varying, 'ERROR'::character varying, 'SKIPPED'::character varying])::text[]))),
    CONSTRAINT ck_edi_837_segmented_transaction_type CHECK (((transaction_type)::text = ANY ((ARRAY['837I'::character varying, '837P'::character varying])::text[])))
);

CREATE TABLE idr_core.edi_837i_domain_load_status (
    edi_837i_domain_load_status_id bigint NOT NULL,
    edi_837i_file_tracking_id bigint NOT NULL,
    edi_837i_parsed_id bigint NOT NULL,
    transaction_type character varying(10) DEFAULT '837I'::character varying,
    domain_entity_name character varying(100) NOT NULL,
    records_attempted integer,
    records_loaded integer,
    records_failed integer,
    load_status character varying(50),
    load_started_on_utc timestamp with time zone,
    load_completed_on_utc timestamp with time zone,
    error_message text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by_user character varying NOT NULL,
    modified_by_user character varying NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    CONSTRAINT edi_837i_domain_status_ck CHECK (((load_status IS NULL) OR ((load_status)::text = ANY ((ARRAY['PENDING'::character varying, 'IN_PROGRESS'::character varying, 'COMPLETED'::character varying, 'FAILED'::character varying])::text[]))))
);

CREATE TABLE idr_core.edi_837i_file_tracking_ingestion_status (
    edi_837i_file_tracking_id bigint NOT NULL,
    source_system character varying(100),
    trading_partner character varying(200),
    transaction_type character varying(10) DEFAULT '837I'::character varying,
    received_on_utc timestamp with time zone,
    picked_on_utc timestamp with time zone,
    processing_started_on_utc timestamp with time zone,
    processing_completed_on_utc timestamp with time zone,
    parser_version character varying(50),
    status character varying(50),
    retry_count integer DEFAULT 0,
    last_error_code character varying(100),
    last_error_message text,
    correlation_id uuid,
    batch_id uuid,
    is_duplicate boolean DEFAULT false,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    document_id uuid,
    error_document_id uuid
);

CREATE TABLE idr_core.edi_837i_header (
    header_id bigint NOT NULL,
    edi_parsed_json_staging_id bigint,
    edi_file_ingestion_id bigint,
    isa06_interchange_sender_id character varying(15),
    isa08_interchange_receiver_id character varying(15),
    isa09_interchange_date date,
    isa10_interchange_time time without time zone,
    isa13_interchange_control_number character varying(9),
    gs02_application_sender_code character varying(15),
    gs03_application_receiver_code character varying(15),
    gs06_group_control_number character varying(9),
    st01_transaction_set_id character varying(3) DEFAULT '837'::character varying,
    st02_transaction_control_number character varying(9),
    bht03_batch_number character varying(30),
    bht04_batch_date date,
    bht05_batch_time time without time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_837i_ingestion_error (
    edi_837i_ingestion_error_id bigint NOT NULL,
    edi_837i_file_tracking_id bigint,
    edi_837i_parsed_id bigint,
    transaction_type character varying(10) DEFAULT '837I'::character varying,
    error_level character varying(30),
    loop_name character varying(100),
    segment_name character varying(50),
    element_name character varying(50),
    line_number integer,
    error_code character varying(100),
    error_message text,
    severity character varying(20),
    is_retryable boolean DEFAULT false,
    raw_segment text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    resolved_on_utc timestamp with time zone,
    resolved_by character varying(100),
    resolution_notes text,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_837i_ingestion_retry (
    edi_837i_ingestion_retry_id bigint NOT NULL,
    edi_837i_file_tracking_id bigint,
    edi_837i_parsed_id bigint,
    transaction_type character varying(10) DEFAULT '837I'::character varying,
    retry_type character varying(50),
    retry_attempt_number integer,
    retry_status character varying(50),
    retry_requested_by character varying(100),
    retry_requested_on_utc timestamp with time zone,
    retry_started_on_utc timestamp with time zone,
    retry_completed_on_utc timestamp with time zone,
    failure_reason text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_837i_ingestion_status (
    edi_837i_ingestion_status_id bigint NOT NULL,
    edi_837i_file_tracking_id bigint,
    edi_837i_parsed_id bigint,
    transaction_type character varying(10) DEFAULT '837I'::character varying,
    domain_entity_name character varying(100),
    records_attempted integer,
    records_loaded integer,
    records_failed integer,
    load_status character varying(50),
    load_started_on_utc timestamp with time zone,
    load_completed_on_utc timestamp with time zone,
    error_message text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_837i_staging (
    edi_837i_parsed_id bigint NOT NULL,
    edi_837i_file_tracking_id bigint,
    transaction_type character varying(10) DEFAULT '837I'::character varying,
    interchange_control_number character varying(50),
    functional_group_control_number character varying(50),
    transaction_set_control_number character varying(50),
    transaction_count integer,
    claim_count integer,
    service_line_count integer,
    parsed_payload_json jsonb,
    status character varying(50),
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_837p_domain_load_status (
    edi_837p_domain_load_status_id bigint NOT NULL,
    edi_837p_file_tracking_id bigint NOT NULL,
    edi_837p_parsed_id bigint NOT NULL,
    transaction_type character varying(10) DEFAULT '837P'::character varying,
    domain_entity_name character varying(100) NOT NULL,
    records_attempted integer,
    records_loaded integer,
    records_failed integer,
    load_status character varying(50),
    load_started_on_utc timestamp with time zone,
    load_completed_on_utc timestamp with time zone,
    error_message text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by_user character varying NOT NULL,
    modified_by_user character varying NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    CONSTRAINT edi_837p_domain_status_ck CHECK (((load_status IS NULL) OR ((load_status)::text = ANY ((ARRAY['PENDING'::character varying, 'IN_PROGRESS'::character varying, 'COMPLETED'::character varying, 'FAILED'::character varying])::text[]))))
);

CREATE TABLE idr_core.edi_837p_file_tracking_ingestion_status (
    edi_837p_file_tracking_id bigint NOT NULL,
    source_system character varying(100),
    trading_partner character varying(200),
    transaction_type character varying(10) DEFAULT '837P'::character varying,
    received_on_utc timestamp with time zone,
    picked_on_utc timestamp with time zone,
    processing_started_on_utc timestamp with time zone,
    processing_completed_on_utc timestamp with time zone,
    parser_version character varying(50),
    status character varying(50),
    retry_count integer DEFAULT 0,
    last_error_code character varying(100),
    last_error_message text,
    correlation_id uuid,
    batch_id uuid,
    is_duplicate boolean DEFAULT false,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    document_id uuid,
    error_document_id uuid
);

CREATE TABLE idr_core.edi_837p_header (
    header_id bigint NOT NULL,
    edi_parsed_json_staging_id bigint,
    edi_file_ingestion_id bigint,
    isa06_interchange_sender_id character varying(15),
    isa08_interchange_receiver_id character varying(15),
    isa09_interchange_date date,
    isa10_interchange_time time without time zone,
    isa13_interchange_control_number character varying(9),
    gs02_application_sender_code character varying(15),
    gs03_application_receiver_code character varying(15),
    gs06_group_control_number character varying(9),
    st01_transaction_set_id character varying(3) DEFAULT '837'::character varying,
    st02_transaction_control_number character varying(9),
    bht03_batch_number character varying(30),
    bht04_batch_date date,
    bht05_batch_time time without time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_837p_ingestion_error (
    edi_837p_ingestion_error_id bigint NOT NULL,
    edi_837p_file_tracking_id bigint,
    edi_837p_parsed_id bigint,
    transaction_type character varying(10) DEFAULT '837P'::character varying,
    error_level character varying(30),
    loop_name character varying(100),
    segment_name character varying(50),
    element_name character varying(50),
    line_number integer,
    error_code character varying(100),
    error_message text,
    severity character varying(20),
    is_retryable boolean DEFAULT false,
    raw_segment text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    resolved_on_utc timestamp with time zone,
    resolved_by character varying(100),
    resolution_notes text,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_837p_ingestion_retry (
    edi_837p_ingestion_retry_id bigint NOT NULL,
    edi_837p_file_tracking_id bigint,
    edi_837p_parsed_id bigint,
    transaction_type character varying(10) DEFAULT '837P'::character varying,
    retry_type character varying(50),
    retry_attempt_number integer,
    retry_status character varying(50),
    retry_requested_by character varying(100),
    retry_requested_on_utc timestamp with time zone,
    retry_started_on_utc timestamp with time zone,
    retry_completed_on_utc timestamp with time zone,
    failure_reason text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_837p_ingestion_status (
    edi_837p_ingestion_status_id bigint NOT NULL,
    edi_837p_file_tracking_id bigint,
    edi_837p_parsed_id bigint,
    transaction_type character varying(10) DEFAULT '837P'::character varying,
    domain_entity_name character varying(100),
    records_attempted integer,
    records_loaded integer,
    records_failed integer,
    load_status character varying(50),
    load_started_on_utc timestamp with time zone,
    load_completed_on_utc timestamp with time zone,
    error_message text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_837p_staging (
    edi_837p_parsed_id bigint NOT NULL,
    edi_837p_file_tracking_id bigint,
    transaction_type character varying(10) DEFAULT '837P'::character varying,
    interchange_control_number character varying(50),
    functional_group_control_number character varying(50),
    transaction_set_control_number character varying(50),
    transaction_count integer,
    claim_count integer,
    service_line_count integer,
    parsed_payload_json jsonb,
    status character varying(50),
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_eob_file_tracking (
    edi_eob_file_tracking_id bigint NOT NULL,
    source_system character varying(100),
    trading_partner character varying(200),
    transaction_type character varying(10) DEFAULT 'EOB'::character varying,
    received_on_utc timestamp with time zone,
    picked_on_utc timestamp with time zone,
    processing_started_on_utc timestamp with time zone,
    processing_completed_on_utc timestamp with time zone,
    parser_version character varying(50),
    status character varying(50),
    retry_count integer DEFAULT 0,
    last_error_code character varying(100),
    last_error_message text,
    correlation_id uuid,
    batch_id uuid,
    is_duplicate boolean DEFAULT false,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    document_id uuid,
    error_document_id uuid
);

CREATE TABLE idr_core.edi_eob_ingestion_error (
    edi_eob_ingestion_error_id bigint NOT NULL,
    edi_eob_file_tracking_id bigint,
    edi_eob_parsed_id bigint,
    transaction_type character varying(10) DEFAULT 'EOB'::character varying,
    error_level character varying(30),
    loop_name character varying(100),
    segment_name character varying(50),
    element_name character varying(50),
    line_number integer,
    error_code character varying(100),
    error_message text,
    severity character varying(20),
    is_retryable boolean DEFAULT false,
    raw_segment text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    resolved_on_utc timestamp with time zone,
    resolved_by character varying(100),
    resolution_notes text,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_eob_ingestion_retry (
    edi_eob_ingestion_retry_id bigint NOT NULL,
    edi_eob_file_tracking_id bigint,
    edi_eob_parsed_id bigint,
    transaction_type character varying(10) DEFAULT 'EOB'::character varying,
    retry_type character varying(50),
    retry_attempt_number integer,
    retry_status character varying(50),
    retry_requested_by character varying(100),
    retry_requested_on_utc timestamp with time zone,
    retry_started_on_utc timestamp with time zone,
    retry_completed_on_utc timestamp with time zone,
    failure_reason text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_eob_ingestion_status (
    edi_eob_ingestion_status_id bigint NOT NULL,
    edi_eob_file_tracking_id bigint,
    edi_eob_parsed_id bigint,
    transaction_type character varying(10) DEFAULT 'EOB'::character varying,
    domain_entity_name character varying(100),
    records_attempted integer,
    records_loaded integer,
    records_failed integer,
    load_status character varying(50),
    load_started_on_utc timestamp with time zone,
    load_completed_on_utc timestamp with time zone,
    error_message text,
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.edi_eob_parsed (
    edi_eob_parsed_id bigint NOT NULL,
    edi_eob_file_tracking_id bigint,
    transaction_type character varying(10) DEFAULT 'EOB'::character varying,
    transaction_count integer,
    eob_record_count integer,
    service_line_count integer,
    check_number character varying(50),
    check_date date,
    check_amount numeric(12,2),
    payment_method character varying(10),
    payee_name character varying(200),
    payee_tax_id character varying(20),
    parsed_payload_json jsonb,
    status character varying(50),
    created_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_on_utc timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.eligibility_exception (
    eligibility_exception_id uuid NOT NULL,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.eligibility_response (
    eligibility_response_id uuid NOT NULL,
    response_status character varying(20),
    response_payload jsonb,
    received_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.eligibility_review (
    eligibility_review_id uuid NOT NULL,
    idr_case_id uuid,
    reviewing_party character varying(10),
    eligibility_result character varying(15),
    ineligibility_reason character varying(200),
    reviewed_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.eligibility_status_history (
    eligibility_status_history_id uuid NOT NULL,
    prior_status character varying(30),
    new_status character varying(30),
    changed_by_user_id uuid,
    changed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.email_ai_extraction (
    extraction_id uuid DEFAULT gen_random_uuid() NOT NULL,
    email_id uuid NOT NULL,
    summary_text text,
    decision_options jsonb,
    model_used character varying(100),
    prompt_version character varying(20),
    raw_response jsonb,
    generated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid
);

CREATE TABLE idr_core.email_attachment (
    attachment_id uuid DEFAULT gen_random_uuid() NOT NULL,
    email_id uuid NOT NULL,
    file_name character varying(500),
    file_type character varying(255),
    file_size_bytes bigint,
    s3_bucket character varying(255),
    s3_key character varying(1000),
    is_multipage boolean DEFAULT false NOT NULL,
    processing_path character varying(20) DEFAULT 'SYNC'::character varying NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    CONSTRAINT email_attachment_processing_path_check CHECK (((processing_path)::text = ANY ((ARRAY['SYNC'::character varying, 'ASYNC'::character varying])::text[])))
);

CREATE TABLE idr_core.email_attachment_extraction (
    extraction_id uuid DEFAULT gen_random_uuid() NOT NULL,
    attachment_id uuid NOT NULL,
    textract_job_id character varying(255),
    status character varying(20) DEFAULT 'PENDING'::character varying NOT NULL,
    output_s3_bucket character varying(255),
    output_s3_key character varying(1000),
    page_count integer,
    extracted_json jsonb,
    extracted_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    CONSTRAINT email_attachment_extraction_status_check CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'IN_PROGRESS'::character varying, 'COMPLETED'::character varying, 'FAILED'::character varying])::text[])))
);

CREATE TABLE idr_core.email_audit_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor_identity character varying(256),
    action character varying(64) NOT NULL,
    entity_type character varying(32),
    entity_id character varying(128),
    case_id uuid,
    metadata jsonb,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid
);

CREATE TABLE idr_core.email_case_mailbox_alias (
    alias_id uuid DEFAULT gen_random_uuid() NOT NULL,
    idr_case_id uuid NOT NULL,
    alias_address character varying(255) NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid
);

CREATE TABLE idr_core.email_classification_result (
    classification_id uuid DEFAULT gen_random_uuid() NOT NULL,
    email_id uuid NOT NULL,
    correspondence_type_id integer,
    predicted_idr_stage character varying(50),
    confidence_score numeric(5,4),
    is_classified boolean DEFAULT true NOT NULL,
    requires_manual_review boolean DEFAULT false NOT NULL,
    is_manually_corrected boolean DEFAULT false NOT NULL,
    corrected_by character varying(100),
    corrected_at timestamp with time zone,
    classified_at timestamp with time zone DEFAULT now() NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    secondary_classifications jsonb,
    manual_review_reason text,
    raw_offer jsonb,
    suggested_outcome_id integer,
    legacy_classification character varying(100),
    legacy_fields jsonb
);

CREATE TABLE idr_core.email_composed (
    composed_email_id uuid DEFAULT gen_random_uuid() NOT NULL,
    email_id uuid,
    idr_case_id uuid,
    dispute_id uuid,
    thread_id uuid,
    template_id uuid,
    decision_option_selected character varying(50),
    subject character varying(500),
    body text,
    populated_variables jsonb,
    status character varying(20) DEFAULT 'DRAFT'::character varying NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    template_version integer,
    CONSTRAINT composed_email_status_check CHECK (((status)::text = ANY ((ARRAY['DRAFT'::character varying, 'PENDING_APPROVAL'::character varying, 'APPROVED'::character varying, 'REJECTED'::character varying, 'SENT'::character varying])::text[])))
);

CREATE TABLE idr_core.email_draft (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    case_id uuid,
    thread_id uuid,
    mode character varying(16),
    owner_identity character varying(256),
    to_addrs text,
    cc_addrs text,
    subject character varying(998),
    body_html text,
    template_id uuid,
    forward_attachment_ids jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.email_failure_alert (
    alert_id uuid DEFAULT gen_random_uuid() NOT NULL,
    stage_id integer NOT NULL,
    alert_category character varying(100) NOT NULL,
    affected_email_count integer NOT NULL,
    affected_email_ids jsonb NOT NULL,
    sent_at timestamp with time zone DEFAULT now() NOT NULL,
    acknowledged_by character varying(100),
    acknowledged_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid
);

CREATE TABLE idr_core.email_fallback_run (
    run_id uuid DEFAULT gen_random_uuid() NOT NULL,
    run_started_at timestamp with time zone DEFAULT now() NOT NULL,
    run_completed_at timestamp with time zone,
    records_picked_up integer DEFAULT 0 NOT NULL,
    records_succeeded integer DEFAULT 0 NOT NULL,
    records_failed integer DEFAULT 0 NOT NULL,
    triggered_by character varying(20) DEFAULT 'SCHEDULED'::character varying NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    CONSTRAINT email_fallback_run_triggered_by_check CHECK (((triggered_by)::text = ANY ((ARRAY['SCHEDULED'::character varying, 'MANUAL'::character varying])::text[])))
);

CREATE TABLE idr_core.email_hitl_review (
    hitl_review_id uuid DEFAULT gen_random_uuid() NOT NULL,
    composed_email_id uuid NOT NULL,
    round_number integer DEFAULT 1 NOT NULL,
    decision_options_presented jsonb,
    reviewer_user_id character varying(100),
    decision character varying(20),
    rejection_reason_id integer,
    routed_to character varying(20),
    reviewed_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    CONSTRAINT email_hitl_review_decision_check CHECK (((decision)::text = ANY ((ARRAY['APPROVED'::character varying, 'REJECTED'::character varying])::text[]))),
    CONSTRAINT email_hitl_review_routed_to_check CHECK (((routed_to)::text = ANY ((ARRAY['CLASSIFIER'::character varying, 'COMPOSER'::character varying])::text[])))
);

CREATE TABLE idr_core.email_identities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email character varying(256) NOT NULL,
    label character varying(128),
    role character varying(32) NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    CONSTRAINT email_identities_role_check CHECK (((role)::text = ANY ((ARRAY['provider'::character varying, 'payer'::character varying, 'internal'::character varying])::text[])))
);

CREATE TABLE idr_core.email_inbound_message (
    email_id uuid DEFAULT gen_random_uuid() NOT NULL,
    idr_case_id uuid,
    dispute_id uuid,
    correlation_id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(255),
    reference_number character varying(100),
    sender_email character varying(255),
    recipient_email text,
    subject character varying(998),
    received_at timestamp with time zone,
    s3_bucket character varying(255),
    s3_key_raw character varying(1000),
    s3_key_eml character varying(1000),
    s3_key_processed character varying(1000),
    is_duplicate boolean DEFAULT false NOT NULL,
    duplicate_of_email_id uuid,
    source_id integer,
    thread_id uuid,
    current_stage_id integer,
    current_status character varying(30) DEFAULT 'RECEIVED'::character varying NOT NULL,
    retry_count integer DEFAULT 0 NOT NULL,
    last_error_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    in_reply_to character varying(998),
    references_header text,
    cc_addresses text,
    body_text text,
    body_html text,
    external_ref character varying(255),
    CONSTRAINT email_inbound_message_current_status_check CHECK (((current_status)::text = ANY ((ARRAY['RECEIVED'::character varying, 'IN_PROGRESS'::character varying, 'PENDING_HITL'::character varying, 'FAILED'::character varying, 'COMPLETED'::character varying])::text[])))
);

CREATE TABLE idr_core.email_message_read_state (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(255),
    identity_id uuid,
    is_read boolean DEFAULT true,
    read_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.email_message_review (
    review_id uuid DEFAULT gen_random_uuid() NOT NULL,
    email_id uuid NOT NULL,
    decision character varying(50) NOT NULL,
    outcome_id integer,
    note text,
    reviewed_by character varying(100) NOT NULL,
    reviewed_at timestamp with time zone DEFAULT now() NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid
);

CREATE TABLE idr_core.email_negotiation_offer (
    offer_id uuid DEFAULT gen_random_uuid() NOT NULL,
    idr_case_id uuid NOT NULL,
    email_id uuid,
    outbound_email_id uuid,
    offer_source character varying(20),
    offered_by character varying(20) NOT NULL,
    offer_amount numeric(12,2) NOT NULL,
    currency_code character varying(3),
    sequence_number integer NOT NULL,
    hitl_finalized boolean DEFAULT false NOT NULL,
    dotnet_synced_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    CONSTRAINT email_negotiation_offer_offer_source_check CHECK (((offer_source)::text = ANY ((ARRAY['INBOUND_PAYER'::character varying, 'OUTBOUND_PROVIDER'::character varying])::text[]))),
    CONSTRAINT email_negotiation_offer_offered_by_check CHECK (((offered_by)::text = ANY ((ARRAY['PAYER'::character varying, 'PROVIDER'::character varying])::text[])))
);

CREATE TABLE idr_core.email_outbound_message (
    outbound_email_id uuid DEFAULT gen_random_uuid() NOT NULL,
    idr_case_id uuid NOT NULL,
    dispute_id uuid,
    thread_id uuid NOT NULL,
    in_reply_to_email_id uuid,
    composed_email_id uuid NOT NULL,
    internal_batch_id character varying(100),
    from_address character varying(255),
    to_address text,
    stage_id integer,
    send_status character varying(20) DEFAULT 'READY_TO_SEND'::character varying NOT NULL,
    ses_message_id character varying(255),
    sent_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    message_id_header character varying(255),
    in_reply_to_header character varying(998),
    references_header text,
    cc_addresses text,
    CONSTRAINT email_outbound_message_send_status_check CHECK (((send_status)::text = ANY ((ARRAY['READY_TO_SEND'::character varying, 'QUEUED'::character varying, 'SENT'::character varying, 'FAILED'::character varying])::text[])))
);

CREATE TABLE idr_core.email_processing_status (
    status_id uuid DEFAULT gen_random_uuid() NOT NULL,
    email_id uuid NOT NULL,
    stage_id integer NOT NULL,
    attempt_number integer DEFAULT 1 NOT NULL,
    status character varying(20) NOT NULL,
    error_message text,
    error_detail jsonb,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    event_type character varying(50),
    event_version character varying(10) DEFAULT '1'::character varying,
    message_id character varying(255),
    event_s3_bucket character varying(255),
    event_s3_key character varying(1000),
    event_metadata jsonb,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    service_name character varying(100),
    processing_id character varying(100),
    CONSTRAINT email_processing_status_status_check CHECK (((status)::text = ANY ((ARRAY['STARTED'::character varying, 'COMPLETED'::character varying, 'FAILED'::character varying, 'SKIPPED'::character varying])::text[])))
);

CREATE TABLE idr_core.email_read_state (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id uuid NOT NULL,
    identity_id uuid NOT NULL,
    is_read boolean DEFAULT true NOT NULL,
    read_at timestamp with time zone DEFAULT now() NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid
);

CREATE TABLE idr_core.email_stage_payload (
    payload_id uuid DEFAULT gen_random_uuid() NOT NULL,
    email_id uuid NOT NULL,
    stage_id integer NOT NULL,
    payload_type character varying(30) NOT NULL,
    attempt_number integer DEFAULT 1 NOT NULL,
    schema_version integer DEFAULT 1 NOT NULL,
    payload_json jsonb,
    payload_s3_bucket character varying(255),
    payload_s3_key character varying(1000),
    payload_sha256 character(64) NOT NULL,
    contains_phi boolean DEFAULT true NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    CONSTRAINT ck_email_stage_payload_body CHECK (((payload_json IS NOT NULL) OR (payload_s3_key IS NOT NULL))),
    CONSTRAINT ck_email_stage_payload_phi CHECK ((contains_phi OR ((payload_type)::text = 'PHI_MASKED'::text))),
    CONSTRAINT email_stage_payload_payload_type_check CHECK (((payload_type)::text = ANY ((ARRAY['PARSED'::character varying, 'ATTACHMENT_MERGED'::character varying, 'PHI_MASKED'::character varying])::text[])))
);

CREATE TABLE idr_core.email_template (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(256),
    category character varying(64),
    subject_template character varying(998),
    body_html_template text,
    variables_schema jsonb,
    is_active boolean DEFAULT true,
    current_version integer DEFAULT 1,
    created_by character varying(256),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.email_template_version (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    template_id uuid,
    version_number integer,
    subject_template character varying(998),
    body_html_template text,
    created_at timestamp with time zone DEFAULT now(),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.email_thread (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    case_id uuid,
    subject character varying(998),
    status character varying(32) DEFAULT 'open'::character varying NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    legacy_case_id character varying(100)
);

CREATE TABLE idr_core.email_unmatched_inbound_queue (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id character varying(998),
    from_addr character varying(256),
    subject character varying(998),
    received_at timestamp with time zone DEFAULT now(),
    status character varying(32) DEFAULT 'pending'::character varying,
    resolved_case_id character varying(64),
    resolved_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    document_id uuid
);

CREATE TABLE idr_core.email_unmatched_queue (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    raw_s3_key character varying(512) NOT NULL,
    message_id character varying(998),
    from_addr character varying(256),
    subject character varying(998),
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    status character varying(32) DEFAULT 'pending'::character varying NOT NULL,
    resolved_case_id uuid,
    resolved_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer DEFAULT 1 NOT NULL,
    provider_id uuid,
    CONSTRAINT email_unmatched_queue_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'resolved'::character varying, 'discarded'::character varying])::text[])))
);

CREATE TABLE idr_core.eob_detail (
    eob_detail_id uuid NOT NULL,
    detail_type character varying(40),
    detail_value jsonb,
    recorded_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.eob_payer_contact (
    eob_payer_contact_id uuid NOT NULL,
    eob_detail_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.exception_reason_configuration (
    exception_reason_configuration_id uuid NOT NULL,
    config_key character varying(60),
    config_value text,
    effective_start_date date,
    effective_end_date date,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.exclusion_reason_configuration (
    exclusion_reason_configuration_id uuid NOT NULL,
    config_key character varying(60),
    config_value text,
    effective_start_date date,
    effective_end_date date,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_case (
    idr_case_id uuid NOT NULL,
    open_negotiation_id uuid,
    idr_filing_batch_id uuid,
    dispute_id uuid,
    filing_deadline_date date,
    idr_status character varying(25),
    created_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_case_claim_version (
    idr_case_claim_version_id bigint NOT NULL,
    idr_case_unit_id bigint NOT NULL,
    edi_837_claim_id uuid NOT NULL,
    edi_837_claim_line_id uuid,
    claim_lineage_id uuid,
    version_sequence integer NOT NULL,
    frequency_code smallint,
    is_void boolean DEFAULT false NOT NULL,
    service_code character varying(50),
    line_charge_amount numeric(14,2),
    change_type character varying(30) NOT NULL,
    note character varying(500),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    CONSTRAINT idr_case_claim_version_change_type_check CHECK (((change_type)::text = ANY ((ARRAY['INITIAL_MATCH'::character varying, 'REPOINTED'::character varying, 'CLAIM_VOIDED'::character varying, 'NO_MATCHING_LINE'::character varying, 'BATCHED_FLAGGED'::character varying])::text[])))
);

CREATE TABLE idr_core.idr_case_financial_summary (
    idr_case_unit_id bigint NOT NULL,
    billed_amount numeric(14,2),
    allowed_amount numeric(14,2),
    paid_amount numeric(14,2),
    qpa_amount numeric(14,2),
    medicare_reference_amount numeric(14,2),
    provider_offer_amount numeric(14,2),
    updated_at_utc timestamp with time zone DEFAULT now() NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_case_outcome_lookup (
    idr_case_outcome_id bigint NOT NULL,
    outcome_code character varying(50) NOT NULL,
    outcome_category character varying(30),
    assignment_mode character varying(30),
    requires_human_review boolean DEFAULT false NOT NULL,
    description character varying(300),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_case_status_history (
    idr_case_status_history_id bigint NOT NULL,
    idr_case_unit_id bigint,
    prior_outcome_id bigint,
    new_outcome_id bigint,
    event_source character varying(100),
    reason_code character varying(100),
    notes character varying(1000),
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_case_unit (
    idr_case_unit_id bigint NOT NULL,
    client_id integer NOT NULL,
    idr_claim_remit_match_id bigint,
    edi_837_claim_line_id uuid NOT NULL,
    edi_835_claim_line_payment_id uuid NOT NULL,
    case_reference character varying(200),
    invoice_number character varying(100),
    patient_control_number character varying(100),
    tax_id character varying(20),
    entity_name character varying(200),
    payer_business_id character varying(100),
    service_line_code character varying(20),
    service_code character varying(50),
    qualifying_modifier character varying(10),
    date_of_service date,
    remit_payment_date date,
    insurance_group_number character varying(100),
    employer_group_number character varying(100),
    funding_type character varying(30),
    facility_state_code character varying(2),
    current_outcome_id bigint,
    current_stage character varying(50) DEFAULT 'CLAIM_SELECTION'::character varying NOT NULL,
    selected_for_federal_idr boolean DEFAULT false NOT NULL,
    active_in_idr_workflow boolean DEFAULT false NOT NULL,
    config_criteria_version_id bigint,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_case_unit_financial_summary (
    financial_summary_id uuid NOT NULL,
    idr_case_unit_id uuid,
    billed_amount numeric(12,2),
    allowed_amount numeric(12,2),
    paid_amount numeric(12,2),
    qpa_amount numeric(12,2),
    provider_offer_amount numeric(12,2),
    payer_offer_amount numeric(12,2),
    awarded_amount numeric(12,2),
    recovery_amount numeric(12,2),
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_case_unit_identifier (
    idr_case_unit_identifier_id bigint NOT NULL,
    idr_case_unit_id bigint,
    case_reference character varying(120),
    invoice_number character varying(50),
    patient_control_number character varying(50),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_case_unit_stage_history (
    stage_history_id bigint NOT NULL,
    idr_case_unit_id bigint,
    prior_stage character varying(30),
    new_stage character varying(30),
    entered_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_case_unit_status_history (
    status_history_id bigint NOT NULL,
    idr_case_unit_id bigint,
    prior_outcome_id bigint,
    new_outcome_id bigint,
    event_source character varying(20),
    changed_by_user_id uuid,
    reason_code character varying(20),
    notes text,
    changed_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_claim_remit_match (
    idr_claim_remit_match_id bigint NOT NULL,
    client_id integer NOT NULL,
    edi_837_claim_line_id uuid NOT NULL,
    edi_835_claim_line_payment_id uuid NOT NULL,
    match_type character varying(30),
    match_status character varying(30),
    matched_837_version_sequence integer,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL,
    CONSTRAINT idr_claim_remit_match_match_type_check CHECK (((match_type)::text = ANY ((ARRAY['EXACT'::character varying, 'APPROVED_DOWNCODE'::character varying])::text[])))
);

CREATE TABLE idr_core.idr_claim_selection_evaluation (
    idr_claim_selection_evaluation_id bigint NOT NULL,
    client_id integer NOT NULL,
    idr_case_unit_id bigint,
    config_criteria_version_id bigint,
    evaluation_type character varying(30),
    final_outcome_code character varying(50),
    failed_rule_count integer,
    missing_data_count integer,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_claim_selection_exception (
    idr_claim_selection_exception_id bigint NOT NULL,
    client_id integer NOT NULL,
    idr_case_unit_id bigint,
    edi_835_claim_line_payment_id uuid NOT NULL,
    exception_code character varying(50) NOT NULL,
    reason_text character varying(500),
    missing_fields jsonb DEFAULT '[]'::jsonb NOT NULL,
    validation_source character varying(50),
    days_remaining_in_window integer,
    status character varying(30) DEFAULT 'OPEN'::character varying NOT NULL,
    retry_count integer DEFAULT 0 NOT NULL,
    last_aged_on date,
    resolved_timestamp timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL,
    CONSTRAINT idr_claim_selection_exception_status_check CHECK (((status)::text = ANY ((ARRAY['OPEN'::character varying, 'RESOLVED'::character varying, 'EXPIRED_EXCLUDED'::character varying, 'CLOSED'::character varying])::text[])))
);

CREATE TABLE idr_core.idr_claim_selection_result (
    idr_claim_selection_result_id bigint NOT NULL,
    idr_claim_selection_evaluation_id bigint,
    idr_case_unit_id bigint,
    outcome_code character varying(50),
    selected_at_utc timestamp with time zone DEFAULT now() NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_claim_selection_rule_result (
    idr_claim_selection_rule_result_id bigint NOT NULL,
    idr_claim_selection_evaluation_id bigint,
    rule_code character varying(100),
    rule_outcome character varying(30),
    exclusion_code character varying(30),
    reason_code character varying(100),
    source_value character varying(500),
    configuration_value character varying(500),
    detail character varying(1000),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    CONSTRAINT idr_claim_selection_rule_result_rule_outcome_check CHECK (((rule_outcome)::text = ANY ((ARRAY['PASS'::character varying, 'FAIL'::character varying, 'MISSING_DATA'::character varying, 'NOT_APPLICABLE'::character varying])::text[])))
);

CREATE TABLE idr_core.idr_cool_off_status (
    idr_cool_off_status_id bigint NOT NULL,
    idr_case_unit_id bigint NOT NULL,
    check_status character varying(30) NOT NULL,
    cool_off_start_date date,
    cool_off_end_date date,
    determination_reference character varying(100),
    is_active boolean DEFAULT false NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    CONSTRAINT idr_cool_off_status_check_status_check CHECK (((check_status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'CLEARED'::character varying, 'DATA_NOT_AVAILABLE'::character varying])::text[])))
);

CREATE TABLE idr_core.idr_filing_batch (
    idr_filing_batch_id uuid NOT NULL,
    source_preliminary_batch_ids jsonb,
    filing_batch_status character varying(15),
    created_at timestamp with time zone,
    parent_on_batch_id uuid,
    sub_batch_identifier character varying(40),
    cms_batching_rule_applied character varying(60),
    service_line_code character varying(10),
    claim_count integer,
    formation_outcome character varying(30),
    filing_deadline_date date,
    filing_deadline_type character varying(20),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_filing_batch_case_unit (
    idr_filing_batch_case_unit_id uuid NOT NULL,
    idr_filing_batch_id uuid,
    idr_case_unit_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_filing_error (
    idr_filing_error_id uuid NOT NULL,
    error_code character varying(30),
    error_message text,
    occurred_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_preliminary_batch (
    idr_preliminary_batch_id bigint NOT NULL,
    client_id integer NOT NULL,
    batch_reference character varying(200) NOT NULL,
    tax_id character varying(20),
    payer_business_id character varying(100),
    insurance_group_number character varying(100),
    service_line_code character varying(20),
    service_code character varying(50),
    grouping_mode character varying(20) DEFAULT 'FullyFunded'::character varying NOT NULL,
    earliest_dos date NOT NULL,
    latest_dos date NOT NULL,
    first_remit_payment_date date NOT NULL,
    batch_open_end_date date NOT NULL,
    batch_status character varying(20) NOT NULL,
    config_criteria_version_id bigint,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    provider_id integer NOT NULL,
    CONSTRAINT idr_preliminary_batch_batch_status_check CHECK (((batch_status)::text = ANY ((ARRAY['OPEN'::character varying, 'CLOSED'::character varying, 'LOCKED'::character varying])::text[]))),
    CONSTRAINT idr_preliminary_batch_grouping_mode_check CHECK (((grouping_mode)::text = ANY ((ARRAY['FullyFunded'::character varying, 'SelfFunded'::character varying, 'SingleCase'::character varying])::text[])))
);

CREATE TABLE idr_core.idr_preliminary_batch_case_unit (
    idr_preliminary_batch_case_unit_id bigint NOT NULL,
    idr_preliminary_batch_id bigint NOT NULL,
    idr_case_unit_id bigint NOT NULL,
    assigned_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    assigned_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_status_history (
    idr_status_history_id uuid NOT NULL,
    prior_status character varying(30),
    new_status character varying(30),
    changed_by_user_id uuid,
    changed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_submission (
    idr_submission_id uuid NOT NULL,
    idr_filing_batch_id uuid,
    submission_channel character varying(20),
    submission_attempt_number integer,
    submission_status character varying(15),
    submitted_at timestamp with time zone,
    cms_confirmation_number character varying(50),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idr_submission_case_unit (
    idr_submission_case_unit_id uuid NOT NULL,
    idr_submission_id uuid,
    idr_case_unit_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idre_assignment (
    idre_assignment_id uuid NOT NULL,
    idr_case_id uuid,
    idre_id uuid,
    assignment_method character varying(20),
    assignment_status character varying(15),
    bot_updating_coi character varying(255),
    assigned_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idre_registry (
    idre_id uuid NOT NULL,
    idre_name character varying(150),
    certification_status character varying(15),
    specialties jsonb,
    contact_info jsonb,
    is_active boolean,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.idre_selection_log (
    selection_log_id uuid NOT NULL,
    idre_assignment_id uuid,
    selection_method character varying(20),
    conflict_of_interest_checked boolean,
    rejection_reason character varying(200),
    logged_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.insurance_coverage (
    coverage_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_id uuid,
    insurance_group_number character varying(50),
    payer_responsibility_sequence character varying(255),
    claim_filing_indicator_code character varying(20),
    funding_type character varying(30),
    state_eligibility_status character varying(30),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    payer_id bigint,
    employer_group_number character varying(50)
);

CREATE TABLE idr_core.insurance_group (
    insurance_group_id uuid NOT NULL,
    insurance_group_number character varying(50),
    group_name character varying(200),
    funding_type_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    payer_id character varying(5),
    CONSTRAINT chk_insurance_group_payer_id_5digit CHECK (((payer_id)::text ~ '^[0-9]{5}$'::text))
);

CREATE TABLE idr_core.insurance_group_eligibility (
    insurance_group_eligibility_id uuid NOT NULL,
    insurance_group_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.job_case_log (
    job_case_log_id bigint NOT NULL,
    job_code character varying(60) NOT NULL,
    client_id integer NOT NULL,
    idr_case_unit_id bigint,
    edi_835_claim_line_payment_id uuid,
    exception_id bigint,
    result character varying(60) NOT NULL,
    detail character varying(500),
    logged_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.job_configuration (
    job_configuration_id uuid NOT NULL,
    config_key character varying(60),
    config_value text,
    effective_start_date date,
    effective_end_date date,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.job_execution (
    job_execution_id uuid NOT NULL,
    job_configuration_id uuid,
    execution_status character varying(15),
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    triggered_by character varying(15),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.job_execution_detail (
    job_execution_detail_id uuid NOT NULL,
    job_execution_id uuid,
    detail_type character varying(40),
    detail_value jsonb,
    recorded_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.job_execution_error (
    job_execution_error_id uuid NOT NULL,
    job_execution_id uuid,
    error_code character varying(30),
    error_message text,
    occurred_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.job_history (
    job_history_id uuid NOT NULL,
    prior_status character varying(30),
    new_status character varying(30),
    changed_by_user_id uuid,
    changed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.job_retry_policy (
    job_retry_policy_id uuid NOT NULL,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.job_run_log (
    job_run_log_id bigint NOT NULL,
    job_code character varying(60) NOT NULL,
    started_at_utc timestamp with time zone DEFAULT now() NOT NULL,
    finished_at_utc timestamp with time zone,
    processed_count integer,
    status character varying(20) DEFAULT 'RUNNING'::character varying NOT NULL,
    error_message text,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.lkp_administrative_fee (
    administrative_fee_id uuid NOT NULL,
    idr_case_id uuid,
    paying_party character varying(10),
    fee_amount numeric(10,2),
    payment_status character varying(15),
    cms_receipt_reference character varying(50),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.lkp_allowed_amount_threshold (
    threshold_id uuid NOT NULL,
    service_line_code character varying(10),
    lower_threshold_pct numeric(5,2),
    upper_threshold_pct numeric(5,2),
    effective_start_date date,
    effective_end_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    payer_id bigint,
    CONSTRAINT chk_allowed_amount_threshold_payer_id_5digit CHECK (((payer_id >= 0) AND (payer_id <= 99999)))
);

CREATE TABLE idr_core.lkp_anesthesia_rate (
    anesthesia_rate_id uuid NOT NULL,
    group_number character varying(30),
    state character varying(2),
    modifier_code character varying(20),
    threshold_amount numeric(10,2),
    effective_start_date date,
    effective_end_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.lkp_batch_rule (
    batch_rule_id uuid NOT NULL,
    rule_name character varying(60),
    rule_value character varying(60),
    effective_start_date date,
    effective_end_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.lkp_bifurcated_state (
    state_name character varying(50) NOT NULL,
    bifurcated_state character varying(10) NOT NULL,
    ssl_allowed character varying(10),
    notes text,
    reference_link character varying(500)
);

CREATE TABLE idr_core.lkp_cpt_downcoding (
    service_code character varying(10) NOT NULL,
    allowed_downcode_lower_range character varying(10) NOT NULL,
    allowed_downcode_upper_range character varying(10) NOT NULL
);

CREATE TABLE idr_core.lkp_email_correspondence_type (
    correspondence_type_id integer NOT NULL,
    type_code character varying(50) NOT NULL,
    type_name character varying(150) NOT NULL,
    idr_stage_context character varying(50),
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);

CREATE TABLE idr_core.lkp_email_message_source (
    source_id integer NOT NULL,
    source_code character varying(50) NOT NULL,
    source_name character varying(150) NOT NULL,
    default_direction character varying(10) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT ck_msg_source_direction CHECK (((default_direction)::text = ANY ((ARRAY['INBOUND'::character varying, 'OUTBOUND'::character varying])::text[])))
);

CREATE TABLE idr_core.lkp_email_outcome (
    outcome_id integer NOT NULL,
    outcome_code character varying(50) NOT NULL,
    stage character varying(50) NOT NULL,
    status character varying(50) NOT NULL,
    tag character varying(50) NOT NULL,
    description text,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE idr_core.lkp_email_processing_stage (
    stage_id integer NOT NULL,
    stage_code character varying(50) NOT NULL,
    stage_name character varying(100) NOT NULL,
    sequence_order integer NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);

CREATE TABLE idr_core.lkp_federal_calendar (
    calendar_date date NOT NULL,
    day_of_week character varying(10) NOT NULL,
    is_weekend boolean NOT NULL,
    is_holiday boolean NOT NULL,
    holiday_name character varying(100),
    actual_holiday boolean NOT NULL,
    observed_holiday boolean NOT NULL,
    is_business_day boolean NOT NULL
);

CREATE TABLE idr_core.lkp_federal_holiday_calendar (
    federal_holiday_calendar_id uuid NOT NULL,
    holiday_date date,
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    holiday_name character varying(60),
    calendar_year integer,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.lkp_fee_schedule (
    fee_schedule_id uuid DEFAULT gen_random_uuid() NOT NULL,
    entity character varying(200) NOT NULL,
    facility character varying(200),
    cpt character varying(20) NOT NULL,
    medicare_allowable character varying(50),
    price_transparency character varying(50),
    allowed_thresholds character varying(100),
    on_offer_amount character varying(50),
    on_acceptance_thresholds character varying(50),
    idr_offer_amount character varying(50),
    aetna_contracted_rate character varying(50),
    cigna_contracted_rate character varying(50)
);

CREATE TABLE idr_core.lkp_funding_type (
    funding_type_id uuid NOT NULL,
    funding_type_code character varying(20),
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.lkp_hitl_rejection_reason (
    rejection_reason_id integer NOT NULL,
    reason_code character varying(50) NOT NULL,
    reason_description character varying(255) NOT NULL,
    routes_to character varying(30) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT ck_hitl_reason_routes_to CHECK (((routes_to)::text = ANY ((ARRAY['CLASSIFIER'::character varying, 'COMPOSER'::character varying])::text[])))
);

CREATE TABLE idr_core.lkp_idr_case_outcome (
    outcome_id bigint NOT NULL,
    outcome_code character varying(40),
    outcome_category character varying(20),
    assignment_mode character varying(20),
    requires_human_review boolean,
    description character varying(200),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.lkp_idr_case_outcome_bkp (
    outcome_id uuid,
    outcome_code character varying(40),
    outcome_category character varying(20),
    assignment_mode character varying(20),
    requires_human_review boolean,
    description character varying(200),
    created_timestamp timestamp with time zone,
    modified_timestamp timestamp with time zone,
    created_by_user character varying(100),
    modified_by_user character varying(100),
    client_id integer,
    provider_id integer
);

CREATE TABLE idr_core.lkp_idre (
    legal_business_name character varying(200) NOT NULL,
    application_id character varying(20) NOT NULL,
    status_note character varying(255),
    fee_2025_single numeric(8,2),
    fee_2025_batched numeric(8,2),
    fee_2025_tiered numeric(8,2),
    fee_2026_single numeric(8,2),
    fee_2026_batched numeric(8,2),
    fee_2026_tiered numeric(8,2)
);

CREATE TABLE idr_core.lkp_idre_choice (
    id bigint NOT NULL,
    payer_name character varying(100) NOT NULL,
    rank_order smallint NOT NULL,
    idre_name character varying(150) NOT NULL,
    is_first_choice boolean DEFAULT false NOT NULL,
    is_second_choice boolean DEFAULT false NOT NULL
);

CREATE TABLE idr_core.lkp_idre_fee (
    idre_fee_id uuid NOT NULL,
    decision_id uuid,
    idre_id uuid,
    fee_type character varying(20),
    fee_amount numeric(10,2),
    liable_party character varying(10),
    payment_status character varying(15),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.lkp_idre_priority_rule (
    idre_priority_rule_id uuid NOT NULL,
    service_line_code character varying(10),
    state character varying(2),
    first_choice_idre_id uuid,
    alternate_choice_idre_id uuid,
    effective_start_date date,
    effective_end_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    payer_id bigint,
    CONSTRAINT chk_idre_priority_rule_payer_id_5digit CHECK (((payer_id >= 0) AND (payer_id <= 99999)))
);

CREATE TABLE idr_core.lkp_medical_code_master (
    medical_code_id uuid NOT NULL,
    code_type character varying(15),
    code_value character varying(10),
    code_description character varying(300),
    effective_start_date date,
    effective_end_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.lkp_medicare_reference_rate (
    medicare_reference_rate_id uuid NOT NULL,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.lkp_payer_insurance_group (
    id bigint NOT NULL,
    payer_eid character varying(50),
    payer_name character varying(150) NOT NULL,
    insurance_group_id character varying(50),
    insurance_group character varying(150) NOT NULL,
    funding_type character varying(20),
    settlement_rate numeric(9,4) NOT NULL
);

CREATE TABLE idr_core.lkp_rarc_inclusion (
    rarc_code character varying(10) NOT NULL,
    payment_event character varying(100) NOT NULL,
    circumstance_summary text NOT NULL,
    applicable_law_flag character varying(50) NOT NULL,
    federal_idr_eligible character varying(100) NOT NULL,
    reference_link character varying(500)
);

CREATE TABLE idr_core.lkp_rarc_inclusion_rule (
    rarc_inclusion_rule_id uuid NOT NULL,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.lkp_stage_timer (
    timer_id character varying(10) NOT NULL,
    stage_code character varying(10) NOT NULL,
    stage_name character varying(100) NOT NULL,
    timer_name character varying(150) NOT NULL,
    trigger_event character varying(255) NOT NULL,
    duration_value integer,
    duration_unit character varying(50) NOT NULL
);

CREATE TABLE idr_core.lkp_state_eligibility_rule (
    state_eligibility_rule_id uuid NOT NULL,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.lkp_tax_id_service_line_entity (
    id bigint NOT NULL,
    tax_id character varying(20) NOT NULL,
    service_line character varying(100) NOT NULL,
    entity_name character varying(200) NOT NULL
);

CREATE TABLE idr_core.negotiation_communication (
    negotiation_communication_id uuid NOT NULL,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.negotiation_document_link (
    negotiation_document_link_id uuid NOT NULL,
    open_negotiation_id uuid,
    document_id uuid,
    linked_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.negotiation_notice (
    notice_id uuid NOT NULL,
    open_negotiation_id uuid,
    notice_type character varying(30),
    generated_at timestamp with time zone,
    sent_at timestamp with time zone,
    delivery_method character varying(20),
    template_version character varying(20),
    document_id uuid,
    recipient_email character varying(150),
    triggered_by character varying(20),
    dispatch_status character varying(30),
    retry_count integer,
    bounce_detected_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.negotiation_offer (
    negotiation_offer_id uuid NOT NULL,
    open_negotiation_id uuid,
    offering_party character varying(15),
    offer_amount numeric(12,2),
    offer_status character varying(15),
    offered_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.negotiation_response (
    response_id uuid NOT NULL,
    open_negotiation_id uuid,
    responding_party character varying(15),
    response_type character varying(20),
    response_amount numeric(12,2),
    received_at timestamp with time zone,
    sender_email character varying(150),
    subject character varying(255),
    body_text text,
    ingestion_timestamp timestamp with time zone,
    classification_label character varying(40),
    ai_confidence_score numeric(5,2),
    acceptance_threshold_pct numeric(5,2),
    accept_condition_met boolean,
    decision_action character varying(10),
    requires_supervisor_approval boolean,
    approved_by_user_id uuid,
    decided_by_user_id uuid,
    decided_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.negotiation_response_exception (
    response_exception_id uuid NOT NULL,
    negotiation_response_id uuid,
    flag_reason character varying(30),
    ai_confidence_score numeric(5,2),
    resolved_classification_label character varying(40),
    resolved_hp_offer_amount numeric(12,2),
    resolved_by_user_id uuid,
    resolved_at timestamp with time zone,
    opened_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.negotiation_status_history (
    negotiation_status_history_id uuid NOT NULL,
    prior_status character varying(30),
    new_status character varying(30),
    changed_by_user_id uuid,
    changed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.not_pursued_reason_configuration (
    not_pursued_reason_configuration_id uuid NOT NULL,
    reason_code character varying(30),
    reason_label character varying(100),
    effective_start_date date,
    effective_end_date date,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    is_standard boolean,
    is_active boolean,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.notification (
    notification_id uuid NOT NULL,
    notification_template_id uuid,
    related_entity_type character varying(40),
    related_entity_id uuid,
    payload jsonb,
    created_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.notification_delivery (
    notification_delivery_id uuid NOT NULL,
    notification_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.notification_event_log (
    notification_event_log_id uuid NOT NULL,
    notification_id uuid,
    event_type character varying(40),
    payload jsonb,
    logged_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.notification_recipient (
    notification_recipient_id uuid NOT NULL,
    notification_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.notification_template (
    notification_template_id uuid NOT NULL,
    notification_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.offer (
    offer_id uuid NOT NULL,
    idr_case_id uuid,
    offering_party character varying(10),
    offer_amount numeric(12,2),
    offer_round integer,
    offer_status character varying(15),
    submitted_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.offer_ai_recommendation (
    recommendation_id uuid NOT NULL,
    offer_id uuid,
    recommended_amount numeric(12,2),
    confidence_score numeric(4,3),
    model_version character varying(30),
    was_accepted boolean,
    generated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.offer_amount_configuration (
    offer_amount_configuration_id uuid NOT NULL,
    tax_id character varying(10),
    effective_start_date date,
    effective_end_date date,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    service_line_code character varying(10),
    cpt_code character varying(10),
    modifier_code character varying(2),
    state character varying(2),
    medicare_fee_schedule_year integer,
    rate_type character varying(25),
    offer_percentage numeric(6,2),
    per_unit_rate numeric(10,2),
    unit_definition character varying(100),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    payer_id character varying(5),
    CONSTRAINT chk_offer_amount_configuration_payer_id_5digit CHECK (((payer_id)::text ~ '^[0-9]{5}$'::text))
);

CREATE TABLE idr_core.offer_calculation (
    offer_calculation_id uuid NOT NULL,
    offer_id uuid,
    calculation_basis character varying(30),
    reference_rate numeric(12,2),
    multiplier numeric(5,2),
    calculated_amount numeric(12,2),
    calculated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.offer_document (
    offer_document_id uuid NOT NULL,
    offer_id uuid,
    document_id uuid,
    linked_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.offer_status_history (
    offer_status_history_id uuid NOT NULL,
    offer_id uuid,
    prior_status character varying(30),
    new_status character varying(30),
    changed_by_user_id uuid,
    changed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.offer_submission (
    offer_submission_id uuid NOT NULL,
    offer_id uuid,
    submission_channel character varying(20),
    submission_status character varying(15),
    submitted_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.on_settlement (
    on_settlement_id uuid NOT NULL,
    open_negotiation_id uuid,
    provider_offer_amount numeric(12,2),
    payer_offer_amount numeric(12,2),
    negotiated_amount numeric(12,2),
    settlement_status character varying(30),
    settled_at timestamp with time zone,
    payment_match_tolerance numeric(6,2),
    matched_claim_payment_id uuid,
    matched_payment_amount numeric(12,2),
    matched_payment_date date,
    monitoring_window_days integer,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.on_settlement_correction (
    correction_id uuid NOT NULL,
    on_settlement_id uuid,
    original_amount numeric(12,2),
    corrected_amount numeric(12,2),
    corrected_by_user_id uuid,
    reason text,
    corrected_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.on_settlement_payment_check (
    payment_check_id uuid NOT NULL,
    on_settlement_id uuid,
    claim_payment_id uuid,
    check_result character varying(15),
    discrepancy_amount numeric(12,2),
    edi_835_file_id uuid,
    checked_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.open_negotiation (
    open_negotiation_id uuid NOT NULL,
    batch_id uuid,
    remit_payment_date date,
    on_initiated_date date,
    on_deadline_date date,
    cool_off_snapshot_status character varying(20),
    negotiation_status character varying(25),
    resolved_amount numeric(12,2),
    created_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.out_of_network_determination (
    out_of_network_determination_id uuid NOT NULL,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.outbox_event (
    outbox_event_id uuid NOT NULL,
    event_type character varying(40),
    payload jsonb,
    logged_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.outbox_event_attempt (
    outbox_event_attempt_id uuid NOT NULL,
    outbox_event_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.patient (
    patient_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_id uuid,
    is_same_as_subscriber boolean,
    patient_identifier character varying(255),
    last_name character varying(200),
    first_name character varying(200),
    corrected_name character varying(200),
    medical_record_number character varying(50),
    dob character varying(255),
    gender_code character varying(20),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.payer (
    id bigint NOT NULL,
    payer_id character varying(100),
    payer_name character varying(200),
    address_line1 character varying(255),
    state character varying(255),
    zip character varying(255),
    contact_dept character varying(255),
    contact_phone character varying(255),
    payer_identifier_qualifier character varying(255),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.payer_configuration (
    payer_configuration_id uuid NOT NULL,
    is_idr_qualifying boolean,
    effective_start_date date,
    effective_end_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    payer_id character varying(5),
    CONSTRAINT chk_payer_configuration_payer_id_5digit CHECK (((payer_id)::text ~ '^[0-9]{5}$'::text))
);

CREATE TABLE idr_core.payer_on_email_reference (
    payer_email_ref_id uuid NOT NULL,
    on_email_address character varying(150),
    source character varying(30),
    effective_start_date date,
    effective_end_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    payer_id character varying(5),
    CONSTRAINT chk_payer_on_email_reference_payer_id_5digit CHECK (((payer_id)::text ~ '^[0-9]{5}$'::text))
);

CREATE TABLE idr_core.payer_service_line_configuration (
    payer_service_line_configuration_id uuid NOT NULL,
    payer_configuration_id uuid,
    config_key character varying(60),
    config_value text,
    effective_start_date date,
    effective_end_date date,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.payment_adjustment (
    payment_adjustment_id uuid NOT NULL,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.payment_expected (
    payment_expected_id uuid NOT NULL,
    payment_reconciliation_id uuid,
    expected_amount numeric(12,2),
    expected_payment_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.payment_received (
    payment_received_id uuid NOT NULL,
    payment_reconciliation_id uuid,
    claim_payment_id uuid,
    received_amount numeric(12,2),
    received_date date,
    source character varying(15),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.payment_reconciliation (
    payment_reconciliation_id uuid NOT NULL,
    idr_case_id uuid,
    decision_id uuid,
    reconciliation_status character varying(20),
    created_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.payment_reconciliation_detail (
    payment_reconciliation_detail_id uuid NOT NULL,
    payment_reconciliation_id uuid,
    detail_type character varying(40),
    detail_value jsonb,
    recorded_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.payment_status_history (
    payment_status_history_id uuid NOT NULL,
    prior_status character varying(30),
    new_status character varying(30),
    changed_by_user_id uuid,
    changed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.payment_variance (
    payment_variance_id uuid NOT NULL,
    payment_reconciliation_id uuid,
    expected_amount numeric(12,2),
    received_amount numeric(12,2),
    variance_amount numeric(12,2),
    variance_reason character varying(100),
    flagged_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.preliminary_batch (
    batch_id uuid NOT NULL,
    batc_name character varying(200),
    tax_id character varying(10),
    insurance_group_number character varying(30),
    service_code character varying(10),
    earliest_dos date,
    latest_dos date,
    first_remit_payment_date date,
    batch_open_end_date date,
    batch_status character varying(15),
    criteria_version_id uuid,
    created_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    payer_id character varying(5),
    CONSTRAINT chk_preliminary_batch_payer_id_5digit CHECK (((payer_id)::text ~ '^[0-9]{5}$'::text))
);

CREATE TABLE idr_core.preliminary_batch_case_unit (
    batch_case_unit_id bigint NOT NULL,
    batch_id bigint,
    idr_case_unit_id bigint,
    assigned_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.preliminary_idr_filing_batch_lineage (
    batch_lineage_id uuid,
    preliminary_batch_id uuid,
    idr_filing_batch_id uuid,
    batch_type character varying(30),
    parent_batch_id uuid,
    parent_batch_type character varying(30),
    effective_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.provider_level_adjustment (
    provider_level_adjustment_id uuid DEFAULT gen_random_uuid() NOT NULL,
    remittance_id uuid,
    provider_identifier character varying(255),
    fiscal_period_end_date date,
    adjustment_reason_code character varying(20),
    adjustment_reference_number character varying(50),
    adjustment_amount numeric(14,2),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.qpa_record (
    qpa_record_id uuid NOT NULL,
    idr_case_unit_id uuid,
    qpa_amount numeric(12,2),
    qpa_source character varying(20),
    validation_status character varying(15),
    captured_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.remittance (
    remittance_id uuid DEFAULT gen_random_uuid() NOT NULL,
    transaction_control_number character varying(50),
    total_payment_amount numeric(14,2),
    credit_debit_flag boolean,
    payment_method character varying(255),
    payment_effective_date date,
    trace_number character varying(50),
    payee_provider_id uuid,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL,
    payer_id bigint,
    CONSTRAINT chk_remittance_payer_id_5digit CHECK (((payer_id)::text ~ '^[0-9]{5}$'::text))
);

CREATE TABLE idr_core.remittance_pament (
    production_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.remittance_payee (
    remittance_payee_id uuid NOT NULL,
    remittance_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.remittance_payer (
    remittance_payer_id uuid NOT NULL,
    remittance_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.remittance_payment (
    remittance_payment_id uuid NOT NULL,
    remittance_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.remittance_trace (
    remittance_trace_id uuid NOT NULL,
    remittance_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.rendering_provider (
    rendering_provider_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_id uuid,
    last_name character varying(200),
    first_name character varying(200),
    rendering_provider_npi character varying(255),
    taxonomy_code character varying(20),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.report_execution (
    report_execution_id uuid NOT NULL,
    report_request_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.report_output (
    report_output_id uuid NOT NULL,
    report_execution_id uuid,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.report_request (
    report_request_id uuid NOT NULL,
    request_status character varying(20),
    requested_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.rpa_bot_callback (
    rpa_bot_callback_id uuid NOT NULL,
    callback_status character varying(20),
    callback_payload jsonb,
    received_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.rpa_bot_error (
    rpa_bot_error_id uuid NOT NULL,
    error_code character varying(30),
    error_message text,
    occurred_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.rpa_bot_run (
    rpa_bot_run_id uuid NOT NULL,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.service_facility (
    service_facility_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_id uuid,
    facility_name character varying(200),
    facility_npi character varying(255),
    address_line1 character varying(255),
    city character varying(255),
    state character varying(255),
    zip_code character varying(20),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.sub_batch_size_configuration (
    sub_batch_size_config_id uuid NOT NULL,
    min_batch_size character varying(255),
    max_batch_size character varying(255),
    service_line character varying(255),
    service_line_code character varying(10),
    min_claim_count integer,
    max_claim_count integer,
    target_claim_count integer,
    effective_start_date date,
    effective_end_date date,
    is_active boolean,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.subscriber (
    subscriber_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_id uuid,
    member_id uuid,
    last_name character varying(200),
    first_name character varying(200),
    dob character varying(255),
    gender_code character varying(20),
    hicn character varying(255),
    relationship_code character varying(20),
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.tax_id_attribute (
    tax_id_attribute_id uuid NOT NULL,
    tax_id character varying(10),
    entity_name character varying(100),
    service_line_code character varying(10),
    group_npi character varying(10),
    group_number character varying(30),
    effective_start_date date,
    effective_end_date date,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE TABLE idr_core.tenant (
    client_name character varying(100),
    is_active boolean,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL
);

CREATE TABLE idr_core.tp_audit_log (
    audit_id bigint NOT NULL,
    date timestamp with time zone NOT NULL,
    event_type text NOT NULL,
    event_code text NOT NULL,
    event_subtype text,
    event_subtype_code text,
    action text NOT NULL,
    outcome text NOT NULL,
    user_id text NOT NULL,
    previous_value jsonb,
    new_value jsonb,
    source text,
    destination text,
    document_name text,
    description text,
    created_timestamp timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE idr_core.user_activity_audit (
    user_activity_audit_id uuid NOT NULL,
    description character varying(200),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    modified_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user character varying(100) NOT NULL,
    modified_by_user character varying(100) NOT NULL,
    client_id integer NOT NULL,
    provider_id integer NOT NULL
);

CREATE VIEW idr_core.vw_835_claim_selection_source AS
 SELECT r.client_id,
    r.provider_id,
    r.remittance_id AS edi_835_remittance_id,
    cp.claim_payment_id AS edi_835_claim_payment_id,
    lp.claim_line_payment_id AS edi_835_claim_line_payment_id,
    cp.patient_control_number,
    payer.payer_id AS payer_business_id,
    r.payment_effective_date AS remit_payment_date,
    lp.line_number,
    lp.date_of_service,
    lp.service_line AS service_line_code,
    lp.paid_service_code,
    lp.units,
    COALESCE(lp.allowed_amount, cp.allowed_amount) AS allowed_amount,
    lp.line_paid_amount,
    lp.line_charge_amount,
    lp.provider_offer_amount,
    NULLIF((cp.drg_code)::text, ''::text) AS drg_code,
    NULLIF((lp.revenue_code)::text, ''::text) AS revenue_code,
    NULLIF((cp.insurance_group_number)::text, ''::text) AS insurance_group_number,
    NULLIF((cp.employer_group_number)::text, ''::text) AS employer_group_number,
    COALESCE(( SELECT array_agg(DISTINCT (m.modifier_code)::character varying) AS array_agg
           FROM idr_core.claim_line_payment_modifier m
          WHERE (m.claim_line_payment_id = lp.claim_line_payment_id)), ARRAY[]::character varying[]) AS modifiers,
    COALESCE(( SELECT array_agg(DISTINCT (k.remark_code)::character varying) AS array_agg
           FROM idr_core.claim_line_remark_code k
          WHERE (k.claim_line_payment_id = lp.claim_line_payment_id)), ARRAY[]::character varying[]) AS rarc_codes
   FROM (((idr_core.remittance r
     JOIN idr_core.claim_payment cp ON ((cp.remittance_id = r.remittance_id)))
     JOIN idr_core.claim_line_payment lp ON ((lp.claim_payment_id = cp.claim_payment_id)))
     LEFT JOIN idr_core.payer payer ON ((payer.id = r.payer_id)));

CREATE VIEW idr_core.vw_837_claim_selection_source AS
 SELECT c.client_id,
    c.provider_id,
    c.claim_id AS edi_837_claim_id,
    l.claim_line_id AS edi_837_claim_line_id,
    c.original_claim_id,
    COALESCE(c.root_claim_id, c.original_claim_id, c.claim_id) AS claim_lineage_id,
    c.version_sequence,
    c.latest_valid_version_flag,
        CASE
            WHEN ((c.frequency_code)::text ~ '^[0-9]+$'::text) THEN (c.frequency_code)::smallint
            ELSE NULL::smallint
        END AS frequency_code,
    c.is_void,
    c.claim_type,
    COALESCE(c.invoice_number, c.patient_account_number) AS invoice_number,
    c.patient_account_number,
    payer.payer_id AS payer_business_id,
    COALESCE(c.provider_tin, billing.provider_tin) AS tax_id,
    billing.billing_provider_npi,
    rendering.rendering_provider_npi,
    facility.facility_npi,
    facility.facility_name,
    facility.state AS facility_state_code,
    facility.zip_code AS facility_zip_code,
    c.facility_type_code AS place_of_service_code,
    coverage.insurance_group_number,
    coverage.employer_group_number,
    l.line_number,
    l.date_of_service,
    l.service_line AS service_line_code,
    l.service_code,
    l.revenue_code,
    COALESCE(NULLIF((l.drg_code)::text, ''::text), (drg.drg_code)::text) AS drg_code,
    l.units,
    l.line_charge_amount,
    COALESCE(( SELECT array_agg((m.modifier_code)::character varying ORDER BY m.modifier_sequence, m.modifier_id) AS array_agg
           FROM idr_core.claim_line_modifier m
          WHERE (m.claim_line_id = l.claim_line_id)), ARRAY[]::character varying[]) AS modifiers,
    ( SELECT (m.modifier_code)::character varying AS modifier_code
           FROM idr_core.claim_line_modifier m
          WHERE (m.claim_line_id = l.claim_line_id)
          ORDER BY m.is_qualifying_modifier DESC, m.modifier_sequence, m.modifier_id
         LIMIT 1) AS qualifying_modifier,
    c.is_active AS is_active_claim
   FROM (((((((idr_core.claim c
     JOIN idr_core.claim_line l ON ((l.claim_id = c.claim_id)))
     LEFT JOIN idr_core.payer payer ON ((payer.id = c.payer_id)))
     LEFT JOIN LATERAL ( SELECT d.drg_code
           FROM idr_core.claim_drg d
          WHERE (d.claim_id = c.claim_id)
          ORDER BY d.claim_drg_id
         LIMIT 1) drg ON (true))
     LEFT JOIN idr_core.billing_provider billing ON ((billing.billing_provider_id = c.billing_provider_id)))
     LEFT JOIN LATERAL ( SELECT r.rendering_provider_npi
           FROM idr_core.rendering_provider r
          WHERE (r.claim_id = c.claim_id)
          ORDER BY r.rendering_provider_id
         LIMIT 1) rendering ON (true))
     LEFT JOIN LATERAL ( SELECT f.facility_npi,
            f.facility_name,
            f.state,
            f.zip_code
           FROM idr_core.service_facility f
          WHERE (f.claim_id = c.claim_id)
          ORDER BY f.service_facility_id
         LIMIT 1) facility ON (true))
     LEFT JOIN LATERAL ( SELECT i.insurance_group_number,
            i.employer_group_number
           FROM idr_core.insurance_coverage i
          WHERE (i.claim_id = c.claim_id)
          ORDER BY i.payer_responsibility_sequence, i.coverage_id
         LIMIT 1) coverage ON (true));

CREATE VIEW idr_core.vw_claim_selection_dashboard_data AS
 SELECT icu.idr_case_unit_id,
    icu.client_id,
    c.claim_id,
    c.is_corrected,
    c.payer_id,
    cl.claim_line_id,
    cl.service_code,
    cl.service_code_type,
    clm.modifier_code,
    tia.tax_id,
    icu.date_of_service,
    r.payment_effective_date,
    o.outcome_code,
    cos.cool_off_start_date,
    cos.cool_off_end_date,
    ig.group_name,
    tia.entity_name,
    tia.group_npi,
    icu.created_timestamp,
    c.invoice_number,
    ans.threshold_amount,
        CASE
            WHEN ((cl.service_code)::text ~ '^(00[1-9][0-9]{2}|01[0-9]{3})$'::text) THEN 'AN'::text
            WHEN ((cl.service_code)::text = ANY (ARRAY['99281'::text, '99282'::text, '99283'::text, '99284'::text, '99285'::text])) THEN 'EM'::text
            WHEN ((cl.service_code)::text = ANY (ARRAY['99221'::text, '99222'::text, '99223'::text, '99231'::text, '99232'::text, '99233'::text])) THEN 'HM'::text
            ELSE NULL::text
        END AS derived_service_line
   FROM (((((((((((idr_core.idr_case_unit icu
     JOIN idr_core.claim_line cl ON ((cl.claim_line_id = icu.edi_837_claim_line_id)))
     JOIN idr_core.claim c ON ((c.claim_id = cl.claim_id)))
     LEFT JOIN idr_core.claim_line_modifier clm ON ((clm.claim_line_id = cl.claim_line_id)))
     LEFT JOIN idr_core.claim_payment cp ON ((cp.claim_payment_id = icu.edi_835_claim_line_payment_id)))
     LEFT JOIN idr_core.remittance r ON ((r.remittance_id = cp.remittance_id)))
     LEFT JOIN idr_core.insurance_coverage ic ON ((ic.claim_id = c.claim_id)))
     LEFT JOIN idr_core.insurance_group ig ON (((ig.insurance_group_number)::text = (ic.insurance_group_number)::text)))
     LEFT JOIN idr_core.cool_off_status cos ON ((cos.idr_case_unit_id = icu.idr_case_unit_id)))
     LEFT JOIN idr_core.idr_case_outcome_lookup o ON ((o.idr_case_outcome_id = icu.current_outcome_id)))
     LEFT JOIN idr_core.tax_id_attribute tia ON (((tia.tax_id)::text = (icu.tax_id)::text)))
     LEFT JOIN idr_core.lkp_anesthesia_rate ans ON (((ans.modifier_code)::text = (clm.modifier_code)::text)));
