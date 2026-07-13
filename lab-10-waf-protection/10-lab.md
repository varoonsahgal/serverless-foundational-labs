# Lab 10: Protecting the Acme Retail API with AWS WAF

## Estimated Duration

~75 minutes

## Scenario / Business Context

**Acme Retail** just launched a new checkout API backed by API Gateway and Lambda. Within 48 hours, the security team's CloudWatch logs show alarming patterns:

- Repeated requests containing `' OR 1=1 --` in query strings — classic **SQL injection** probes.
- Hundreds of rapid-fire login attempts from a single IP block — **credential stuffing**.
- Requests from known Tor exit nodes and datacenter IP ranges — **anonymized attack traffic**.
- A single IP hammering the `/checkout` route 500 times per minute — **scraping or rate abuse**.

Before this traffic reaches Lambda (and racks up invocation costs or corrupts data), Acme needs a **Web Application Firewall** placed in front of the API to inspect, filter, and optionally block every request before it enters the application tier. That firewall is **AWS WAF**.

In this lab you act as Acme's cloud security engineer. You will:

1. Understand WAF's core concepts (Web ACLs, rules, rule groups, WCUs).
2. Create a regional Web ACL with multiple AWS Managed Rule Groups.
3. Write custom rules (IP blocking, geo-restriction, rate limiting).
4. Enable WAF logging to CloudWatch Logs.
5. Run simulated attack traffic and view the results in WAF Sampled Requests.
6. Understand the full WAF ecosystem (Shield, Bot Control, CAPTCHA/Challenge).

---

## Learning Objectives

By the end of this lab you will be able to:

- Explain what a **Web ACL**, **Rule Group**, **Rule**, **IP Set**, and **Regex Pattern Set** are.
- Add AWS Managed Rule Groups and explain what each one protects against.
- Write **custom rules** for IP blocking, geo-matching, and rate limiting.
- Configure **WAF logging** to Amazon CloudWatch Logs.
- Understand **WCU (Web ACL Capacity Units)** and why they exist.
- Explain the difference between **Count mode** and **Block mode** and when to use each.
- Understand **AWS Shield Standard vs. Shield Advanced** at a conceptual level.
- Explain what **Bot Control**, **CAPTCHA**, and **Challenge** actions do.
- Compare WAF on API Gateway vs. CloudFront vs. ALB.

---

## AWS Services Used

- **AWS WAF & Shield** (primary)
- **Amazon API Gateway** (REST API — association target)
- **Amazon CloudWatch Logs** (WAF logging destination)
- **AWS IAM** (WAF logging delivery role)

---

## Prerequisites

- An AWS account with IAM user or Identity Center access.
- Permissions for: `wafv2:*`, `apigateway:*`, `logs:*`, `iam:CreateRole`, `iam:PutRolePolicy`.
- **Do not use the root user.**
- Region: **US West (Oregon) `us-west-2`** for everything in this lab.
- A terminal with `curl` (macOS/Linux built-in; Windows: Git Bash or PowerShell).
- An email address you can check.

> **Why us-west-2?** Acme Retail has standardized on US West (Oregon) as its primary region for cost efficiency and proximity to its West Coast data center. All resources in this course use `us-west-2`.


> **Shared Account — Use Your Initials on Every Resource:** You are working in a **shared AWS account** alongside other students. To avoid naming conflicts, **append your initials to every resource you create** in this lab. For example, if your name is Jane Smith use the suffix `-js` (lowercase) or `-JS` (uppercase) consistently.
>
> | Default name in instructions | What you should actually create |
> |---|---|
> | `acme-order-processor` | `acme-order-processor-js` |
> | `AcmeProducts` | `AcmeProducts-JS` |
> | `AcmeLambdaExecRole` | `AcmeLambdaExecRole-JS` |
>
> This applies to **all** Lambda functions, DynamoDB tables, IAM roles, IAM policies, Cognito User Pools, SNS topics, SQS queues, Step Functions state machines, API Gateway APIs, CodePipeline pipelines, CloudWatch dashboards, S3 buckets, and any other named AWS resource. Wherever the instructions say to type a resource name, add your initials. Skip initials only for things you are not creating (e.g., selecting an existing AWS managed policy like `AmazonDynamoDBReadOnlyAccess`).

---

## WAF Architecture Overview

```
Internet Traffic
       |
       v
+------------------+
|   AWS WAF        |  <-- Web ACL evaluates EVERY request
|   Web ACL        |      Rules run in priority order (low # first)
|                  |      First BLOCK match → 403 returned immediately
|  [Rule 1] IP     |      First ALLOW match → skip remaining rules
|  [Rule 2] Geo    |      No match → Default Action (Allow or Block)
|  [Rule 3] SQLi   |
|  [Rule 4] XSS    |
|  [Rule 5] Rate   |
|  [Default: Allow]|
+--------+---------+
         |  (only allowed requests pass through)
         v
+------------------+
|  API Gateway     |  REST API  →  prod stage
|  acme-checkout   |
+--------+---------+
         |
         v
+------------------+
|  AWS Lambda      |
|  acme-checkout   |
+------------------+
```

> **AWS Mental Model:** A Web ACL is a **bouncer at the front door of your API**. Every request presents itself to the bouncer, who checks it against an ordered rulebook. Known troublemakers (reputation-listed IPs, SQL injection patterns, Tor exit nodes) are turned away immediately with a 403. Regular customers (requests matching nothing bad) walk right in. The bouncer never builds the app — it only decides who enters, in milliseconds, before any Lambda invocation even begins.

---

## Core Concepts Before You Start

### Web ACL

A **Web ACL (Web Access Control List)** is the top-level container in WAF. It holds:
- One or more **rules** or **rule groups**, each with an assigned **priority number**.
- A **default action** (Allow or Block) — what to do when no rule matches.
- A **scope**: either `REGIONAL` (for ALB, API Gateway REST, AppSync, Cognito, App Runner) or `CLOUDFRONT` (for CloudFront distributions only).

A Web ACL is associated with one or more AWS resources. The association is what activates WAF inspection on that resource.

### Rules and Rule Groups

A **rule** defines a **condition** (what to inspect) and an **action** (Allow, Block, Count, CAPTCHA, Challenge). Conditions include: IP set match, geo-match, string match, regex match, SQL injection match, XSS match, size constraint, rate-based count.

A **rule group** is a reusable collection of rules packaged together. AWS publishes **AWS Managed Rule Groups** maintained by the AWS Threat Research team. Third parties publish rule groups on AWS Marketplace. You can create your own.

### IP Sets and Regex Pattern Sets

- An **IP Set** is a named list of CIDR blocks you can reference in a rule (e.g., "block these 10 specific IPs" or "allow only our corporate ranges").
- A **Regex Pattern Set** is a named list of regex patterns you can reference in rules (e.g., a set of known bad User-Agent strings).

These are reusable — one IP Set can be referenced by multiple rules in multiple Web ACLs.

### WCU — Web ACL Capacity Units

Every rule and rule group "costs" a number of **WCUs** based on computational complexity. A Web ACL has a default **maximum of 1,500 WCUs**. Simple rules (IP set match) cost 1 WCU. Complex rules (regex match across the body) cost more. AWS Managed Rule Groups have published WCU costs. The WCU system ensures no Web ACL becomes so complex it adds meaningful latency to request inspection.

| Rule Type | Approximate WCU Cost |
|---|---|
| IP set match | 1 WCU |
| Geo-match | 1 WCU |
| Rate-based rule (no scope-down) | 2 WCUs |
| String match on headers | 10 WCUs |
| Regex match on body | 30–50 WCUs |
| AWSManagedRulesCommonRuleSet | 700 WCUs |
| AWSManagedRulesSQLiRuleSet | 200 WCUs |
| AWSManagedRulesKnownBadInputsRuleSet | 200 WCUs |

### Rule Priority

Rules are evaluated in **ascending priority number order** — the lowest number is evaluated first. The **first terminating action** (Allow or Block) ends evaluation. Count and Challenge actions are non-terminating — they record or challenge but evaluation continues. This means your most specific or most performance-sensitive rules should get lower priority numbers (run first).

### Default Action

The default action fires when **no rule produces a terminating action**. For a public API where you block known-bad traffic and want everyone else through, use **Allow** as the default. For a strict internal API where only specific IPs are allowed, use **Block** as the default and write Allow rules for the specific IPs.

### Count Mode vs. Block Mode

When you first deploy a rule group in production, you should put it in **Count mode**:
- Requests that would have been blocked are instead **counted** (metric recorded, sample logged), but the request **passes through**.
- You can observe what the rule would block without impacting real users.
- After validating no false positives, switch to **Block mode**.

> **Security Consideration:** Always deploy new managed rule groups in **Count** mode first in production. The `AWSManagedRulesCommonRuleSet` can occasionally block legitimate traffic (e.g., unusually large POST bodies from form submissions). Monitor for 1–2 days in Count mode before switching to Block.

---

## AWS Managed Rule Groups Overview

| Rule Group | Protection | WCU |
|---|---|---|
| `AWSManagedRulesCommonRuleSet` | OWASP Top 10 generalist protection: XSS, LFI, RFI, log4j, oversized bodies | 700 |
| `AWSManagedRulesSQLiRuleSet` | SQL injection patterns in URI, query string, body, cookie, header | 200 |
| `AWSManagedRulesKnownBadInputsRuleSet` | Known bad input patterns (Log4JRCE, SSRF patterns, PROPFIND) | 200 |
| `AWSManagedRulesAmazonIpReputationList` | Amazon threat-intel IPs (botnets, scanners) | 25 |
| `AWSManagedRulesAnonymousIpList` | Tor exit nodes, VPN providers, hosting ranges | 50 |
| `AWSManagedRulesBotControlRuleSet` | Common bots — scrapers, crawlers, headless browsers | 50+ (varies) |

> **Why This Matters:** AWS Threat Research continuously updates these rule groups. When a new CVE drops (like Log4Shell in 2021), AWS pushes an update within hours — and every Web ACL using `AWSManagedRulesKnownBadInputsRuleSet` automatically gets it. You get threat intelligence without maintaining any rules yourself.

---

## Part 1 — Create a REST API to Protect

AWS WAF for regional resources supports **REST API stages** but NOT HTTP API stages. Acme's checkout API is a REST API.

1. Open the AWS Console. Set the **region selector** (top-right) to **US West (Oregon) `us-west-2`**. Verify this before every step.
2. Search for **API Gateway** and open it.
3. Under **REST API** (the one that says "Develop an API..."), choose **Build**.
   - **Not HTTP API** — WAF cannot attach to an HTTP API stage. REST API stages are the supported type.
4. Choose **New API**:
   - API name: `acme-checkout-api`
   - Description: `Acme Retail checkout REST API — WAF lab target`
   - Endpoint type: **Regional** (not Edge-optimized — Regional APIs in `us-west-2` can attach to a Regional WAF Web ACL in `us-west-2`)
   - Choose **Create API**.
5. In the left menu choose **Resources**. With the root `/` resource selected, choose **Create resource**:
   - Resource name: `checkout`
   - Resource path: `/checkout`
   - Choose **Create resource**.
6. With `/checkout` selected, choose **Create method**:
   - Method type: **POST**
   - Integration type: **Mock**
   - Choose **Create method**.
7. For the Mock integration, set up a response. On the **Method Response** tab, expand **200**. On the **Integration Response** tab, expand **200** > **Mapping Templates** > add `application/json`:
   ```json
   {"message": "Checkout simulated successfully", "orderId": "MOCK-001"}
   ```
   Choose **Save**.
8. Choose **Deploy API**:
   - Stage: **[New Stage]**, Stage name: `prod`
   - Choose **Deploy**.
9. Note the **Invoke URL** shown: `https://<api-id>.execute-api.us-west-2.amazonaws.com/prod`. Your full endpoint for the checkout route is: `https://<api-id>.execute-api.us-west-2.amazonaws.com/prod/checkout`.

> **Cost Awareness:** A Mock REST API stage with near-zero traffic costs pennies. REST API requests are billed at $3.50 per million; you will send fewer than 50 in this lab.

---

## Part 2 — Create a CloudWatch Log Group for WAF Logging

WAF can deliver access logs to CloudWatch Logs, S3, or Kinesis Data Firehose. **CloudWatch Logs** is the simplest option for a lab — logs appear within seconds and you can query them directly.

**Important naming rule:** CloudWatch log groups used for WAF logging **must start with** `aws-waf-logs-`.

1. Search for **CloudWatch** and open it (region `us-west-2`).
2. In the left menu, choose **Logs** > **Log groups** > **Create log group**.
3. Log group name: `aws-waf-logs-acme-checkout`
4. Retention: **1 week** (keeps costs minimal for a lab).
5. Choose **Create**.

---

## Part 3 — Create the Web ACL

1. Search for **WAF & Shield** and open it.
2. In the left navigation, choose **Web ACLs**.
3. **Scope / region:** In the top-right dropdown confirm the region reads **US West (Oregon)**. WAF Web ACL scope and region must match the associated resource.

   > **Common Beginner Mistake:** If you accidentally set scope to **CloudFront (Global)** and try to attach it to an API Gateway stage, the association will fail. Regional resources (ALB, REST API, AppSync, Cognito, App Runner, Verified Access) require a **Regional** Web ACL in the same region as the resource.

4. Choose **Create web ACL**.

### Step 1: Describe the Web ACL

- **Resource type**: Regional resources
- **Region**: US West (Oregon)
- **Name**: `acme-checkout-web-acl`
- **CloudWatch metric name**: leave auto-filled (`acme-checkout-web-acl`)
- **Description**: WAF protection for Acme Retail checkout API
- **Associated AWS resources**: Choose **Add AWS resources** > resource type **API Gateway** > select `acme-checkout-api` stage `prod` > **Add**.
- Choose **Next**.

### Step 2: Add Rules and Rule Groups

You will add managed rule groups and one custom rule in later steps. For now, add the managed groups:

**Add AWS Managed Rule Groups:**

Choose **Add rules** > **Add managed rule groups** > expand **AWS managed rule groups**.

Add the following in order (toggle **Add to web ACL** to **On** for each):

1. **Amazon IP reputation list** (`AWSManagedRulesAmazonIpReputationList`)
   - **What it protects against:** Requests from IP addresses identified by Amazon's internal threat intelligence as associated with botnets, scanning infrastructure, malware command-and-control, and automated attack tools.
   - **Why Acme needs it:** The checkout API sees IPs from known botnet operators. This rule blocks those IPs before they even probe for vulnerabilities.
   - WCU cost: 25

2. **Anonymous IP list** (`AWSManagedRulesAnonymousIpList`)
   - **What it protects against:** Requests from Tor exit nodes, public VPN services, hosting providers, and other anonymization infrastructure.
   - **Why Acme needs it:** Legitimate customers don't route checkout requests through Tor. Anonymized traffic is a strong signal of malicious intent for a payment flow.
   - WCU cost: 50

3. **Core rule set** (`AWSManagedRulesCommonRuleSet`)
   - **What it protects against:** The OWASP Top 10 generalist threats — XSS (cross-site scripting), LFI (local file inclusion), RFI (remote file inclusion), oversized request bodies, the Log4Shell (log4j JNDI) exploit string, and other common web attack patterns.
   - **Why Acme needs it:** The checkout API accepts user input (product IDs, quantities, promo codes). Any user-supplied input field is a potential injection vector.
   - **Override to Count mode for now:** Expand the rule group after adding it, choose **Override rule group action** > **Count** (so it records what it would block without blocking it — we'll validate, then switch to Block).
   - WCU cost: 700

4. **SQL injection rule set** (`AWSManagedRulesSQLiRuleSet`)
   - **What it protects against:** SQL injection payloads in URI, query string, body, cookie, and headers. This group focuses exclusively on SQLi patterns with higher accuracy than the generic rules in CRS.
   - **Why Acme needs it:** Acme's order data lives in RDS. Even if the API uses parameterized queries, defense-in-depth means blocking known SQLi patterns at the WAF layer too.
   - WCU cost: 200

5. **Known bad inputs rule set** (`AWSManagedRulesKnownBadInputsRuleSet`)
   - **What it protects against:** Specific high-impact known-bad input strings: SSRF (Server-Side Request Forgery) patterns (e.g., requests for `169.254.169.254`), `PROPFIND` method abuse, Log4JRCE exploit strings, and Java deserialization attack payloads.
   - **Why Acme needs it:** SSRF could allow attackers to read Acme's EC2 instance metadata. This rule blocks such attempts at the perimeter.
   - WCU cost: 200

Choose **Add rules**.

**Observe WCU usage:** The console shows current capacity. 25 + 50 + 700 + 200 + 200 = **1,175 WCUs** — under the 1,500 default limit with 325 WCUs left for custom rules.

### Step 3: Set Rule Priority

The priority order (lower number = evaluated first) matters. Arrange rules so the cheapest evaluations run first:

| Priority | Rule | Reason |
|---|---|---|
| 0 | Amazon IP Reputation List | Cheap (25 WCU), blocks known-bad IPs immediately |
| 1 | Anonymous IP List | Cheap (50 WCU), blocks anonymizers early |
| 2 | SQL Injection Rule Set | Targeted (200 WCU) |
| 3 | Known Bad Inputs | Targeted (200 WCU) |
| 4 | Core Rule Set | Most expensive (700 WCU), runs last |

Drag rules or use the arrows to achieve this order. Choose **Next**.

### Step 4: Configure Metrics

Leave defaults — **CloudWatch metrics enabled** and **Sampled requests enabled** (up to 100 sampled per rule per hour are stored). Choose **Next**.

### Step 5: Default Action

- **Default action: Allow**
- This means any request not explicitly blocked by a rule is allowed through. Acme's checkout API is public — you block known-bad traffic, not allowlist known-good traffic.

Choose **Next**, review, and choose **Create web ACL**.

> **What Is Happening Behind the Scenes?** After creation, AWS WAF starts intercepting **every** request to the associated API Gateway `prod` stage. The request never reaches API Gateway's routing engine until WAF approves it. WAF evaluation adds single-digit milliseconds of latency — typically 1–3ms for a regional Web ACL.

---

## Part 4 — Enable WAF Logging to CloudWatch Logs

1. Open `acme-checkout-web-acl` in the WAF console.
2. Go to the **Logging and metrics** tab.
3. Choose **Enable logging**.
4. **Logging destination**: choose **CloudWatch Logs log group**.
5. **Log group**: select `aws-waf-logs-acme-checkout` (the one you created in Part 2).
6. **Log filter** (optional): leave empty to log all requests (allowed and blocked).
   - In production you might filter to log only **BLOCK** decisions to reduce log volume and cost. For this lab, log everything to see the full picture.
7. Choose **Save**.

> **What Is Happening Behind the Scenes?** WAF writes a structured JSON log record to CloudWatch Logs for every inspected request. Each record includes: `timestamp`, `action` (ALLOW/BLOCK/COUNT), `terminatingRuleId`, `httpSourceName`, source IP, country, URI, and the full list of non-terminating rule matches. This is invaluable for security analysis and debugging false positives.

> **Cost Awareness:** WAF logging to CloudWatch Logs incurs standard CWL ingestion and storage costs (~$0.50/GB ingested, $0.03/GB stored). For a lab with light traffic this is cents. In production with millions of requests, consider logging only BLOCK decisions or using S3 with lifecycle policies.

---

## Part 5 — Add Custom Rules

### 5A — Rate-Based Rule: Protect Against Credential Stuffing

Rate-based rules block a source IP (or other aggregation key) that exceeds a request threshold in a rolling time window. For Acme's checkout endpoint, an IP sending more than 100 requests in 5 minutes is almost certainly automated.

1. In `acme-checkout-web-acl`, go to the **Rules** tab > **Add rules** > **Add my own rules and rule groups**.
2. Rule type: **Rate-based rule**.
3. Configure:
   - Name: `acme-rate-limit-checkout`
   - **Rate limit**: `100`
   - **Evaluation window**: `5 minutes` (300 seconds)
     - WAF supports windows of 1, 2, 5, or 10 minutes. The count is a rolling estimate.
   - **Request aggregation**: `Source IP address` — each unique client IP has its own counter.
   - **Scope-down statement**: choose **Add scope-down statement** > condition type **URI path** > match type **Starts with string** > string to match: `/prod/checkout`
     - This scopes the rate limit to only the `/checkout` route. The WAF rate counter only increments for requests to `/prod/checkout`.
   - **Action**: **Block**
4. **Priority**: set priority to `5` (after the managed groups, priority 0–4).
5. Choose **Add rule** > **Save**.

> **Why This Matters:** Without rate limiting, an attacker can try thousands of stolen credential pairs against `/checkout` without any throttling. API Gateway does have usage plans, but those apply per API key — not per source IP for unauthenticated callers. WAF rate-based rules add IP-level rate limiting at the perimeter.

### 5B — Geo-Match Rule: Block High-Risk Geographies

Acme Retail currently ships only to the US, Canada, and the UK. Traffic from other countries hitting the checkout API is unexpected and potentially malicious.

1. In `acme-checkout-web-acl`, **Rules** tab > **Add rules** > **Add my own rules and rule groups**.
2. Rule type: **Regular rule**.
3. Configure:
   - Name: `acme-geo-block`
   - **If a request** matches the statement:
   - **Inspect**: **Originates from a country in**
   - **Country codes**: add any geography your business does not serve — for this lab add: `CN`, `RU`, `KP`, `IR` (China, Russia, North Korea, Iran — high-risk for demo purposes).
     - **Note:** In a real deployment, you would tailor this list to countries you genuinely do not serve. Over-blocking is a real risk — do not block countries where legitimate customers live.
   - **Action**: **Block**
4. **Priority**: `6`
5. Choose **Add rule** > **Save**.

> **Security Consideration:** Geo-blocking is a coarse tool. Sophisticated attackers use US-based proxies or cloud infrastructure. It reduces noise from certain attack sources but is not a substitute for deeper security controls. Use it as one layer in defense-in-depth, not as primary protection.

### 5C — View the Final Rule Order

After adding both custom rules, your Web ACL should show (in priority order):

| Priority | Rule | WCU | Action |
|---|---|---|---|
| 0 | AWSManagedRulesAmazonIpReputationList | 25 | Block |
| 1 | AWSManagedRulesAnonymousIpList | 50 | Block |
| 2 | AWSManagedRulesSQLiRuleSet | 200 | Block |
| 3 | AWSManagedRulesKnownBadInputsRuleSet | 200 | Block |
| 4 | AWSManagedRulesCommonRuleSet | 700 | Count (temporary) |
| 5 | acme-rate-limit-checkout | 2 | Block |
| 6 | acme-geo-block | 1 | Block |
| — | Default action | — | Allow |

Total WCU: ~1,178 (under 1,500 limit).

---

## Part 6 — Security Testing: Send Simulated Attack Traffic

### 6A — Normal Request (Should Be Allowed)

From your terminal, replace `<api-id>` with your actual API ID from Part 1:

```bash
curl -X POST \
  "https://<api-id>.execute-api.us-west-2.amazonaws.com/prod/checkout" \
  -H "Content-Type: application/json" \
  -d '{"productId": "SHOES-001", "quantity": 2, "promoCode": "SAVE10"}'
```

**Expected:** HTTP 200 with:
```json
{"message": "Checkout simulated successfully", "orderId": "MOCK-001"}
```

This request should be **Allowed** — no rule matches.

### 6B — SQL Injection Test (Should Be Blocked)

```bash
curl -v \
  "https://<api-id>.execute-api.us-west-2.amazonaws.com/prod/checkout?id=1%27+OR+1%3D1--" \
  -H "Content-Type: application/json"
```

The query string `id=1' OR 1=1--` is a classic SQL injection probe. The `AWSManagedRulesSQLiRuleSet` should detect and block this.

**Expected:** HTTP 403 with body:
```json
{"message":"Forbidden"}
```

### 6C — XSS Test (Should Be Blocked or Counted by CRS)

```bash
curl -v \
  "https://<api-id>.execute-api.us-west-2.amazonaws.com/prod/checkout" \
  -H "Content-Type: application/json" \
  -d '{"productId": "<script>alert(1)</script>", "quantity": 1}'
```

The `AWSManagedRulesCommonRuleSet` contains XSS detection rules. Because you set CRS to **Count** mode, this request will be **counted but allowed** (you will see it in Sampled Requests with action `COUNT`).

### 6D — Large Request Body Test (Should Be Blocked by CRS)

```bash
python3 -c "print('A' * 10000)" | \
  curl -v -X POST \
  "https://<api-id>.execute-api.us-west-2.amazonaws.com/prod/checkout" \
  -H "Content-Type: application/json" \
  --data-binary @-
```

CRS includes a rule blocking request bodies over 8KB (the `SizeRestrictions_BODY` rule). Because CRS is in Count mode, this will be counted but allowed.

### 6E — View Sampled Requests

1. In `acme-checkout-web-acl`, choose the **Traffic overview** tab (or **Sampled requests** tab).
2. Wait **2–5 minutes** for metrics to populate. WAF metrics have a slight delay.
3. For the **AWSManagedRulesSQLiRuleSet** rule, the sampled requests panel should show the SQL injection request from step 6B with action **BLOCK**, source IP (your IP), and the matched rule within the group.
4. For the **AWSManagedRulesCommonRuleSet**, you may see the XSS request with action **COUNT** (because you set it to Count mode).

> **What Is Happening Behind the Scenes?** WAF stores up to 100 request samples per rule per hour. Each sample includes the full request metadata: timestamp, source IP, country, URI, HTTP method, matched rule ID, and action taken. This is invaluable for diagnosing false positives — you can see exactly which rule matched and why.

### 6F — Validate via CloudWatch Logs

1. Open **CloudWatch** > **Log groups** > `aws-waf-logs-acme-checkout`.
2. Choose the most recent log stream.
3. You should see JSON log entries for each request. Look for a BLOCK entry:

```json
{
  "timestamp": 1720000000000,
  "formatVersion": 1,
  "webaclId": "arn:aws:wafv2:us-west-2:...",
  "terminatingRuleId": "AWS-AWSManagedRulesSQLiRuleSet",
  "terminatingRuleType": "MANAGED_RULE_GROUP",
  "action": "BLOCK",
  "httpSourceName": "APIGW",
  "httpRequest": {
    "clientIp": "1.2.3.4",
    "country": "US",
    "uri": "/prod/checkout",
    "args": "id=1' OR 1=1--",
    "httpMethod": "GET"
  }
}
```

The `terminatingRuleId` tells you exactly which rule blocked the request.

---

## Part 7 — Switch Core Rule Set to Block Mode

After observing that no legitimate traffic was incorrectly counted in Part 6 (CRS Count mode), switch the Core Rule Set to Block mode:

1. `acme-checkout-web-acl` > **Rules** tab > click on the `AWS-AWSManagedRulesCommonRuleSet` row.
2. Choose **Edit**.
3. Under **Override rule group action**, change from **Count** to **None** (uses the rule group's own action, which is Block for matched rules).
4. Choose **Save rule**.

In production you would monitor Count mode for several days before this switch. For this lab, a few minutes of validation is sufficient.

---

## Concept Callouts

### WAF on API Gateway vs. CloudFront vs. ALB

| Attachment Point | WAF Scope | Use When |
|---|---|---|
| CloudFront distribution | CLOUDFRONT (Global) | You use CloudFront CDN; inspection happens at edge PoPs globally |
| Application Load Balancer | REGIONAL | Web app behind ALB; inspect HTTP/HTTPS at the load balancer layer |
| API Gateway REST API stage | REGIONAL | Serverless API; no ALB or CDN in front |
| API Gateway HTTP API | **NOT SUPPORTED** | Cannot attach WAF directly; use CloudFront in front of the HTTP API instead |

> **Common Beginner Mistake:** API Gateway **HTTP APIs** (v2) do not support direct WAF attachment. If you need WAF on an HTTP API, put a **CloudFront distribution** in front of the HTTP API, and attach a **CloudFront-scoped (Global)** WAF Web ACL to the distribution.

### AWS Shield Standard vs. Shield Advanced

| Feature | Shield Standard | Shield Advanced |
|---|---|---|
| Cost | Free, automatic | ~$3,000/month per organization |
| L3/L4 DDoS protection | Yes (always on) | Yes, enhanced |
| L7 DDoS mitigation | No | Yes, with WAF integration |
| Attack visibility | Basic | Detailed attack reports |
| DRT (DDoS Response Team) | No | 24/7 access |
| Cost protection | No | Yes (credits for scaling costs during attack) |
| SRT automatic rules | No | Yes (WAF rules auto-applied during active attacks) |

**Shield Standard** is automatically active on all AWS accounts at no charge. It protects against common L3/L4 (network/transport) DDoS attacks. **Shield Advanced** adds L7 (application layer) DDoS mitigation, the AWS DDoS Response Team (DRT), financial protections, and detailed attack telemetry. For most SaaS applications, Shield Standard + WAF provides strong protection. Regulated industries and large public services may benefit from Shield Advanced.

### Bot Control

**AWS WAF Bot Control** is a managed rule group specifically designed to detect and manage bot traffic:
- **Common Bot Control**: detects category A bots — scrapers, crawlers, monitoring agents. Can allow verified bots (Googlebot) and block others.
- **Targeted Bot Control**: detects sophisticated bots that rotate IPs, use headless browsers, and try to evade detection.

Bot Control uses a combination of signature matching and behavioral analysis. It can categorize bots (search engine bot, SEO crawler, headless browser, etc.) and apply actions selectively.

### CAPTCHA and Challenge Actions

Beyond Allow/Block/Count, WAF supports two interactive actions:
- **CAPTCHA**: returns a CAPTCHA puzzle. If the user solves it, WAF issues a time-limited token and retries the request. Bots cannot solve CAPTCHAs (without additional ML).
- **Challenge**: presents a silent JavaScript challenge (like Cloudflare Turnstile). Legitimate browsers solve it automatically; scripts and bots typically fail.

These actions allow WAF to distinguish human users from automated tools without simply blocking.

---

## Validation Checkpoint

Before proceeding to challenges, verify:

- [ ] `acme-checkout-web-acl` exists in `us-west-2`, Regional scope.
- [ ] Associated with `acme-checkout-api` prod stage.
- [ ] 5 managed rule groups + 2 custom rules appear in Rules tab.
- [ ] WAF logging enabled to `aws-waf-logs-acme-checkout`.
- [ ] SQL injection test returned HTTP 403.
- [ ] Normal checkout POST returned HTTP 200.
- [ ] Sampled requests shows the blocked SQLi request.
- [ ] CloudWatch log group has WAF log entries.

---

## Challenge Exercises

### Challenge 1: Create a Custom IP Allowlist Rule

Acme's internal security team needs to test the checkout API from a known corporate IP range. Create a custom **IP Set** for the corporate IP range `203.0.113.0/24` (a TEST-NET-3 documentation range, safe for lab use), and create a WAF rule that **Allows** requests from this IP range at **priority 0** (evaluated before any block rules). This ensures corporate security testers are never blocked by WAF.

**Requirements:**
- Create an IP Set named `acme-corporate-ips` containing `203.0.113.0/24`
- Add a Regular rule named `acme-allow-corporate` at priority 0 that Allows requests from that IP Set
- The Allow rule should supersede all block rules (ensuring security testers are never blocked)
- Explain why an Allow rule at priority 0 is the correct approach (vs. adding exceptions to block rules)

**Hint:** WAF > IP sets (left nav). Then create a Regular rule using "IP set" as the inspect condition.

### Challenge 2: Add AWS Bot Control Managed Rule Group

The Acme Retail product team notices that their inventory data is being scraped by competitors. Add the **AWS Bot Control Common** managed rule group to the Web ACL, configure it in **Count mode** (to observe without blocking), and explain how you would configure it to block scrapers while allowing Googlebot and other verified bots.

**Requirements:**
- Add `AWSManagedRulesBotControlRuleSet` in Count mode
- Note the additional WCU cost and how it affects the total
- Describe the rule override strategy to allow verified bots but block "scrapers"
- Describe how you would switch from Count to Block mode once validated

**Hint:** Bot Control is in "AWS managed rule groups" like the others, but shows "Bot Control" in the category. Look at the rule group's individual rules — some are labeled with bot categories.

---

## Cleanup Instructions

Clean up in this order to avoid dependency errors:

1. **Disassociate the resource first:**
   - WAF & Shield > **Web ACLs** > `acme-checkout-web-acl` > **Associated AWS resources** tab > select `prod` stage > **Remove** > confirm.
   - *(A Web ACL with active associations cannot be deleted.)*

2. **Delete the Web ACL:**
   - WAF & Shield > **Web ACLs** > select `acme-checkout-web-acl` > **Delete** > type the name to confirm.

3. **Delete the IP Set (if you completed Challenge 1):**
   - WAF & Shield > **IP sets** > select `acme-corporate-ips` > **Delete**.

4. **Delete the WAF log group:**
   - CloudWatch > **Log groups** > `aws-waf-logs-acme-checkout` > **Delete log group**.

5. **Delete the REST API:**
   - API Gateway > **APIs** > select `acme-checkout-api` > **Delete** > confirm.

> **Cost Reminder:** WAF bills ~$5/month per Web ACL and ~$1/month per rule group just for existing — even at zero traffic. Cleanup is critical. A Web ACL left running for a month costs ~$12 with the rules in this lab.

---

## Key Takeaways

- A **Web ACL** is an ordered list of rules. WAF evaluates every request in priority order; the first terminating action (Allow or Block) wins.
- **Default action** fires only when no rule matches. Use **Allow** for public APIs you're filtering; use **Block** for strict allow-list models.
- **AWS Managed Rule Groups** provide continuously-updated threat intelligence with no rule management overhead. Always deploy in **Count mode** first in production.
- **WCU** is a computational budget (default 1,500) that prevents Web ACLs from adding excessive request latency.
- **Rate-based rules** protect against credential stuffing, scraping, and simple DDoS bursts by tracking per-IP request rates.
- **Geo-match rules** reduce noise from high-risk geographies, but are a coarse tool — use as one defense layer, not the primary one.
- WAF attaches to **REST API stages** but NOT HTTP API stages. For HTTP APIs, place CloudFront in front and attach a CloudFront-scoped Web ACL.
- **WAF logging** (CloudWatch Logs / S3 / Firehose) gives you forensic visibility into every request and exactly which rule matched.
- **Shield Standard** is free and always-on for L3/L4 DDoS; **Shield Advanced** adds L7 mitigation, DRT access, and cost protection.
