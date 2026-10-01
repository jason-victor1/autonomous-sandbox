# ADR 001: Zero-Egress Network Isolation and Dynamic IAM Quarantine for Agentic Execution Runtimes

* **Status:** Accepted & Empirically Verified
* **Date:** 2026-10-01
* **Deciders:** Cloud Security Architecture & DevSecOps Engineering
* **Scope:** Autonomous Sandbox Infrastructure (`terraform/modules/*`)

---

## Context & Problem Statement
Autonomous AI agents executing arbitrary, code-generating, or untrusted workloads introduce critical operational risks:
1. **Model Weight & Data Exfiltration:** Compromised tasks may attempt to stream sensitive artifacts or execution scratchpads to external endpoints.
2. **Resource Hijacking & Runaway Spend:** Flawed reasoning loops or recursive sub-agent spawns can drive compute costs beyond acceptable limits.
3. **Lateral Movement via Cloud Metadata:** Tasks running in standard VPC configurations can probe the IMDS (Instance Metadata Service) or external APIs to pivot across cloud boundaries.

Traditional perimeter-only defenses (firewalls, API rate limits) are insufficient once execution begins inside the compute layer. The architecture requires deterministic Layer 4 containment and automated containment mechanisms that function independently of the compromised runtime.

---

## Decision Drivers
* **Absolute Containment:** Inability of the container to initiate connections to the public internet, regardless of application compromise or code injection.
* **Deterministic Governance:** Policy enforcement must occur before deployment via Policy-as-Code admission gates.
* **Zero Trust Data Plane:** Data at rest and in transit must be encrypted using customer-managed keys (AWS KMS CMK); runtime compute must lack access to KMS keys unless executing valid work.
* **Automated Blast-Radius Containment:** Incident response must execute within seconds to sever running processes and identity tokens without manual intervention.

---

## Considered Options

* **Option 1: Public Subnets with Egress Proxies (Squid/Envoy Filtering)**
  * *Pros:* Simple outbound monitoring; software-based domain allowlisting.
  * *Cons:* Layer 7 proxies introduce single points of failure, TLS inspection overhead, and potential software bypass vulnerabilities. Egress routing to an IGW remains physically possible if proxy configuration drifts.

* **Option 2: Private Subnets with NAT Gateways and AWS Network Firewall (ANFW)**
  * *Pros:* Native AWS managed service; deep packet inspection.
  * *Cons:* High idle hourly baseline cost; complex stateful rule sets; still retains a default route (`0.0.0.0/0`) out of the VPC.

* **Option 3: Air-Gapped Isolated Subnets, Private VPC Endpoints, and Event-Driven IAM Quarantine (Selected)**
  * *Pros:* No internet route tables (`0.0.0.0/0`) exist. Hypervisor drops all outbound packets not matching internal interface endpoints or the AWS-managed S3 Prefix List. EventBridge and Lambda provide out-of-band credential revocation.
  * *Cons:* Requires dedicated AWS VPC Interface Endpoints for each communicating service (SQS, KMS, ECR, CloudWatch Logs); requires strict initial IAM permission scoping.

---

## Decision Outcome

**Selected Option 3:** Implement an air-gapped VPC architecture paired with out-of-band identity quarantine.

### Key Architectural Commitments:
1. **Network Layer:** Subnets contain no route entries for `0.0.0.0/0`. The ECS tasks are placed in subnets backed exclusively by Private VPC Interface Endpoints (AWS PrivateLink) and an S3 Gateway Endpoint. Security groups permit outbound HTTPS (443) only to the local VPC CIDR (`10.0.0.0/16`) and the AWS S3 Prefix List (`pl-63a5400a`).
2. **Identity Layer:** Non-human identities operate under strict separation of duties:
   * `gh-actions-deployer-role`: Restricted to infrastructure deployment with an IAM Permissions Boundary ceiling (`ci-deployment-permission-boundary`).
   * `ecs-agent-task-runtime-role`: Scoped to consume only designated SQS messages and S3 artifacts encrypted under key `a9d4c9fb-1464-4606-bc7c-ad81e3d96b42`.
3. **Tripwire Circuit Breaker:** An EventBridge governance bus routes anomalies to Lambda. Containment is enforced by injecting an inline IAM policy named `EmergencyDenyAllQuarantine`:

```json
{
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
```

   Because AWS evaluates explicit denies before any allow statements, this invalidates active task credentials across all AWS services instantly.

---

## Verification & Empirical Proof

The architecture was deployed and validated through live attack-simulation drills:

1. **Edge Rejection:** Sent malicious cross-site scripting payload (`<script>alert(1)</script>`) to `https://4fr5x7b9a1.execute-api.us-east-1.amazonaws.com/v1/tasks`.
   * *Evidence:* AWS WAF intercepted and returned `HTTP/2 403 Forbidden` (`x-amzn-errortype: ForbiddenException`).
2. **Network Egress Restriction:** Security group rules on `sg-00c0e7bc6d887edcb` were enumerated.
   * *Evidence:* Confirmed 0 egress rules pointing to `0.0.0.0/0`. Outbound traffic is restricted to `10.0.0.0/16` and `pl-63a5400a`.
3. **Tripwire Containment:** Dispatched synthetic event `CircuitBreakerTripped` to `agent-governance-bus-dev`.
   * *Evidence:* CloudWatch logs confirmed Lambda invocation; `aws iam list-role-policies` confirmed immediate attachment of `EmergencyDenyAllQuarantine`.
4. **Clean Lifecycle Teardown:** Ran `terraform destroy -auto-approve`.
   * *Evidence:* 76 resources destroyed cleanly without orphaned resources or dependency locks. State file confirmed empty.

---

## Consequences

### Positive Consequences
* **Zero Exfiltration Vector:** Malicious code executing in the container cannot connect to external command-and-control servers or exfiltrate data to arbitrary cloud IPs.
* **Instantaneous Blast-Radius Control:** Credential revocation occurs out-of-band via AWS control-plane APIs, neutralizing compromised tasks even if the container OS is unresponsive.
* **Deterministic Governance:** Architecture drift is prevented in CI/CD by automated Checkov static analysis and Conftest Rego policies before `terraform apply`.

### Negative / Operational Consequences
* **PrivateLink Interface Cost:** Running VPC Interface Endpoints (ECR, SQS, CloudWatch, KMS) incurs a continuous per-endpoint-hour charge.
* **Teardown Operational Dependency:** Out-of-band attached quarantine policies must be deleted via script or AWS CLI before running `terraform destroy`, as Terraform state is unaware of dynamically injected IAM policies.
