using System;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.IO;
using System.Text;
using System.Threading.Tasks;
public sealed class WebsiteFixture : IDisposable {
    readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
    readonly bool tls;
    readonly X509Certificate2 certificate;
    public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;
    public WebsiteFixture(bool secure) {
        tls=secure;
        if(tls) {
            using(var rsa=RSA.Create(2048)) {
                var req=new CertificateRequest("CN=wrong.example",rsa,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
                using(var generated=req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-10),DateTimeOffset.UtcNow.AddDays(-1)))
                    certificate=X509CertificateLoader.LoadPkcs12(generated.Export(X509ContentType.Pfx),null,X509KeyStorageFlags.Exportable);
            }
        }
        listener.Start(); _ = Run();
    }
    async Task Run() {
        while(true) { TcpClient c; try {c=await listener.AcceptTcpClientAsync();} catch {break;} _=Serve(c); }
    }
    async Task Serve(TcpClient c) {
        using(c) try {
            Stream s=c.GetStream();
            if(tls) {var ssl=new SslStream(s); await ssl.AuthenticateAsServerAsync(certificate); s=ssl;}
            using(s) using(var reader=new StreamReader(s,Encoding.ASCII,false,1024,true)) {
                var first=await reader.ReadLineAsync(); if(first==null)return;
                string line; while(!string.IsNullOrEmpty(line=await reader.ReadLineAsync())) {}
                var path=first.Split(' ')[1].Split('?')[0];
                string status="200 OK", extra="";
                if(path=="/redirect") {status="302 Found";extra="Location: /ok\r\n";}
                if(path=="/loop") {status="301 Moved";extra="Location: /loop\r\n";}
                if(path=="/bad") {status="302 Found";extra="Location: ftp://example.com/file\r\n";}
                if(path=="/missing") status="404 Not Found";
                if(path=="/auth") status="401 Unauthorized";
                if(path=="/noloc") status="302 Found";
                if(path=="/slow") await Task.Delay(1800);
                var data=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+"\r\n"+extra+"Content-Length: 0\r\nConnection: close\r\n\r\n");
                await s.WriteAsync(data,0,data.Length);
            }
        } catch {}
    }
    public void Dispose(){listener.Stop();certificate?.Dispose();}
}
