"""Write a PEM private key from an env var to a file (mode 600), tolerant to copy/paste accidents:
Windows line endings, leading/trailing spaces, line breaks lost (key on one line). Prints the SHA-256 fingerprint
of the PUBLIC key, to compare with RSA_PUBLIC_KEY_FP in `DESC USER` (the fingerprint is not secret).
Usage: KEY="$SECRET" python scripts/ci/write_key.py /tmp/key.p8"""
import base64
import hashlib
import os
import re
import sys
import textwrap

from cryptography.hazmat.primitives import serialization

raw = os.environ["KEY"].replace("\r", "").strip()
body = re.sub(r"\s+", "", re.sub(r"-----(BEGIN|END) PRIVATE KEY-----", "", raw))
pem = "-----BEGIN PRIVATE KEY-----\n" + "\n".join(textwrap.wrap(body, 64)) + "\n-----END PRIVATE KEY-----\n"
key = serialization.load_pem_private_key(pem.encode(), password=None)          # fails loudly if the secret is wrong
der = key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
print("public key fingerprint: SHA256:" + base64.b64encode(hashlib.sha256(der).digest()).decode())
old = os.umask(0o077)
with open(sys.argv[1], "w") as f:
    f.write(pem)
os.umask(old)
