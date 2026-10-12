using Amazon.Runtime;
using Amazon.Runtime.CredentialManagement;
using Amazon.Runtime.Credentials;
using TH.Common.AuroraPostgreSql.Authentication;
using TH.Common.AuroraPostgreSql.Configuration;
using TH.Common.AuroraPostgreSql.Connections;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace TH.Common.AuroraPostgreSql.Extensions;

/// <summary>
/// DI registration for consuming applications.
/// </summary>
public static class ServiceCollectionExtensions
{
    /// <summary>
    /// Registers <see cref="AuroraPgOptions"/>, an IAM token provider, and an
    /// <see cref="IAuroraConnectionFactory"/> for connecting to Aurora PostgreSQL with
    /// IAM database authentication.
    /// </summary>
    /// <param name="configureOptions">Callback to populate <see cref="AuroraPgOptions"/>.</param>
    /// <param name="credentials">
    /// AWS credentials used to sign IAM auth tokens. If omitted, the default AWS credential
    /// resolution chain is used (environment variables, shared config/credentials file,
    /// ECS/EC2/EKS instance role, etc.) via <see cref="DefaultAWSCredentialsIdentityResolver"/> —
    /// the recommended approach for workloads running on AWS compute with an attached IAM role.
    /// </param>
    public static IServiceCollection AddAuroraPostgreSql(
        this IServiceCollection services,
        Action<AuroraPgOptions> configureOptions,
        AWSCredentials? credentials = null)
    {
        ArgumentNullException.ThrowIfNull(configureOptions);

        services.Configure(configureOptions);
        services.TryAddSingleton(credentials ?? ResolveCredentials(configureOptions));
        services.TryAddSingleton<IIamTokenProvider, IamTokenProvider>();
        services.TryAddSingleton<IAuroraConnectionFactory, AuroraConnectionFactory>();

        return services;
    }

    /// <summary>
    /// Credentials for signing IAM tokens: the profile named in <see cref="AuroraPgOptions.AwsProfile"/> when one is set,
    /// otherwise the default AWS credential chain.
    /// </summary>
    private static AWSCredentials ResolveCredentials(Action<AuroraPgOptions> configureOptions)
    {
        var options = new AuroraPgOptions();
        configureOptions(options);

        if (string.IsNullOrWhiteSpace(options.AwsProfile))
        {
            return DefaultAWSCredentialsIdentityResolver.GetCredentials();
        }

        var profile = options.AwsProfile.Trim();
        if (new CredentialProfileStoreChain().TryGetAWSCredentials(profile, out var credentials))
        {
            return credentials;
        }

        throw new InvalidOperationException(
            $"AWS profile '{profile}' (AuroraPostgreSql:AwsProfile) was not found or could not be used. Check the profile name in ~/.aws/credentials or ~/.aws/config " +
            "and that its credentials (access key, session token / SSO login) have not expired.");
    }
}
