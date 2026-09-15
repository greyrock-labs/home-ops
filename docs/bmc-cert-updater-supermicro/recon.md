# SuperMicro BMC endpoint reconnaissance — 2026-09-15

Firmware: SuperMicro IPMI 03.95 (12/23/2021)
Hostname: kvm-homeassistant.internal.greyrock.io (10.1.20.14)

## Pre-existing cert

The BMC already serves a non-default cert that was installed today
by some path other than this plan; observed via `openssl s_client`
just before and just after the sample upload (the BMC rejected the
junk CSR, so the live fingerprint is unchanged across the run):

- **subject:** `CN=kvm-homeassistant.internal.greyrock.io, O=LocalCA`
- **issuer:** `CN=Grey Rock Intermediate CA, O=LocalCA`
- **notBefore:** `Sep 15 14:45:29 2026 GMT`
- **notAfter:** `Oct 18 14:45:29 2027 GMT`
- **sha256:** `15:D7:D9:85:EC:7A:E7:F4:71:A3:0A:FF:88:4B:98:7E:BC:F9:40:5C:20:1A:45:A8:B0:B0:C4:12:1E:67:14:4B`

Worth surfacing: when this CronJob first runs and detects a leaf
mismatch, it will overwrite today's manually-set cert with the
cluster's `*.internal.greyrock.io` LE leaf. If that's not desired,
reconcile before the CronJob's first scheduled run.

## Login

- **URL:** `https://kvm-homeassistant.internal.greyrock.io/cgi/login.cgi`
- **Method:** POST
- **Body fields:** `name`, `pwd` (form-encoded; the submit button is
  named `Login` and is not a payload field). The form's `action` on
  the unauthenticated `/` page is `/cgi/login.cgi`.
- **Success response:** `200 OK`, body is the post-login redirect
  shell:
  ```html
  <script>self.location = "../cgi/url_redirect.cgi?url_name=mainmenu";</script>
  ```
  Set-Cookie: `SID=<hex>` (e.g. `SID=0h4VepZ4mFcwjW4`,
  `SID=ihPZptlcpMumZJM`, … — server-rotated per login; HttpOnly).
- **Failure response:** the same endpoint returns `200 OK` plus a
  different body (`SessionTimeout` shell) with no `Set-Cookie` —
  there is no per-failure status code, so the script must check for
  the presence of a `SID` cookie in the jar.

## Cert upload page (csrf source)

- **URL:** `https://kvm-homeassistant.internal.greyrock.io/cgi/url_redirect.cgi?url_name=config_ssl`
- Discovered via the topmenu's Configuration > SSL link:
  `javascript:page_mapping('configuration', 'config_ssl')` (the
  `page_mapping` function issues the `url_name=config_ssl` redirect
  when the user clicks that submenu).
- 200 OK, `text/html`, ~7775 bytes. Session cookie required.

**Form input fields (`name` → source-of-value):**

| `name`     | source-of-value                                                |
|------------|----------------------------------------------------------------|
| `cert_file`| user-selected file, `<input type="file">` (`id="sslcrt_file"`) |
| `key_file` | user-selected file, `<input type="file">` (`id="privkey_file"`)|
| `CSRF_TOKEN` | injected at page-load time by JS: `SmcCsrfInsert("CSRF_TOKEN", "<base64>")` → `_doCsrfInsert` in `/js/utils.js` appends a hidden `<input type="hidden" name="CSRF_TOKEN" value="…">` to every form on the page |

The CSRF field name is **`CSRF_TOKEN`** (uppercase, no underscore
prefix), confirmed both from the JS source (`SmcCsrfInsert
("CSRF_TOKEN", "…")`) and from the `uploadCert()` function which
submits via `form.submit()` after appending the hidden field. For
XHR paths, `_doCsrfInsert` would also set a custom request header
named `CSRF_TOKEN` — but `uploadCert()` uses a real form submit, so
the script must send CSRF as a multipart field, not a header.

The original brief's awk/grep pattern assumed `_csrf_token` /
`csrf_token` / `csrftoken` / `TOKEN` as candidates; none of those
matched. The correct extraction is:
`grep -oE 'SmcCsrfInsert *\( *"CSRF_TOKEN" *, *"[^"]*"' body.html | sed 's/.*, *"\([^"]*\)"$/\1/'`

## Upload endpoint

- **URL:** `https://kvm-homeassistant.internal.greyrock.io/cgi/upload_ssl.cgi`
- **Method:** POST multipart (form enctype `multipart/form-data`,
  confirmed in the upload page's `<form>` tag).
- **Form fields:**
  - `cert_file` — PEM-encoded leaf cert (BMC also accepts `.cert`)
  - `key_file` — PEM-encoded private key (must end `.pem`)
  - `CSRF_TOKEN` — single base64-shaped string; ~43 chars in the
    observed sessions (`XT3wSHgEz4r/z+q2T4q4xrMMUu9FeweWIw0zMEWfGlc`,
    `tAW59RB/REsM7yXaTUlaywHKnM2CuHaD7jZbweI6hv0`,
    `9h769M8gEEp/JzB4Z66IxtcMmanDryVEtT6ABnYQp54`).
- **Response on failure (e.g. dummy CSR uploaded):** `200 OK`,
  `text/html`, ~8065 bytes — the BMC re-renders the same
  `url_name=config_ssl` page. On page-load, the BMC fires an AJAX
  `POST /cgi/ipmi.cgi?SSL_VALIDATE.XML=(0,0)`. If `VALIDATE` is `0`,
  the page calls `alert(lang.LANG_CONFIG_SSL_CRTFAILED)` ("certificate
  validation failed") and bounces to `CONFPAGE`. The BMC does **not**
  return a dedicated HTTP error code for a bad cert — the script must
  detect success via the post-upload `SSL_STATUS.XML` round-trip and
  the served-leaf comparison in the script's retry loop, **not** by
  curl's HTTP status. The BMC's currently-served leaf fingerprint
  remained identical across the probe run, confirming the BMC rejected
  the junk CSR and did not apply it.
- **Response on success:** expected `200 OK` with the same re-rendered
  page; client-side AJAX calls `SSLReadingResult` which shows
  `lang.LANG_CONFIG_SSL_SUCCSAVE` ("certificate successfully saved")
  via `NewConfirmWin` and then bounces to `CONFPAGE_RESET` (which
  triggers the BMC web-server restart that the design's retry loop is
  meant to ride out).

## Decisions

- **Login:** `curl -ksS -c <jar> -d "name=$UN" -d "pwd=$HP"
  https://kvm-homeassistant.internal.greyrock.io/cgi/login.cgi` —
  capture the session `SID` cookie from the jar.
- **Cert page fetch:** `curl -ksS -b <jar>
  https://kvm-homeassistant.internal.greyrock.io/cgi/url_redirect.cgi?url_name=config_ssl`
  — must be the exact `url_name=config_ssl` (not `ssl_cert_upload`,
  `certificate_upload`, `upload_ssl`, or `ssl_upload` — those either
  404 or are the upload endpoint, not the form page).
- **CSRF extraction:** `csrf=$(grep -oE 'SmcCsrfInsert *\( *"CSRF_TOKEN" *, *"[^"]*"'
  "$page" | head -1 | sed 's/.*, *"\([^"]*\)"$/\1/')`
- **Upload:** `curl -ksS -b <jar> -F cert_file=@tls.crt -F
  key_file=@tls.key -F "CSRF_TOKEN=$csrf"
  https://kvm-homeassistant.internal.greyrock.io/cgi/upload_ssl.cgi`
- **Failure detection:** a 200 from `upload_ssl.cgi` does **not**
  indicate success — verify by re-reading the BMC's served leaf and
  matching against `/certs/tls.crt` (per the design's retry loop);
  also poll `https://kvm-homeassistant.internal.greyrock.io/cgi/ipmi.cgi?SSL_STATUS.XML=(0,0)`
  for `VALID_FROM`/`VALID_UNTIL` if a non-reboot success path is
  needed.

## Discrepancies from design assumptions

| design.md assumption                | recon finding                                                                 |
|-------------------------------------|-------------------------------------------------------------------------------|
| Login URL = `/cgi/login.cgi`        | **matches.**                                                                  |
| Cert page URL = `url_name=ssl_cert_upload` | **WRONG.** Actual: `url_name=config_ssl`. The brief's `ssl_cert_upload` and `certificate_upload` candidates both 404. |
| CSRF field name = `_csrf_token`     | **WRONG.** Actual field name: `CSRF_TOKEN` (uppercase, no underscore prefix). The token is injected client-side via `SmcCsrfInsert` in `/js/utils.js`, not present in the static HTML. |
| Upload URL = `/cgi/upload_ssl.cgi`  | **matches.**                                                                  |
| Upload form fields = `cert_file`, `key_file`, `_csrf_token` | **partly WRONG.** Field names are `cert_file`, `key_file`, `CSRF_TOKEN`. CSRF must be a multipart field (not a header) because `uploadCert()` uses `form.submit()`, not XHR. |
| Failure response shape (any)        | **WRONG.** BMC returns `200 OK` with a re-rendered config page; failure is detected client-side via `SSL_VALIDATE.XML` AJAX. The script's retry loop should not rely on HTTP status alone. |

All five discrepancies propagate into Task 4's upload script; the
script must use `url_name=config_ssl`, multipart field
`CSRF_TOKEN=<base64>`, and a served-leaf comparison (not HTTP
status) for success detection.
