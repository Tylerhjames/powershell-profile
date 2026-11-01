param([string]$Source=(Join-Path $PSScriptRoot '../Functions/Test-WebsiteCertificate.ps1'))
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
. $Source
foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -match '-Wc'},$true)) { . ([scriptblock]::Create($node.Extent.Text)) }
$script:passed=0
function Assert($Condition,$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:passed++; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Code) { $failed=$false;try { & $Code | Out-Null } catch {$failed=$true}; Assert $failed 'Invalid input rejected' }
Assert ((ConvertTo-WcUri 'example.com').AbsoluteUri -eq 'https://example.com/') 'Hostname defaults to HTTPS'
Assert ((ConvertTo-WcUri 'http://localhost:8080/path?q=x#fragment').AbsoluteUri -eq 'http://localhost:8080/path?q=x') 'Port/path/query retained; fragment removed'
Reject { ConvertTo-WcUri 'https://user:secret@example.com' }
Reject { ConvertTo-WcUri 'ftp://example.com' }
Reject { ConvertTo-WcUri "example.com`ncommand" }
Reject { Test-WebsiteCertificate -NoPrompt }
Assert ((Format-WcUrl ([uri]'https://example.com/path?token=SECRET')) -notmatch 'SECRET') 'Ticket URL redacts query'
$html=New-WcClipboardHtml "🌐 Report`n✓ Good <tag>"
Assert ($html.Contains('#8fa880') -and $html.Contains('&lt;tag&gt;')) 'Clipboard color and HTML escaping'
$bytes=[Text.Encoding]::UTF8.GetBytes($html)
$null=$html -match 'StartFragment:(\d+)';$start=[int]$Matches[1]
$null=$html -match 'EndFragment:(\d+)';$end=[int]$Matches[1]
$fragment=[Text.Encoding]::UTF8.GetString($bytes,$start,$end-$start)
Assert ($fragment.StartsWith('<div') -and $fragment.EndsWith('</div>')) 'Clipboard UTF-8 fragment offsets'
Add-Type -Path (Join-Path $PSScriptRoot 'WebsiteFixture.cs')
$server=[WebsiteFixture]::new($false); $tls=[WebsiteFixture]::new($true)
try {
    $base="http://127.0.0.1:$($server.Port)"
    $r=Test-WebsiteCertificate "$base/redirect?token=SECRET" -NoPrompt -PassThru
    Assert ($r.Hops.Count -eq 2 -and $r.Hops[-1].Status -eq 200) 'Relative redirect reaches success'
    Assert ($r.Summary -notmatch 'SECRET' -and $r.Summary -match 'unencrypted') 'Report redaction and HTTP warning'
    $r=Test-WebsiteCertificate "$base/loop" -NoPrompt -PassThru
    Assert ($r.Hops.Count -eq 1 -and $r.Assessment -match 'loop') 'Redirect loop bounded'
    $r=Test-WebsiteCertificate "$base/redirect" -MaxRedirects 0 -NoPrompt -PassThru
    Assert ($r.Hops.Count -eq 1 -and $r.Assessment -match 'limit') 'Redirect limit enforced'
    $r=Test-WebsiteCertificate "$base/bad" -NoPrompt -PassThru
    Assert ($r.Assessment -match 'unsupported') 'Unsupported redirect blocked'
    $r=Test-WebsiteCertificate "$base/noloc" -NoPrompt -PassThru
    Assert ($r.Assessment -match 'no Location') 'Missing redirect location reported'
    $r=Test-WebsiteCertificate "$base/missing" -NoPrompt -PassThru
    Assert ($r.Hops[0].Status -eq 404 -and $r.Assessment -notmatch 'successful') 'HTTP error preserved'
    $r=Test-WebsiteCertificate "$base/auth" -NoPrompt -PassThru
    Assert ($r.Hops[0].Status -eq 401 -and $r.Assessment -match 'authentication') 'Authentication required without login'
    $r=Test-WebsiteCertificate "$base/slow" -TimeoutMs 500 -NoPrompt -PassThru
    Assert ($r.Assessment -match 'timed out') 'Timeout bounded'
    $r=Test-WebsiteCertificate "https://127.0.0.1:$($tls.Port)/" -NoPrompt -PassThru
    Assert ($r.Hops[0].CertificateSeen -and $r.Hops[0].Status -eq 0) 'Invalid certificate captured but request rejected'
    Assert (-not $r.Hops[0].NameMatches -and $r.Summary -match 'NotTimeValid' -and $r.Assessment -match 'validation failed') 'Mismatch, expired certificate and trust failure reported'
} finally {$server.Dispose(); $tls.Dispose()}
Write-Host "Passed $script:passed checks."
