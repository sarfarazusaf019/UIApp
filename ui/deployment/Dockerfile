# Claim Selection UI image: the built React app served by nginx, '/api' proxied to the API service.
# Run these from the ui folder (the build context is the folder, this file sits in deployment/):
#   npm install ; npm run build
#   docker build -t claim-selection-ui -f deployment/Dockerfile .
# Kubernetes (local containerd): nerdctl -n k8s.io build -t claim-selection-ui:v1 -f deployment/Dockerfile .   then kubectl apply -f deployment/
FROM nginxinc/nginx-unprivileged:stable
COPY deployment/nginx.conf.template /etc/nginx/templates/default.conf.template
# where '/api' goes: the API service of the cluster (override with -e API_UPSTREAM=http://host:port, for example http://host.docker.internal:5080 for a local run)
ENV API_UPSTREAM=http://claim-selection-api.claim-selection.svc.cluster.local:80
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
COPY dist/ /usr/share/nginx/html/
EXPOSE 8080
