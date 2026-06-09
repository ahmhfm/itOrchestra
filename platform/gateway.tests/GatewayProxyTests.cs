using System.Net;
using DotNet.Testcontainers.Builders;
using DotNet.Testcontainers.Containers;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace ItOrchestra.Gateway.Tests;

// Integration tests for the YARP gateway. A REAL upstream runs in a Testcontainers-managed
// container (traefik/whoami, which echoes the request it receives); the gateway is hosted
// in-process via WebApplicationFactory and configured (in-memory) to proxy /proxy/* to that
// container. This proves the edge behaviour end to end: routing, correlation-id propagation, and
// spoofable-header stripping - against a live backend rather than a mock.
public sealed class GatewayFixture : IAsyncLifetime
{
    // traefik/whoami is a shell-less, scratch-based image, so an *internal* wait strategy (which
    // execs inside the container) would hang. We wait on the *external* mapped port instead - a
    // plain host-side TCP connect that needs nothing inside the container.
    private readonly IContainer _upstream = new ContainerBuilder("traefik/whoami:latest")
        .WithPortBinding(80, assignRandomHostPort: true)
        .WithWaitStrategy(Wait.ForUnixContainer().UntilExternalTcpPortIsAvailable(80))
        .Build();

    private WebApplicationFactory<Program>? _factory;

    public HttpClient Client { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        await _upstream.StartAsync();
        var upstreamPort = _upstream.GetMappedPublicPort(80);

        _factory = new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, config) =>
                config.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["ReverseProxy:Routes:test:ClusterId"] = "upstream",
                    ["ReverseProxy:Routes:test:Match:Path"] = "/proxy/{**catch-all}",
                    ["ReverseProxy:Clusters:upstream:Destinations:d1:Address"] =
                        $"http://localhost:{upstreamPort}/",
                })));

        Client = _factory.CreateClient();
    }

    public async Task DisposeAsync()
    {
        Client?.Dispose();
        if (_factory is not null)
        {
            await _factory.DisposeAsync();
        }

        await _upstream.DisposeAsync();
    }
}

public sealed class GatewayProxyTests(GatewayFixture fixture) : IClassFixture<GatewayFixture>
{
    private readonly HttpClient _client = fixture.Client;

    [Fact]
    public async Task Healthz_returns_ok()
    {
        var response = await _client.GetAsync("/healthz");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("ok", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Root_returns_service_identity_with_correlation_header()
    {
        var response = await _client.GetAsync("/");

        response.EnsureSuccessStatusCode();
        Assert.True(response.Headers.Contains("X-Correlation-Id"));
        Assert.Contains("itorchestra-gateway", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Proxies_request_to_the_real_upstream_container()
    {
        var response = await _client.GetAsync("/proxy/whoami");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        // whoami's body lists "Hostname:", "GET /proxy/whoami", and the received headers.
        Assert.Contains("hostname", (await response.Content.ReadAsStringAsync()).ToLowerInvariant());
    }

    [Fact]
    public async Task Strips_spoofable_user_headers_before_proxying()
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "/proxy/echo");
        request.Headers.TryAddWithoutValidation("X-User-Id", "spoofed-admin");

        var response = await _client.SendAsync(request);
        var echoed = (await response.Content.ReadAsStringAsync()).ToLowerInvariant();

        // The gateway removes X-User-* inbound headers, so the upstream must never see them.
        Assert.DoesNotContain("x-user-id", echoed);
        Assert.DoesNotContain("spoofed-admin", echoed);
    }

    [Fact]
    public async Task Forwards_correlation_id_to_the_upstream()
    {
        var response = await _client.GetAsync("/proxy/echo");
        var echoed = (await response.Content.ReadAsStringAsync()).ToLowerInvariant();

        Assert.Contains("x-correlation-id", echoed);
    }

    [Fact]
    public async Task Preserves_a_caller_supplied_correlation_id()
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "/healthz");
        request.Headers.TryAddWithoutValidation("X-Correlation-Id", "fixed-id-123");

        var response = await _client.SendAsync(request);

        Assert.Equal("fixed-id-123", response.Headers.GetValues("X-Correlation-Id").Single());
    }
}
