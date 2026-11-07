import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

spec = importlib.util.spec_from_file_location("runtime", Path(__file__).parents[2] / "deploy/portainer/imagens/runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeTests(unittest.TestCase):
    def test_invalid_names(self):
        for stack, owner in [("a;rm", "teste"), ("deskcomm", "../outro"), ("", "teste")]:
            with self.assertRaises(ValueError):
                runtime.Observer(stack, owner)

    def test_proof_checks_official_tag_and_ancestry(self):
        with tempfile.TemporaryDirectory() as directory:
            observer = runtime.Observer("deskcomm", "teste", directory)
            with patch.object(runtime, "command", return_value="a" * 40) as command:
                self.assertEqual(observer.proof("b" * 40, "1.102.0"), "a" * 40)
                calls = [c.args for c in command.call_args_list]
                self.assertTrue(any(runtime.OFFICIAL in c for c in calls))
                self.assertTrue(any("merge-base" in c and "--is-ancestor" in c for c in calls))
                self.assertTrue(any("refs/tags/v1.102.0:refs/runtime-base/v1.102.0" in c for c in calls))

    def test_bad_ancestry_cannot_be_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            observer = runtime.Observer("deskcomm", "teste", directory)
            def command(*args):
                if "merge-base" in args:
                    raise subprocess.CalledProcessError(1, "git")
                return "a" * 40
            with patch.object(runtime, "command", side_effect=command):
                with self.assertRaises(subprocess.CalledProcessError):
                    observer.proof("b" * 40, "1.102.0")
                self.assertEqual(observer.proofs, {})

    def test_report_uses_internal_endpoint_and_header_without_executing_response(self):
        observer = runtime.Observer("deskcomm", "teste")
        observation = {"services": [{"base_version": "1.102.0", "revision": "b" * 40}]}
        with patch.object(observer, "collect", return_value=observation), \
                patch.object(observer, "token", return_value="segredo-falso"), \
                patch.object(runtime.urllib.request, "urlopen") as send, \
                patch.object(runtime.Path, "touch") as touch:
            send.return_value.__enter__.return_value.status = 200
            observer.report()
            request = send.call_args.args[0]
            self.assertEqual(request.full_url, "http://app:3000/api/v1/system/agent")
            self.assertEqual(request.get_header("Authorization"), "Bearer segredo-falso")
            payload = json.loads(request.data)
            self.assertFalse(payload["supports_forced_update"])
            self.assertNotIn("segredo-falso", request.data.decode())
            self.assertEqual(payload["runtime_confirmation"], observation)
            touch.assert_called_once()

    def test_failed_report_does_not_refresh_health(self):
        observer = runtime.Observer("deskcomm", "teste")
        with patch.object(observer, "collect", return_value={"services": [{"base_version": None, "revision": None}]}), \
                patch.object(observer, "token", return_value="segredo-falso"), \
                patch.object(runtime.urllib.request, "urlopen", side_effect=HTTPError("http://app", 401, "", {}, None)), \
                patch.object(runtime.Path, "touch") as touch:
            with self.assertRaises(HTTPError):
                observer.report()
            touch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
