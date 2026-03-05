# Generate RSA 2048-bit keypair for Internal JWT signing (APISIX → Backend Services)
# Private key: mount into APISIX container only
# Public key: mount into all backend service containers
#
# Uses .NET RSACryptoServiceProvider — compatible with PowerShell 5.x / .NET Framework 4.x
# No openssl required.

$ErrorActionPreference = "Stop"

$KeyDir         = Join-Path (Join-Path $PSScriptRoot "..") "keys"
$PrivateKeyPath = Join-Path $KeyDir "internal-jwt-private.pem"
$PublicKeyPath  = Join-Path $KeyDir "internal-jwt-public.pem"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ARDA Internal JWT Keypair Generator" -ForegroundColor Cyan
Write-Host "  (using .NET RSACryptoServiceProvider — no openssl needed)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Create keys directory
if (-not (Test-Path $KeyDir)) {
    New-Item -ItemType Directory -Path $KeyDir -Force | Out-Null
    Write-Host "Created directory: $KeyDir" -ForegroundColor Green
}

# Check if keys already exist
if ((Test-Path $PrivateKeyPath) -or (Test-Path $PublicKeyPath)) {
    $response = Read-Host "Keys already exist. Overwrite? (y/N)"
    if ($response -ne "y") {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

# ── Helper: break base64 into 64-char lines (PEM standard) ───────────────────
function ConvertTo-PemLines([string]$b64) {
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $b64.Length; $i += 64) {
        $sb.AppendLine($b64.Substring($i, [Math]::Min(64, $b64.Length - $i))) | Out-Null
    }
    return $sb.ToString().TrimEnd()
}

# ── Helper: encode a length field in DER/ASN.1 ───────────────────────────────
function Get-DerLength([int]$len) {
    if ($len -lt 0x80) {
        return [byte[]]@($len)
    } elseif ($len -lt 0x100) {
        return [byte[]]@(0x81, $len)
    } else {
        return [byte[]]@(0x82, ($len -shr 8) -band 0xFF, $len -band 0xFF)
    }
}

Write-Host "`n--> Generating RSA 2048-bit keypair..." -ForegroundColor Yellow

$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)

try {
    # ── Export private key as PKCS#1 RSAPrivateKey DER, then wrap in PKCS#8 ─────
    # RSACryptoServiceProvider can export PKCS#1 via ExportCspBlob(true) or
    # via the XML round-trip.  We use ToXmlString then reconstruct manually via
    # a helper class available in all .NET Framework / Core versions.
    #
    # Simplest cross-version approach: write a C# helper inline

    $csharp = @"
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

public static class PemHelper {
    // Wrap base64 at 64 chars
    private static string WrapBase64(byte[] data) {
        string b64 = Convert.ToBase64String(data);
        var sb = new StringBuilder();
        for (int i = 0; i < b64.Length; i += 64)
            sb.AppendLine(b64.Substring(i, Math.Min(64, b64.Length - i)));
        return sb.ToString().TrimEnd();
    }

    public static void GenerateAndSave(string privatePath, string publicPath) {
        using (var rsa = new RSACryptoServiceProvider(2048)) {
            // --- Private key: PKCS#1 RSAPrivateKey PEM ---
            byte[] privDer = ExportPrivateKeyDer(rsa);
            string privPem = "-----BEGIN RSA PRIVATE KEY-----\n" + WrapBase64(privDer) + "\n-----END RSA PRIVATE KEY-----\n";
            File.WriteAllText(privatePath, privPem, Encoding.ASCII);

            // --- Public key: SubjectPublicKeyInfo (SPKI) PEM ---
            byte[] pubSpki = ExportPublicKeySpki(rsa);
            string pubPem = "-----BEGIN PUBLIC KEY-----\n" + WrapBase64(pubSpki) + "\n-----END PUBLIC KEY-----\n";
            File.WriteAllText(publicPath, pubPem, Encoding.ASCII);
        }
    }

    // Encode ASN.1 DER length
    private static byte[] DerLen(int len) {
        if (len < 0x80) return new byte[] { (byte)len };
        if (len < 0x100) return new byte[] { 0x81, (byte)len };
        return new byte[] { 0x82, (byte)(len >> 8), (byte)(len & 0xFF) };
    }

    // Strip leading 0x00 padding added to positive integers in DER
    private static byte[] Unsigned(byte[] b) {
        int i = 0;
        while (i < b.Length - 1 && b[i] == 0) i++;
        if (i == 0) return b;
        byte[] r = new byte[b.Length - i];
        Array.Copy(b, i, r, 0, r.Length);
        return r;
    }

    // Encode a byte array as a DER INTEGER
    private static byte[] DerInteger(byte[] val) {
        // Ensure positive: prepend 0x00 if high bit set
        if ((val[0] & 0x80) != 0) {
            byte[] tmp = new byte[val.Length + 1];
            tmp[0] = 0x00;
            Array.Copy(val, 0, tmp, 1, val.Length);
            val = tmp;
        }
        byte[] lenBytes = DerLen(val.Length);
        byte[] result = new byte[1 + lenBytes.Length + val.Length];
        result[0] = 0x02; // INTEGER tag
        Array.Copy(lenBytes, 0, result, 1, lenBytes.Length);
        Array.Copy(val, 0, result, 1 + lenBytes.Length, val.Length);
        return result;
    }

    // Build PKCS#1 RSAPrivateKey DER from RSAParameters
    private static byte[] ExportPrivateKeyDer(RSACryptoServiceProvider rsa) {
        RSAParameters p = rsa.ExportParameters(true);
        // PKCS#1 RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dp, dq, qinv }
        byte[] version = new byte[] { 0x02, 0x01, 0x00 }; // INTEGER 0
        byte[] n    = DerInteger(p.Modulus);
        byte[] e    = DerInteger(p.Exponent);
        byte[] d    = DerInteger(p.D);
        byte[] prP  = DerInteger(p.P);
        byte[] prQ  = DerInteger(p.Q);
        byte[] dp   = DerInteger(p.DP);
        byte[] dq   = DerInteger(p.DQ);
        byte[] qinv = DerInteger(p.InverseQ);

        int bodyLen = version.Length + n.Length + e.Length + d.Length +
                      prP.Length + prQ.Length + dp.Length + dq.Length + qinv.Length;
        byte[] lenBytes = DerLen(bodyLen);
        byte[] der = new byte[1 + lenBytes.Length + bodyLen];
        int pos = 0;
        der[pos++] = 0x30; // SEQUENCE tag
        Array.Copy(lenBytes, 0, der, pos, lenBytes.Length); pos += lenBytes.Length;
        foreach (var part in new[] { version, n, e, d, prP, prQ, dp, dq, qinv }) {
            Array.Copy(part, 0, der, pos, part.Length); pos += part.Length;
        }
        return der;
    }

    // Build SubjectPublicKeyInfo (SPKI) DER — wraps PKCS#1 RSAPublicKey
    private static byte[] ExportPublicKeySpki(RSACryptoServiceProvider rsa) {
        RSAParameters p = rsa.ExportParameters(false);
        // RSAPublicKey ::= SEQUENCE { n INTEGER, e INTEGER }
        byte[] n = DerInteger(p.Modulus);
        byte[] e = DerInteger(p.Exponent);
        int rsaPubLen = n.Length + e.Length;
        byte[] rsaPubLenBytes = DerLen(rsaPubLen);
        byte[] rsaPubDer = new byte[1 + rsaPubLenBytes.Length + rsaPubLen];
        int pos = 0;
        rsaPubDer[pos++] = 0x30;
        Array.Copy(rsaPubLenBytes, 0, rsaPubDer, pos, rsaPubLenBytes.Length); pos += rsaPubLenBytes.Length;
        Array.Copy(n, 0, rsaPubDer, pos, n.Length); pos += n.Length;
        Array.Copy(e, 0, rsaPubDer, pos, e.Length);

        // AlgorithmIdentifier for rsaEncryption: SEQUENCE { OID 1.2.840.113549.1.1.1, NULL }
        byte[] algId = new byte[] {
            0x30, 0x0D,
            0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
            0x05, 0x00
        };

        // BIT STRING wrapping the RSAPublicKey DER (prepend 0x00 unused-bits byte)
        byte[] bitStringContent = new byte[rsaPubDer.Length + 1];
        bitStringContent[0] = 0x00;
        Array.Copy(rsaPubDer, 0, bitStringContent, 1, rsaPubDer.Length);
        byte[] bsLenBytes = DerLen(bitStringContent.Length);
        byte[] bitString = new byte[1 + bsLenBytes.Length + bitStringContent.Length];
        pos = 0;
        bitString[pos++] = 0x03; // BIT STRING tag
        Array.Copy(bsLenBytes, 0, bitString, pos, bsLenBytes.Length); pos += bsLenBytes.Length;
        Array.Copy(bitStringContent, 0, bitString, pos, bitStringContent.Length);

        // SPKI SEQUENCE { algId, bitString }
        int spkiBodyLen = algId.Length + bitString.Length;
        byte[] spkiLenBytes = DerLen(spkiBodyLen);
        byte[] spki = new byte[1 + spkiLenBytes.Length + spkiBodyLen];
        pos = 0;
        spki[pos++] = 0x30;
        Array.Copy(spkiLenBytes, 0, spki, pos, spkiLenBytes.Length); pos += spkiLenBytes.Length;
        Array.Copy(algId, 0, spki, pos, algId.Length); pos += algId.Length;
        Array.Copy(bitString, 0, spki, pos, bitString.Length);
        return spki;
    }
}
"@

    Add-Type -TypeDefinition $csharp -Language CSharp

    [PemHelper]::GenerateAndSave($PrivateKeyPath, $PublicKeyPath)

    Write-Host "    Private key : $PrivateKeyPath" -ForegroundColor Green
    Write-Host "    Public key  : $PublicKeyPath" -ForegroundColor Green

} finally {
    $rsa.Dispose()
}

# ── .gitignore ────────────────────────────────────────────────────────────────
$gitignorePath = Join-Path $KeyDir ".gitignore"
Set-Content -Path $gitignorePath -Value "*.pem`n"
Write-Host "`n--> Created .gitignore in keys directory" -ForegroundColor Green

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  KEYPAIR GENERATED SUCCESSFULLY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Usage:" -ForegroundColor White
Write-Host "    Private key -> Mount into APISIX container" -ForegroundColor Gray
Write-Host "    Public key  -> Mount into backend services (classpath)" -ForegroundColor Gray
Write-Host ""
Write-Host "  For K8s:" -ForegroundColor White
Write-Host "    kubectl create secret generic arda-jwt-keys \" -ForegroundColor Gray
Write-Host "      --from-file=private.pem=$PrivateKeyPath \" -ForegroundColor Gray
Write-Host "      --from-file=public.pem=$PublicKeyPath" -ForegroundColor Gray
