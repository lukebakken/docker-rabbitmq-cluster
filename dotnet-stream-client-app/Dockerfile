FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY dotnet-stream-client-app.csproj .
RUN dotnet restore
COPY Program.cs .
RUN dotnet publish --configuration Release --output /app

FROM mcr.microsoft.com/dotnet/runtime:8.0
WORKDIR /app
COPY --from=build /app .
ENTRYPOINT ["dotnet", "dotnet-stream-client-app.dll"]
