```
SIMPLE PROXY

A small mitmproxy interceptor, written as an example of how to build a proxy on macOS.

The bundled addon returns `202 {"status":"ok"}` for telemetry endpoints.
Apps continue working, you see every intercepted request in the log.

Sentry is left alone - crash reports are useful.


INSTALL

python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/mitmproxy # run once to generate the CA
open ~/.mitmproxy
# drag mitmproxy-ca-cert.pem into System > Certificates tab
# double-click, expand "Trust", set "When using this certificate" to "Always Trust"

./run.sh


Add this function to your shell rc to prefix any command:

sp() {
  HTTPS_PROXY=http://127.0.0.1:8420 \
  HTTP_PROXY=http://127.0.0.1:8420 \
  NO_PROXY=localhost,127.0.0.1 \
  NODE_EXTRA_CA_CERTS=~/.mitmproxy/mitmproxy-ca-cert.pem \
  "$@"
}

Then `sp claude`, `sp node script.js`, `sp npm install`, `sp gh pr list`, etc.


QUICK CHECK

sp curl -s https://example.com/ -o /dev/null -w "%{http_code}\n"
# 200

sp curl -s -X POST https://api.mixpanel.com/track -d '{"event":"hi"}'
# {"status":"ok"}
```
