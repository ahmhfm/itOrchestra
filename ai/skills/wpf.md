# Skill: WPF (.NET 10)

## Purpose
Define how end-user Windows desktop applications are built. Used for rich productivity clients consumed by enterprise users.

## Architecture Role
A pure client application. Talks to backend services exclusively through **YARP API Gateway** over HTTPS REST. Never touches MSSQL directly. Holds no business logic of its own.

## Rules

1. **Strict MVVM.** Views are XAML; logic lives in ViewModels; state lives in observable properties.
2. **No business logic** in the UI layer. ViewModels orchestrate calls to API clients only.
3. **No direct database access.** All data flows through Web API via `IHttpClientFactory`.
4. **DI everywhere.** No `new` for services; use `Microsoft.Extensions.DependencyInjection`.
5. UI thread must remain responsive: all I/O `async`, dispatched back via `Dispatcher` only when binding requires it.
6. Tokens (JWT) stored using Windows DPAPI; never plain in disk or in `Settings`.
7. Crash + telemetry logs go to OpenTelemetry (OTLP exporter).
8. Localization-ready from day one (no hardcoded user-visible strings).

## Best Practices

- Use `CommunityToolkit.Mvvm` for `INotifyPropertyChanged`, `RelayCommand`, source generators (`[ObservableProperty]`, `[RelayCommand]`).
- Use `IHttpClientFactory` to construct API clients; register named/typed clients per backend (`OrdersApi`, `CustomersApi`).
- Define API client interfaces in a shared `Contracts.Client` project; implementations call YARP.
- Use Refit (HTTP) or hand-written typed clients; both must wrap in Polly (Retry + CircuitBreaker).
- Use `IDialogService` / `INavigationService` abstractions — never call `MessageBox.Show` from ViewModels.
- Use `x:Bind` style bindings sparingly (WPF has no `x:Bind`; this is WinUI). For WPF, use `Binding` with `Mode=OneWay`/`TwoWay` explicitly.
- Use `ItemsControl.Virtualization` for any list > 100 items.
- Keep code-behind empty except for `InitializeComponent()` and view-only event handlers.

## Anti-Patterns

| Don't | Do |
|---|---|
| Call `SqlConnection` from a WPF View | Always go through Web API via YARP |
| Put business rules in `Button_Click` | Commands on ViewModels |
| Block the UI thread (`.Result`, `.Wait()`) | `async/await`, `IAsyncRelayCommand` |
| Hardcode endpoint URLs | Read from `appsettings.json` + Vault-injected secrets |
| Store JWT in plain `Settings.Default` | Use DPAPI / Windows Credential Manager |
| New up HttpClient per call | Use `IHttpClientFactory` |
| Reference `EntityFramework` packages | Never; WPF talks to the backend only |
| Singleton ViewModels for navigated pages | Scoped/Transient via DI |

## Security Requirements

- Use **OAuth 2.0 + PKCE** for authentication against Keycloak (e.g., `IdentityModel.OidcClient`).
- Store refresh tokens using DPAPI scoped to the current user.
- Validate the Keycloak ID token signature before accepting claims.
- Disable WebView2 dev tools in release builds.
- Use HTTPS only; pin the YARP certificate if the threat model demands it.
- App is signed with a valid Authenticode certificate before distribution.
- Auto-update channel verified by signature.

## Performance Guidelines

- Cold start < 2 seconds on enterprise hardware.
- Bind to `ObservableCollection<T>` only for lists that change; for static lists, bind to `IReadOnlyList<T>`.
- Defer heavy operations until `Window_Loaded` (not constructor).
- Use `Frozen` resources where applicable (`Freezable` types like `SolidColorBrush`).
- Use `RenderOptions.BitmapScalingMode="LowQuality"` for large icon grids during scroll.
- Profile with `dotnet-trace` / `PerfView` before optimizing.

## Example Implementations

### App startup (Generic Host + DI)

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
                .AddEnvironmentVariables())
            .ConfigureServices((ctx, services) =>
            {
                services.Configure<ApiOptions>(ctx.Configuration.GetSection("Api"));
                services.AddHttpClient<IOrdersApi, OrdersApi>(c =>
                {
                    c.BaseAddress = new Uri(ctx.Configuration["Api:Orders"]!);
                })
                .AddPolicyHandler(HttpPolicies.Retry())
                .AddPolicyHandler(HttpPolicies.CircuitBreaker());

                services.AddSingleton<IAuthService, KeycloakOidcAuthService>();
                services.AddSingleton<INavigationService, NavigationService>();
                services.AddSingleton<IDialogService, DialogService>();
                services.AddTransient<MainWindow>();
                services.AddTransient<OrdersViewModel>();
            })
            .Build();

        await _host.StartAsync();

        var window = _host.Services.GetRequiredService<MainWindow>();
        window.DataContext = _host.Services.GetRequiredService<OrdersViewModel>();
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

### ViewModel (CommunityToolkit.Mvvm)

```csharp
public sealed partial class OrdersViewModel(IOrdersApi api, IDialogService dialogs) : ObservableObject
{
    [ObservableProperty] private ObservableCollection<OrderRow> _orders = new();
    [ObservableProperty] private bool _isLoading;

    [RelayCommand]
    private async Task LoadAsync(CancellationToken ct)
    {
        try
        {
            IsLoading = true;
            var result = await api.ListAsync(ct);
            Orders.Clear();
            foreach (var item in result) Orders.Add(item);
        }
        catch (Exception ex)
        {
            await dialogs.ShowErrorAsync("Failed to load orders.", ex.Message);
        }
        finally
        {
            IsLoading = false;
        }
    }
}
```

### View (XAML)

```xml
<Window x:Class="itOrchestra.Wpf.Views.OrdersWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Orders" Height="600" Width="900">
    <Grid>
        <DataGrid ItemsSource="{Binding Orders}" AutoGenerateColumns="False" IsReadOnly="True">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Id"     Binding="{Binding Id}" />
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" />
                <DataGridTextColumn Header="Total"  Binding="{Binding Total, StringFormat=N2}" />
            </DataGrid.Columns>
        </DataGrid>
        <Button Content="Refresh" Command="{Binding LoadCommand}" HorizontalAlignment="Right" VerticalAlignment="Top" />
    </Grid>
</Window>
```

## Integration Rules

- **All HTTP** calls target YARP (`https://api.itorchestra.com/api/v1/...`). Never call a microservice directly.
- **JWT** acquired from Keycloak via OIDC; refresh handled by the auth service singleton.
- **Telemetry:** OpenTelemetry OTLP exporter sends crash + usage events to the cluster's collector. PII scrubbed.
- **Updates:** ClickOnce or Squirrel for distribution; signed with the company certificate.
- **Configuration:** non-secret config in `appsettings.json`; secrets fetched per-session from Vault via a backend API (never embedded).

## Checklist

- [ ] MVVM strictly enforced (no logic in code-behind).
- [ ] All API clients wired through `IHttpClientFactory` + Polly.
- [ ] JWT stored via DPAPI.
- [ ] No direct DB references in any project.
- [ ] DI registrations complete and lifetimes correct.
- [ ] Cancellation tokens flow through async operations.
- [ ] Strings extracted to `.resx` for localization.
- [ ] Telemetry registered, sensitive fields scrubbed.
- [ ] App signed; auto-update channel signed.
- [ ] Crash dumps captured and uploaded.

## Related

- [`maui.md`](./maui.md)
- [`../patterns/wpf-template.md`](../patterns/wpf-template.md)
- [`keycloak.md`](./keycloak.md)
- [`polly-resilience.md`](./polly-resilience.md)
- [`opentelemetry.md`](./opentelemetry.md)
