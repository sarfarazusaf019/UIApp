# Claim Selection API image (the UI's backend). Run these from the api folder (the build context is the folder, this file sits in deployment/):
#   dotnet publish src/TH.IDR.ClaimSelection.Api -c Release -o publish
#   docker build -t claim-selection-api -f deployment/Dockerfile .
#   docker compose -f deployment/docker-compose.yml up        (local, see docker-compose.yml: http://localhost:5080/api/health)
# Kubernetes (local containerd): nerdctl -n k8s.io build -t claim-selection-api:v1 -f deployment/Dockerfile .   then kubectl apply -f deployment/
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY publish/ .
# the base image's non-root user. Local runs mount the AWS credentials at /home/app/.aws; in AWS the task / instance / pod role is used.
USER app
ENV HOME=/home/app
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "TH.IDR.ClaimSelection.Api.dll"]
