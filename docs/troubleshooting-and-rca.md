# Engineering Postmortems & Operational Field Notes

This document captures the real-world operational failure modes, root-cause analyses (RCA), and deterministic architectural guardrails established across the development, testing, and teardown cycles of the **Autonomous Sandbox**.

---

## Incident 1: The OIDC Chicken-and-Egg Bootstrap Deadlock

### Incident Summary
* **Severity:** High (Pipeline Execution Blocker)
* **Subsystem:** GitHub Actions CI/CD / AWS IAM OIDC Federation
* **Phase:** Post-Teardown Regression Testing

### 1. The Problem & Error Signature
Following a full environment destruction drill (`terraform destroy`), subsequent commits pushed to the repository failed immediately during the `Plan & Conftest Admission Gate` workflow at the `Configure AWS Credentials (OIDC)` step:

```
Run aws-actions/configure-aws-credentials@v4
Assuming role with OIDC
Error: Could not assume role with OIDC: The web identity token provided could not be validated.
See the AssumeRoleWithWebIdentity documentation for requirements.
```

### 2. Root Cause Analysis (RCA)
* The root `main.tf` orchestrates both the foundational identity provider (`module.identity`) and ephemeral application resources (VPC endpoints, ECS, WAF, API Gateway).
* Running `terraform destroy` destroyed all 76 managed cloud resources—including `aws_iam_openid_connect_provider.github` and `aws_iam_role.gh_actions_deployer`.
* When GitHub Actions subsequently ran, it generated a signed JSON Web Token (JWT) from `token.actions.githubusercontent.com`. However, because AWS IAM no longer had the GitHub OIDC provider registered as an identity trust anchor, AWS STS rejected the token exchange with an invalid web identity error.
* The pipeline could not provision the infrastructure because the identity provider needed to run the pipeline was destroyed with the infrastructure.

### 3. Engineering Resolution & Prevention
* **Decoupled Identity Bootstrap:** Re-provisioned the zero-cost identity foundation independently of the compute and network layers using targeted module targeting:
  ```bash
  terraform apply -target=module.identity -auto-approve
  ```
* **Architectural Standard:** In enterprise production architectures, machine identity bootstrap modules (OIDC providers, state storage buckets, DynamoDB lock tables) must reside in a dedicated foundational state stack (`terraform/foundations/`) separate from the ephemeral workload stack (`terraform/environments/dev/`).

---

## Incident 2: EventBridge Schema Mismatch and Silent Target Drops

### Incident Summary
* **Severity:** Medium (Silent Containment Failure)
* **Subsystem:** Amazon EventBridge / AWS Lambda Circuit Breaker
* **Phase:** Incident Response Drill #3

### 1. The Problem & Error Signature
During the kill-switch integration drill, a synthetic incident event was dispatched to the custom governance bus via the AWS CLI. The CLI returned a successful submission with zero failed entries:

```json
{
    "FailedEntryCount": 0,
    "Entries": [
        {
            "EventId": "9d8e7b6a-4c3d-2e1f-0a9b-8c7d6e5f4a3b"
        }
    ]
}
```

However, the kill-switch Lambda function was never invoked. CloudWatch Metrics for the Lambda showed zero invocations, and no inline quarantine policy was attached to the ECS runtime role.

### 2. Root Cause Analysis (RCA)
* Queried the rule configuration via `aws events describe-rule --event-bus-name agent-governance-bus-dev --name circuit-breaker-rule`.
* The Terraform rule definition enforced a strict pattern match:
  ```json
  {
    "source": ["sandbox.security", "sandbox.finops"],
    "detail-type": ["CircuitBreakerTripped", "BudgetLimitExceeded"]
  }
  ```
* The test command had published an event with `source: "custom.sandbox.governance"` and `detail-type: "CircuitBreakerTriggered"`.
* EventBridge operates on exact JSON string matching. If an event schema does not match the rule pattern precisely, EventBridge drops the event silently without raising an error or routing it to the dead-letter queue (DLQ).

### 3. Engineering Resolution & Prevention
* Updated the validation drill script to use the exact matching schema contract:
  ```bash
  aws events put-events --entries '[{
    "EventBusName": "agent-governance-bus-dev",
    "Source": "sandbox.security",
    "DetailType": "CircuitBreakerTripped",
    "Detail": "{"reason": "ManualSecurityTripwire", "severity": "CRITICAL"}"
  }]'
  ```
* Configured an Amazon SQS Dead-Letter Queue (DLQ) on the EventBridge rule target to capture unrouted or failed invocations during production monitoring.

---

## Incident 3: Out-of-Band State Drift (Dynamic Quarantine vs. IaC State)

### Incident Summary
* **Severity:** Medium (Teardown Failure & State Inconsistency)
* **Subsystem:** AWS IAM / Terraform State Engine
* **Phase:** Clean Teardown & Lifecycle Verification

### 1. The Problem & Error Signature
When attempting to run `terraform destroy` after a triggered circuit breaker drill, Terraform failed during the deletion of `module.identity.aws_iam_role.ecs_agent_task_runtime`:

```
Error: deleting IAM Role (ecs-agent-task-runtime-role): Cannot delete entity: 
Must delete role policy EmergencyDenyAllQuarantine first.
```

### 2. Root Cause Analysis (RCA)
* The kill-switch Lambda operates out-of-band: it dynamically attaches an inline IAM policy named `EmergencyDenyAllQuarantine` (`Deny * on *`) directly via the AWS IAM control-plane API (`iam:PutRolePolicy`).
* Terraform's state file (`terraform.tfstate`) only tracks resources and inline policies managed directly within IaC.
* AWS IAM prohibits deleting an IAM role while inline policies remain attached. Because Terraform was unaware of the dynamically injected policy, it attempted to call `iam:DeleteRole` without first calling `iam:DeleteRolePolicy`, causing the API call to fail.

### 3. Engineering Resolution & Prevention
* **Pre-Teardown Operational Hygiene:** Codified a pre-destroy remediation step in the runbook to strip unmanaged dynamic policies prior to running Terraform:
  ```bash
  aws iam delete-role-policy     --role-name "ecs-agent-task-runtime-role"     --policy-name "EmergencyDenyAllQuarantine" 2>/dev/null || true
  ```
* **Long-Term Preventive Design:** For multi-environment deployments, dynamic quarantine policies should be managed as standalone managed policy attachments or executed by assuming a boundary change rather than direct inline mutation.

---

## Incident 4: Git Tag Pointer Drift and Pipeline Triggering

### Incident Summary
* **Severity:** Low (Repository Hygiene & Unnecessary CI/CD Cost)
* **Subsystem:** Git Versioning / GitHub Actions Trigger Filter
* **Phase:** Release Tagging (`v1.0.0`)

### 1. The Problem & Error Signature
* Pushing documentation updates (`README.md`, `case-study.md`) triggered full AWS CI/CD deployment workflows, executing Terraform plan cycles and incurring runner minutes.
* After tagging the release, running `git rev-parse --short v1.0.0^{commit}` returned `35f9c6d`, while `git rev-parse --short HEAD` returned `bd3263a`. The release tag was frozen to an obsolete commit that lacked critical documentation and workflow updates.

### 2. Root Cause Analysis (RCA)
* Git annotated tags (`git tag -a`) create independent Git objects pointing to a specific commit SHA. When new commits are added to `main`, the tag does not advance automatically.
* The GitHub Actions workflow file lacked `paths-ignore` directives, causing pushes that only contained markdown files to trigger Terraform validation checks that required live AWS OIDC authentication.

### 3. Engineering Resolution & Prevention
* **Path Filtering:** Added `paths-ignore` filters to `.github/workflows/pipeline.yml` for `**.md`, `docs/**`, and `.gitignore`.
* **Tag Realignment:** Force-updated the local and remote annotated tag to track `HEAD`:
  ```bash
  git tag -fa v1.0.0 -m "Verified zero-egress sandbox release"
  git push origin v1.0.0 --force
  ```

---

## Incident 5: Deterministic Network Isolation Verification vs. Flow Logs

### Incident Summary
* **Severity:** Low (Verification Ambiguity)
* **Subsystem:** Amazon EC2 Networking / VPC Flow Logs
* **Phase:** Zero-Egress Network Verification Drill

### 1. The Problem & Error Signature
When attempting to prove zero-egress isolation using VPC Flow Logs, running `aws ec2 describe-flow-logs` returned `LogGroupName: None`. Without flow log data, network isolation could not be audited purely through traffic capture logs.

### 2. Root Cause Analysis (RCA)
* VPC Flow Logs were not configured in the active Terraform environment, meaning no passive packet capture was being collected.
* Relying on flow logs to prove network security confuses **observability** (detecting traffic that occurred) with **enforcement** (preventing traffic from being physically routable).

### 3. Engineering Resolution & Prevention
* Shifted from passive log sampling to **deterministic Layer 4 hypervisor verification**:
  ```bash
  aws ec2 describe-security-group-rules     --filters "Name=group-id,Values=sg-00c0e7bc6d887edcb"
  ```
* Enumerated all outbound rules to mathematically verify:
  1. Exactly **0** outbound rules exist targeting `0.0.0.0/0`.
  2. Outbound HTTPS (443) is strictly constrained to the local VPC CIDR (`10.0.0.0/16`) and the AWS S3 Prefix List (`pl-63a5400a`).
* Proved that regardless of container runtime state, the AWS Nitro/Fargate hypervisor will drop all non-allowlisted outbound packets before they traverse the virtual network interface.
