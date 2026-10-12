using Dapper;
using Npgsql;
using TH.IDR.ClaimSelection.Api.Database;

namespace TH.IDR.ClaimSelection.Api;

public sealed class NewLine
{
    public string? ServiceLine { get; set; }
    public string? ServiceCode { get; set; }          // 837 code
    public string? PaidServiceCode { get; set; }      // 835 code (defaults to the 837 code)
    public string? DateOfService { get; set; }
    public string? DateOfService835 { get; set; }     // blank = same as the 837 date of service
    public decimal? Units { get; set; }
    public decimal? ChargeAmount { get; set; }
    public decimal? PaidAmount { get; set; }
    public decimal? AllowedAmount { get; set; }
    public decimal? OfferAmount { get; set; }
    public string? RevenueCode837 { get; set; }       // institutional: line revenue code on the 837
    public string? RevenueCode835 { get; set; }       // institutional: revenue code on the 835 line
    public string? Modifiers837 { get; set; }         // comma separated
    public string? Modifiers835 { get; set; }
}

public sealed class NewRecordRequest
{
    public string? ClientId { get; set; }
    public string ClaimType { get; set; } = "P";      // P = professional (837P), I = institutional (837I)
    public string? PatientControlNumber { get; set; }
    public string? PayerId { get; set; }
    public string? RemitPayerId { get; set; }         // blank = same as the 837 payer
    public string? InsuranceGroup { get; set; }
    public bool Include837 { get; set; } = true;
    public bool Include835 { get; set; } = true;     // false = only the 837 (a corrected / void claim sent after the remit)
    public bool RegisterTin { get; set; } = true;
    public string? InvoiceNumber { get; set; }
    public string? FrequencyCode { get; set; } = "1";
    public bool IsVoid { get; set; }
    public string? Tin { get; set; }
    public string? BillingNpi { get; set; }
    public string? RenderingNpi { get; set; }
    public string? FacilityNpi { get; set; }
    public string? FacilityName { get; set; }
    public string? FacilityState { get; set; }
    public string? RemitPaymentDate { get; set; }
    public string? RarcCodes { get; set; }
    public string? Drg837 { get; set; }               // institutional: claim DRG on the 837
    public string? Drg835 { get; set; }               // institutional: claim DRG on the 835 (CLP11)
    public List<NewLine> Lines { get; set; } = [];
}

public static class RecordWriter
{
    /// <summary>Writes the 837 / 835 into the domain tables, as Data Ingestion would.</summary>
    public static async Task<object> InsertAsync(IDbConnectionFactory ds, NewRecordRequest r)
    {
        var client = Required(r.ClientId, "Client");
        var pcn = Required(r.PatientControlNumber, "Patient control number").Trim();
        var payer = Required(r.PayerId, "Payer ID").Trim();
        if (r.Lines.Count == 0)
        {
            throw new ArgumentException("Add at least one service line.");
        }

        var claimType = string.Equals(r.ClaimType, "I", StringComparison.OrdinalIgnoreCase) ? "837I" : "837P";
        DateOnly? remitDate = DateOnly.TryParse(r.RemitPaymentDate, out var rd) ? rd : null;   // blank = missing data (exception 202)
        var stamp = DateTime.UtcNow.ToString("yyyyMMddHHmmss");

        await using var connection = await ds.OpenConnectionAsync();
        await using var tx = await connection.BeginTransactionAsync();

        // Case creation needs an active criteria version for the client (Claim Selection criteria version 1).
        await connection.ExecuteAsync(
            """
            INSERT INTO idr_core.config_criteria_version (client_id, version_number, is_active_version, approved_by)
            SELECT @client, 1, true, 'demo-ui'
            WHERE NOT EXISTS (SELECT 1 FROM idr_core.config_criteria_version WHERE client_id = @client AND is_active_version)
            ON CONFLICT (client_id, version_number) DO UPDATE SET is_active_version = true
            """, new { client }, tx);

        long? claimId = null;
        var version = 1;
        if (r.Include837)
        {
            var tin = Blank(r.Tin);   // blank = missing Tax ID (eligibility exception)
            var payerKey = await PayerKeyAsync(connection, tx, payer);
            var previous = (await connection.QueryAsync<(long Id, int Version, long? Root)>(
                "SELECT claim_id, version_sequence, root_claim_id FROM idr_core.claim WHERE client_id = @client AND patient_account_number = @pcn ORDER BY version_sequence",
                new { client, pcn }, tx)).ToList();
            long? root = previous.Count == 0 ? null : previous[0].Root ?? previous[0].Id;
            version = previous.Count == 0 ? 1 : previous.Max(p => p.Version) + 1;
            if (previous.Count > 0)
            {
                await connection.ExecuteAsync(
                    "UPDATE idr_core.claim SET latest_valid_version_flag = false WHERE client_id = @client AND patient_account_number = @pcn",
                    new { client, pcn }, tx);
            }

            var billingId = await connection.ExecuteScalarAsync<long>(
                """
                INSERT INTO idr_core.billing_provider (provider_name, billing_provider_npi, provider_tin)
                VALUES (@name, @npi, @tin) RETURNING billing_provider_id
                """, new { name = "Demo billing provider", npi = Blank(r.BillingNpi), tin }, tx);

            var frequency = string.IsNullOrWhiteSpace(r.FrequencyCode) ? "1" : r.FrequencyCode.Trim();
            claimId = await connection.ExecuteScalarAsync<long>(
                """
                INSERT INTO idr_core.claim
                (client_id, claim_type, patient_account_number, invoice_number, total_charge_amount, facility_type_code, frequency_code,
                 is_corrected, is_void, latest_valid_version_flag, billing_provider_id, payer_id, provider_tin,
                 original_claim_id, root_claim_id, version_sequence, source_received_at_utc, is_active)
                VALUES (@client, @claimType, @pcn, @invoice, @charge, @pos, @frequency, @corrected, @isVoid, true, @billingId, @payerKey, @tin,
                        @root, @root, @version, now(), true)
                RETURNING claim_id
                """,
                new
                {
                    client, claimType, pcn, invoice = string.IsNullOrWhiteSpace(r.InvoiceNumber) ? $"INV-{pcn}-{version}" : r.InvoiceNumber,
                    charge = r.Lines.Sum(l => l.ChargeAmount ?? 0m), pos = claimType == "837I" ? "21" : "23", frequency,
                    corrected = frequency == "7", isVoid = r.IsVoid, billingId, payerKey, tin, root, version
                }, tx);

            await connection.ExecuteAsync(
                "INSERT INTO idr_core.insurance_coverage (claim_id, payer_id, insurance_group_number, payer_responsibility_sequence) VALUES (@claimId, @payerKey, @group, 'P')",
                new { claimId, payerKey, group = Blank(r.InsuranceGroup) }, tx);
            if (Blank(r.RenderingNpi) is not null)
            {
                await connection.ExecuteAsync(
                    "INSERT INTO idr_core.rendering_provider (claim_id, rendering_provider_npi) VALUES (@claimId, @npi)",
                    new { claimId, npi = Blank(r.RenderingNpi) }, tx);
            }

            if (Blank(r.Drg837) is not null)
            {
                await connection.ExecuteAsync(
                    "INSERT INTO idr_core.claim_drg (claim_id, drg_code, drg_type, is_inpatient_indicator) VALUES (@claimId, @drg, 'MS-DRG', true)",
                    new { claimId, drg = Blank(r.Drg837) }, tx);
            }

            await connection.ExecuteAsync(
                "INSERT INTO idr_core.service_facility (claim_id, facility_name, facility_npi, state) VALUES (@claimId, @name, @npi, @state)",
                new { claimId, name = Blank(r.FacilityName), npi = Blank(r.FacilityNpi), state = Blank(r.FacilityState) }, tx);

            var number = 0;
            foreach (var line in r.Lines)
            {
                number++;
                var lineId = await connection.ExecuteScalarAsync<long>(
                    """
                    INSERT INTO idr_core.claim_line
                    (claim_id, line_number, claim_type, service_code_type, service_code, service_line, revenue_code, line_charge_amount, unit_type, units, date_of_service)
                    VALUES (@claimId, @number, @claimType, 'HC', @code, @serviceLine, @revenue, @charge, 'UN', @units, @dos)
                    RETURNING claim_line_id
                    """,
                    new
                    {
                        claimId, number, claimType, code = Blank(line.ServiceCode), serviceLine = Blank(line.ServiceLine), revenue = Blank(line.RevenueCode837),
                        charge = line.ChargeAmount, units = line.Units ?? 1m, dos = ParseOptional(line.DateOfService)
                    }, tx);
                var seq = 0;
                foreach (var modifier in Split(line.Modifiers837))
                {
                    seq++;
                    await connection.ExecuteAsync(
                        "INSERT INTO idr_core.claim_line_modifier (claim_line_id, modifier_code, modifier_sequence, is_qualifying_modifier) VALUES (@lineId, @modifier, @seq, @first)",
                        new { lineId, seq, modifier, first = seq == 1 }, tx);
                }

                if (r.RegisterTin && tin is not null && !string.IsNullOrWhiteSpace(line.ServiceLine))
                {
                    await connection.ExecuteAsync(
                        """
                        INSERT INTO idr_core.config_tax_id_entity_mapping (client_id, tax_id, service_line, entity_legal_name)
                        VALUES (@client, @tin, @serviceLine, @name) ON CONFLICT (client_id, tax_id, service_line) DO NOTHING
                        """,
                        new { client, tin, serviceLine = line.ServiceLine, name = "Demo entity " + tin }, tx);
                }
            }
        }

        if (!r.Include835)
        {
            await tx.CommitAsync();
            return new { client_id = client, pcn, claim_id = claimId, claim_version = r.Include837 ? version : (int?)null, remit_line_ids = new List<long>() };
        }

        var remitPayerKey = await PayerKeyAsync(connection, tx, Blank(r.RemitPayerId) ?? payer);
        var remitId = await connection.ExecuteScalarAsync<long>(
            """
            INSERT INTO idr_core.remittance
            (client_id, transaction_control_number, total_payment_amount, credit_debit_flag, payment_method, payment_effective_date,
             production_date, trace_number, payer_id, payee_provider_id, source_received_at_utc)
            VALUES (@client, @trx, @total, 'C', 'ACH', @remitDate, @remitDate, @trace, @payerKey, 'DEMO-PAYEE', now())
            RETURNING remittance_id
            """,
            new { client, trx = $"TRX-{pcn}-{stamp}", total = r.Lines.Sum(l => l.PaidAmount ?? 0m), remitDate, trace = $"TRACE-{pcn}-{stamp}", payerKey = remitPayerKey }, tx);

        var paymentId = await connection.ExecuteScalarAsync<long>(
            """
            INSERT INTO idr_core.claim_payment
            (remittance_id, patient_control_number, claim_status_code, claim_charge_amount, claim_payment_amount,
             patient_responsibility_amount, claim_filing_indicator_code, payer_claim_control_number, facility_type_code, claim_frequency_code,
             insurance_group_number, drg_code)
            VALUES (@remitId, @pcn, '1', @charge, @paid, 0, 'CI', @pccn, @pos, '1', @group, @drg)
            RETURNING claim_payment_id
            """,
            new
            {
                remitId, pcn, charge = r.Lines.Sum(l => l.ChargeAmount ?? 0m), paid = r.Lines.Sum(l => l.PaidAmount ?? 0m),
                pccn = $"PCCN-{pcn}-{stamp}", pos = claimType == "837I" ? "21" : "23", group = Blank(r.InsuranceGroup), drg = Blank(r.Drg835)
            }, tx);

        var remitLineIds = new List<long>();
        var n = 0;
        foreach (var line in r.Lines)
        {
            n++;
            var lineId = await connection.ExecuteScalarAsync<long>(
                """
                INSERT INTO idr_core.claim_line_payment
                (claim_payment_id, line_number, service_code_type, paid_service_code, service_line, revenue_code, line_charge_amount,
                 line_paid_amount, units, date_of_service, line_item_control_number, allowed_amount, provider_offer_amount)
                VALUES (@paymentId, @n, 'HC', @code, @serviceLine, @revenue, @charge, @paid, @units, @dos, @lic, @allowed, @offer)
                RETURNING claim_line_payment_id
                """,
                new
                {
                    paymentId, n, code = Blank(line.PaidServiceCode) ?? Blank(line.ServiceCode), serviceLine = Blank(line.ServiceLine), revenue = Blank(line.RevenueCode835),
                    charge = line.ChargeAmount, paid = line.PaidAmount, units = line.Units ?? 1m,
                    dos = ParseOptional(Blank(line.DateOfService835) ?? line.DateOfService), lic = $"L-{pcn}-{n}",
                    allowed = line.AllowedAmount, offer = line.OfferAmount
                }, tx);
            remitLineIds.Add(lineId);
            var seq = 0;
            foreach (var modifier in Split(line.Modifiers835))
            {
                seq++;
                await connection.ExecuteAsync(
                    "INSERT INTO idr_core.claim_line_payment_modifier (claim_line_payment_id, modifier_code, modifier_sequence) VALUES (@lineId, @modifier, @seq)",
                    new { lineId, seq, modifier }, tx);
            }

            foreach (var rarc in Split(r.RarcCodes).Distinct())
            {
                await connection.ExecuteAsync(
                    "INSERT INTO idr_core.claim_line_remark_code (claim_line_payment_id, remark_code_qualifier, remark_code) VALUES (@lineId, 'HE', @rarc)",
                    new { lineId, rarc }, tx);
            }
        }

        await tx.CommitAsync();
        return new { client_id = client, pcn, claim_id = claimId, claim_version = r.Include837 ? version : (int?)null, remit_line_ids = remitLineIds };
    }

    /// <summary>idr_core.payer holds one row per business payer id (unique index); returns its technical key.</summary>
    private static async Task<long> PayerKeyAsync(NpgsqlConnection connection, NpgsqlTransaction tx, string payerId)
    {
        var id = await connection.ExecuteScalarAsync<long?>("SELECT id FROM idr_core.payer WHERE payer_id = @payerId", new { payerId }, tx);
        return id ?? await connection.ExecuteScalarAsync<long>(
            "INSERT INTO idr_core.payer (payer_id, payer_name) VALUES (@payerId, @payerId) RETURNING id", new { payerId }, tx);
    }

    private static string Required(string? value, string label) =>
        string.IsNullOrWhiteSpace(value) ? throw new ArgumentException($"{label} is required.") : value;

    private static string? Blank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static IEnumerable<string> Split(string? value) =>
        (value ?? "").Split([',', ';', ' '], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private static DateOnly? ParseOptional(string? value) => DateOnly.TryParse(value, out var d) ? d : null;
}
