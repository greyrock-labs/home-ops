"""Offline protocol and failure-path checks; never connects to a camera."""

import datetime
import importlib.util
import io
from pathlib import Path
import ssl
import subprocess
import tempfile
import unittest
import urllib.error
from unittest.mock import patch
import xml.etree.ElementTree as ET


SCRIPT = (Path(__file__).resolve().parents[2] / "kubernetes/apps/network/"
          "camera-cert-updater-hikvision/app/config/push-certs.py")
spec = importlib.util.spec_from_file_location("updater", SCRIPT)
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)

CAP = b"""<SecurityCap><keyIterateNum>100</keyIterateNum>
<isIrreversible>true</isIrreversible><salt>test-salt</salt>
<isSupportEncryptCertificate>true</isSupportEncryptCertificate></SecurityCap>"""


class FakeCamera:
    host = "garage-camera-todd.internal.greyrock.io"

    def __init__(self, desired):
        self.desired = desired
        self.current = b"old-leaf"
        self.writes = []
        self.entries = [{"customID": "default", "type": "HTTPS,SRTP"}]
        self.selected = {"CertificateSelect": {"serverCertificate": "default", "CACertificate": "unchanged"}}
        self.clock = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.fail_upload = None
        self.fail_validation = False
        self.fail_select = False

    def request(self, path):
        if path == "/ISAPI/System/time":
            return f"<Time><localTime>{self.clock}</localTime></Time>".encode()
        assert path == "/ISAPI/Security/capabilities?username=certupdater"
        return CAP

    def inventory(self):
        return self.entries

    def selection(self):
        return self.selected

    def served_leaf(self, verify=False):
        if verify and self.fail_validation:
            raise ssl.SSLError("test verification failure")
        return self.current

    def delete_unused_slot(self, slot):
        self.writes.append(("delete", slot))

    def upload(self, slot, kind, value, key, iv):
        self.writes.append(("upload", slot, kind))
        if kind == self.fail_upload:
            raise updater.UpdateError("Test import failure")

    def set_selection(self, selection):
        self.writes.append(("select", selection["CertificateSelect"]["serverCertificate"]))
        if self.fail_select:
            raise updater.UpdateError("Test selection failure")
        self.current = self.desired


class UpdaterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem"),
                        "-days", "2", "-subj", "/CN=garage-camera-todd.internal.greyrock.io",
                        "-addext", "subjectAltName=DNS:garage-camera-todd.internal.greyrock.io"],
                       check=True, capture_output=True)
        cls.cert = (root / "cert.pem").read_bytes()
        cls.key = (root / "key.pem").read_bytes()
        cls.der = ssl.PEM_cert_to_DER_cert(cls.cert.decode())

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.camera = FakeCamera(self.der)

    def run_update(self, check=False):
        with patch.object(updater.time, "sleep"):
            updater.update(self.camera, self.cert, self.key, "certupdater", "test-password", check)

    def test_web_ui_encryption_matches_independent_node_crypto_vector(self):
        key = updater.aes_key(ET.fromstring(CAP), "certupdater", "test-password")
        self.assertEqual(key, "a5b42d72f10cdf93b7300f647c07c204")
        self.assertEqual(updater.encrypt_key(b"test-private-key\n", key,
                                            "00112233445566778899aabbccddeeff"),
                         "cad472bb76d9dda2265cefd939b40a10e15fec30406b110981c6ea20079c30d742"
                         "291bbaebac380525c5776d18f0fbce75fe8ddbffa258727b3776328d247235")

    def test_bundled_self_signed_root_does_not_extend_trusted_roots(self):
        self.assertEqual(updater.intermediate_bundle(self.cert + self.cert), "")

    def test_http_failure_reports_status_without_response_secrets_or_query(self):
        camera = updater.Camera(self.camera.host, "certupdater", "test-password")
        error = urllib.error.HTTPError(camera.base, 403, "Forbidden", {}, io.BytesIO(
            b"<ResponseStatus><subStatusCode>lowPrivilege</subStatusCode>"
            b"<password>must-not-print</password></ResponseStatus>"))
        with patch.object(camera.opener, "open", side_effect=error):
            with self.assertRaises(updater.UpdateError) as result:
                camera.request("/test?private=query", "POST", b"private-body")
        self.assertEqual(str(result.exception), "POST /test: HTTP 403 (lowPrivilege)")

    def test_upload_uses_firmware_multipart_field_names_and_encrypted_key(self):
        camera = updater.Camera(self.camera.host, "certupdater", "test-password")
        # This firmware wraps the value in two namespaced customID elements.
        response = b'<customID xmlns="http://www.hikvision.com/ver20/XMLSchema">\n<customID>certupdaterA</customID>\n</customID>'
        with patch.object(camera, "request", return_value=response) as request:
            camera.upload("certupdaterA", "certificate", self.cert, "11" * 16, "22" * 16)
            body = request.call_args.args[2]
            self.assertIn(b'name="CertificateReq"', body)
            self.assertIn(b'name="certificateKHFile"; filename="server.crt"', body)
            self.assertIn(b"<dataType>certificate</dataType>", body)
            camera.upload("certupdaterA", "privateKey", self.key, "11" * 16, "22" * 16)
            body = request.call_args.args[2]
            self.assertIn(b'name="importPrivateKey"', body)
            self.assertIn(b"<privateKeyMode>seperateKey</privateKeyMode>", body)
            self.assertNotIn(self.key, body)

    def test_current_certificate_does_not_write(self):
        self.camera.current = self.der
        self.run_update()
        self.assertEqual(self.camera.writes, [])

    def test_matching_leaf_still_requires_trusted_https(self):
        self.camera.current = self.der
        self.camera.fail_validation = True
        with self.assertRaises(ssl.SSLError):
            self.run_update()
        self.assertEqual(self.camera.writes, [])

    def test_preflight_does_not_write(self):
        self.run_update(check=True)
        self.assertEqual(self.camera.writes, [])

    def test_invalid_clock_aborts_before_writes(self):
        self.camera.clock = "1970-01-01T00:00:00+08:00"
        with self.assertRaisesRegex(updater.UpdateError, "clock"):
            self.run_update()
        self.assertEqual(self.camera.writes, [])

    def test_wrong_hostname_aborts_before_writes(self):
        self.camera.host = "different.internal.greyrock.io"
        with self.assertRaisesRegex(updater.UpdateError, "hostname"):
            self.run_update()
        self.assertEqual(self.camera.writes, [])

    def test_mismatched_private_key_aborts_before_writes(self):
        other_key = updater.openssl("genrsa", "2048")
        with self.assertRaisesRegex(updater.UpdateError, "do not match"):
            updater.update(self.camera, self.cert, other_key, "certupdater", "test-password")
        self.assertEqual(self.camera.writes, [])

    def test_import_order_and_previous_certificate_retained(self):
        self.run_update()
        self.assertEqual(self.camera.writes, [("upload", "certupdaterA", "certificate"),
                                             ("upload", "certupdaterA", "privateKey"),
                                             ("select", "certupdaterA")])
        self.assertEqual(self.camera.selected["CertificateSelect"]["CACertificate"], "unchanged")

    def test_rotation_reclaims_only_inactive_updater_slot(self):
        self.camera.selected["CertificateSelect"]["serverCertificate"] = "certupdaterA"
        self.camera.entries.append({"customID": "certupdaterB", "type": ""})
        self.run_update()
        self.assertEqual(self.camera.writes[0], ("delete", "certupdaterB"))
        self.assertEqual(self.camera.writes[-1], ("select", "certupdaterB"))

    def test_slot_used_by_other_function_is_preserved(self):
        self.camera.entries.append({"customID": "certupdaterA", "type": "SRTP"})
        with self.assertRaisesRegex(updater.UpdateError, "another function"):
            self.run_update()
        self.assertEqual(self.camera.writes, [])

    def test_import_failure_never_changes_binding(self):
        for kind in ["certificate", "privateKey"]:
            with self.subTest(kind=kind):
                self.camera = FakeCamera(self.der)
                self.camera.fail_upload = kind
                with self.assertRaises(updater.UpdateError):
                    self.run_update()
                self.assertFalse(any(write[0] == "select" for write in self.camera.writes))
                self.assertFalse(any(write == ("delete", "default") for write in self.camera.writes))

    def test_selection_failure_preserves_previous_slot(self):
        self.camera.fail_select = True
        with self.assertRaises(updater.UpdateError):
            self.run_update()
        self.assertFalse(any(write[0] == "delete" for write in self.camera.writes))

    def test_failed_verification_does_not_report_success_or_delete_previous_slot(self):
        self.camera.fail_validation = True
        with self.assertRaisesRegex(updater.UpdateError, "previous slot retained"):
            self.run_update()
        self.assertFalse(any(write[0] == "delete" for write in self.camera.writes))


if __name__ == "__main__":
    unittest.main()
