# itOrchestra API Gateway (YARP) - multi-stage build.
# Build stage uses the .NET 10 SDK; runtime uses the slim ASP.NET 10 image and runs
# as the non-root $APP_UID baked into the image (required by 'restricted' PodSecurity).
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY Gateway.csproj ./
RUN dotnet restore Gateway.csproj

COPY . ./
RUN dotnet publish Gateway.csproj -c Release -o /app /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app ./

ENV ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_gcServer=1

# Non-root user provided by the base image (uid 1654).
USER $APP_UID

ENTRYPOINT ["dotnet", "Gateway.dll"]
