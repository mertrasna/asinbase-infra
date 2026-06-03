"""Night-down handler for the dev EC2 instance.

Invoked by two EventBridge schedules:
  - {"action": "stop"}  at 00:00 Europe/Berlin -> power the instance off
  - {"action": "start"} at 08:00 Europe/Berlin -> power it back on

The instance ID is injected via the INSTANCE_ID environment variable, so the
function stays generic and never has an instance ID hard-coded in it.
"""

import os

import boto3

ec2 = boto3.client("ec2")


def handler(event, context):
    instance_id = os.environ["INSTANCE_ID"]
    action = event.get("action")

    if action == "stop":
        ec2.stop_instances(InstanceIds=[instance_id])
    elif action == "start":
        ec2.start_instances(InstanceIds=[instance_id])
    else:
        raise ValueError(f"unknown action {action!r}, expected 'stop' or 'start'")

    print(f"{action} requested for {instance_id}")
    return {"action": action, "instance_id": instance_id}
