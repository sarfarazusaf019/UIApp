# UI - Claim Selection demo (React + Vite + TypeScript)

Talks only to the API (`../api`, http://localhost:5080). Own folder / repository. No code is shared with the other applications.

## Run
```
cd ui
npm install        # first time
npm run dev        # http://localhost:5173   ('/api' is proxied to http://localhost:5080, see vite.config.ts)
```
Start the API first (see `../api/README.md`). To point at another API address change the proxy target in `vite.config.ts`.
`npm run build` creates a static `dist/` folder.

Pages: Jobs, IDR cases (+ case detail), Unmatched remits, New claim-remit record, Configuration, IDR process reference.

## Deployment folder (`deployment/`)
`Dockerfile` (nginx serving the built app), `nginx.conf.template` (single page app + `/api/` proxied to the API service, address in `API_UPSTREAM`), `deployment.yaml`, `service.yaml`.
```
npm install ; npm run build
docker build -t claim-selection-ui -f deployment/Dockerfile .
nerdctl -n k8s.io build -t claim-selection-ui:v1 -f deployment/Dockerfile .      (local Kubernetes, no registry)
kubectl apply -f deployment/deployment.yaml -f deployment/service.yaml
```
Change the namespace and, if the API service has another name, `API_UPSTREAM` in `deployment/deployment.yaml`. Local container against the Api on your machine: `docker run -p 5173:8080 -e API_UPSTREAM=http://host.docker.internal:5080 claim-selection-ui`.

## Move it out
Copy the `ui/` folder (without `node_modules`) to its own repository; nothing else references it. The Run buttons are disabled: the Worker service runs the jobs.
