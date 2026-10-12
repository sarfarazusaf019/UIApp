using TH.Common.AuroraPostgreSql.Authentication;
using TH.Common.AuroraPostgreSql.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Npgsql;
using Polly;
using Polly.Retry;

namespace TH.Common.AuroraPostgreSql.Connections;

/// <inheritdoc cref="IAuroraConnectionFactory" />
public class AuroraConnectionFactory : IAuroraConnectionFactory
{
    private readonly AuroraPgOptions _options;
    private readonly IIamTokenProvider _tokenProvider;
    private readonly ILogger<AuroraConnectionFactory> _logger;
    private readonly AsyncRetryPolicy _retryPolicy;

    public AuroraConnectionFactory(
        IOptions<AuroraPgOptions> options,
        IIamTokenProvider tokenProvider,
        ILogger<AuroraConnectionFactory> logger)
    {
        _options = options.Value;
        _tokenProvider = tokenProvider;
        _logger = logger;

        // A stale IAM token or a transient network blip both surface as NpgsqlException when
        // opening the connection; retrying re-enters BuildConnectionStringAsync, so a rejected
        // token is refreshed (the cache is only reused while still valid) on the next attempt.
        _retryPolicy = Policy
            .Handle<NpgsqlException>()
            .WaitAndRetryAsync(
                _options.MaxRetryAttempts,
                attempt => TimeSpan.FromMilliseconds(_options.RetryBaseDelayMilliseconds * Math.Pow(2, attempt - 1)),
                onRetry: (exception, delay, attempt, _) =>
                {
                    _logger.LogWarning(
                        exception,
                        "Aurora PostgreSQL connection attempt {Attempt}/{MaxAttempts} failed. Retrying in {Delay}.",
                        attempt,
                        _options.MaxRetryAttempts,
                        delay);
                });
    }

    public async Task<NpgsqlConnection> CreateOpenConnectionAsync(CancellationToken cancellationToken = default)
    {
        return await _retryPolicy.ExecuteAsync(async ct =>
        {
            var connectionString = await BuildConnectionStringAsync(ct).ConfigureAwait(false);
            var connection = new NpgsqlConnection(connectionString);

            try
            {
                await connection.OpenAsync(ct).ConfigureAwait(false);
                return connection;
            }
            catch
            {
                await connection.DisposeAsync().ConfigureAwait(false);
                throw;
            }
        }, cancellationToken).ConfigureAwait(false);
    }

    private async Task<string> BuildConnectionStringAsync(CancellationToken cancellationToken)
    {
        var builder = new NpgsqlConnectionStringBuilder
        {
            Host = _options.Host,
            Port = _options.Port,
            Database = _options.Database,
            Username = _options.DbUser,
            Timeout = _options.ConnectionTimeoutSeconds,
            CommandTimeout = _options.CommandTimeoutSeconds,
            SslMode = _options.UseSsl ? SslMode.Require : SslMode.Disable,
            // Aurora authenticates with the IAM token; without this Npgsql probes for the Kerberos library (libgssapi_krb5) on Linux and prints an error when it is missing.
            GssEncryptionMode = GssEncryptionMode.Disable,
        };

        if (_options.UseIamAuthentication)
        {
            // IAM auth tokens are used as the connection password; Aurora validates it against
            // the caller's IAM identity and the target DB user's rds_iam grant.
            builder.Password = await _tokenProvider.GetAuthTokenAsync(cancellationToken).ConfigureAwait(false);
        }

        return builder.ConnectionString;
    }
}
