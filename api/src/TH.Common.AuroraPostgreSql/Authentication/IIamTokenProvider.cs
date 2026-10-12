namespace TH.Common.AuroraPostgreSql.Authentication;

/// <summary>
/// Produces short-lived IAM authentication tokens used as the PostgreSQL connection password
/// when connecting to an Aurora PostgreSQL cluster with IAM database authentication enabled.
/// </summary>
public interface IIamTokenProvider
{
    /// <summary>
    /// Returns a valid IAM auth token, generating and caching a new one if none is cached
    /// or the cached token is close to expiring.
    /// </summary>
    Task<string> GetAuthTokenAsync(CancellationToken cancellationToken = default);
}
