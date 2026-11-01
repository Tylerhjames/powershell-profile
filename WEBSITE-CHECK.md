# Website & Certificate Check

Open `tech` → **L — Website & Certificate Check**. Enter a hostname or HTTP(S)
URL; a bare hostname uses HTTPS. Blank input returns to TECH.

- Shows HTTP status, redirect hops and time to response headers.
- Shows certificate subject, issuer, hostname match, OS validation and expiration.
- Warns when expiry is within 30 days. Invalid certificates are never bypassed.
- Stops at redirect loops, five redirects, or an HTTPS-to-HTTP downgrade.
- **C** copies icons, colors and a plain-text fallback into the clipboard.
  Ticket editors that remove formatting retain the text and icons.

No login, cookies, settings changes or repairs. Uses system proxy settings without
supplying credentials. Sends GET requests but does not download/render the page
body. As with any website visit, requests may be logged by the destination.
Certificate validation may contact issuer/revocation services.

Tickets omit URL query values, but include hostnames and paths. A successful HTTP
response does not prove that login or the application works. HTTP has no certificate.
Timing includes DNS, connection, TLS and headers as applicable, not page rendering.

For scripts:

```powershell
Test-WebsiteCertificate -Target https://example.com -NoPrompt -PassThru
```

Optional: `-TimeoutMs 10000` (per hop), `-MaxRedirects 5`. Returned hop objects
contain original URLs and raw errors; review before sharing them.
