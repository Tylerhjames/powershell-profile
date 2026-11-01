using System;
using System.Diagnostics;
using System.Net.Http;
using System.Net.Security;
using System.Threading.Tasks;
using System.Linq;

namespace RoamingProfile {
    // Compiled on first use. TLS callbacks run on .NET threads, not PowerShell runspaces.
    public sealed class WebsiteHop {
        public string Url, Location, Error, Subject, Issuer, Thumbprint, PolicyErrors, ChainStatus;
        public DateTime? NotBeforeUtc, NotAfterUtc;
        public int Status;
        public long Milliseconds;
        public bool CertificateSeen, NameMatches;
    }
    public static class WebsiteProbe {
        public static async Task<WebsiteHop> Check(string url, int timeoutMs) {
            var result = new WebsiteHop { Url = url };
            var timer = Stopwatch.StartNew();
            using (var handler = new HttpClientHandler()) {
                handler.AllowAutoRedirect = false;
                handler.UseCookies = false;
                handler.UseDefaultCredentials = false;
                handler.CheckCertificateRevocationList = true;
                handler.MaxResponseHeadersLength = 32;
                handler.ServerCertificateCustomValidationCallback = (request, cert, chain, errors) => {
                    result.PolicyErrors = errors.ToString();
                    if (cert != null) {
                        result.CertificateSeen = true;
                        result.Subject = cert.Subject;
                        result.Issuer = cert.Issuer;
                        result.Thumbprint = cert.Thumbprint;
                        result.NotBeforeUtc = cert.NotBefore.ToUniversalTime();
                        result.NotAfterUtc = cert.NotAfter.ToUniversalTime();
                        result.NameMatches = (errors & SslPolicyErrors.RemoteCertificateNameMismatch) == 0;
                        result.ChainStatus = chain == null ? "Unavailable" : string.Join("; ", chain.ChainStatus.Select(s => s.Status.ToString()));
                    }
                    return errors == SslPolicyErrors.None;
                };
                using (var client = new HttpClient(handler)) {
                    client.Timeout = TimeSpan.FromMilliseconds(timeoutMs);
                    client.DefaultRequestHeaders.UserAgent.ParseAdd("RoamingProfile-WebsiteCheck/1.0");
                    try {
                        using (var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false)) {
                            result.Status = (int)response.StatusCode;
                            result.Location = response.Headers.Location?.OriginalString;
                        }
                    } catch (OperationCanceledException) { result.Error = "Request timed out."; }
                      catch (Exception ex) { result.Error = ex.GetBaseException().Message; }
                }
            }
            result.Milliseconds = timer.ElapsedMilliseconds;
            return result;
        }
    }
}
