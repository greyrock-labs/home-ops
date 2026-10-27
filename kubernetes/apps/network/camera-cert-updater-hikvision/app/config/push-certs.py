#!/usr/bin/env python3
"""Sync the internal certificate using the Hikvision V5.7.17 web UI's ISAPI flow."""

import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


class UpdateError(Exception):
    pass


def openssl(*args, data=None):
    result = subprocess.run(
        ["openssl", *args], input=data, capture_output=True, check=False
    )
    if result.returncode:
        # Never print OpenSSL input, output, or arguments: they may contain a key.
        raise UpdateError("OpenSSL validation or encryption failed")
    return result.stdout


def xml_value(root, name):
    return next((node.text.strip() for node in root.iter()
                 if node.tag.split("}")[-1] == name
                 and node.text and node.text.strip()), "")


def intermediate_bundle(bundle):
    intermediates = []
    for certificate in re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", bundle, re.S)[1:]:
        names = openssl("x509", "-noout", "-subject", "-issuer", data=certificate).decode().splitlines()
        subject, issuer = [line.split("=", 1)[1].strip() for line in names]
        # A bundled root must not extend the runtime's trusted root set.
        if subject != issuer:
            intermediates.append(certificate.decode())
    return "\n".join(intermediates)


def aes_key(capabilities, username, password):
    iterations = int(xml_value(capabilities, "keyIterateNum"))
    if not 1 <= iterations <= 100000:
        raise UpdateError("Unsupported key derivation iteration count")
    value = password
    if xml_value(capabilities, "isIrreversible") == "true":
        salt = xml_value(capabilities, "salt")
        if not salt:
            raise UpdateError("Missing user-specific security salt")
        value = hashlib.sha256((username + salt + password).encode()).hexdigest()
    value = hashlib.sha256((value + "AaBbCcDd1234!@#$").encode()).hexdigest()
    for _ in range(1, iterations):
        value = hashlib.sha256(value.encode()).hexdigest()
    return value[:32]


def encrypt_key(private_key, key, iv):
    # The firmware encodes file bytes as lowercase hex, then base64; it pads
    # that text with NULs to a block boundary before AES-CBC with PKCS#7 padding.
    text = base64.b64encode(private_key.hex().encode())
    text += b"\0" * (-len(text) % 16)
    return openssl("enc", "-aes-128-cbc", "-K", key, "-iv", iv, data=text).hex()


def multipart(fields):
    boundary = "hikvision-" + secrets.token_hex(16)
    body = bytearray()
    for name, value in fields.items():
        body.extend(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"".encode())
        if isinstance(value, bytes):
            body.extend(b'; filename="server.crt"\r\nContent-Type: application/x-x509-ca-cert')
        body.extend(b"\r\n\r\n")
        body.extend(value if isinstance(value, bytes) else value.encode())
        body.extend(b"\r\n")
    body.extend(f"--{boundary}--\r\n".encode())
    return bytes(body), "multipart/form-data; boundary=" + boundary


class Camera:
    def __init__(self, host, username, password):
        self.host = host
        self.base = "https://" + host
        self.intermediates = ""
        manager = urllib.request.HTTPPasswordMgrWithDefaultRealm()
        manager.add_password(None, self.base, username, password)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPDigestAuthHandler(manager),
            urllib.request.HTTPSHandler(context=context),
        )

    def request(self, path, method="GET", data=None, content_type="application/json"):
        request = urllib.request.Request(
            self.base + path, data=data, method=method,
            headers={"Content-Type": content_type},
        )
        try:
            with self.opener.open(request, timeout=30) as response:
                body = response.read(1024 * 1024 + 1)
        except urllib.error.HTTPError as error:
            # Report only a short machine-readable status, never a response
            # body that could echo certificate data or credentials.
            detail = ""
            try:
                failure = ET.fromstring(error.read(65536))
                status = xml_value(failure, "subStatusCode")
                if re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", status):
                    detail = " (" + status + ")"
            except (ET.ParseError, OSError):
                pass
            raise UpdateError(f"{method} {path.split('?')[0]}: HTTP {error.code}{detail}") from None
        except (OSError, urllib.error.URLError) as error:
            raise UpdateError(f"{method} {path.split('?')[0]}: connection failed") from error
        if len(body) > 1024 * 1024:
            raise UpdateError("Oversized ISAPI response")
        return body

    def inventory(self):
        response = json.loads(self.request(
            "/ISAPI/Security/serverCertificate/certificates?format=json"))
        return response["ServerCertificates"]["CertificateInfoList"]["CertificateInfo"]

    def selection(self):
        return json.loads(self.request(
            "/ISAPI/Security/certificate/select/HTTPS?format=json"))

    def served_leaf(self, verify=False):
        context = ssl.create_default_context() if verify else ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        if verify and self.intermediates:
            context.load_verify_locations(cadata=self.intermediates)
            # Supply missing intermediate certificates without making them
            # trust anchors: the chain must still reach a system-trusted root.
            context.verify_flags &= ~ssl.VERIFY_X509_PARTIAL_CHAIN
        if not verify:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        with socket.create_connection((self.host, 443), timeout=10) as connection:
            with context.wrap_socket(connection, server_hostname=self.host) as tls:
                return tls.getpeercert(binary_form=True)

    def upload(self, slot, kind, value, key, iv):
        root = ET.Element("CertificateReq")
        for name, text in (("certificateMode", "privateKey"),
                           ("privateKeyMode", "seperateKey"),
                           ("seperateKeyPassword", ""), ("dataType", kind)):
            ET.SubElement(root, name).text = text
        fields = {"CertificateReq": ET.tostring(root, encoding="unicode")}
        if kind == "certificate":
            fields["certificateKHFile"] = value
        else:
            fields["importPrivateKey"] = encrypt_key(value, key, iv)
        body, content_type = multipart(fields)
        query = urllib.parse.urlencode({"customID": slot, "security": "1", "iv": iv})
        response = ET.fromstring(self.request(
            "/ISAPI/Security/serverCertificate/certificate?" + query,
            "POST", body, content_type))
        if xml_value(response, "customID") != slot:
            raise UpdateError(f"Camera did not confirm {kind} import")

    def set_selection(self, selection):
        body = self.request("/ISAPI/Security/certificate/select/HTTPS?format=json",
                            "PUT", json.dumps(selection).encode())
        if json.loads(body).get("statusCode") != 1:
            raise UpdateError("Camera rejected HTTPS certificate selection")

    def delete_unused_slot(self, slot):
        body = self.request(
            "/ISAPI/Security/serverCertificate/certificates/" + slot + "?format=json",
            "DELETE")
        if json.loads(body).get("statusCode") != 1:
            raise UpdateError("Camera rejected removal of inactive updater certificate")


def update(camera, cert, private_key, username, password, check_only=False):
    match = re.search(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", cert, re.S)
    if not match:
        raise UpdateError("No PEM leaf certificate found")
    leaf = match.group() + b"\n"
    camera.intermediates = intermediate_bundle(cert)
    desired = ssl.PEM_cert_to_DER_cert(leaf.decode())
    openssl("x509", "-noout", "-checkend", "0", data=leaf)
    try:
        hostname_check = openssl("x509", "-noout", "-checkhost", camera.host, data=leaf)
    except UpdateError:
        raise UpdateError("Desired certificate does not cover the camera hostname") from None
    if not hostname_check.rstrip().endswith(b" does match certificate"):
        raise UpdateError("Desired certificate does not cover the camera hostname")
    public_key = openssl("x509", "-pubkey", "-noout", data=leaf)
    rsa_info = openssl("rsa", "-pubin", "-text", "-noout", data=public_key)
    if not re.search(rb"\((1024|2048) bit\)", rsa_info):
        raise UpdateError("Camera requires a 1024- or 2048-bit RSA certificate")
    public_der = openssl("pkey", "-pubin", "-outform", "DER", data=public_key)
    if public_der != openssl("pkey", "-pubout", "-outform", "DER", data=private_key):
        raise UpdateError("Certificate and private key do not match")
    if camera.served_leaf() == desired:
        if camera.served_leaf(verify=True) != desired:
            raise UpdateError("Certificate changed during verification")
        print("Served certificate is current and validates with bundled intermediates; nothing to do.")
        return

    # Check prerequisites before touching even the inactive certificate slot.
    clock = ET.fromstring(camera.request("/ISAPI/System/time"))
    now = datetime.datetime.fromisoformat(xml_value(clock, "localTime"))
    if now.tzinfo is None or abs((now - datetime.datetime.now(datetime.timezone.utc)).total_seconds()) > 86400:
        raise UpdateError("Camera clock differs by more than a day; fix its time settings first")
    capabilities = ET.fromstring(camera.request(
        "/ISAPI/Security/capabilities?" + urllib.parse.urlencode({"username": username})))
    if xml_value(capabilities, "isSupportEncryptCertificate") != "true":
        raise UpdateError("Encrypted certificate import is not supported")
    selection = camera.selection()
    active = selection["CertificateSelect"]["serverCertificate"]
    slot = "certupdaterB" if active == "certupdaterA" else "certupdaterA"
    inventory = camera.inventory()
    existing = next((entry for entry in inventory if entry["customID"] == slot), None)
    if existing and existing.get("type"):
        raise UpdateError("Inactive updater slot is used by another function; refusing to replace it")
    if check_only:
        print(f"Preflight passed; would import into {slot} and select it for HTTPS.")
        return
    key = aes_key(capabilities, username, password)
    if existing:
        camera.delete_unused_slot(slot)
    iv = secrets.token_hex(16)
    camera.upload(slot, "certificate", cert, key, iv)
    camera.upload(slot, "privateKey", private_key, key, iv)
    print("Imported certificate and encrypted private key.")
    selection["CertificateSelect"]["serverCertificate"] = slot
    camera.set_selection(selection)
    # Selection can restart the web server. Do not retry writes or reboot the
    # camera: wait for the actual served leaf and verify the chain and hostname.
    for attempt in range(24):
        try:
            if camera.served_leaf(verify=True) == desired:
                print("Camera is serving the new certificate; validates with bundled intermediates.")
                return
        except (OSError, ssl.SSLError):
            pass
        if attempt < 23:
            time.sleep(5)
    raise UpdateError("Camera did not serve a valid copy of the new certificate; previous slot retained")


def main():
    host = os.environ.get("HIKVISION_HOST", "garage-camera-todd.internal.greyrock.io")
    if not re.fullmatch(r"[a-zA-Z0-9.-]+", host):
        raise UpdateError("Invalid camera hostname")
    username = "admin"
    password = os.environ["HIKVISION_PASSWORD"]
    if not username or not password:
        raise UpdateError("Empty updater credentials")
    update(Camera(host, username, password),
           Path(os.environ.get("CERT_FILE", "/certs/tls.crt")).read_bytes(),
           Path(os.environ.get("KEY_FILE", "/certs/tls.key")).read_bytes(),
           username, password, check_only="--check" in sys.argv[1:])


if __name__ == "__main__":
    try:
        main()
    except (UpdateError, KeyError, ValueError, OSError, ET.ParseError) as error:
        # An API response can contain sensitive material. Only our controlled
        # UpdateError messages are safe to display.
        print("ERROR: " + (str(error) if isinstance(error, UpdateError)
                           else "Invalid configuration, input, or API response"), file=sys.stderr)
        sys.exit(1)
