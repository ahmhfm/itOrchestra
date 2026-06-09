using System.Security.Cryptography.X509Certificates;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.RateLimiting;
using Serilog;
using Serilog.Context;
using Yarp.ReverseProxy.Transforms;

// itOrchestra API Gateway (YARP) - Phase 0.3 skeleton.
// Responsibilities at the edge: TLS termination, routing, rate limiting, CORS,
// correlation-id propagation, inbound header sanitization, health endpoints.
// JWT validation (Keycloak) is wired in after Phase 0.4. No business logic here.

const string CorrelationHeader = "X-Correlation-Id";

Log.Logger = new LoggerConfiguration()
    .WriteTo.Console()
    .CreateBootstrapLogger();

try
{
    var builder = WebApplication.CreateBuilder(args);

    builder.Services.AddSerilog((services, loggerConfig) => loggerConfig
        .ReadFrom.Configuration(builder.Configuration)
        .ReadFrom.Services(services)
        .Enrich.FromLogContext());

    // Kestrel: plaintext on 8080 (kubelet probes), HTTPS on 8443 (external traffic).
    // Non-root friendly ports (>1024) so the pod stays 'restricted' PodSecurity compliant.
    builder.WebHost.ConfigureKestrel(options =>
    {
        options.AddServerHeader = false;
        options.ListenAnyIP(8080);

        var certPath = builder.Configuration["Gateway:Tls:CertPath"];
        var certPassword = builder.Configuration["Gateway:Tls:CertPassword"];
        if (!string.IsNullOrWhiteSpace(certPath) && File.Exists(certPath))
        {
            var certificate = X509CertificateLoader.LoadPkcs12FromFile(certPath, certPassword);
            options.ListenAnyIP(8443, listen => listen.UseHttps(certificate));
        }
    });

    builder.Services.AddProblemDetails();

    // CORS: strict allow-list from configuration. Never a wildcard origin.
    var corsOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];
    builder.Services.AddCors(options =>
        options.AddPolicy("default", policy =>
        {
            if (corsOrigins.Length > 0)
            {
                policy.WithOrigins(corsOrigins)
                    .AllowAnyHeader()
                    .AllowAnyMethod()
                    .AllowCredentials();
            }
        }));

    // Edge rate limiting. We partition by client IP. Admin-console paths (Keycloak console +
    // OIDC endpoints, Grafana dashboard) fan out into many static-asset requests on first
    // load, so they get a more generous bucket than the default edge limit.
    builder.Services.AddRateLimiter(options =>
    {
        options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
        options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(context =>
        {
            var (bucket, limit) = IsConsolePath(context.Request.Path) ? ("console", 300) : ("edge", 60);
            return RateLimitPartition.GetFixedWindowLimiter($"{bucket}:{ClientKey(context)}", _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = limit,
                Window = TimeSpan.FromMinutes(1),
                QueueLimit = 0
            });
        });
        options.AddPolicy("anonymous", context =>
            RateLimitPartition.GetFixedWindowLimiter(ClientKey(context), _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 60,
                Window = TimeSpan.FromMinutes(1),
                QueueLimit = 0
            }));
        options.AddPolicy("sensitive", context =>
            RateLimitPartition.GetFixedWindowLimiter(ClientKey(context), _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 10,
                Window = TimeSpan.FromMinutes(1),
                QueueLimit = 0
            }));
    });

    // Reverse proxy: routes/clusters are declarative (config-driven). Empty in the 0.3
    // skeleton; service routes are added as each microservice is onboarded.
    builder.Services.AddReverseProxy()
        .LoadFromConfig(builder.Configuration.GetSection("ReverseProxy"))
        .AddTransforms(context =>
        {
            context.AddRequestTransform(transform =>
            {
                if (transform.HttpContext.Items[CorrelationHeader] is string correlationId
                    && !string.IsNullOrEmpty(correlationId))
                {
                    transform.ProxyRequest.Headers.Remove(CorrelationHeader);
                    transform.ProxyRequest.Headers.TryAddWithoutValidation(CorrelationHeader, correlationId);
                }
                return ValueTask.CompletedTask;
            });
            context.AddResponseTransform(transform =>
            {
                transform.HttpContext.Response.Headers["Strict-Transport-Security"] =
                    "max-age=63072000; includeSubDomains";
                return ValueTask.CompletedTask;
            });
        });

    builder.Services.Configure<ForwardedHeadersOptions>(options =>
        options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto);

    var app = builder.Build();

    app.UseForwardedHeaders();

    // Correlation id + inbound header sanitization. Runs first so every log line and
    // every proxied request carries the same id.
    app.Use(async (context, next) =>
    {
        var correlationId = context.Request.Headers[CorrelationHeader].FirstOrDefault();
        if (string.IsNullOrWhiteSpace(correlationId))
        {
            correlationId = Guid.NewGuid().ToString("N");
        }

        context.Items[CorrelationHeader] = correlationId;
        context.Response.Headers[CorrelationHeader] = correlationId;

        var spoofable = context.Request.Headers.Keys
            .Where(header => header.StartsWith("X-User-", StringComparison.OrdinalIgnoreCase)
                || header.Equals("X-Forwarded-User", StringComparison.OrdinalIgnoreCase))
            .ToArray();
        foreach (var header in spoofable)
        {
            context.Request.Headers.Remove(header);
        }

        using (LogContext.PushProperty("CorrelationId", correlationId))
        {
            await next();
        }
    });

    app.UseSerilogRequestLogging();
    app.UseExceptionHandler();
    app.UseStatusCodePages();
    app.UseCors("default");
    app.UseRateLimiter();

    app.MapGet("/healthz", () => Results.Text("ok")).DisableRateLimiting();
    app.MapGet("/readyz", () => Results.Text("ready")).DisableRateLimiting();
    app.MapGet("/", () => Results.Ok(new
    {
        service = "itorchestra-gateway",
        status = "ok",
        version = GatewayVersion()
    }));

    app.MapReverseProxy();

    app.Run();
}
catch (Exception ex)
{
    Log.Fatal(ex, "itOrchestra gateway terminated unexpectedly");
}
finally
{
    Log.CloseAndFlush();
}

static string ClientKey(HttpContext context) =>
    context.Connection.RemoteIpAddress?.ToString() ?? "unknown";

static bool IsConsolePath(PathString path) =>
    path.StartsWithSegments("/realms", StringComparison.OrdinalIgnoreCase)
    || path.StartsWithSegments("/resources", StringComparison.OrdinalIgnoreCase)
    || path.StartsWithSegments("/admin", StringComparison.OrdinalIgnoreCase)
    || path.StartsWithSegments("/js", StringComparison.OrdinalIgnoreCase)
    || path.StartsWithSegments("/grafana", StringComparison.OrdinalIgnoreCase);

static string GatewayVersion() =>
    typeof(Program).Assembly.GetName().Version?.ToString() ?? "0.0.0";

// Exposes the implicit top-level Program type so the test project's WebApplicationFactory<Program>
// can host the gateway in-process (Phase 0.11 integration tests). No runtime effect.
public partial class Program { }
