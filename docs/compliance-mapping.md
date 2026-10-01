# Enterprise Compliance & Security Framework Mapping

This document maps the architectural controls, identity guardrails, and automated containment mechanisms implemented in the **Autonomous Sandbox** against three industry standards:
1. **NIST SP 800-207** (Zero Trust Architecture)
2. **NIST AI RMF 1.0** (Artificial Intelligence Risk Management Framework)
3. **SOC 2 Type II** (Trust Services Criteria / Security & Confidentiality)

---

## 1. NIST SP 800-207: Zero Trust Architecture (ZTA)

The sandbox architecture aligns directly with the seven core tenets of Zero Trust, eliminating implicit network trust and separating the Policy Decision Point (PDP) from the Policy Enforcement Point (PEP).

| Tenet ID | Tenet Description | Sandbox Implementation | Architectural Evidence |
| :--- | :--- | :--- | :--- |
| **Tenet 1** | *All data sources and computing services are considered resources.* | Every resource (S3 bucket, SQS FIFO queue, ECS task, KMS CMK) is explicitly defined, addressed, and governed via distinct ARN-scoped IAM policies. | `terraform/modules/data`, `terraform/modules/ingress` |
| **Tenet 2** | *All communication is secured regardless of network location.* | No implicit trust exists on the local VPC. Inter-service traffic traverses private AWS PrivateLink interface endpoints and TLS 1.3. Compute cannot reach the public internet. | `subnet-0c6d9421...` (No IGW/NAT), VPC Endpoints SG |
| **Tenet 3** | *Access to individual enterprise resources is granted on a per-session basis.* | Workloads do not use persistent credentials. CI/CD runners authenticate via ephemeral GitHub OIDC STS tokens; ECS tasks assume temporary instance profile credentials. | `gh-actions-deployer-role`, `ecs-agent-task-runtime-role` |
| **Tenet 4** | *Access to resources is determined by dynamic policy.* | Policy enforcement occurs statically at admission (Conftest Rego) and dynamically at runtime (EventBridge incident tripwires injecting quarantine policies). | `policies/terraform.rego`, `agent-circuit-breaker-dev` |
| **Tenet 5** | *The enterprise monitors and measures the integrity and security state of all assets.* | Continuous logging enabled across WAFv2, API Gateway stage, ECS container logs, and CloudWatch Log groups. SQS depth and Fargate task lifecycles are actively monitored. | `/ecs/agent-worker-dev`, `/aws/lambda/agent-circuit-breaker-dev` |
| **Tenet 6** | *All resource authentication and authorization are dynamic and strictly enforced.* | Edge ingress is gated by AWS WAFv2 Common Rule Sets. API Gateway executes authenticated STS role assumption (`apigw-sqs-enqueue-role`) to write to SQS FIFO. | `aws_wafv2_web_acl.ingress_waf`, `aws_api_gateway_integration` |
| **Tenet 7** | *The enterprise collects information about assets and infrastructure to improve security.* | VPC Flow Logs and CloudWatch event logs aggregate metrics into a centralized log group for behavioral audit and threat analytics. | VPC Flow Logs, EventBridge governance bus |

---

## 2. NIST AI Risk Management Framework (AI RMF 1.0)

The sandbox addresses unique operational risks associated with autonomous agents, non-deterministic model actions, and automated code execution loops.

| AI RMF Function | Category & Subcategory | Threat Mitigated | Technical Control Mechanism |
| :--- | :--- | :--- | :--- |
| **GOVERN** | **GOVERN 1.2:** Systems to manage risks from third-party or untrusted AI components. | Malicious or unvetted AI agent code executing unauthorized external commands or package downloads. | **Air-gapped VPC confinement:** Isolated subnets with zero `0.0.0.0/0` outbound routing prevent untrusted workloads from reaching external servers. |
| **GOVERN** | **GOVERN 1.5:** Ongoing monitoring and review of AI system boundaries. | Infrastructure configuration drift weakening sandbox isolation over time. | **Pre-flight admission gates:** GitHub Actions executes Checkov SAST and Conftest Rego policies prior to Terraform plan and deployment. |
| **MAP** | **MAP 1.5:** Identification of potential negative impacts (exfiltration, runaway spend). | Autonomous agent executing infinite retry loops, causing massive API and compute cost overruns. | **EventBridge FinOps triggers:** Budget and anomaly events routed from `sandbox.finops` directly into the circuit breaker bus. |
| **MEASURE** | **MEASURE 2.6:** Security, data integrity, and privacy verification. | Exploitation of model weights or prompt injection payloads compromising runtime memory. | **Empirical negative testing:** Perimeter WAF blocks injection payloads (`403 Forbidden`); S3 model artifacts encrypted with dedicated KMS CMK. |
| **MANAGE** | **MANAGE 2.4:** Fail-safe mechanisms, automated shutdown, and circuit breakers. | Runaway agent process or host compromise attempting lateral cloud movement. | **Out-of-band kill switch:** Lambda executes `ecs:StopTask` and injects `EmergencyDenyAllQuarantine` (`Deny * on *`), revoking STS tokens in <5s. |
| **MANAGE** | **MANAGE 4.1:** Post-incident containment and remediation mechanisms. | Compromised container evading operating system-level termination signals. | **IAM control-plane quarantine:** Dynamic explicit deny policy invalidates data plane access even if the container operating system hangs. |

---

## 3. SOC 2 Type II: Trust Services Criteria Mapping

| SOC 2 Criteria | Control Requirement | Sandbox Implementation | Verification Method |
| :--- | :--- | :--- | :--- |
| **CC6.1** *(Logical Access)* | Restrict logical access to infrastructure, data, and source code to authorized identities. | GitHub Actions federates via OIDC; deployer role bound to an immutable `ci-deployment-permission-boundary`. | IAM policy audit: zero static AWS credentials in CI/CD secrets. |
| **CC6.6** *(Boundary Protection)* | Protect logical boundaries to prevent unauthorized egress and network intrusion. | Isolated subnets with no IGW or NAT; security group `sg-00c0e7bc6d887edcb` has 0 outbound rules to `0.0.0.0/0`. | AWS CLI security group enumeration confirms restricted egress. |
| **CC6.7** *(Data Transmission & Storage)* | Encrypt data in transit and at rest using approved cryptographic algorithms. | S3 model artifacts and SQS queues use Server-Side Encryption with Customer-Managed Keys (KMS CMK `a9d4c9fb-...`). | AWS CLI inspection of S3 bucket encryption and SQS KMS attributes. |
| **CC7.2** *(Incident Detection & Containment)* | Monitor and respond to unauthorized behavior and anomalous operational activity. | EventBridge bus `agent-governance-bus-dev` trips circuit breaker Lambda on security threshold breaches. | Synthetic breach drill: verified automatic attachment of `EmergencyDenyAllQuarantine`. |
| **CC8.1** *(Change Management)* | Prevent unauthorized infrastructure changes through automated approval and testing. | All changes managed via GitOps. Pull requests must pass Checkov static analysis and Conftest Rego admission. | CI/CD pipeline execution logs (GitHub Actions Run #17). |

---

## 4. Continuous Audit & Verification Summary

All mapped controls were empirically validated in a live AWS environment:

```
1. Edge Inspection: WAFv2 dropped exploit payload with HTTP 403 Forbidden.
2. Network Boundary: Security Group audit verified zero 0.0.0.0/0 egress rules.
3. Identity Ceiling: GitHub Actions deployer role constrained by permission boundary.
4. Active Containment: EventBridge tripwire injected EmergencyDenyAllQuarantine in <5s.
5. Lifecycle Hygiene: Clean teardown confirmed via 76 destroyed resources and empty state.
```
