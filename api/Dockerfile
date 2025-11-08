FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base
WORKDIR /app
EXPOSE 80
EXPOSE 443

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY ["Sprint4AzureDevOps.csproj", "."]
RUN dotnet restore "Sprint4AzureDevOps.csproj"
COPY . .
RUN dotnet build "Sprint4AzureDevOps.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "Sprint4AzureDevOps.csproj" -c Release -o /app/publish

FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .
ENTRYPOINT ["dotnet", "Sprint4AzureDevOps.dll"]
