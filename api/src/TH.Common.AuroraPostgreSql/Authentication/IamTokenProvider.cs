using Amazon;
using Amazon.RDS.Util;
using Amazon.Runtime;
using TH.Common.AuroraPostgreSql.Configuration;
using Microsoft.Extensions.Options;

namespace TH.Common.AuroraPostgreSql.Authentication;

/// <summary>
/// Generates AWS RDS IAM authentication tokens and caches them for their ~15 minute lifetime,
/// so callers don't re-sign a new token on every connection attempt.
/// </summary>
public class IamTokenProvider : IIamTokenProvider
{
    // RDS/Aurora IAM auth tokens are valid for 15 minutes from generation.
    private static readonly TimeSpan TokenLifetime = TimeSpan.FromMinutes(15);

    private readonly AuroraPgOptions _options;
    private readonly AWSCredentials _credentials;
    private readonly SemaphoreSlim _refreshLock = new(1, 1);

    private string? _cachedToken;
    private DateTimeOffset _cachedTokenExpiresAt = DateTimeOffset.MinValue;

    public IamTokenProvider(IOptions<AuroraPgOptions> options, AWSCredentials credentials)
    {
        _options = options.Value;
        _credentials = credentials;
    }

    public async Task<string> GetAuthTokenAsync(CancellationToken cancellationToken = default)
    {
        if (TryGetCachedToken(out var cached))
        {
            return cached;
        }

        await _refreshLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // Re-check: another caller may have refreshed the token while we waited for the lock.
            if (TryGetCachedToken(out cached))
            {
                return cached;
            }

            var region = RegionEndpoint.GetBySystemName(_options.Region);

            var token = RDSAuthTokenGenerator.GenerateAuthToken(
                _credentials,
                region,
                _options.Host,
                _options.Port,
                _options.DbUser);

            _cachedToken = token;
            _cachedTokenExpiresAt = DateTimeOffset.UtcNow
                .Add(TokenLifetime)
                .AddSeconds(-Math.Max(_options.TokenExpiryBufferSeconds, 0));

            return token;
        }
        finally
        {
            _refreshLock.Release();
        }
    }

    private bool TryGetCachedToken(out string token)
    {
        if (_cachedToken is not null && DateTimeOffset.UtcNow < _cachedTokenExpiresAt)
        {
            token = _cachedToken;
            return true;
        }

        token = string.Empty;
        return false;
    }
}
