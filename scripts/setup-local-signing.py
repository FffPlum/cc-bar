#!/usr/bin/env python3
"""Create a persistent local code-signing identity. Never run during a build."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile


CONFIG = Path.home() / "Library/Application Support/CCBar/local-signing.json"
NAME = "CCBar Local Signing"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    if CONFIG.exists():
        identity = json.loads(CONFIG.read_text())["identity"]
        identities = run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning",
                         capture_output=True, text=True).stdout
        if identity not in identities:
            raise SystemExit("本机签名配置存在，但证书不可用；请恢复原证书与私钥，不要重新生成。")
        print(f"复用固定签名身份：{identity}")
        return

    # Refuse to silently replace an existing identity when only its config is lost.
    certificates = subprocess.run(
        ["/usr/bin/security", "find-certificate", "-c", NAME, "-Z"],
        capture_output=True, text=True)
    if certificates.returncode == 0:
        raise SystemExit("钥匙串已有 CCBar Local Signing；请恢复配置并复用原身份，不要重复创建。")

    keychain = run("/usr/bin/security", "default-keychain", "-d", "user",
                   capture_output=True, text=True).stdout.strip().strip('"')
    # Directory is mode 0700; key and archive disappear after import, including
    # failed attempts. The persistent private key stays in the login keychain.
    with tempfile.TemporaryDirectory(prefix="ccbar-local-signing-") as folder:
        root = Path(folder)
        os.chmod(root, 0o700)
        config = root / "openssl.cnf"
        config.write_text("""[req]
distinguished_name = subject
x509_extensions = codesign
prompt = no
[subject]
CN = CCBar Local Signing
[codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
        private_key, certificate, archive = (root / f for f in ("key.pem", "cert.pem", "identity.p12"))
        run("/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes",
            "-days", "3650", "-config", str(config), "-keyout", str(private_key),
            "-out", str(certificate), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        os.chmod(private_key, 0o600)
        password = secrets.token_urlsafe(32)
        run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(private_key),
            "-in", str(certificate), "-out", str(archive), "-passout", "stdin",
            input=(password + "\n").encode(), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        os.chmod(archive, 0o600)
        der = run("/usr/bin/openssl", "x509", "-in", str(certificate), "-outform", "DER",
                  capture_output=True).stdout
        identity = hashlib.sha1(der).hexdigest().upper()
        run("/usr/bin/security", "import", str(archive), "-k", keychain,
            "-P", password, "-T", "/usr/bin/codesign")
        # Trust only for code signing in this user's trust settings, not TLS or
        # system-wide roots. macOS may request user authentication here.
        run("/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
            "-k", keychain, str(certificate))
        identities = run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning",
                         capture_output=True, text=True).stdout
        if identity not in identities:
            raise SystemExit("证书已导入，但未通过代码签名验证；请在钥匙串访问中检查它。")
        CONFIG.parent.mkdir(parents=True, exist_ok=True)
        # This file contains only the public fingerprint, never a private key.
        CONFIG.write_text(json.dumps({"identity": identity, "name": NAME}, indent=2) + "\n")
        os.chmod(CONFIG, 0o600)
        print(f"固定签名身份已配置：{identity}")
        print(f"本机配置：{CONFIG}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        # Commands may contain the temporary PKCS#12 password. Never print argv.
        raise SystemExit(f"本机证书配置未完成，系统工具退出码 {error.returncode}。") from None
