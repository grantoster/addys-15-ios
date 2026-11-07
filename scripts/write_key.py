#!/usr/bin/env python3
"""Write the App Store Connect .p8 key from $ASC_KEY_P8 to the path in argv[1].
Accepts the key pasted with real line breaks, with literal \\n, without its
BEGIN/END lines, or as one base64 string of the whole file. Prints only
shape diagnostics, never key material."""
import base64, os, re, sys, textwrap

raw = os.environ.get("ASC_KEY_P8", "").strip().strip('"').strip("'")
if not raw:
    sys.exit("ASC_KEY_P8 is empty")
text = raw.replace("\\r", "").replace("\\n", "\n").replace("\r", "")

if "BEGIN PRIVATE KEY" not in text:
    try:
        dec = base64.b64decode(re.sub(r"\s+", "", text), validate=True).decode("utf-8", "strict")
        if "BEGIN PRIVATE KEY" in dec:
            text = dec
            print("key shape: base64 of the whole .p8 file")
    except Exception:
        pass

m = re.search(r"-----BEGIN PRIVATE KEY-----(.*?)-----END PRIVATE KEY-----", text, re.S)
body = m.group(1) if m else text
body = re.sub(r"[^A-Za-z0-9+/=]", "", body)
if len(body) < 100:
    sys.exit(f"ASC_KEY_P8 does not look like a .p8 key (only {len(body)} key characters)")
pem = "-----BEGIN PRIVATE KEY-----\n" + "\n".join(textwrap.wrap(body, 64)) + "\n-----END PRIVATE KEY-----\n"
with open(sys.argv[1], "w") as f:
    f.write(pem)
print(f"key shape: header {'found' if m else 'added'}, {len(body)} key characters, {pem.count(chr(10))} lines written")
