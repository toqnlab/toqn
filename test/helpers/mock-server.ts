import http from "http";
import fs from "fs";
import path from "path";

interface CapturedRequest {
  body: string;
  headers: http.IncomingHttpHeaders;
}

export function createMockServer() {
  let lastRequest: CapturedRequest | null = null;
  const requests: CapturedRequest[] = [];
  let customHeaders: Record<string, string> = {};

  const server = http.createServer((req, res) => {
    // Serve hook script for installer tests
    if (req.method === "GET" && req.url?.includes("toqn-hook.sh")) {
      const script = fs.readFileSync(
        path.resolve(__dirname, "../../scripts/toqn-hook.sh"),
        "utf-8"
      );
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end(script);
      return;
    }

    // Device auth endpoints
    const url = new URL(req.url || "/", `http://localhost`);

    if (req.method === "POST" && url.pathname === "/api/auth/device") {
      const addr = server.address();
      const port = typeof addr === "object" ? addr!.port : 0;
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({
        device_code: "test-device-code",
        user_code: "ABCD-1234",
        verification_url: `http://localhost:${port}/auth/device?code=ABCD-1234`,
        expires_in: 600,
        interval: 1,
      }));
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/auth/device/token") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({
        status: "authorized",
        api_key: "device-auth-api-key",
      }));
      return;
    }

    // Capture POST requests
    if (req.method === "POST") {
      let body = "";
      req.on("data", (chunk) => (body += chunk));
      req.on("end", () => {
        const captured = { body, headers: req.headers };
        lastRequest = captured;
        requests.push(captured);
        res.writeHead(200, { "Content-Type": "application/json", ...customHeaders });
        res.end(JSON.stringify({ success: true }));
      });
      return;
    }

    res.writeHead(404);
    res.end();
  });

  return {
    start: () =>
      new Promise<number>((resolve) => {
        server.listen(0, () => {
          const addr = server.address();
          resolve(typeof addr === "object" ? addr!.port : 0);
        });
      }),
    stop: () => new Promise<void>((resolve) => server.close(() => resolve())),
    getLastRequest: () => lastRequest,
    getRequests: () => requests,
    setResponseHeaders: (headers: Record<string, string>) => { customHeaders = headers; },
    reset: () => {
      lastRequest = null;
      requests.length = 0;
      customHeaders = {};
    },
  };
}
