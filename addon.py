import sys

from mitmproxy import http, tcp

# Line-buffer stdout so logs survive a crash even when piped to a file.
sys.stdout.reconfigure(line_buffering=True)


# Hosts dedicated to telemetry ingest. Suffix match, any method. Safe to
# blanket-mock - none of these serve a marketing site or dashboard UI.
INGEST_HOSTS = (
    # Datadog browser RUM (regional)
    "browser-intake-datadoghq.com",
    "browser-intake-datadoghq.eu",
    "browser-intake-datadoghq.us",
    "browser-intake-us3-datadoghq.com",
    "browser-intake-us5-datadoghq.com",
    "browser-intake-ap1-datadoghq.com",

    # Google Analytics / GTM / DoubleClick (use GET pixels - must be here)
    "google-analytics.com",
    "analytics.google.com",
    "googletagmanager.com",
    "stats.g.doubleclick.net",
    "app-measurement.com",

    "firebaselogging.googleapis.com",
    "firebase-settings.crashlytics.com",

    # Product analytics - dedicated API subdomains only, never the apex.
    "api.mixpanel.com", "api-eu.mixpanel.com",
    "api.amplitude.com", "api2.amplitude.com", "api.eu.amplitude.com",
    "api.segment.io",

    "notify.bugsnag.com", "sessions.bugsnag.com",
    "api.rollbar.com",

    "collector.newrelic.com",
    "nr-data.net",
    "dc.services.visualstudio.com",
    "applicationinsights.azure.com",
    "in.appcenter.ms",

    "lr-ingest.io",
    "vitals.vercel-insights.com",

    "mc.yandex.ru", "mc.yandex.com",
    "telemetr.ee",
)

# Vendor apex domains that ALSO host marketing sites or customer dashboards.
# Mock only non-GET requests so browsing the site (and loading static assets)
# still works, while POST/PUT/PATCH event uploads get absorbed.
VENDOR_SUFFIXES_NON_GET = (
    "datadoghq.com", "datadoghq.eu", "datadoghq.us",
    "mixpanel.com",
    "amplitude.com",
    "newrelic.com",
    "appsflyer.com",
    "adjust.com",
    "singular.net",
    "kochava.com",
    "pendo.io",
    "fullstory.com",
    "hotjar.com", "hotjar.io",
    "smartlook.com", "inspectlet.com", "mouseflow.com",
    "logrocket.io",
    "crashlytics.com",
    "heapanalytics.com",
    "telemetree.io",
    "splunkcloud.com", "sumologic.com", "loggly.com",
    "vercel-analytics.com",
)

# Hosts that mix event ingest with feature flags / remote config. Mock only
# the event paths so the app's flag/config calls still resolve.
#
# Deliberately NOT mocked:
#   - Sentry (sentry.io, *.ingest.sentry.io) - crash reports stay on
#   - Cloudflare Insights                     - kept on by request
#   - Branch (api.branch.io)                  - also resolves deep links
#   - Firebase Remote Config / Installations  - apps depend on these to boot
MOCK_PATH_PREFIXES = (
    ("i.posthog.com",           ("/e/", "/batch/", "/capture/", "/s/")),
    ("app.posthog.com",         ("/e/", "/batch/", "/capture/", "/s/")),
    ("events.statsigapi.net",   ("/",)),
    ("events.launchdarkly.com", ("/",)),
    ("mobile.launchdarkly.com", ("/mobile/events",)),
)


def _host_matches(host: str, suffix: str) -> bool:
    return host == suffix or host.endswith("." + suffix)


def _mock_reason(method: str, host: str, path: str) -> str | None:
    host = host.lower()
    path_only = path.split("?", 1)[0]
    if any(_host_matches(host, h) for h in INGEST_HOSTS):
        return "ingest"
    if method != "GET" and any(_host_matches(host, h) for h in VENDOR_SUFFIXES_NON_GET):
        return "vendor-post"
    for h, prefixes in MOCK_PATH_PREFIXES:
        if _host_matches(host, h) and any(path_only.startswith(p) for p in prefixes):
            return "path"
    return None


def _safe_url(req: http.Request) -> str:
    # Strip query string (OAuth tokens, session IDs, signed URLs) and any
    # control / DEL chars (defends terminal against ANSI-escape injection).
    url = req.pretty_url.split("?", 1)[0]
    return "".join(c if c == "\t" or (" " <= c < "\x7f") else "?" for c in url)


def request(flow: http.HTTPFlow) -> None:
    safe = _safe_url(flow.request)
    print(f"HTTP {flow.request.method} {safe}")
    reason = _mock_reason(
        flow.request.method, flow.request.pretty_host, flow.request.path
    )
    if reason:
        # No X-Mocked-By header - paranoid SDKs could detect the marker
        # and change behavior (retry, refuse to function, surface a warning).
        flow.response = http.Response.make(
            202,
            b'{"status":"ok"}',
            {"Content-Type": "application/json"},
        )
        print(f"  ⊘ mocked [{reason}] → {safe}")


def response(flow: http.HTTPFlow) -> None:
    if flow.response is None:
        return
    print(f"  → {flow.response.status_code} {_safe_url(flow.request)}")


def tcp_start(flow: tcp.TCPFlow) -> None:
    addr = flow.server_conn.address
    if addr:
        print(f"TCP  connect → {addr[0]}:{addr[1]}")


def tcp_end(flow: tcp.TCPFlow) -> None:
    addr = flow.server_conn.address
    if addr:
        print(f"TCP  close   → {addr[0]}:{addr[1]}")
