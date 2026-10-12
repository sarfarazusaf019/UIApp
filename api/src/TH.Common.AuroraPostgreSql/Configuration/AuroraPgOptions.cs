namespace TH.Common.AuroraPostgreSql.Configuration;

/// <summary>
/// Configuration for connecting to an AWS Aurora PostgreSQL cluster using IAM database authentication.
/// </summary>
public class AuroraPgOptions
{
    /// <summary>
    /// Configuration section name to bind from (e.g. appsettings.json: "AuroraPostgreSql").
    /// </summary>
    public const string SectionName = "AuroraPostgreSql";

    /// <summary>Cluster/instance endpoint hostname (writer or reader endpoint).</summary>
    public string Host { get; set; } = string.Empty;

    /// <summary>PostgreSQL port. Defaults to 5432.</summary>
    public int Port { get; set; } = 5432;

    /// <summary>Target database name.</summary>
    public string Database { get; set; } = string.Empty;

    /// <summary>
    /// Database user. Must be a PostgreSQL role granted the rds_iam role
    /// (see AWS docs: "Creating a database account using IAM authentication").
    /// </summary>
    public string DbUser { get; set; } = string.Empty;

    /// <summary>AWS region the cluster lives in, e.g. "us-east-1".</summary>
    public string Region { get; set; } = string.Empty;

    /// <summary>
    /// When true (default), authenticate using a short-lived IAM auth token instead of a static password.
    /// </summary>
    public bool UseIamAuthentication { get; set; } = true;

    /// <summary>
    /// Optional name of the AWS profile (shared credentials file, config file or SSO / "aws login" profile) used to sign the IAM token,
    /// for example for local testing. Empty = the default AWS credential chain (environment variables, the "default" profile, container or
    /// instance role), which is what a deployed service should use.
    /// </summary>
    public string? AwsProfile { get; set; }

    /// <summary>Whether to require SSL/TLS on the connection. Aurora requires this for IAM auth.</summary>
    public bool UseSsl { get; set; } = true;

    /// <summary>Npgsql connection open timeout, in seconds.</summary>
    public int ConnectionTimeoutSeconds { get; set; } = 15;

    /// <summary>Default command timeout, in seconds.</summary>
    public int CommandTimeoutSeconds { get; set; } = 30;

    /// <summary>Number of retry attempts when opening a connection fails transiently.</summary>
    public int MaxRetryAttempts { get; set; } = 3;

    /// <summary>Base delay for exponential backoff between connection retry attempts, in milliseconds.</summary>
    public int RetryBaseDelayMilliseconds { get; set; } = 200;

    /// <summary>
    /// Seconds subtracted from the IAM token's real 15-minute lifetime before it is considered
    /// expired, so a cached token is never handed out right before it stops being valid.
    /// </summary>
    public int TokenExpiryBufferSeconds { get; set; } = 60;
}
