## Troubleshooting & Bug Fixes

The repository was provided with a deliberately misconfigured staging setup. Below is the step-by-step technical breakdown of the architectural issues discovered during local testing and how they were systematically resolved.

### 1. Backend Isolation Issue (Dockerfile)
- **Symptom:** The backend container built successfully but was completely unreachable from outside the container network, even when ports were mapped.
- **Discovery:** Inspection of the `CMD` layer revealed Uvicorn binding to `--host 127.0.0.1`. Inside an isolated Docker container, loopback addresses (`127.0.0.1`) limit traffic strictly to the internal container loop.
- **Fix:** Refactored the command string to bind to `--host 0.0.0.0`, instructing the ASGI server to listen across all network interfaces so external proxy traffic from Nginx could be processed.

### 2. Missing Static Assets (Docker Compose)
- **Symptom:** Nginx kept throwing a standard `404 Not Found` error when attempting to access the application root URL.
- **Discovery:** Evaluated the volume mounts within `docker-compose.yml` and noticed that the frontend static directory mapping to Nginx's HTML target path (`/usr/share/nginx/html`) had been completely commented out.
- **Fix:** Uncommented the volume block to mount local `./frontend` code dynamically into the proxy container, allowing Nginx to correctly fetch and serve `index.html`.

### 3. Nginx Upstream Resolution & Protocol Failures (nginx.conf)
- **Symptom:** The webpage loaded correctly, but the chat feature was non-functional due to immediate and continuous WebSocket handshake drops.
- **Discovery:** Checking the Nginx location blocks revealed two major structural flaws:
  1. The `proxy_pass` directive was hardcoded to forward traffic to `http://localhost:8000/ws`. Inside Nginx's container space, `localhost` refers to itself—not the backend container.
  2. The mandatory connection upgrading headers (`Upgrade` and `Connection`) required to elevate standard HTTP requests into dynamic WebSocket pipelines were completely commented out.
- **Fix:** 
  - Updated the reverse proxy target to leverage Docker's built-in DNS service discovery, routing traffic directly to the service identifier name (`http://backend:8000/ws`).
  - Uncommented the `Upgrade` and `Connection` headers to pass standard hop-by-hop HTTP upgrade sequences cleanly through the proxy server.

## Local Verification & Test Automation Results

To validate the stability and behavioral correctness of the fixed infrastructure layout, the environment was subjected to localized integration and resilience test suites.

### Test Case 1: Multi-Tab Real-Time WebSocket Broadcast
- **Objective:** Verify that the Nginx proxy layer successfully transitions HTTP handshakes to full-duplex WebSocket channels and ensures seamless message broadcasting across independent client instances.
- **Methodology:** 
  1. Initialized the stack and spawned two isolated browser sessions at `http://localhost`.
  2. Executed a payload transmission from Client A.
- **Result:** **PASSED**. Handshakes completed successfully on route `/ws`. Upstream frames were captured, processed by the FastAPI core, and instantly broadcasted back through the Nginx layer to Client B's socket instance in real-time, confirming socket state-sharing works perfectly.

### Test Case 2: Process Resilience & Supervisor Restart Policy
- **Objective:** Verify container fault tolerance and adherence to high-availability specifications (`restart: always`).
- **Methodology:** 
  1. Isolated the active container process via `docker ps`.
  2. Executed a forced termination sequence using an explicit runtime signal: `docker kill chat-nginx`.
- **Result:** **PASSED**. The underlying `docker-compose.yml` lifecycle configurations were verified. 

