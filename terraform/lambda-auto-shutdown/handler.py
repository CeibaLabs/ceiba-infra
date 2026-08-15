"""Ceiba billing circuit breaker.

Invoked via SNS when the CloudWatch AWS/Billing EstimatedCharges alarm fires
(cloudwatch-billing-alarm.tf). Stops the Ceiba app EC2 instance to arrest a
slow cost leak. Deliberately does NOT touch RDS — stopping RDS only pauses
billing for up to 7 days before AWS silently restarts it (see the
billing-guardrail runbook, maintained privately).

Resolves the target instance by its Name tag (TARGET_INSTANCE_NAME) rather
than a hardcoded instance ID, since the ID isn't known until after the first
`terraform apply`.
"""

import os

import boto3

TARGET_INSTANCE_NAME = os.environ["TARGET_INSTANCE_NAME"]
TARGET_REGION = os.environ["TARGET_REGION"]


def lambda_handler(event, context):
    print("Billing alarm triggered:", event)

    ec2 = boto3.client("ec2", region_name=TARGET_REGION)

    described = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [TARGET_INSTANCE_NAME]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )
    instance_ids = [
        instance["InstanceId"]
        for reservation in described["Reservations"]
        for instance in reservation["Instances"]
    ]

    if not instance_ids:
        print(f"No running instance tagged Name={TARGET_INSTANCE_NAME}; nothing to stop.")
        return {"statusCode": 200, "body": "No running target instance found."}

    response = ec2.stop_instances(InstanceIds=instance_ids)
    print("Stop response:", response)
    return {
        "statusCode": 200,
        "body": f"Stopped instances: {instance_ids}",
    }
