using Npgsql;

namespace TH.Common.AuroraPostgreSql.Connections;

/// <summary>
/// Creates opened <see cref="NpgsqlConnection"/> instances to an Aurora PostgreSQL cluster,
/// authenticating with an IAM token when IAM authentication is enabled in configuration.
/// </summary>
public interface IAuroraConnectionFactory
{
    /// <summary>
    /// Builds a connection string (fetching a fresh IAM token if needed), opens the connection,
    /// and returns it. Transient failures are retried according to configured retry settings.
    /// The caller owns the returned connection and must dispose of it.
    /// </summary>
    Task<NpgsqlConnection> CreateOpenConnectionAsync(CancellationToken cancellationToken = default);
}
