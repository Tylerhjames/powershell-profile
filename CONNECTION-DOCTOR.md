# Connection Doctor

Open `tech` > **K: Connection Doctor**, or run `Test-ConnectionDoctor`.

1. Enter a hostname, IPv4 address, or HTTP(S) URL. SSH-only aliases such as `arca` are not
   expanded: use the actual server hostname or IP instead.
2. Choose HTTPS, HTTP, SSH, RDP, SMB, or Custom using arrow keys + Enter (or 1–6).
   Q cancels. Redirected/narrow terminals use a numbered prompt. A URL suggests its port;
   the URL path/query is not sent or included in the report.
3. For names, optionally enter another DNS server's IPv4 address. Otherwise only configured IPv4
   resolvers on active adapters are queried (these may include public/VPN DNS).
   Never send internal/customer names to an external resolver without permission.
4. Read the colored connection/route, DNS and assessment sections.
   Choose **C** to copy a ticket summary, **D** for full details, or **Q** to return.
   Copy includes icons and toolkit colors as HTML, plus an icon-bearing Unicode
   text fallback. Rich-text ticket editors may retain colors; plain-text fields
   cannot. Ticket editors can also sanitize formatting. No ANSI escapes are copied.

The tool reports system name resolution, selected route/adapter/source, actual TCP
source on successful connections, TCP timing/results, and resolver A/CNAME
answers with TTLs (in Details/ticket summary). It tests up to four system-resolved IPv4 addresses and compares up to four
configured resolvers plus one explicitly supplied resolver. Address order follows
the system resolver. DNS comparison uses Windows quick timeouts, which can still
take several seconds per resolver; the TCP timeout is per tested address.

```powershell
# Noninteractive; return structured results and a copyable Summary property
$result = Test-ConnectionDoctor -Target 10.31.31.5 -Port 22 -NoPrompt -PassThru
$result.Summary
```

**Read-only means no repairs or configuration changes.** No DNS flush, DHCP renew,
route changes, login, packet capture, automatic export or automatic clipboard write.
DNS queries/TCP handshakes generate network traffic and may be logged remotely.
TCP success proves connectivity—not certificate validity, authentication or service
health. Timeouts do not identify a firewall or prove a VPN is disconnected.

DNS answers can legitimately differ because of split DNS, caching or load balancing.
Explicit resolver queries do not reproduce all system cache/hosts/NRPT behavior.
Missing Windows networking cmdlets or permissions are reported as unavailable;
remaining checks continue. No administrator access is normally required.

Reports contain machine names/internal addresses: review before sharing. Nothing
is automatically sent to a ticket system or saved into Git.

Tests: `pwsh -NoProfile -File Tests/Test-ConnectionDoctor.Tests.ps1`
