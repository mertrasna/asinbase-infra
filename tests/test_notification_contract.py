"""Offline cross-repository contract and deployment-boundary checks; no AWS SDK."""
import hashlib
import json
import os
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "modules/notification_operations"

class NotificationContract(unittest.TestCase):
    def test_canonical_contract_integrity_and_optional_app_parity(self):
        raw = (MODULE / "operational-telemetry-v1.json").read_bytes()
        expected = (MODULE / "operational-telemetry-v1.sha256").read_text().split()[0]
        self.assertEqual(hashlib.sha256(raw).hexdigest(), expected)
        source = os.environ.get("ASINBASE_APP_CONTRACT")
        if source:
            self.assertEqual(raw, Path(source).read_bytes(), "Application and infrastructure contracts differ")

    def test_every_metric_pair_is_finite_allowlisted_and_filter_count_is_bounded(self):
        contract = json.loads((MODULE / "operational-telemetry-v1.json").read_text())
        self.assertEqual(contract["event"], "operational_metric_v1")
        self.assertFalse(contract["privacy"]["additional_fields"])
        filters = 0
        for name, definition in contract["metrics"].items():
            self.assertIn(definition["unit"], ["count", "seconds", "tokens"])
            self.assertIn(definition["kind"], ["counter", "gauge"])
            allowed = [component for component, metrics in contract["components"].items() if name in metrics]
            self.assertTrue(allowed, name)
            filters += (len(allowed) + 7) // 8
        # Leave space beneath CloudWatch's 100 filters/log-group for nine existing filters.
        self.assertLessEqual(filters, 80)
        for component, metrics in contract["components"].items():
            self.assertRegex(component, r"^[a-z0-9_]+$")
            self.assertEqual(len(metrics), len(set(metrics)))
            self.assertTrue(set(metrics) <= contract["metrics"].keys())
        for component in contract["unavailable_producers"]:
            self.assertIn("CapabilityUnavailable", contract["components"][component])
        self.assertNotIn("recommendation_email", contract["components"])

    def test_roots_pin_independent_boundaries_and_default_off(self):
        for environment, project in [("dev", "nehqpiqhdodkmyalpfpx"), ("prod", "bbzowpqwdqamcrmwahch")]:
            source = (ROOT / "environments" / environment / "notification_operations.tf").read_text()
            self.assertIn(f'"{environment}"', source)
            self.assertIn(project, source)
            self.assertIn(f"aws_iam_role.ec2_{environment}.name", source)
            self.assertIn(f"aws_cloudwatch_log_group.{environment}.name", source)
            self.assertRegex(source, r'variable "notification_operations_enabled"\s*\{[^}]*default\s*=\s*false')
            self.assertNotIn('default = true', source)

    def test_no_provisioner_parameter_secret_subscription_or_cloud_workflow(self):
        source = "\n".join(p.read_text() for p in MODULE.glob("*.tf"))
        for forbidden in ['"aws_ssm_parameter"', '"aws_secretsmanager_secret"', '"aws_sns_topic_subscription"', '"local-exec"', '"remote-exec"', 'sqs:PurgeQueue', 'sqs:*', 'Resource = "*"']:
            self.assertNotIn(forbidden, source)
        workflow = (ROOT / ".github/workflows/notification-contracts.yml").read_text()
        for forbidden in ["aws-actions/", "terraform apply", "terraform plan", "role-to-assume", "id-token: write"]:
            self.assertNotIn(forbidden, workflow)

if __name__ == "__main__":
    unittest.main()
