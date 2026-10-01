# Autonomous Sandbox: Hardened Agentic AI Execution Runtime

An enterprise-grade, air-gapped container execution environment designed for untrusted AI agent execution and long-running model workloads. Built with HashiCorp Terraform on AWS, this architecture enforces deterministic Layer 4 network isolation, strict non-human identity (NHI) governance, automated pre-flight CI/CD admission gating, and an out-of-band event-driven kill switch.

---

## Architecture Overview

```
                                  +------------------------------------------------------+
                                  |                    AWS Perimeter                     |
                                  +------------------------------------------------------+
                                                             |
                                               [ HTTPS Request with Task Payload ]
                                                             v
                                            +----------------------------------+
                                            |   AWS WAFv2 (WebACL Regional)    |
                                            |   - Rate Limiting (IP Throttling)|
                                            |   - AWSManagedRulesCommonRuleSet |
                                            +----------------------------------+
                                                             | (Inspect & Filter)
                                                             v
                                            +----------------------------------+
                                            |    Regional REST API Gateway     |
                                            |  - Path: POST /v1/tasks          |
                                            |  - Request Validation & Mapping  |
                                            +----------------------------------+
                                                             |
                                                             | (Action=SendMessage / Deduplication)
                                                             v
                                            +----------------------------------+
                                            |       SQS FIFO Task Buffer       |
                                            |  - Server-Side KMS CMK Encrypted |
                                            |  - Content-Based Deduplication   |
                                            |  - Dead Letter Queue (DLQ) Attached
                                            +----------------------------------+
                                                             |
    =========================================================|=========================================================
    VPC BOUNDARY (vpc-0b338d3c7bf5c2c0b)                     | (Private VPC Interface Endpoint)
                                                             v
    +-----------------------------------------------------------------------------------------------------------------+
    | Isolated Private Subnets (No IGW / No NAT Gateway / No Public Routes)                                           |
    | [ subnet-0c6d9421299dc11ee | subnet-0165c36e1650b4053 ]                                                        |
    |                                                                                                                 |
    |   +---------------------------------------------------------------------------------------------------------+   |
    |   | Security Group: sg-00c0e7bc6d887edcb                                                                    |   |
    |   | Egress: TCP 443 -> VPC CIDR (10.0.0.0/16) | TCP 443 -> S3 Prefix List (pl-63a5400a) | UDP/TCP 53 -> VPC |   |
    |   |                                                                                                         |   |
    |   |   +-------------------------------------------------------------------------------------------------+   |   |
    |   |   | ECS Fargate Worker Task (ai-platform-dev-cluster / agent-worker)                                |   |   |
    |   |   | - Non-root container runtime (`nobody` / UID 65534)                                             |   |   |
    |   |   | - Read-only root filesystem with ephemeral `/tmp-scratch` volume                                |   |   |
    |   |   | - Assumed IAM Task Role: `ecs-agent-task-runtime-role`                                          |   |   |
    |   |   +-------------------------------------------------------------------------------------------------+   |   |
    |   +---------------------------------------------------------------------------------------------------------+   |
    +-----------------------------------------------------------------------------------------------------------------+
                                                             ^
                                                             | (Immediate Explicit Deny Injection)
    +--------------------------------------------------------|--------------------------------------------------------+
    | OUT-OF-BAND CIRCUIT BREAKER GOVERNANCE                 |                                                        |
    |                                                        |                                                        |
    |   +-----------------------------+          +-----------+------------------+          +----------------------+   |
    |   | EventBridge Governance Bus  | -------> | Kill-Switch Lambda Function  | -------> | IAM Runtime Role     |   |
    |   | (agent-governance-bus-dev)  |          | (agent-circuit-breaker-dev)  |          | Attach: DenyAllQuar. |   |
    |   +-----------------------------+          +------------------------------+          +----------------------+   |
    +-----------------------------------------------------------------------------------------------------------------+
```

---

## Core Security Controls

### 1. Perimeter Defense & Rate Limiting
* **Inspection Engine:** Regional AWS WAFv2 WebACL (`agent-ingress-waf-dev`) directly attached to API Gateway stage `v1`.
* **Exploit Mitigation:** Enforces `AWSManagedRulesCommonRuleSet` to terminate cross-site scripting (XSS), HTTP request smuggling, and protocol anomaly attacks at the edge before payload consumption.
* **Buffering & Decoupling:** API Gateway uses native AWS Service Integration (`Action=SendMessage`) to enqueue requests directly into SQS FIFO without compute intermediaries. Payload deduplication is enforced via `$context.requestId`.

### 2. Deterministic Layer 4 Network Isolation
* **Zero Internet Routing:** Subnets (`subnet-0c6d9421299dc11ee`, `subnet-0165c36e1650b4053`) are provisioned without Internet Gateways, NAT Gateways, or egress proxies.
* **Hypervisor-Level Enforcement:** The compute security group (`sg-00c0e7bc6d887edcb`) contains **no wildcard outbound rules (`0.0.0.0/0`)**.
* **Strict Egress Whitelist:**
  * **HTTPS (TCP 443):** Restricted to VPC Interface Endpoints (`10.0.0.0/16`) for SQS, ECR, CloudWatch Logs, and KMS.
  * **S3 Gateway Access:** Restricted to the AWS-managed S3 Prefix List (`pl-63a5400a`).
  * **Internal DNS:** Restricted to Route 53 Resolver (`10.0.0.0/16`) on UDP/TCP port 53.

### 3. Non-Human Identity (NHI) Governance
* **OIDC CI/CD Federation:** GitHub Actions provisions infrastructure via AWS STS role assumption (`gh-actions-deployer-role`), eliminating persistent access keys.
* **Permission Boundary Ceilings:** The deployer role is constrained by `ci-deployment-permission-boundary`, preventing privilege escalation across IAM, VPC, and KMS boundaries.
* **Bucket Configuration Inspection:** Scoped inspection actions (`s3:GetBucket*`, `s3:Get*Configuration`) authorize full Terraform state inspection (SSE, Object Lock, Transfer Acceleration) without granting object retrieval (`s3:GetObject`).

### 4. Active Out-of-Band Circuit Breaker
* **Tripping Mechanism:** EventBridge governance bus (`agent-governance-bus-dev`) matches events from `sandbox.security` and `sandbox.finops` for detail types `CircuitBreakerTripped` and `BudgetLimitExceeded`.
* **Automated Containment:** Execution targets Lambda (`agent-circuit-breaker-dev`), which calls `ecs:StopTask` on active containers and dynamically attaches an inline `EmergencyDenyAllQuarantine` policy to `ecs-agent-task-runtime-role`.
* **IAM Evaluation Override:** The injected explicit `Deny` on `*` actions across `*` resources instantly overrides all active STS tokens, revoking data plane access to S3, KMS, and SQS.

---

## Empirical Verification Matrix

The sandbox lifecycle and threat boundary protections were validated via end-to-end integration drills in the `dev` environment:

| Gate / Drill | Target Mechanism | Empirical Stimulus | Observed System Response | Status |
| :--- | :--- | :--- | :--- | :--- |
| **CI/CD Admission Gate** | Checkov SAST & Conftest Rego Policy | `git push` to `main` (Run #17) | Scans passed; Conftest validated zero-egress SG & encryption rules; plan generated via OIDC STS. | **PASSED** |
| **Ingress Enqueue** | API Gateway Direct Integration | `POST /v1/tasks` (Valid JSON payload) | API Gateway returned `HTTP 200` (`status: QUEUED`); SQS returned `MessageId: 40246978...`. | **PASSED** |
| **Perimeter Rejection** | WAF Common Rule Set | `POST /v1/tasks` (`<script>alert(1)</script>`) | WAF dropped request at edge: `HTTP 403 Forbidden` (`x-amzn-errortype: ForbiddenException`). | **PASSED** |
| **Network Confinement** | L4 Hypervisor Isolation | Security Group Audit on `sg-00c0e7bc6d887edcb` | Zero `0.0.0.0/0` egress rules; egress locked to `10.0.0.0/16` and S3 prefix list `pl-63a5400a`. | **PASSED** |
| **Circuit Breaker** | Incident Response & Quarantine | Synthetic event published to `agent-governance-bus-dev` | Lambda executed; injected inline `EmergencyDenyAllQuarantine` (explicit `Deny * on *`) on task role. | **PASSED** |
| **Clean Teardown** | Infrastructure Lifecycle Hygiene | `terraform destroy -auto-approve` | All 76 managed cloud resources cleanly destroyed; remote S3 state file verified empty. | **PASSED** |

---

## Repository Structure

```
autonomous-sandbox/
├── .github/
│   └── workflows/
│       └── pipeline.yml            # CI/CD: Scans, Conftest OPA admission, plan generation
├── docs/
│   └── adr/
│       └── 001-sandbox-security-architecture.md
├── policies/
│   └── terraform.rego              # Conftest admission rules (no 0.0.0.0/0, mandatory CMK)
├── terraform/
│   ├── environments/
│   │   └── dev/
│   │       ├── main.tf             # Module orchestration & provider configuration
│   │       ├── outputs.tf          # Exported identifiers and endpoint URLs
│   │       ├── terraform.tf        # S3 backend & DynamoDB state locking
│   │       └── variables.tf
│   └── modules/
│       ├── compute/                # ECS Cluster, Fargate Task Definition, CloudWatch Logs
│       ├── data/                   # S3 Model Storage (Bucket Versioning, Encryption, SSE-KMS)
│       ├── governance/             # EventBridge Bus, Rules, Circuit Breaker Lambda
│       ├── identity/               # GitHub OIDC Role, Task Runtime Role, Permission Boundaries
│       ├── ingress/                # Regional REST API Gateway, WAFv2 WebACL, SQS FIFO
│       └── network/                # Isolated Subnets, VPC Interface Endpoints, Security Groups
└── tests/
    └── circuit_breaker_test.py     # Local unit test harness for breaker logic
```

---

## Operational Runbook

### Prerequisites
* AWS CLI v2 configured with target deployment credentials
* Terraform v1.5+
* Checkov & Conftest (`rego`) installed locally

### Local Deployment
```bash
cd terraform/environments/dev

# 1. Initialize remote state and modules
terraform init

# 2. Run deterministic planning
terraform plan -out=tfplan.binary

# 3. Apply infrastructure
terraform apply tfplan.binary
```

### Tripping the Circuit Breaker (Manual Drill)
```bash
# Publish breach trigger to EventBridge governance bus
aws events put-events --entries '[
  {
    "EventBusName": "agent-governance-bus-dev",
    "Source": "sandbox.security",
    "DetailType": "CircuitBreakerTripped",
    "Detail": "{"reason": "ManualSecurityTripwire", "severity": "CRITICAL"}"
  }
]'

# Verify quarantine policy injection on the runtime role
aws iam get-role-policy   --role-name "ecs-agent-task-runtime-role"   --policy-name "EmergencyDenyAllQuarantine"
```

### Complete Infrastructure Teardown
```bash
# 1. Strip dynamic out-of-band quarantine policy prior to teardown
aws iam delete-role-policy   --role-name "ecs-agent-task-runtime-role"   --policy-name "EmergencyDenyAllQuarantine" 2>/dev/null || true

# 2. Destroy all managed resources
cd terraform/environments/dev
terraform destroy -auto-approve

# 3. Verify state cleanliness
terraform show
```
