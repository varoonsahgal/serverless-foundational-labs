# Lab 10: Protecting an API with AWS WAF

## Estimated Duration

~30 minutes

## Scenario / Business Context

**Acme Retail** has just launched a public API for its online store. Within days, the security team notices suspicious traffic: repeated hits from anonymizing proxies and IP addresses that are known sources of botnet activity. Before this becomes a real incident, Acme wants a first line of defense that inspects every incoming request and filters out obviously malicious traffic — *before* it ever reaches the application code.

In this lab you play the role of an Acme cloud engineer standing up **AWS WAF (Web Application Firewall)** to protect the Acme API.

## Learning Objectives

By the end of this exercise you will be able to:

- Explain what a **Web ACL** (Access Control List) is and how AWS WAF inspects traffic.
- Create a regional Web ACL in `us-east-1`.
- Add AWS **managed rule groups** and reason about **rule priority** and the **default action**.
- Understand **WCU (Web ACL Capacity Units)** at a high level.
- Understand which AWS resource types WAF can and cannot be associated with, and why.
- Validate a Web ACL and inspect sampled requests / metrics.

## AWS Services Used

- AWS WAF (part of the **AWS WAF & Shield** console)
- Amazon API Gateway (REST API — optional, used as the association target)

## Prerequisites

- An AWS account.
- Sign in as an **IAM user** (or IAM Identity Center user) with permissions for AWS WAF and API Gateway. **Do not use the root user.**
- Region: **us-east-1** (N. Virginia). All steps use this region.
- **Lab-specific:** To *associate* the Web ACL with a live resource, you need a supported resource. AWS WAF supports association with:
  - Amazon **CloudFront** distributions (scope = CloudFront / Global)
  - Application Load Balancers (ALB)
  - **Amazon API Gateway REST API stages**
  - AWS AppSync GraphQL APIs
  - Amazon Cognito user pools
  - AWS App Runner services
  - Verified Access instances

  > **Accuracy note — HTTP APIs are NOT supported.** As of 2026, AWS WAF **cannot** be associated directly with an API Gateway **HTTP API**. WAF only supports API Gateway **REST API** stages. If you only have an HTTP API, you have two choices: (a) create a minimal REST API for this lab (guided below), or (b) build and inspect the Web ACL *without* a live association. Both paths are covered.

---

## Part 1 — (Optional) Create a Minimal REST API to Protect

If you already have an API Gateway **REST API** with a deployed stage, skip to Part 2. If you only have an HTTP API (or nothing), do this to get a supported association target. If you would rather not create an API at all, skip to Part 2 and follow the **"no association" path** — everything else works identically.

1. In the AWS Console search bar, type **API Gateway** and open it.
2. Confirm the region selector (top-right) reads **N. Virginia / us-east-1**.
3. Under **REST API** (the one that is *not* private), choose **Build**.
   - **What this does:** creates a classic REST API, which supports WAF association at the stage level.
4. Choose **New API**. API name: `acme-waf-demo-api`. Leave defaults. Choose **Create API**.
5. In the left menu choose **Resources**. With the `/` root selected, choose **Create method**.
   - Method type: **GET**
   - Integration type: **Mock** (returns a canned response, no backend needed — keeps this free and simple).
   - Choose **Create method**.
6. Choose **Deploy API** (top-right).
   - Stage: **New stage**, name it `prod`. Choose **Deploy**.
   - **Why it matters:** WAF associates with a **stage**, not the API itself. No deployed stage = nothing to attach to.
7. Note the **Invoke URL** shown for the `prod` stage (looks like `https://abc123.execute-api.us-east-1.amazonaws.com/prod`). You will reference this stage in Part 3.

> **Cost Awareness:** A Mock REST API stage with no traffic incurs no meaningful cost. API Gateway REST API requests are billed per million requests; you will send only a handful.

---

## Part 2 — Create the Web ACL

1. In the AWS Console search bar, type **WAF** and open **AWS WAF & Shield**.
2. In the left navigation, choose **Web ACLs**.
3. **Set the scope / region correctly.** Above the region selector you will see a resource-type context. For anything that is *not* CloudFront, you must pick a **Region**. Set the region selector (top-right) to **US East (N. Virginia) us-east-1**.
   - **Regional vs CloudFront scope:** WAF has two scopes. **CloudFront (Global)** Web ACLs attach only to CloudFront distributions. **Regional** Web ACLs attach to regional resources (ALB, API Gateway REST stage, AppSync, Cognito, App Runner) *in that specific region*. A Regional Web ACL in `us-east-1` can only protect `us-east-1` resources.
4. Choose **Create web ACL**.
5. **Step 1 — Describe web ACL and associate resources:**
   - Resource type: choose **Regional resources** (Application Load Balancer, API Gateway, etc.). *(Do not choose CloudFront.)*
   - Name: `acme-web-acl`
   - CloudWatch metric name: leave the auto-filled value.
   - **Associated AWS resources (optional):** Choose **Add AWS resources**.
     - If you created the REST API in Part 1: select resource type **API Gateway**, then check the `acme-waf-demo-api` **prod** stage, and choose **Add**.
     - **No-association path:** skip this — leave it empty. You will still build and inspect the ACL. (You can associate later from the API Gateway or WAF console.)
   - Choose **Next**.

6. **Step 2 — Add rules and rule groups:**
   - Choose **Add rules** > **Add managed rule groups**.
   - Expand **AWS managed rule groups**.
   - Find **Amazon IP reputation list** (rule group `AWSManagedRulesAmazonIpReputationList`). Toggle **Add to web ACL** to **On**.
     - **What it does:** blocks requests from IP addresses that Amazon threat intelligence has flagged (bots, malware sources, etc.).
   - Find **Anonymous IP list** (rule group `AWSManagedRulesAnonymousIpList`). Toggle **Add to web ACL** to **On**.
     - **What it does:** blocks/limits requests coming from VPNs, Tor exit nodes, hosting providers, and other anonymizing services.
   - Choose **Add rules**.
   - **WCU (Web ACL Capacity Units):** Notice the console shows a **capacity** number as you add rules. Every Web ACL has a budget (default max 1500 WCUs). Each rule group "costs" some WCUs based on how expensive it is to evaluate. This prevents a Web ACL from becoming so complex it hurts latency. The two rule groups here are well within budget.

7. **Set rule priority.** On the rules list, the order top-to-bottom is the **evaluation priority**. WAF evaluates rules from lowest priority number (top) to highest (bottom) and stops at the first rule that **blocks** or **allows** a request. Leave the two managed groups in their default order — either order is fine for this lab because both only *block* bad traffic.

8. **Step 3 — Set rule priority:** (a review screen) confirm the order and choose **Next**.

9. **Step 4 — Configure metrics:** leave defaults (CloudWatch metrics + sampled requests enabled). Choose **Next**.

10. **Step 5 — Default action.** This is critical:
    - **Default action = Allow.**
    - **What the default action means:** it is what WAF does with a request that **no rule** explicitly matched. `Allow` means "if none of my block rules matched, let it through." `Block` would mean "deny everything unless a rule explicitly allows it" (a strict allow-list model). For a public API you protect *from* known-bad traffic, `Allow` is correct.
11. Choose **Next**, review everything, and choose **Create web ACL**.

---

## Part 3 — Validate

1. Back on **Web ACLs**, confirm `acme-web-acl` appears with **Region = US East (N. Virginia)**.
2. Open `acme-web-acl`. On the **Rules** tab, confirm both managed rule groups are listed:
   - `AWS-AWSManagedRulesAmazonIpReputationList`
   - `AWS-AWSManagedRulesAnonymousIpList`
3. **If you associated a resource:** open the **Associated AWS resources** tab and confirm your `prod` REST API stage is listed. You can also verify from the other direction: API Gateway > your API > **Stages** > `prod` — the stage settings will show the associated Web ACL ARN.
4. **Sampled requests / metrics:**
   - Open the **Sampled requests** tab (or **Traffic overview**).
   - **Expected result right now:** likely empty. WAF only records sampled requests after real traffic flows through an associated resource, and metrics can take a few minutes to populate.
   - If you associated the REST API, generate a little traffic: open the stage **Invoke URL** in a browser (or `curl https://<your-id>.execute-api.us-east-1.amazonaws.com/prod`) a few times, wait 2–5 minutes, then refresh **Sampled requests**. You should see sampled `GET /` requests with an action of **Allow** (your own IP is not on the reputation lists).

> **What Is Happening Behind the Scenes?** When a request hits the associated resource, API Gateway hands the request metadata to WAF *first*. WAF walks its rules in priority order. If a rule matches with a Block action, WAF returns a 403 and the request never reaches your integration. If nothing blocks, the default action (Allow) lets it continue. All of this happens in milliseconds, at the edge of your service.

---

## Concept Callouts

**AWS Mental Model:** Think of a Web ACL as a **bouncer at the door of a club**. Every guest (HTTP request) is inspected against a checklist (the rules) before entering. Known troublemakers (bad-reputation IPs, anonymizers) are turned away at the door; everyone else (default action Allow) gets in. The bouncer never *builds* the club — it only decides who enters.

**Common Beginner Mistake:**
- Trying to attach a Web ACL to an **unsupported resource** — most commonly an API Gateway **HTTP API** (not supported) or an S3 bucket (not supported). Only the supported list (CloudFront, ALB, REST API stage, AppSync, Cognito, App Runner, Verified Access) works.
- Choosing the wrong **scope**: creating a **CloudFront (Global)** Web ACL and then wondering why your ALB or REST stage doesn't appear — regional resources need a **Regional** Web ACL *in the same region*.
- Expecting **sampled requests to appear instantly**. They need real traffic through an associated resource and a few minutes.

**Authentication vs. Authorization:** WAF is **neither**. Authentication answers "who are you?" (handled by Cognito, an identity provider, or API keys). Authorization answers "are you allowed to do this?" (handled by IAM, Cognito scopes, Lambda authorizers). **WAF is traffic filtering** — it inspects request *patterns, IP reputation, rates, and payloads* and decides allow/block *before* auth even runs. A request can be allowed by WAF and still be rejected by authentication, and vice versa.

**Cost Awareness:** **AWS WAF costs money even at zero traffic.** Pricing has three parts: a **monthly charge per Web ACL** (~$5/month, prorated), a **monthly charge per rule / rule group** (~$1 each — the two **AWS Managed Rules** groups in this lab do **not** add any extra subscription fee; only third-party **AWS Marketplace** managed rule groups do), and a **per-request charge** (~$0.60 per million requests inspected). Because the Web ACL and its rules accrue charges *just by existing*, **delete this lab promptly** when finished.

**Security Consideration:** Managed rule groups are maintained by AWS and updated automatically as new threats emerge — you get fresh threat intelligence without editing rules yourself. In production, start managed rules in **Count** mode first to observe what they *would* block before switching them to **Block**, so you don't accidentally block legitimate customers. For this lab we used Block directly because the reputation/anonymizer lists rarely match normal users.

---

## Key Takeaways

- A **Web ACL** is a container of rules that inspects every request to an associated resource and allows or blocks it.
- **Scope matters:** CloudFront (Global) vs Regional. Regional Web ACLs protect regional resources in the same region.
- **Default action** applies when no rule matches — use **Allow** for a public API you're filtering, **Block** for strict allow-lists.
- **Rule priority** determines evaluation order; WAF stops at the first terminating (Allow/Block) match.
- **WCU** is a capacity budget that keeps Web ACLs from becoming too expensive to evaluate.
- WAF associates only with **supported resource types** — **HTTP APIs are not supported; REST API stages are.**
- WAF is **traffic filtering**, distinct from authentication (Cognito) and authorization (IAM).

---

## Cleanup Instructions

Do these in order to avoid ongoing WAF charges.

1. **Disassociate the resource first.**
   - WAF & Shield > **Web ACLs** > `acme-web-acl` > **Associated AWS resources** tab.
   - Select the associated `prod` stage and choose **Remove**. Confirm.
   - *(A Web ACL cannot be deleted while it still has associations.)*
2. **Delete the Web ACL.**
   - WAF & Shield > **Web ACLs** > select `acme-web-acl` > **Delete**. Type the confirmation and delete.
3. **Delete the REST API (if you created one in Part 1).**
   - API Gateway > **APIs** > select `acme-waf-demo-api` > **Actions / Delete** (or the **Delete** button). Confirm.
4. Double-check the **Web ACLs** list is empty (region us-east-1) so no monthly Web ACL charge continues.

> **Reminder:** Because WAF bills per Web ACL and per rule *monthly regardless of traffic*, cleanup is the most important step in this lab.

---

## Early-Finisher Challenge

Add a **rate-based rule** to `acme-web-acl` that **blocks any single IP address that sends more than 100 requests in a 5-minute window**. This defends against brute-force and simple denial-of-service bursts. Validate that the rule appears in the Web ACL, then clean it up.

---

## Challenge Solution

1. WAF & Shield > **Web ACLs** > open `acme-web-acl`.
2. **Rules** tab > **Add rules** > **Add my own rules and rule groups**.
3. Rule type: choose **Rate-based rule**.
4. Configure:
   - Name: `acme-rate-limit`
   - **Rate limit:** `100`
     - **What it means:** the maximum number of requests allowed from a single aggregation key within the evaluation window before the action triggers.
   - **Evaluation window:** `5 minutes` (300 seconds).
     - *(Note: AWS WAF rate-based rules support 1, 2, 5, or 10-minute windows. The count is a rolling estimate over that window.)*
   - **Request aggregation:** choose **Source IP address** (block per-IP, not globally).
   - **Action:** **Block**.
   - **Scope-down statement:** leave off (apply to all requests).
5. **Priority:** set this rule to a **lower priority number** (evaluated earlier) or leave it appended — for a rate limit, evaluating it early is fine. Choose **Add rule**.
6. Save/confirm changes to the Web ACL.
7. **Validate:** open `acme-web-acl` > **Rules** tab and confirm `acme-rate-limit` is listed alongside the two managed rule groups, with action **Block** and the `100 / 5 min` limit. *(To truly trigger it you'd need to send 100+ requests from one IP within 5 minutes; for the lab, confirming its presence is sufficient.)*
8. **Cleanup the challenge:** **Rules** tab > select `acme-rate-limit` > **Delete rule** > save. Then follow the main **Cleanup Instructions** above to remove the Web ACL and REST API.
