# Foundational AWS Labs — One-Day Build & Explore Track

Welcome to the foundational track of the **AWS Microcredentials Bootcamp: Serverless + Agentic AI**. These twelve labs are **guided, build-and-explore, console-based** exercises. Their job is to teach you *how the core AWS services actually work* — by building small, working pieces with your own hands in the AWS Management Console — **before** you reach the later break-fix modules where you diagnose and repair deliberately broken systems.

Nothing here is broken on purpose. You will create real resources, watch them work, understand *why* they behave the way they do, and then clean them up. By the end of the day you will have touched identity, data, compute, APIs, authentication, messaging, orchestration, observability, security, and deployment — the same building blocks you will later troubleshoot and, eventually, combine with agentic AI.

---

## Folder Structure

Each lab lives in its own folder with **two files**:

| File | Purpose |
|------|---------|
| `XX-lab.md` | The full lab — steps, concepts, mental models, and challenge prompts |
| `XX-solutions.md` | **Instructor-release-after-attempt** — complete solutions for all challenge exercises |

Challenge exercises appear in the main lab file as prompts only (no answers). Distribute the solutions file **after** students have attempted the challenge.

---

## The 12 Exercises

| # | Exercise | Folder | Est. Duration | Primary Services |
|---|----------|--------|---------------|-----------------|
| 01 | IAM Deep Dive: Identities, Roles, and Least Privilege | [lab-01-iam-deep-dive/](lab-01-iam-deep-dive/) | ~120 min | IAM, STS |
| 02 | DynamoDB: Store a Product Catalog | [lab-02-dynamodb-product-catalog/](lab-02-dynamodb-product-catalog/) | ~75 min | DynamoDB |
| 03 | Lambda: Build an Order-Processing Function | [lab-03-lambda-order-processor/](lab-03-lambda-order-processor/) | ~90 min | Lambda, IAM, CloudWatch Logs |
| 04 | API Gateway: Expose a Lambda with an HTTP API | [lab-04-api-gateway-http-api/](lab-04-api-gateway-http-api/) | ~90 min | API Gateway (HTTP API), Lambda |
| 05 | Cognito: Add User Sign-Up and Sign-In | [lab-05-cognito-authentication/](lab-05-cognito-authentication/) | ~90 min | Cognito |
| 06 | SNS: Send Order Notifications | [lab-06-sns-notifications/](lab-06-sns-notifications/) | ~75 min | SNS, Lambda |
| 07 | SQS: Queue Work Between Services | [lab-07-sqs-work-queue/](lab-07-sqs-work-queue/) | ~90 min | SQS, Lambda |
| 08 | Step Functions: Orchestrate an Order Workflow | [lab-08-step-functions-order-workflow/](lab-08-step-functions-order-workflow/) | ~105 min | Step Functions, Lambda |
| 09 | CloudWatch: Logs, Metrics, Alarms, and Dashboards | [lab-09-cloudwatch-observability/](lab-09-cloudwatch-observability/) | ~90 min | CloudWatch |
| 10 | AWS WAF: Protect an API | [lab-10-waf-protection/](lab-10-waf-protection/) | ~75 min | AWS WAF, API Gateway |
| 11 | CodePipeline: Deploy Changes Safely | [lab-11-codepipeline-deployment/](lab-11-codepipeline-deployment/) | ~90 min | CodePipeline, CodeBuild, S3, Lambda |
| 12 | Capstone: Wire All the Services Together | [lab-12-capstone-integration/](lab-12-capstone-integration/) | ~120 min | Lambda, DynamoDB, API Gateway, SNS/SQS, Step Functions, Cognito, WAF, CloudWatch |

**Total guided lab time: ~1,110 minutes (~18.5 hours)**. Run across a full day with challenges as stretch goals.

---

## How to Use These Labs

- **Sign in as an IAM user or an IAM Identity Center user — never the root user.** The root user (the email address you used to create the account) is for account setup and billing only. Doing daily work as an admin-capable IAM identity is a core AWS security practice you will learn to respect in Lab 01.
- **Work through the labs in order the first time.** They are technically independent — each provides its own standalone setup — but the *concepts* build on one another. IAM (Lab 01) underpins everything else.
- **Use `us-west-2` (US West — Oregon) for every lab** unless a lab explicitly says otherwise. All ARN examples and console instructions in these labs are written for `us-west-2`. Mixing regions is the single most common way beginners "lose" resources they just created.
- **Keep costs minimal.** Every lab is sized to fit comfortably in the AWS Free Tier or to cost only pennies. The key habit: **always run the Cleanup section at the end of each lab.**
- **Read the concept callouts.** The boxes labeled *Why This Matters*, *AWS Mental Model*, *Common Beginner Mistake*, and similar are where the real learning lives — not just the click-by-click steps.
- **Challenge exercises:** attempt them before looking at the solutions. The solutions file for each lab (`XX-solutions.md`) is provided separately so instructors can distribute it after the attempt.

## Cost Awareness

All twelve labs are designed for **minimal usage** and most resources fall within the AWS Free Tier. However, **charges can still apply** — for example, resources left running (idle queues, standing WAF web ACLs, retained CloudWatch log groups) accrue cost over time, and Free Tier limits vary by account age. **Always run the Cleanup section at the end of each lab.** If you stop partway through, either finish the cleanup for what you built or note what remains so you can remove it later.

## Region

Use **US West (Oregon) — `us-west-2`** for all labs. This region has broad service availability (including Amazon Bedrock, which you'll use in the agentic AI modules), competitive pricing, and is a common choice for production workloads. Always confirm the region selector in the top-right corner of the console before you start clicking.

> **Why us-west-2?** Oregon is one of AWS's most complete regions — it has full Bedrock model availability, Aurora, all serverless services, and strong Free Tier behavior. Every ARN example in these labs uses `us-west-2`. Learning here transfers directly to real-world usage.

## Dependencies

The labs are **independently self-contained** — each includes its own setup — but the **concepts build in order**:

```
01-IAM → foundation for every other lab
02-DynamoDB → data store used by Lambda (03) and later labs
03-Lambda → compute used by API Gateway (04) and all later labs
04-API Gateway → the HTTP front door for Cognito (05) and WAF (10)
05-Cognito → authentication referenced in API Gateway labs
06-SNS + 07-SQS → messaging used in Step Functions (08)
08-Step Functions → orchestration of all previous services
09-CloudWatch → observability across all services
10-WAF → security layer on top of API Gateway
11-CodePipeline → CI/CD for Lambda deployments
12-Capstone → ties everything together
```

If you only have time for one lab, do **Lab 01: IAM Deep Dive**. If you have time for two, add **Lab 03: Lambda**.

---

## Quick Navigation

### Lab Files (Student)

- [lab-01-iam-deep-dive/01-lab.md](lab-01-iam-deep-dive/01-lab.md)
- [lab-02-dynamodb-product-catalog/02-lab.md](lab-02-dynamodb-product-catalog/02-lab.md)
- [lab-03-lambda-order-processor/03-lab.md](lab-03-lambda-order-processor/03-lab.md)
- [lab-04-api-gateway-http-api/04-lab.md](lab-04-api-gateway-http-api/04-lab.md)
- [lab-05-cognito-authentication/05-lab.md](lab-05-cognito-authentication/05-lab.md)
- [lab-06-sns-notifications/06-lab.md](lab-06-sns-notifications/06-lab.md)
- [lab-07-sqs-work-queue/07-lab.md](lab-07-sqs-work-queue/07-lab.md)
- [lab-08-step-functions-order-workflow/08-lab.md](lab-08-step-functions-order-workflow/08-lab.md)
- [lab-09-cloudwatch-observability/09-lab.md](lab-09-cloudwatch-observability/09-lab.md)
- [lab-10-waf-protection/10-lab.md](lab-10-waf-protection/10-lab.md)
- [lab-11-codepipeline-deployment/11-lab.md](lab-11-codepipeline-deployment/11-lab.md)
- [lab-12-capstone-integration/12-lab.md](lab-12-capstone-integration/12-lab.md)

### Solution Files (Instructor — release after challenge attempts)

- [lab-01-iam-deep-dive/01-solutions.md](lab-01-iam-deep-dive/01-solutions.md)
- [lab-02-dynamodb-product-catalog/02-solutions.md](lab-02-dynamodb-product-catalog/02-solutions.md)
- [lab-03-lambda-order-processor/03-solutions.md](lab-03-lambda-order-processor/03-solutions.md)
- [lab-04-api-gateway-http-api/04-solutions.md](lab-04-api-gateway-http-api/04-solutions.md)
- [lab-05-cognito-authentication/05-solutions.md](lab-05-cognito-authentication/05-solutions.md)
- [lab-06-sns-notifications/06-solutions.md](lab-06-sns-notifications/06-solutions.md)
- [lab-07-sqs-work-queue/07-solutions.md](lab-07-sqs-work-queue/07-solutions.md)
- [lab-08-step-functions-order-workflow/08-solutions.md](lab-08-step-functions-order-workflow/08-solutions.md)
- [lab-09-cloudwatch-observability/09-solutions.md](lab-09-cloudwatch-observability/09-solutions.md)
- [lab-10-waf-protection/10-solutions.md](lab-10-waf-protection/10-solutions.md)
- [lab-11-codepipeline-deployment/11-solutions.md](lab-11-codepipeline-deployment/11-solutions.md)
- [lab-12-capstone-integration/12-solutions.md](lab-12-capstone-integration/12-solutions.md)
