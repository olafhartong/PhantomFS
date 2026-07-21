# YAML Synthetic Data (`--syntheticyaml`)

Lets PhantomFS load its decoy file list and file content from a YAML file
instead of the `<syntheticFileList>` / `<syntheticTemplates>` blocks in
`PhantomFS.exe.config`. Everything under `<settings>` (alerts, cleanup,
verbose, etc.) still comes from the XML config as usual.

## Enable it

```
PhantomFS.exe --virtroot C:\Honeypot --syntheticonly --syntheticyaml C:\Honeypot\synthetic-data.yml
```

Or embed the path for scheduled tasks/services that run with no CLI args:

```xml
<settings>
  <syntheticYamlPath>C:\Honeypot\synthetic-data.yml</syntheticYamlPath>
</settings>
```

## Schema

```yaml
files:
  - path: AWS/credentials      # "/" or "\" both work
    directory: false           # default: false
    size: 116                  # bytes, default: 0
    timestamp: 1741508986      # unix seconds, default: 0

templates:
  - name: credentials          # exact filename match ...
  - extension: .pdf            # ... or extension fallback (pick one)
    content: |
      plain text content, padded/truncated to the entry's "size"

  - name: id_rsa
    type: pem                  # generates a fake PEM block
    pemLabel: RSA PRIVATE KEY

  - name: logo.png
    type: base64               # real binary, base64-encoded
    content: |
      iVBORw0KGgo...

  - name: deck.pptx
    type: base64gzip           # real binary, gzip then base64 (compact)
    content: |
      H4sIAAAAAAAA...
```

## Notes

- `type: base64` / `type: base64gzip` decode is **lazy** (happens on first
  read, then cached) so embedding many binaries doesn't slow startup.
- The `files:` entry's `size:` must equal the exact **decoded** byte
  length, or the content gets truncated/padded and most binary formats
  (`.pdf`, `.docx`/`.xlsx`, images) will fail to open. A mismatch logs a
  one-time `[WARN]` on first read.
- `type="base64"` / `type="base64gzip"` also work in the XML
  `<template>` element, for parity.
