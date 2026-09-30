import json
import logging
import os
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ecs_client = boto3.client("ecs")
iam_client = boto3.client("iam")

CLUSTER_NAME = os.environ.get("CLUSTER_NAME")
AGENT_ROLE_NAME = os.environ.get("AGENT_ROLE_NAME")

DENY_ALL_POLICY = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "EmergencyCircuitBreakerDenyAll",
            "Effect": "Deny",
            "Action": "*",
            "Resource": "*"
        }
    ]
}


def lambda_handler(event: dict, context) -> dict:
    """
    Emergency containment handler triggered by EventBridge.
    1. Attaches an immediate inline DenyAll policy to the agent task role.
    2. Identifies and terminates all running ECS agent tasks.
    """
    logger.warning("CIRCUIT BREAKER TRIGGERED: Intercepted containment event.")
    logger.info("Event payload: %s", json.dumps(event))

    actions_taken = []

    # Step 1: Revoke Agent IAM credentials via inline DenyAll
    if AGENT_ROLE_NAME:
        try:
            iam_client.put_role_policy(
                RoleName=AGENT_ROLE_NAME,
                PolicyName="EmergencyDenyAllQuarantine",
                PolicyDocument=json.dumps(DENY_ALL_POLICY)
            )
            logger.info(
                "Successfully attached DenyAll quarantine policy to role: %s", AGENT_ROLE_NAME)
            actions_taken.append(f"Quarantined IAM Role: {AGENT_ROLE_NAME}")
        except ClientError as e:
            logger.error("Failed to attach quarantine policy: %s", e)
            raise e

    # Step 2: Terminate running ECS agent tasks
    if CLUSTER_NAME:
        try:
            task_arns = ecs_client.list_tasks(
                cluster=CLUSTER_NAME,
                desiredStatus="RUNNING"
            ).get("taskArns", [])

            logger.info(
                "Discovered running tasks for termination: %s", task_arns)

            for task_arn in task_arns:
                ecs_client.stop_task(
                    cluster=CLUSTER_NAME,
                    task=task_arn,
                    reason="Circuit breaker tripped: Budget overrun or anomalous agent behavior."
                )
                logger.warning("Terminated running task: %s", task_arn)
                actions_taken.append(f"Terminated Task: {task_arn}")

        except ClientError as e:
            logger.error("Failed to terminate ECS tasks: %s", e)
            raise e

    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "CONTAINED",
            "actions": actions_taken
        })
    }
