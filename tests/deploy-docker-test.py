"""Exercise deployment validation and transport routing without contacting a host."""

import os
from pathlib import Path
import re
import subprocess
import unittest

import yaml


ACTION = yaml.safe_load(
    (Path(__file__).resolve().parents[1] / "actions/deploy-docker/action.yml")
    .read_text()
)
INPUT = re.compile(r"\$\{\{ inputs\.([a-z_]+) \}\}")


def inputs(**overrides):
    values = {
        name: str(spec.get("default", ""))
        for name, spec in ACTION["inputs"].items()
    }
    values.update(ssh_key="target-key", ssh_host="target", ssh_username="deploy")
    values.update(overrides)
    return values


def render(text, values):
    return INPUT.sub(lambda match: values[match[1]], text)


def validate(**overrides):
    values = inputs(**overrides)
    step = ACTION["runs"]["steps"][0]
    env = os.environ | {
        name: render(value, values) for name, value in step["env"].items()
    }
    return subprocess.run(
        ["bash", "-c", render(step["run"], values)],
        env=env,
        capture_output=True,
        text=True,
    )


class DeploymentTransportTest(unittest.TestCase):
    def test_direct_key_and_password_connections_remain_valid(self):
        for auth in ({}, {"ssh_key": "", "ssh_password": "target-password"}):
            with self.subTest(auth=auth):
                self.assertEqual(validate(**auth).returncode, 0)

    def test_gateway_accepts_a_separate_key(self):
        result = validate(
            ssh_proxy_host="gateway",
            ssh_proxy_username="forwarder",
            ssh_proxy_key="gateway-key",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_target_configuration_fails_before_deployment(self):
        for name in ("ssh_host", "ssh_port", "ssh_username"):
            with self.subTest(name=name):
                result = validate(**{name: ""})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name.upper(), result.stdout)

    def test_gateway_cannot_replace_target_authentication(self):
        result = validate(
            ssh_key="",
            ssh_proxy_host="gateway",
            ssh_proxy_username="forwarder",
            ssh_proxy_key="gateway-key",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("inputs.ssh_key or inputs.ssh_password", result.stdout)

    def test_incomplete_gateway_configuration_fails_before_deployment(self):
        for gateway in (
            {"ssh_proxy_host": "gateway"},
            {"ssh_proxy_host": "gateway", "ssh_proxy_username": "forwarder"},
            {"ssh_proxy_host": "gateway", "ssh_proxy_key": "gateway-key"},
            {"ssh_proxy_username": "forwarder"},
            {"ssh_proxy_key": "gateway-key"},
        ):
            with self.subTest(gateway=gateway):
                result = validate(**gateway)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("::error::", result.stdout)

    def test_every_upload_and_command_routes_through_the_same_gateway(self):
        # A missing proxy on even the cleanup or optional image-upload step can
        # make deployment fail midway against a private target.
        transports = [
            step
            for step in ACTION["runs"]["steps"]
            if step.get("uses", "").startswith(("appleboy/ssh-", "appleboy/scp-"))
        ]
        self.assertTrue(any("scp-action" in step["uses"] for step in transports))
        self.assertTrue(any("ssh-action" in step["uses"] for step in transports))
        for gateway in (
            {},
            dict(
                ssh_proxy_host="gateway",
                ssh_proxy_port="4444",
                ssh_proxy_username="forwarder",
                ssh_proxy_key="gateway-key",
            ),
        ):
            values = inputs(**gateway)
            for step in transports:
                with self.subTest(step=step["name"], gateway=gateway):
                    actual = {
                        key: render(step["with"][key], values)
                        for key in (
                            "host", "username", "key", "proxy_host",
                            "proxy_port", "proxy_username", "proxy_key",
                        )
                    }
                    self.assertEqual(actual, dict(
                        host="target", username="deploy", key="target-key",
                        proxy_host=values["ssh_proxy_host"],
                        proxy_port=values["ssh_proxy_port"],
                        proxy_username=values["ssh_proxy_username"],
                        proxy_key=values["ssh_proxy_key"],
                    ))
        self.assertEqual(inputs()["ssh_proxy_port"], "22")


if __name__ == "__main__":
    unittest.main(verbosity=2)
