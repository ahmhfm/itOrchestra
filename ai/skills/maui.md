# Skill: .NET MAUI (.NET 10)

## Purpose
Define how cross-platform clients are built for macOS, Linux, Android, and iOS. MAUI is the only sanctioned framework for non-Windows desktop and mobile.

## Architecture Role
A pure client. Communicates with backend services exclusively through **YARP API Gateway** over HTTPS REST. Never connects to MSSQL or any internal service directly. Platform-specific concerns isolated behind interfaces.

## Rules

1. **Strict MVVM** with `CommunityToolkit.Mvvm` (`[ObservableProperty]`, `[RelayCommand]`).
2. **No direct database access.** All data via Web API behind YARP.
3. **DI via `MauiProgram.cs`.** Use `Microsoft.Extensions.DependencyInjection`.
4. **Platform code isolated** behind interfaces (`IBiometricService`, `ISecureStorage`); implementations under `Platforms/<TFM>`.
5. **Async-only I/O.** No blocking the UI thread.
6. **Secure storage** for tokens: `Microsoft.Maui.Storage.SecureStorage` (uses Keychain / Keystore / DPAPI).
7. **No PII in logs.** OpenTelemetry export with scrubbed payloads.
8. **Offline-aware:** caches read-only views in SQLite (managed by the framework — this is allowed, it is not a service DB).

## Best Practices

- Use **Shell** for navigation; declare routes once in `AppShell.xaml`.
- Use `CollectionView` over `ListView` for performance.
- Bind to `ObservableCollection<T>` only for mutable lists; `IReadOnlyList<T>` otherwise.
- Use `IHttpClientFactory` (with `MauiAppBuilder.Services.AddHttpClient<T>`).
- Use `Connectivity` (`Microsoft.Maui.Networking`) to gate network calls and degrade gracefully.
- Use `MainThread.BeginInvokeOnMainThread` only when crossing into UI from a non-UI context — rare; most calls are already on UI via `RelayCommand`.
- Apply `[QueryProperty]` for passing parameters across Shell routes.

## Anti-Patterns

| Don't | Do |
|---|---|
| `new HttpClient()` per page | `IHttpClientFactory` typed clients |
| Store JWT in `Preferences` (plain) | Use `SecureStorage` |
| Tightly couple UI to platform APIs | Use interface + `Platforms/<TFM>` |
| Long-lived static state | Scoped services via DI |
| Use legacy `Xamarin.Forms` packages | MAUI only on .NET 10 |
| Connect to internal services directly | Always via YARP REST |
| Embed secrets in code or appsettings | Fetch per-session from a backend `Settings` endpoint |

## Security Requirements

- **OAuth 2.0 + PKCE** against Keycloak using `IdentityModel.OidcClient`.
- **Tokens** stored via `SecureStorage` (Keychain on iOS/macOS, Keystore on Android, DPAPI on Windows).
- **Biometric** unlock required for sensitive actions where available.
- **Certificate pinning** for the YARP host if the threat model requires.
- **Jailbreak / root detection** signaled to telemetry; restrict sensitive flows on rooted devices.
- **No `AllowAnonymous`** on production endpoints; offline mode still requires a valid (cached) JWT until expiry.

## Performance Guidelines

- Cold start < 3 seconds on mid-range mobile.
- Image cache via `FFImageLoading.Maui` or built-in caching; never bundle huge images.
- Avoid deep visual trees; flatten layouts.
- Use `OnPlatform` markup carefully; prefer DI-based platform services.
- Profile with `dotnet-trace` and platform tools (Xcode Instruments, Android Profiler).

## Example Implementations

### MauiProgram.cs

```csharp
public static MauiApp CreateMauiApp()
{
    var builder = MauiApp.CreateBuilder();

    builder
        .UseMauiApp<App>()
        .UseMauiCommunityToolkit()
        .ConfigureFonts(fonts =>
        {
            fonts.AddFont("Inter-Regular.ttf", "InterRegular");
        });

    builder.Services.Configure<ApiOptions>(builder.Configuration.GetSection("Api"));

    builder.Services.AddHttpClient<IOrdersApi, OrdersApi>(c =>
    {
        c.BaseAddress = new Uri(builder.Configuration["Api:BaseUrl"]!);
    })
    .AddPolicyHandler(HttpPolicies.Retry())
    .AddPolicyHandler(HttpPolicies.CircuitBreaker());

    builder.Services.AddSingleton<IAuthService, KeycloakOidcAuthService>();
    builder.Services.AddSingleton<ISecureTokenStore, SecureTokenStore>();
    builder.Services.AddSingleton<INavigationService, ShellNavigationService>();

    builder.Services.AddTransient<OrdersViewModel>();
    builder.Services.AddTransient<OrdersPage>();

    return builder.Build();
}
```

### Secure token store

```csharp
public interface ISecureTokenStore
{
    Task SaveAsync(string accessToken, string refreshToken);
    Task<(string? Access, string? Refresh)> LoadAsync();
    Task ClearAsync();
}

public sealed class SecureTokenStore : ISecureTokenStore
{
    public Task SaveAsync(string accessToken, string refreshToken)
    {
        return Task.WhenAll(
            SecureStorage.Default.SetAsync("access_token", accessToken),
            SecureStorage.Default.SetAsync("refresh_token", refreshToken));
    }

    public async Task<(string? Access, string? Refresh)> LoadAsync() =>
        (await SecureStorage.Default.GetAsync("access_token"),
         await SecureStorage.Default.GetAsync("refresh_token"));

    public Task ClearAsync()
    {
        SecureStorage.Default.Remove("access_token");
        SecureStorage.Default.Remove("refresh_token");
        return Task.CompletedTask;
    }
}
```

### ViewModel (Toolkit)

```csharp
public sealed partial class OrdersViewModel(IOrdersApi api) : ObservableObject
{
    [ObservableProperty] private ObservableCollection<OrderRow> _orders = new();
    [ObservableProperty] private bool _isBusy;

    [RelayCommand]
    private async Task RefreshAsync(CancellationToken ct)
    {
        if (IsBusy) return;
        try
        {
            IsBusy = true;
            var rows = await api.ListAsync(ct);
            Orders.Clear();
            foreach (var r in rows) Orders.Add(r);
        }
        finally { IsBusy = false; }
    }
}
```

### View (XAML)

```xml
<ContentPage xmlns="http://schemas.microsoft.com/dotnet/2021/maui"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             x:Class="itOrchestra.Maui.Views.OrdersPage"
             Title="Orders">
    <Grid Padding="12" RowDefinitions="Auto,*">
        <Button Text="Refresh" Command="{Binding RefreshCommand}" />
        <CollectionView Grid.Row="1" ItemsSource="{Binding Orders}">
            <CollectionView.ItemTemplate>
                <DataTemplate>
                    <StackLayout Padding="8">
                        <Label Text="{Binding Id}" />
                        <Label Text="{Binding Status}" />
                        <Label Text="{Binding Total, StringFormat='{}{0:N2}'}" />
                    </StackLayout>
                </DataTemplate>
            </CollectionView.ItemTemplate>
        </CollectionView>
    </Grid>
</ContentPage>
```

## Integration Rules

- **Backend** only via YARP REST. No gRPC clients in MAUI (gRPC is internal-only).
- **Auth:** Keycloak OIDC + PKCE; tokens in `SecureStorage`. ID token validated before use.
- **Telemetry:** OpenTelemetry OTLP exporter to the platform's HTTPS collector endpoint.
- **Localization:** `.resx` per supported language; default English.
- **Configuration:** non-secret in `appsettings.json` (embedded as Maui Resource); secrets retrieved via the authenticated `/api/v1/me/config` endpoint after login.

## Checklist

- [ ] MVVM strictly enforced.
- [ ] Services registered via DI in `MauiProgram.cs`.
- [ ] `SecureStorage` used for tokens.
- [ ] `IHttpClientFactory` + Polly for all backend calls.
- [ ] `Connectivity` checked before network calls.
- [ ] No PII or token values in logs.
- [ ] Platform-specific code in `Platforms/<TFM>` behind interfaces.
- [ ] Localized strings, no hardcoded UI text.
- [ ] Telemetry registered.
- [ ] App signed for each platform's store.

## Related

- [`wpf.md`](./wpf.md)
- [`webapi.md`](./webapi.md)
- [`keycloak.md`](./keycloak.md)
- [`polly-resilience.md`](./polly-resilience.md)
- [`opentelemetry.md`](./opentelemetry.md)
