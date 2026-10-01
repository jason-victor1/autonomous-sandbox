# Executive Case Study: Securing Autonomous AI Agent Runtimes via Zero-Egress Infrastructure and Automated Blast-Radius Containment

---

## Executive Summary

As enterprise adoption shifts from human-directed LLMs to autonomous agentic architectures, the operational threat surface expands significantly. Autonomous execution runtimes introduce non-deterministic tool use, code execution loops, and automated credential consumption—creating distinct vectors for proprietary model exfiltration, runaway inference spend, and lateral cloud pivoting.

The **Autonomous Sandbox** establishes a verified, zero-trust cloud runtime engineered for unvetted AI agents and long-horizon tasks. Utilizing HashiCorp Terraform on Amazon Web Services (AWS), the platform eliminates public network pathways, binds non-human identities (NHIs) to mathematical policy ceilings, and couples runtime compute with an out-of-band event-driven circuit breaker capable of revoking credentials within seconds of anomalous behavior.

---

## Strategic Business Risk Reduction

| Business Risk | Threat Scenario | Architectural Mitigation | Quantifiable Outcome |
| :--- | :--- | :--- | :--- |
| **Intellectual Property & Model Exfiltration** | An untrusted agent executes reverse-shell code to beam proprietary model weights or customer data to an external C2 server. | Layer 4 hypervisor isolation (air-gapped subnets, no IGW/NAT) and egress locked exclusively to AWS PrivateLink endpoints and managed S3 prefix lists. | **100% data exfiltration barrier** at the network layer; packets destined outside internal endpoints are dropped by the AWS hypervisor. |
| **Financial "Bill Shock" & Runaway Compute** | An agent enters an infinite reasoning loop or spawns runaway compute threads, resulting in massive API and Fargate utilization. | Amazon EventBridge integration with FinOps threshold triggers; automated kill-switch Lambda forcefully terminates active tasks (`ecs:StopTask`). | **Automated spend containment** enforced in under 5 seconds, capping maximum unexpected financial exposure. |
| **Compliance & Supply Chain Tampering** | Malicious IaC drift or unauthorized pipeline changes grant compute instances excessive administrative privileges. | OIDC-federated GitHub Actions deployer role bound to an immutable IAM Permission Boundary and audited via Checkov and Conftest Rego gates. | **Zero persistent long-term credentials**; policy drift blocked pre-merge; full alignment with **NIST SP 800-207 (Zero Trust)** and **ISO/IEC 42001**. |

---

## Non-Human Identity (NHI) Governance & Identity Ceilings

Modern cloud security failures predominantly stem from non-human identity misconfigurations rather than application exploits. In this architecture, identity governance is enforced across two distinct operating planes:

```
[ CI/CD Machine Identity ]
 GitHub Actions (OIDC STS) ──► Assumes: gh-actions-deployer-role
                                     │
                                     ▼ (Bounded By)
                               ci-deployment-permission-boundary
                               (Hard ceiling: Cannot grant IAM escalation, 
                                cannot attach wildcard allowances)

[ Runtime Machine Identity ]
 ECS Fargate Container     ──► Assumes: ecs-agent-task-runtime-role
                                     │
                                     ├─► Least-Privilege Data Access:
                                     │   - SQS FIFO Task Dequeue
                                     │   - KMS CMK Decrypt (Scoped ARN)
                                     │   - S3 Artifact Read (Dedicated Bucket)
                                     │
                                     ▼ (Out-of-Band Containment Trigger)
                               Injected: EmergencyDenyAllQuarantine
                               (Immediate explicit Deny * on * overrides all active tokens)
```

### Key NHI Design Safeguards:
1. **OIDC Federation & Zero Static Secrets:** CI/CD runners authenticate through short-lived STS tokens exchangeable only from verified GitHub repository claims (`repo:jason-victor1/autonomous-sandbox:*`), eliminating leaked static API keys.
2. **Permission Boundary Ceilings:** The deployer role is constrained by `ci-deployment-permission-boundary`. Even if the deployer configuration is compromised, it cannot create IAM roles or policies exceeding the boundary ceiling.
3. **Scoped Inspection Scopes:** Cloud automation is granted read inspection actions (`s3:GetBucket*`, `s3:Get*Configuration`) to refresh resource state during pipeline planning without exposing data-plane access (`s3:GetObject`).

---

## Deterministic Operational Containment

Containment is decoupled from the execution runtime. If an AI agent compromises its host OS or container environment, it cannot suppress, tamper with, or evade security enforcement.

### 1. Dual-Plane Network Boundary
The container execution plane has **no default internet gateway (IGW) or NAT gateway route**. Outbound network calls are physically dropped unless they target:
* **Private VPC Interface Endpoints:** Scoped to internal AWS service endpoints (ECR, SQS, CloudWatch Logs, and KMS) across private subnet IPs (`10.0.0.0/16`).
* **S3 Gateway Endpoint:** Scoped strictly to the regional AWS S3 prefix list (`pl-63a5400a`).
* **Private DNS:** Constrained strictly to the VPC Route 53 Resolver on port 53.

### 2. Out-of-Band Event-Driven Kill Switch
When an anomaly (budget overrun or threat tripwire) is detected by the governance bus, containment triggers outside the runtime boundary:

```
[ Anomaly Trigger: sandbox.security / sandbox.finops ]
                       │
                       ▼
         [ EventBridge Governance Bus ]
                       │
                       ▼ (Matched Rule: CircuitBreakerTripped)
         [ agent-circuit-breaker-dev (Lambda) ]
           ├── 1. ecs:StopTask ─────────────► Terminates running container processes
           └── 2. iam:PutRolePolicy ────────► Attaches EmergencyDenyAllQuarantine
```

Because AWS IAM evaluates an explicit `Deny` before any permissive statement, the injection of `EmergencyDenyAllQuarantine` immediately invalidates all cached STS credentials, instantly locking the task out of S3, SQS, and KMS.

---

## Empirical Verification & Production Audit Results

The architecture underwent end-to-end negative and positive validation drills in a live AWS environment:

```
[ Attack Simulation: Edge XSS / Script Injection ]
Payload: {"task_id": "<script>alert(1)</script>"}
Result:  HTTP 403 Forbidden (Blocked at perimeter by AWS WAFv2 Common Rule Set)

[ Network Layer Audit: sg-00c0e7bc6d887edcb ]
Result:  0 outbound rules to 0.0.0.0/0
         Egress restricted exclusively to 10.0.0.0/16 and pl-63a5400a

[ Circuit Breaker Drill: EventBridge Tripwire ]
Stimulus: Synthesized 'CircuitBreakerTripped' event published to governance bus
Result:  Lambda invoked; 'EmergencyDenyAllQuarantine' policy injected on runtime role;
         Immediate authorization revocation verified via AWS CLI

[ Lifecycle Teardown Drill ]
Command: terraform destroy -auto-approve
Result:  76 of 76 cloud resources cleanly destroyed; 0 orphaned IAM roles or ENIs;
         Remote S3 state file verified empty
```
