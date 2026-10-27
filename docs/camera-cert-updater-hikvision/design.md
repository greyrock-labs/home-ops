# Hikvision camera certificate updater

## Targets and credentials

`camera-cert-updater-hikvision` runs in `network`. Its mounted `cameras.json`
lists each camera's hostname and the environment variable holding its password.

| Camera (`.internal.greyrock.io`) | Address | Model | Firmware | 1Password field |
| --- | --- | --- | --- | --- |
| `garage-camera-todd` | `10.1.60.11` | DS-2CD2087G2H-LIU/SL | V5.7.17 build 240606 | `garage-camera-todd` |
| `garage-camera-andy` | `10.1.60.12` | DS-2CD2087G2H-LIU/SL | V5.7.17 build 240606 | `garage-camera-andy` |
| `side-yard-camera` | `10.1.60.13` | DS-2CD2386G2-ISU/SL | V5.7.19 build 241207 | `side-yard-camera` |

The username is hardcoded to the camera's built-in `admin` account. The
`Cert Updater` item in the Kubernetes 1Password vault supplies the
camera-specific password fields through an app-template ExternalSecret.
Certificate import requires `admin`: an Operator account receives HTTP 403
(`lowPrivilege`) even with `parameterConfig=true`.

The shared `internal-greyrock-io-tls` Secret provides the RSA 2048-bit wildcard
certificate and private key. The CronJob checks daily at 03:15 in the controller's
timezone, forbids concurrent runs, and does not retry failed Jobs. Egress allows
only camera TCP 443 plus the namespace's existing DNS allowance.

Cameras run sequentially with separate Digest authentication state, salts, and
passwords. Every camera reports its hostname and result. A failure, missing
password, or timeout fails that camera and processing continues with the next.
The Job exits nonzero if any camera failed and prints the success/failure counts.
Each camera has a 600-second limit; the Job has no fixed overall deadline that
could cut off later cameras as the list grows. `--check` covers the entire list
without changing any camera.

To add a camera, inspect its current state, add its hostname and password-variable
name to `app/config/cameras.json`, map that variable to its exact 1Password field
in the HelmRelease's `externalSecrets.data`, and allow its address on TCP 443 in
`networkpolicies`. No script changes are needed. Passwords stay out of the camera
list and ConfigMap. All camera hostnames are validated and duplicates are rejected
before processing starts.

## Import protocol

The implementation follows this firmware's own web interface:

- `/doc/js/33_chunk.5677bef03ef271e6dfe7.js.gz` implements certificate management.
- `/doc/js/default~root-application_chunk.ebfc4e6d43626a94ef62.js.gz` implements
  security capability queries, key derivation, and AES encryption.

These static assets and the following GET endpoints were inspected directly on
the camera. Hikvision's [ISAPI documentation portal](https://tpp.hikvision.com/download/)
provides model-specific developer guides.

1. Validate the desired certificate, hostname, RSA key size, and key pairing.
   Compare the served DER leaf certificate; when current, verify its trust chain
   and hostname before exiting without an authenticated request.
2. Read `/ISAPI/System/time` and reject a clock more than one day from the Job's
   clock before making changes. Maintain correct camera time through its own
   settings; this updater does not configure time or NTP.
3. GET `/ISAPI/Security/capabilities?username=admin` for the user-specific
   salt and iteration count. Derive the AES-128 key exactly as the UI does:
   SHA256(username + salt + password), then SHA256(hash + `AaBbCcDd1234!@#$`),
   then repeat SHA256 over the hex text for the remaining iterations.
4. Read `/ISAPI/Security/certificate/select/HTTPS?format=json` and
   `/ISAPI/Security/serverCertificate/certificates?format=json`. Alternate the
   reserved slots `certupdaterA` and `certupdaterB`. Certificate IDs must be
   alphanumeric; a hyphen causes `customIDIllegal`. Reclaim the inactive slot
   only when its inventory `type` is empty; refuse to replace a slot used by any
   other function. These slots are reserved for this updater and must not be
   populated manually. The initial read-only inventory contains only `default`.
5. POST multipart data to
   `/ISAPI/Security/serverCertificate/certificate?customID=<slot>&security=1&iv=<hex>`.
   The `CertificateReq` XML field sets `certificateMode=privateKey`,
   `privateKeyMode=seperateKey` (firmware spelling), an empty
   `seperateKeyPassword`, and `dataType=certificate`. The `certificateKHFile`
   file field contains the certificate bundle.
6. POST the private key to the same URL, with `dataType=privateKey` and the
   `importPrivateKey` text field. Encode key bytes as lowercase hex then base64,
   NUL-pad that text to a 16-byte boundary, then AES-128-CBC encrypt with PKCS#7
   padding. Send the ciphertext as lowercase hex. Each import response must
   confirm the requested `customID`. This firmware nests the value inside two
   namespaced `customID` elements; ignore whitespace-only wrapper text.
7. PUT the existing HTTPS selection object with only `serverCertificate`
   changed. Poll for a trusted TLS connection serving exactly the desired leaf.
   Selection takes a few seconds to affect new TLS connections.
   The previous certificate remains installed. There is no reboot or automatic
   rollback; a failed verification fails the Job.

ISAPI requests use HTTP Digest over HTTPS, tolerating the device's existing
untrusted certificate to permit replacement. Final TLS verification uses the
runtime CA store and checks the hostname. The camera serves only the leaf, even
when imported as a full PEM bundle or PKCS#12 file. Verification supplies the
missing intermediates from the mounted certificate bundle. Self-issued roots
are excluded from that supplemental bundle, and partial-chain trust is disabled,
so validation must reach a root already trusted by the runtime. Other clients
also need the intermediate certificates available to validate this camera.
API responses and credentials are not
printed. Python's standard library supplies HTTP, XML, JSON, and TLS; OpenSSL
supplies certificate/key validation and AES. The pinned full Python Debian image
contains OpenSSL, so the Job needs no runtime package downloads.

## Validation and operation

Offline tests require OpenSSL 3 (the pinned runtime provides it; macOS LibreSSL
does not implement the same certificate validation flags). They exercise the
encryption against an independent Node crypto vector,
multipart encoding, idempotence, preflight, clock rejection, slot rotation,
preservation of certificates in use, import failures, and TLS verification failure:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 docs/camera-cert-updater-hikvision/test_updater.py
```

`--check` runs certificate and read-only device preflight without deleting,
importing, or selecting certificates. It needs the mounted certificate and the
updater's own credentials. It cannot establish that write permissions or uploads
work. Local live tests verify PEM certificate/private-key import with `admin`,
HTTPS selection, chain validation using the mounted intermediates, and a second
run that exits without changes. The original `default` certificate is retained.
A Job created from the Flux-deployed CronJob also succeeds inside the `network`
namespace, verifying the current certificate with bundled intermediates and
exiting without changes. Renewal rotation remains unverified.

An authorized manual run uses the deployed CronJob:

```sh
kubectl -n network create job camera-cert-updater-hikvision-manual --from=cronjob/camera-cert-updater-hikvision
```

If import fails, the current HTTPS binding remains unchanged. Inspect sanitized
Job logs and camera permissions before retrying. If HTTPS selection succeeds but
verification fails, inspect the selected slot and certificate chain; the updater
retains the previous slot for manual recovery. Only HTTPS is rebound; SRTP and
SDK-over-TLS retain their own selections.
