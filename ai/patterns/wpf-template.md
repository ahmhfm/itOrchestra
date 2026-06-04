# Pattern: WPF Application Template

Canonical layout for a Windows desktop application built on WPF + .NET 10. Use this template to start a new WPF client.

## Solution layout

```
src/
  itOrchestra.Wpf.App/                       # WPF host (App.xaml, Program.cs)
    App.xaml
    App.xaml.cs
    appsettings.json
    Resources/
      Inter-Regular.ttf
      Strings.en.resx
      Strings.ar.resx
  itOrchestra.Wpf.Views/                     # Windows + UserControls
    OrdersWindow.xaml
    OrdersWindow.xaml.cs
    Dialogs/
  itOrchestra.Wpf.ViewModels/                # Observable ViewModels (Toolkit.Mvvm)
    OrdersViewModel.cs
    Navigation/
  itOrchestra.Wpf.Services/                  # API clients, navigation, dialogs, auth
    Api/
      IOrdersApi.cs
      OrdersApi.cs
    Auth/
      KeycloakOidcAuthService.cs
      SecureTokenStore.cs
    Navigation/
    Dialogs/
  itOrchestra.Wpf.Infrastructure/            # Telemetry, Polly, options
  itOrchestra.Wpf.Tests/                     # xUnit unit tests
```

## Project responsibilities

| Project | Responsibility | References |
|---|---|---|
| `App` | DI bootstrap, main window startup, configuration | Views, ViewModels, Services, Infrastructure |
| `Views` | XAML + minimal code-behind | ViewModels (via DataContext) |
| `ViewModels` | Observable state + Commands | Services |
| `Services` | API clients, auth, navigation abstractions | Contracts (shared with backend) |
| `Infrastructure` | Telemetry, Polly, secure storage | (none app-specific) |

## DI bootstrap (App.xaml.cs)

```csharp
public partial class App : Application
{
    private IHost? _host;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _host = Host.CreateDefaultBuilder()
            .ConfigureAppConfiguration(c => c
                .AddJsonFile("appsettings.json", optional: false)
                .AddJsonFile($"appsettings.{Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT") ?? "Production"}.json", optional: true)
                .AddEnvironmentVariables())
            .ConfigureServices((ctx, services) =>
            {
                services.Configure<ApiOptions>(ctx.Configuration.GetSection("Api"));
                services.Configure<KeycloakOptions>(ctx.Configuration.GetSection("Keycloak"));

                services.AddSingleton<ISecureTokenStore, DpapiTokenStore>();
                services.AddSingleton<IAuthService, KeycloakOidcAuthService>();
                services.AddSingleton<INavigationService, NavigationService>();
                services.AddSingleton<IDialogService, DialogService>();

                services.AddHttpClient<IOrdersApi, OrdersApi>((sp, c) =>
                {
                    var opts = sp.GetRequiredService<IOptions<ApiOptions>>().Value;
                    c.BaseAddress = new Uri(opts.BaseUrl);
                })
                .AddHttpMessageHandler<AuthorizationHandler>()
                .AddPolicyHandler(PollyPolicies.HttpTimeout)
                .AddPolicyHandler(PollyPolicies.HttpRetry)
                .AddPolicyHandler(PollyPolicies.HttpCircuitBreaker);

                services.AddTransient<AuthorizationHandler>();

                services.AddTransient<MainWindow>();
                services.AddTransient<OrdersWindow>();
                services.AddTransient<OrdersViewModel>();

                services.AddOpenTelemetryClientInstrumentation();
            })
            .Build();

        await _host.StartAsync();

        var login = _host.Services.GetRequiredService<IAuthService>();
        if (!await login.RestoreSessionAsync())
            await login.LoginAsync();

        var window = _host.Services.GetRequiredService<MainWindow>();
        window.DataContext = _host.Services.GetService(typeof(MainWindowViewModel));
        window.Show();
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        if (_host is not null)
        {
            await _host.StopAsync();
            _host.Dispose();
        }
        base.OnExit(e);
    }
}
```

## Auth handler injects Bearer token

```csharp
public sealed class AuthorizationHandler(IAuthService auth) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken ct)
    {
        var token = await auth.GetAccessTokenAsync(ct);
        if (!string.IsNullOrEmpty(token))
            request.Headers.Authorization = new("Bearer", token);
        return await base.SendAsync(request, ct);
    }
}
```

## Secure token store (DPAPI)

```csharp
public sealed class DpapiTokenStore : ISecureTokenStore
{
    private const string FileName = "tokens.bin";

    public async Task SaveAsync(string access, string refresh)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(new { access, refresh });
        var enc = ProtectedData.Protect(payload, null, DataProtectionScope.CurrentUser);
        await File.WriteAllBytesAsync(Path(), enc);
    }

    public async Task<(string? Access, string? Refresh)> LoadAsync()
    {
        if (!File.Exists(Path())) return (null, null);
        var enc = await File.ReadAllBytesAsync(Path());
        var dec = ProtectedData.Unprotect(enc, null, DataProtectionScope.CurrentUser);
        var doc = JsonDocument.Parse(dec);
        return (doc.RootElement.GetProperty("access").GetString(),
                doc.RootElement.GetProperty("refresh").GetString());
    }

    public Task ClearAsync()
    {
        if (File.Exists(Path())) File.Delete(Path());
        return Task.CompletedTask;
    }

    private static string Path() => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "itOrchestra", FileName);
}
```

## ViewModel + View

```csharp
public sealed partial class OrdersViewModel(IOrdersApi api, IDialogService dialogs) : ObservableObject
{
    [ObservableProperty] private ObservableCollection<OrderRow> _orders = new();
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private string? _statusMessage;

    [RelayCommand]
    private async Task LoadAsync(CancellationToken ct)
    {
        try
        {
            IsLoading = true;
            var rows = await api.ListAsync(ct);
            Orders.Clear();
            foreach (var r in rows) Orders.Add(r);
            StatusMessage = $"Loaded {Orders.Count} orders.";
        }
        catch (Exception ex)
        {
            await dialogs.ShowErrorAsync("Failed to load orders.", ex.Message);
        }
        finally { IsLoading = false; }
    }
}
```

```xml
<Window x:Class="itOrchestra.Wpf.Views.OrdersWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Orders" Height="600" Width="900">
    <DockPanel Margin="12">
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal">
            <Button Content="Refresh" Command="{Binding LoadCommand}" Margin="0,0,8,0" />
            <TextBlock Text="{Binding StatusMessage}" VerticalAlignment="Center" />
        </StackPanel>
        <ProgressBar DockPanel.Dock="Top" IsIndeterminate="{Binding IsLoading}" Height="2" />
        <DataGrid ItemsSource="{Binding Orders}" AutoGenerateColumns="False" IsReadOnly="True">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Id"     Binding="{Binding Id}" />
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" />
                <DataGridTextColumn Header="Total"  Binding="{Binding Total, StringFormat=N2}" />
                <DataGridTextColumn Header="Created" Binding="{Binding CreatedAt, StringFormat=yyyy-MM-dd HH:mm}" />
            </DataGrid.Columns>
        </DataGrid>
    </DockPanel>
</Window>
```

## Required cross-cutting

- **Logging:** Serilog → OpenTelemetry OTLP.
- **Telemetry:** crash + usage events; PII scrubbed.
- **Localization:** `.resx` per supported language; default English.
- **Update channel:** ClickOnce or Squirrel, signed with Authenticode certificate.
- **App icon and version metadata** populated.

## Checklist

- [ ] DI bootstrap via Generic Host.
- [ ] All API clients wired through `IHttpClientFactory` + `AuthorizationHandler` + Polly.
- [ ] Tokens stored via DPAPI; cleared on logout.
- [ ] MVVM strictly enforced; no logic in code-behind.
- [ ] Localized strings via `.resx`.
- [ ] OpenTelemetry registered.
- [ ] App signed; auto-update channel signed.
- [ ] Cold start measured + within budget.

## Related

- [`../skills/wpf.md`](../skills/wpf.md)
- [`../skills/maui.md`](../skills/maui.md)
- [`../skills/keycloak.md`](../skills/keycloak.md)
- [`../skills/polly-resilience.md`](../skills/polly-resilience.md)
