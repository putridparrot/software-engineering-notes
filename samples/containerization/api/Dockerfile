# ---- Stage 1: build ----
# The SDK image contains the compilers and tooling - large, only used to build
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Copy the project file first and restore, so this layer is cached
# until the package references change
COPY Api.csproj .
RUN dotnet restore

# Now copy the source and publish
COPY . .
RUN dotnet publish -c Release -o /app/publish --no-restore

# ---- Stage 2: runtime ----
# The ASP.NET runtime image is much smaller and contains no build tools
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app/publish .

# Run as the built-in non-root user rather than root
USER $APP_UID

# .NET 8+ images listen on 8080 by default
EXPOSE 8080
ENTRYPOINT ["dotnet", "Api.dll"]
