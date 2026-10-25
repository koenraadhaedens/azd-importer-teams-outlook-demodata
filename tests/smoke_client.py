"""Verify Caddy's local-CA chain and hostname without changing machine trust."""

import argparse
import http.client
import json
import ssl
import urllib.request


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("ca")
    args = parser.parse_args()
    context = ssl.create_default_context(cafile=args.ca)
    for path in ("/healthz", "/", "/static/app.css"):
        with urllib.request.urlopen(
            "https://localhost:8443" + path, context=context, timeout=10
        ) as response:
            body = response.read().decode()
            assert response.status == 200
            assert response.headers["Strict-Transport-Security"] == "max-age=31536000"
            if path == "/healthz":
                assert json.loads(body)["status"] == "ready"
            elif path == "/":
                assert "Sign in with Microsoft Entra ID" in body
                assert 'href="/static/app.css"' in body
    connection = http.client.HTTPConnection("localhost", 8080, timeout=10)
    connection.request("GET", "/")
    redirect = connection.getresponse()
    assert redirect.status == 308
    assert redirect.headers["Location"].startswith("https://")
    connection.close()
    print("PASS: Caddy TLS chain + hostname, HSTS, health, HTML, CSS and HTTP->HTTPS redirect")


if __name__ == "__main__":
    main()
