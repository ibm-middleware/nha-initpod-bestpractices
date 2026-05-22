import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent
INIT_SH_SCRIPT = REPO_ROOT / "mq_vault_cert_init.sh"


def run(cmd, cwd, **kwargs):
    return subprocess.run(cmd, cwd=cwd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)


def generate_cert_material(workdir: Path):
    ca_key = workdir / "ca.key"
    ca_crt = workdir / "ca.crt"
    leaf_key = workdir / "tls.key"
    leaf_csr = workdir / "tls.csr"
    leaf_crt = workdir / "tls.crt"
    ext = workdir / "leaf.ext"
    ext.write_text(
        "subjectAltName=DNS:tmpqm001-qmgr.qa.aws.mycompany.org\n"
        "extendedKeyUsage=serverAuth,clientAuth\n",
        encoding="utf-8",
    )
    run(["openssl", "genrsa", "-out", str(ca_key), "2048"], workdir)
    run(
        [
            "openssl",
            "req",
            "-x509",
            "-new",
            "-nodes",
            "-key",
            str(ca_key),
            "-sha256",
            "-days",
            "30",
            "-subj",
            "/CN=MyCompany Test CA",
            "-out",
            str(ca_crt),
        ],
        workdir,
    )
    run(["openssl", "genrsa", "-out", str(leaf_key), "2048"], workdir)
    run(
        [
            "openssl",
            "req",
            "-new",
            "-key",
            str(leaf_key),
            "-subj",
            "/CN=tmpqm001-qmgr.qa.aws.mycompany.org",
            "-out",
            str(leaf_csr),
        ],
        workdir,
    )
    run(
        [
            "openssl",
            "x509",
            "-req",
            "-in",
            str(leaf_csr),
            "-CA",
            str(ca_crt),
            "-CAkey",
            str(ca_key),
            "-CAcreateserial",
            "-out",
            str(leaf_crt),
            "-days",
            "30",
            "-sha256",
            "-extfile",
            str(ext),
        ],
        workdir,
    )
    return {
        "tls.key": leaf_key.read_text(encoding="utf-8"),
        "tls.crt": leaf_crt.read_text(encoding="utf-8"),
        "ca.crt": ca_crt.read_text(encoding="utf-8"),
    }


class FakeVaultHandler(BaseHTTPRequestHandler):
    token = "root"
    secret_map = {}
    requested_paths = []

    def do_GET(self):
        self.requested_paths.append(self.path)
        if self.headers.get("X-Vault-Token") != self.token:
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b'{"errors":["permission denied"]}')
            return
        
        # Determine secret based on request path
        matched_path = None
        for path in self.secret_map:
            if self.path.startswith(path):
                matched_path = path
                break
                
        if matched_path:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"data": {"data": self.secret_map[matched_path]}}).encode("utf-8"))
            return
            
        self.send_response(404)
        self.end_headers()

    def log_message(self, fmt, *args):
        return


class BashInitContainerTest(unittest.TestCase):
    def setUp(self):
        if not shutil.which("openssl"):
            self.skipTest("openssl is required")
        if not shutil.which("curl"):
            self.skipTest("curl is required")
        self.tmp = tempfile.TemporaryDirectory()
        self.workdir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_fetches_pem_triplet_from_vault_and_writes_mq_layout_using_bash(self):
        material = generate_cert_material(self.workdir)
        FakeVaultHandler.requested_paths = []
        
        # Populate map for mock Vault KV v2 paths
        FakeVaultHandler.secret_map = {
            "/v1/kv/data/mq/TMPQM001/app-pki": {
                "tls.key": material["tls.key"],
                "tls.crt": material["tls.crt"],
                "ca.crt": material["ca.crt"],
            },
            "/v1/kv/data/mq/TMPQM001/nha-tls": {
                "tls.key": material["tls.key"],
                "tls.crt": material["tls.crt"],
                "ca.crt": material["ca.crt"],
            },
            "/v1/kv/data/mq/TMPQM001/nhacrr-tls": {
                "tls.key": material["tls.key"],
                "tls.crt": material["tls.crt"],
                "ca.crt": material["ca.crt"],
            }
        }
        
        server = HTTPServer(("127.0.0.1", 0), FakeVaultHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        
        try:
            output_dir = self.workdir / "out"
            
            # Setup environment variables for Bash script
            env = dict(os.environ)
            env["VAULT_ADDR"] = f"http://127.0.0.1:{server.server_port}"
            env["VAULT_TOKEN"] = FakeVaultHandler.token
            env["VAULT_KV_MOUNT"] = "kv"
            env["VAULT_CERT_BASE_PATH"] = "mq/TMPQM001"
            env["QM_NAME"] = "TMPQM001"
            env["OUT_DIR"] = str(output_dir)
            
            proc = subprocess.run(
                ["/bin/bash", str(INIT_SH_SCRIPT)],
                cwd=REPO_ROOT,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            
            self.assertEqual(proc.returncode, 0, f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}")
            
            # Check created file structure and properties
            self.assertTrue((output_dir / "pki" / "keys" / "default" / "tls.key").is_file())
            self.assertTrue((output_dir / "pki" / "keys" / "default" / "tls.crt").is_file())
            self.assertTrue((output_dir / "pki" / "keys" / "default" / "ca.crt").is_file())
            self.assertTrue((output_dir / "ha" / "pki" / "keys" / "ha-vault" / "tls.key").is_file())
            self.assertTrue((output_dir / "ha" / "pki" / "keys" / "ha-vault" / "tls.crt").is_file())
            self.assertTrue((output_dir / "groupha" / "pki" / "keys" / "groupha" / "tls.key").is_file())
            self.assertTrue((output_dir / "groupha" / "pki" / "keys" / "ha-group" / "tls.key").is_file())
            self.assertTrue((output_dir / "groupha" / "pki" / "trust" / "remote" / "ca.crt").is_file())
            self.assertTrue((output_dir / "pki" / "trust" / "default" / "ca.crt").is_file())
            self.assertTrue((output_dir / ".mq-certs-ready").is_file())
            self.assertTrue(any("nhacrr-tls" in path for path in FakeVaultHandler.requested_paths))
            
            # Validate permissions
            self.assertEqual(os.stat(output_dir / "pki" / "keys" / "default" / "tls.key").st_mode & 0o777, 0o600)
            self.assertEqual(os.stat(output_dir / "pki" / "keys" / "default" / "tls.crt").st_mode & 0o777, 0o644)
            self.assertEqual(os.stat(output_dir / "pki" / "keys" / "default" / "ca.crt").st_mode & 0o777, 0o644)
            
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
