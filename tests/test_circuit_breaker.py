import importlib.util
import json
import os
from pathlib import Path
import sys
from unittest.mock import MagicMock, patch

# 1. Set environment variables BEFORE module import
os.environ["CLUSTER_NAME"] = "ai-platform-dev-cluster"
os.environ["AGENT_ROLE_NAME"] = "ecs-agent-task-runtime-role"

# 2. Stub boto3 and botocore before importing handler
if "boto3" not in sys.modules:
    mock_boto3 = MagicMock()
    mock_botocore = MagicMock()

    class MockClientError(Exception):
        def __init__(self, error_response=None, operation_name=None):
            self.response = error_response or {
                "Error": {"Message": "Mock ClientError"}
            }
            super().__init__(str(self.response))

    mock_botocore_exceptions = MagicMock()
    mock_botocore_exceptions.ClientError = MockClientError
    mock_botocore.exceptions = mock_botocore_exceptions

    sys.modules["boto3"] = mock_boto3
    sys.modules["botocore"] = mock_botocore
    sys.modules["botocore.exceptions"] = mock_botocore_exceptions

# 3. Dynamically import handler
HANDLER_PATH = (
    Path(__file__).resolve().parent.parent
    / "src"
    / "kill_switch"
    / "handler.py"
)
spec = importlib.util.spec_from_file_location("handler", HANDLER_PATH)
handler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handler)

# Ensure module attributes are explicitly set
handler.CLUSTER_NAME = "ai-platform-dev-cluster"
handler.AGENT_ROLE_NAME = "ecs-agent-task-runtime-role"


def test_circuit_breaker_execution():
    mock_event = {
        "version": "0",
        "id": "mock-event-uuid-1234",
        "detail-type": "CircuitBreakerTripped",
        "source": "sandbox.security",
        "time": "2026-09-30T17:35:00Z",
        "region": "us-east-1",
        "resources": [],
        "detail": {
            "reason": (
                "Autonomous agent exceeded token burn threshold ($50.00 / hr"
                " limit breached)."
            ),
            "detected_vector": "Unbounded tool looping",
        },
    }

    print("\n--- SIMULATING CIRCUIT BREAKER TRIP ---")

    with (
        patch.object(handler, "iam_client") as mock_iam,
        patch.object(handler, "ecs_client") as mock_ecs,
    ):
        # Mock active worker tasks running in the cluster
        mock_ecs.list_tasks.return_value = {
            "taskArns": [
                "arn:aws:ecs:us-east-1:478076837031:task/ai-platform-dev-cluster/task-worker-001",
                "arn:aws:ecs:us-east-1:478076837031:task/ai-platform-dev-cluster/task-worker-002",
            ]
        }

        # Execute handler
        response = handler.lambda_handler(mock_event, None)

        # Assertion 1: IAM Quarantine Policy applied to agent runtime role
        mock_iam.put_role_policy.assert_called_once()
        call_args = mock_iam.put_role_policy.call_args[1]
        assert call_args["RoleName"] == "ecs-agent-task-runtime-role"
        assert call_args["PolicyName"] == "EmergencyDenyAllQuarantine"

        policy_doc = json.loads(call_args["PolicyDocument"])
        assert policy_doc["Statement"][0]["Effect"] == "Deny"
        assert policy_doc["Statement"][0]["Action"] == "*"
        print(
            "[+] PASS: IAM Quarantine policy successfully generated and attached."
        )

        # Assertion 2: All active tasks terminated
        assert mock_ecs.stop_task.call_count == 2
        print(
            f"[+] PASS: Verified termination calls issued for {mock_ecs.stop_task.call_count} running ECS tasks."
        )

        # Assertion 3: Containment confirmation returned
        assert response["statusCode"] == 200
        res_body = json.loads(response["body"])
        assert res_body["status"] == "CONTAINED"
        print(
            f"[+] PASS: Circuit breaker returned containment status: {res_body['actions']}"
        )


if __name__ == "__main__":
    test_circuit_breaker_execution()
