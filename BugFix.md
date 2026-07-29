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

## Local Verification & Test Results

The infrastructure fixes were verified locally on a macOS environment using two empirical integration test scenarios.

### Test Case 1: Multi-Tab Message Broadcast
* **Command / Action:** Started the application stack via Compose, opened two independent browser tabs at `http://localhost`, and transmitted a message from Tab 1.
* **Observation:** The message instantly rendered inside the viewport of Tab 2. Inspecting the browser network console confirmed an active, uninterrupted connection state on `ws://localhost/ws`.
* **Conclusion:** This confirms Nginx successfully handles standard HTTP traffic at the root route while transparently upgrading and proxying WebSocket streams to the backend container service.

### Test Case 2: Process Resilience & Container Restart Policy
* **Command / Action:** 
  To simulate an unexpected application crash while respecting the container's read-only (`:ro`) file system volume constraints, the Nginx process was forced to shut down abruptly from within the container:
  ```bash
  docker exec chat-nginx nginx -s stop
  docker ps
  ```
* **Observation:** 
  The terminal output confirmed the signal was sent (`signal process started`). Upon running `docker ps`, the `chat-backend` container showed an uninterrupted uptime of `12 minutes`, while the `chat-nginx` container's status rolled back to `Up 5 seconds`.
* **Conclusion:** 
  This explicitly confirms that the `restart: always` configuration block within `docker-compose.yml` functions exactly as intended. The Docker daemon successfully intercepts unexpected internal runtime process failures and automatically spawns a fresh container instance to guarantee service availability without dropping the rest of the application stack.
* **Note:** nginx -s stop produces a clean exit; this test specifically validates restart: always, which restarts on any exit condition. A true crash-recovery test for on-failure policies would require a non-zero exit (e.g. nginx -s quit vs a segfault or kill -9 on the master process)."