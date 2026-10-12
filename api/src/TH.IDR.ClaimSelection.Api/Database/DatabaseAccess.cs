using Amazon.Runtime;
using Npgsql;
using TH.Common.AuroraPostgreSql.Configuration;
using TH.Common.AuroraPostgreSql.Connections;
using TH.Common.AuroraPostgreSql.Extensions;

namespace TH.IDR.ClaimSelection.Api.Database;

public enum DatabaseAuthenticationMode
{
    /// <summary>AWS IAM database authentication through TH.Common.AuroraPostgreSql (section "AuroraPostgreSql").</summary>
    Iam,

    /// <summary>Plain Npgsql connection string (ConnectionStrings:ClaimSelection), for local testing.</summary>
    ConnectionString
}

/// <summary>Configuration section "Database": which of the two ways to reach the database is used.</summary>
public sealed class DatabaseOptions
{
    public const string SectionName = "Database";

    public DatabaseAuthenticationMode AuthenticationMode { get; set; } = DatabaseAuthenticationMode.Iam;
}

/// <summary>The only way the API obtains a database connection. The caller owns the returned connection and disposes it.</summary>
public interface IDbConnectionFactory
{
    ValueTask<NpgsqlConnection> OpenConnectionAsync(CancellationToken cancellationToken = default);
}

/// <summary>Connection string mode: pooled <see cref="NpgsqlDataSource"/> (user name and password in the connection string).</summary>
public sealed class ConnectionStringDbConnectionFactory(NpgsqlDataSource dataSource) : IDbConnectionFactory
{
    public ValueTask<NpgsqlConnection> OpenConnectionAsync(CancellationToken cancellationToken = default) =>
        dataSource.OpenConnectionAsync(cancellationToken);
}

/// <summary>IAM mode: the Aurora library signs a short-lived token with the IAM role and opens the connection (with retry).</summary>
public sealed class AuroraIamDbConnectionFactory(IAuroraConnectionFactory auroraConnectionFactory) : IDbConnectionFactory
{
    public async ValueTask<NpgsqlConnection> OpenConnectionAsync(CancellationToken cancellationToken = default) =>
        await auroraConnectionFactory.CreateOpenConnectionAsync(cancellationToken);
}

public static class DatabaseAccessExtensions
{
    /// <summary>
    /// Database:AuthenticationMode = Iam (default): AWS IAM authentication, settings in section AuroraPostgreSql
    /// (Host, Database, DbUser, Region, optional AwsProfile for local testing).
    /// Database:AuthenticationMode = ConnectionString: ConnectionStrings:ClaimSelection, for local testing.
    /// </summary>
    public static IServiceCollection AddApiDatabase(this IServiceCollection services, IConfiguration configuration, AWSCredentials? credentials = null)
    {
        var database = configuration.GetSection(DatabaseOptions.SectionName).Get<DatabaseOptions>() ?? new DatabaseOptions();

        if (database.AuthenticationMode == DatabaseAuthenticationMode.ConnectionString)
        {
            var connectionString = configuration.GetConnectionString("ClaimSelection");
            if (string.IsNullOrWhiteSpace(connectionString) || connectionString.Contains('<'))
            {
                throw new InvalidOperationException(
                    "Database:AuthenticationMode is ConnectionString but ConnectionStrings:ClaimSelection is empty or still a placeholder.");
            }

            // GSS / Kerberos is not used: switching it off stops Npgsql from probing for libgssapi_krb5 on Linux.
            var builder = new NpgsqlConnectionStringBuilder(connectionString) { GssEncryptionMode = GssEncryptionMode.Disable };
            services.AddSingleton(NpgsqlDataSource.Create(builder.ConnectionString));
            services.AddSingleton<IDbConnectionFactory, ConnectionStringDbConnectionFactory>();
            return services;
        }

        var aurora = configuration.GetSection(AuroraPgOptions.SectionName).Get<AuroraPgOptions>() ?? new AuroraPgOptions();
        var missing = new[]
            {
                (nameof(aurora.Host), aurora.Host), (nameof(aurora.Database), aurora.Database),
                (nameof(aurora.DbUser), aurora.DbUser), (nameof(aurora.Region), aurora.Region)
            }
            .Where(x => string.IsNullOrWhiteSpace(x.Item2) || x.Item2.Contains('<'))
            .Select(x => x.Item1)
            .ToList();
        if (missing.Count > 0)
        {
            throw new InvalidOperationException(
                $"Database:AuthenticationMode is Iam but section {AuroraPgOptions.SectionName} is incomplete: {string.Join(", ", missing)}. " +
                "Set them, or use Database:AuthenticationMode = ConnectionString for local testing.");
        }

        services.AddAuroraPostgreSql(o =>
        {
            configuration.GetSection(AuroraPgOptions.SectionName).Bind(o);
            o.UseIamAuthentication = true;
        }, credentials);
        services.AddSingleton<IDbConnectionFactory, AuroraIamDbConnectionFactory>();
        return services;
    }
}

/// <summary>Start-up check that the database has the tables and views the API reads, so a database that is not set up is reported clearly.</summary>
public static class SchemaCheck
{
    private static readonly string[] Required =
    [
        "claim", "claim_line", "claim_line_payment", "claim_payment", "remittance", "payer",
        "config_client", "config_service_line", "config_payer_insurance_group", "config_exception_reason", "config_exclusion_reason",
        "idr_case_unit", "idr_case_outcome_lookup", "idr_case_financial_summary", "idr_case_status_history", "idr_case_claim_version",
        "idr_claim_remit_match", "idr_claim_selection_exception", "idr_claim_selection_evaluation", "idr_claim_selection_rule_result",
        "idr_cool_off_status", "idr_preliminary_batch", "idr_preliminary_batch_case_unit", "job_run_log", "job_case_log",
        "vw_835_claim_selection_source", "vw_837_claim_selection_source"
    ];

    public static async Task EnsureAsync(IDbConnectionFactory db, CancellationToken ct = default)
    {
        await using var connection = await db.OpenConnectionAsync(ct);
        await using var command = new NpgsqlCommand("SELECT n FROM unnest(@names) AS n WHERE to_regclass('idr_core.' || n) IS NULL ORDER BY n", connection);
        command.Parameters.AddWithValue("names", Required);
        var missing = new List<string>();
        await using var reader = await command.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            missing.Add(reader.GetString(0));
        }

        if (missing.Count > 0)
        {
            throw new InvalidOperationException("The database schema is out of date. Missing in schema idr_core: " + string.Join(", ", missing) + ". Apply the database schema scripts first.");
        }
    }
}
