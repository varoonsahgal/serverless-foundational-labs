# Lab 11: Automated CI/CD Deployment with AWS CodePipeline

## Estimated Duration

~90 minutes

## Scenario / Business Context

**Acme Retail's** Lambda-based checkout service has been deployed manually for months. The process is painful: a developer runs `zip` on their laptop, uploads to S3, then manually updates the Lambda function code through the console. Two weeks ago, a developer accidentally uploaded the wrong zip file — a file from a different project — and took the checkout service down for 20 minutes during peak traffic. That outage cost Acme $15,000 in lost sales.

The engineering lead has mandated: **all Lambda deployments must go through an automated pipeline**. Every code change must be:
1. Automatically detected when pushed to the source repository.
2. Run through a **build stage** that packages the code and runs tests.
3. **Held for human approval** before any deployment to production.
4. **Deployed automatically** to Lambda once approved.

This is **Continuous Integration / Continuous Delivery (CI/CD)**. In this lab you build a full CodePipeline that fulfills all four requirements.

---

## CI/CD Concepts

Before building, understand the vocabulary:

| Term | Definition |
|---|---|
| **Continuous Integration (CI)** | Every code commit automatically triggers a build and automated test run. The team always knows if the code compiles and passes tests. |
| **Continuous Delivery (CD)** | Every passing build is automatically prepared for deployment. A human makes the go/no-go deployment decision. |
| **Continuous Deployment** | Every passing build is automatically deployed to production with no human approval. Rare in production; common for dev/staging environments. |
| **Pipeline** | The top-level automation workflow: a sequence of stages. |
| **Stage** | A phase of the pipeline (Source, Build, Test, Approval, Deploy). Stages run sequentially. |
| **Action** | A specific task inside a stage (fetch from S3, run CodeBuild, wait for approval). A stage can contain multiple parallel actions. |
| **Artifact** | A package (usually a ZIP file) that one stage produces and the next stage consumes. Artifacts move through an S3 "artifact store." |
| **Transition** | The connection between two stages. Transitions can be disabled to pause the pipeline at a specific point. |

> **AWS Mental Model:** CodePipeline is an **assembly line**. Raw materials (your source code) enter one end. Each workstation (stage) does something to the product (code). Quality checkpoints (approvals) halt the line for inspection. The finished product (deployed Lambda function) exits at the other end. CodePipeline is the **conveyor belt** — it doesn't build or test code itself, it orchestrates the specialists (CodeBuild, CodeDeploy, Lambda) that do.

---

## Architecture: What You Are Building

```
                        ┌─────────────────────────────────────────────────────────┐
                        │                  acme-checkout-pipeline                  │
                        │                                                           │
  ┌──────────────┐      │  ┌──────────────┐    ┌──────────────┐    ┌────────────┐ │
  │   Developer  │      │  │   Stage 1    │    │   Stage 2    │    │  Stage 3   │ │
  │   uploads    │ ───► │  │   SOURCE     │──► │   APPROVAL   │──► │   BUILD    │ │
  │  source.zip  │      │  │   (S3)       │    │  (Manual)    │    │ (CodeBuild)│ │
  └──────────────┘      │  └──────────────┘    └──────────────┘    └─────┬──────┘ │
                        │                                                  │        │
                        └──────────────────────────────────────────────────┼────────┘
                                                                           │
                                                                           ▼
                                                                  ┌────────────────┐
                                                                  │  Stage 4       │
                                                                  │  DEPLOY        │
                                                                  │ (Lambda update)│
                                                                  └────────────────┘
                                                                           │
                                                                           ▼
                                                                  ┌────────────────┐
                                                                  │  AWS Lambda    │
                                                                  │ acme-checkout  │
                                                                  └────────────────┘
```

**Artifact flow:**
```
source.zip (in S3) ──► [Source stage downloads] ──► SourceArtifact
SourceArtifact ──► [Build stage packages + tests] ──► BuildArtifact
BuildArtifact ──► [Deploy stage] ──► Lambda function code updated
```

---

## Learning Objectives

By the end of this lab you will be able to:

- Explain CI/CD concepts and the difference between CI, CD (delivery), and CD (deployment).
- Create a versioned S3 source bucket and upload a source artifact.
- Write a `buildspec.yml` that installs dependencies, runs tests, and packages a Lambda zip.
- Create a CodeBuild project with appropriate environment settings.
- Add a manual approval stage with SNS email notification.
- Configure a deploy stage that updates Lambda function code.
- Use pipeline execution history to view build logs and identify failures.
- Configure SNS notifications for pipeline state changes.
- Understand Lambda versions, aliases, and the concept of blue/green Lambda deployment.

---

## AWS Services Used

- **AWS CodePipeline** (orchestration)
- **AWS CodeBuild** (build and test execution)
- **AWS Lambda** (deployment target)
- **Amazon S3** (source bucket + artifact store)
- **Amazon SNS** (approval notifications + pipeline state notifications)
- **AWS IAM** (service roles for pipeline and build)
- **Amazon CloudWatch Logs** (CodeBuild build logs)
- **Amazon EventBridge** (automated pipeline trigger)

---

## Prerequisites

- An AWS account. Region: **US West (Oregon) `us-west-2`** for everything.
- IAM user with permissions for: `codepipeline:*`, `codebuild:*`, `lambda:*`, `s3:*`, `sns:*`, `iam:PassRole`, `iam:CreateRole`, `iam:PutRolePolicy`, `events:*`.
- **Do not use the root user.**
- A terminal (macOS/Linux or Git Bash on Windows) with `zip` and `python3` available.
- An email address you can check.

> **Note on Source:** This lab uses **Amazon S3** as the code source. AWS CodeCommit was deprecated in 2024 and is no longer available to new customers. S3 is the simplest alternative for a learning lab. In production teams typically use GitHub, GitLab, or Bitbucket integrated via CodePipeline's source action or GitHub Actions.


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

## Part 1 — Create the Lambda Function (Deployment Target)

Before building the pipeline, create the Lambda function that CodePipeline will deploy code to.

1. Open **Lambda** (region `us-west-2`) > **Create function** > **Author from scratch**.
2. Configure:
   - **Function name**: `acme-checkout-lambda`
   - **Runtime**: Python 3.12
   - **Architecture**: x86_64
   - **Permissions**: Create a new role with basic Lambda permissions.
3. Choose **Create function**.
4. In the code editor, replace the default handler with a simple placeholder:
   ```python
   import json

   def lambda_handler(event, context):
       return {
           "statusCode": 200,
           "body": json.dumps({"version": "1.0", "status": "Acme checkout placeholder"})
       }
   ```
5. Choose **Deploy**.
6. Note the Lambda function ARN (shown at the top of the function page): `arn:aws:lambda:us-west-2:<account-id>:function:acme-checkout-lambda`. You will need this in the deploy stage.

> **Why create the function first?** The CodePipeline deploy action updates an *existing* Lambda function's code. CodeDeploy's Lambda deployment requires the function to already exist. You cannot create a new Lambda function through CodePipeline's standard deploy action.

---

## Part 2 — Create the Source S3 Bucket

CodePipeline's S3 source action detects changes by watching for **new object versions** in a versioned S3 bucket. Versioning is mandatory.

1. Open **S3** (region `us-west-2`) > **Create bucket**.
2. Configure:
   - **Bucket name**: `acme-pipeline-src-<yourinitials>` (e.g., `acme-pipeline-src-jsmith`)
     - Bucket names are globally unique across all AWS accounts worldwide. Add your initials to ensure uniqueness.
   - **AWS Region**: US West (Oregon) `us-west-2`
   - **Bucket Versioning**: **Enable** (critical — CodePipeline requires it)
   - **Block Public Access**: leave all settings checked (bucket must be private)
3. Choose **Create bucket**.

> **Why versioning?** CodePipeline's S3 source action triggers when a new **object version** appears for the source key (`source.zip`). Without versioning, uploading a new file to the same key is a replacement, not a new version — the pipeline has no reliable trigger. With versioning, each upload is a distinct version ID, and EventBridge fires the pipeline on each new version.

---

## Part 3 — Build the Source Package

Create a realistic Lambda deployment package with application code, tests, and a `buildspec.yml`.

### 3A — Create the Application Files

Create a local directory called `acme-checkout-source` with these files:

**`lambda_function.py`** — The Lambda handler:
```python
import json
import os
import boto3
from datetime import datetime

def lambda_handler(event, context):
    """
    Acme Retail Checkout Lambda.
    Accepts POST /checkout with a JSON body containing:
      - productId (str)
      - quantity (int)
      - customerId (str)
    Returns an order confirmation.
    """
    # Parse body from HTTP API payload format 2.0
    raw_body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        import base64
        raw_body = base64.b64decode(raw_body).decode("utf-8")

    try:
        data = json.loads(raw_body)
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON body"})

    product_id = data.get("productId")
    quantity = data.get("quantity", 1)
    customer_id = data.get("customerId")

    if not product_id or not customer_id:
        return _response(400, {"error": "productId and customerId are required"})

    if not isinstance(quantity, int) or quantity < 1:
        return _response(400, {"error": "quantity must be a positive integer"})

    # In production this would write to DynamoDB, charge payment, etc.
    order_id = f"ORD-{datetime.utcnow().strftime('%Y%m%d%H%M%S')}"

    return _response(200, {
        "orderId": order_id,
        "productId": product_id,
        "quantity": quantity,
        "customerId": customer_id,
        "status": "CONFIRMED",
        "version": os.environ.get("APP_VERSION", "2.0")
    })

def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body)
    }
```

**`test_lambda_function.py`** — Unit tests:
```python
import json
import sys
import os

# Allow import of lambda_function from the same directory
sys.path.insert(0, os.path.dirname(__file__))
from lambda_function import lambda_handler

def make_event(body_dict):
    """Helper: build a minimal HTTP API v2.0 event."""
    return {
        "body": json.dumps(body_dict),
        "isBase64Encoded": False,
        "requestContext": {"http": {"method": "POST"}}
    }

def test_valid_order():
    event = make_event({"productId": "SHOES-001", "quantity": 2, "customerId": "CUST-123"})
    response = lambda_handler(event, None)
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["productId"] == "SHOES-001"
    assert body["status"] == "CONFIRMED"
    print("PASS: test_valid_order")

def test_missing_product_id():
    event = make_event({"quantity": 1, "customerId": "CUST-123"})
    response = lambda_handler(event, None)
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "error" in body
    print("PASS: test_missing_product_id")

def test_invalid_quantity():
    event = make_event({"productId": "SHOES-001", "quantity": -1, "customerId": "CUST-123"})
    response = lambda_handler(event, None)
    assert response["statusCode"] == 400
    print("PASS: test_invalid_quantity")

def test_invalid_json():
    event = {"body": "this is not json", "isBase64Encoded": False}
    response = lambda_handler(event, None)
    assert response["statusCode"] == 400
    print("PASS: test_invalid_json")

if __name__ == "__main__":
    test_valid_order()
    test_missing_product_id()
    test_invalid_quantity()
    test_invalid_json()
    print("\nAll tests passed!")
```

**`buildspec.yml`** — CodeBuild instructions (must be at the root of the zip):
```yaml
version: 0.2

env:
  variables:
    APP_VERSION: "2.0"
    FUNCTION_NAME: "acme-checkout-lambda"

phases:
  install:
    runtime-versions:
      python: 3.12
    commands:
      - echo "=== INSTALL PHASE ==="
      - echo "Installing test dependencies..."
      - pip install pytest --quiet

  pre_build:
    commands:
      - echo "=== PRE-BUILD PHASE ==="
      - echo "Running unit tests before packaging..."
      - python -m pytest test_lambda_function.py -v --tb=short
      - echo "All tests passed. Proceeding to build."

  build:
    commands:
      - echo "=== BUILD PHASE ==="
      - echo "Packaging Lambda deployment ZIP..."
      - zip -r deployment.zip lambda_function.py
      - echo "Build artifact created: deployment.zip"
      - ls -lh deployment.zip

  post_build:
    commands:
      - echo "=== POST-BUILD PHASE ==="
      - echo "Build complete for Acme Checkout Lambda v${APP_VERSION}"
      - echo "Artifact ready for deployment to function: ${FUNCTION_NAME}"

artifacts:
  files:
    - deployment.zip
  name: BuildOutput
```

> **buildspec.yml phases explained:**
> - **install**: runs once to set up the build environment. Here we set Python 3.12 runtime and install pytest.
> - **pre_build**: runs before the main build. We run unit tests here — if tests fail, CodeBuild exits with a non-zero code, the build stage fails, and the pipeline stops. Code with failing tests never reaches deploy.
> - **build**: the actual packaging step. We zip `lambda_function.py` into `deployment.zip`.
> - **post_build**: cleanup, notifications, or logging. Runs even if build phase fails.
> - **artifacts**: declares what files to store as the build output artifact. CodePipeline picks up `deployment.zip` from here and passes it to the deploy stage.

### 3B — Create and Upload the Source Zip

From your terminal, inside the `acme-checkout-source` directory:

```bash
cd acme-checkout-source
zip source.zip lambda_function.py test_lambda_function.py buildspec.yml
```

**Critical layout check:** `buildspec.yml` must be at the root of `source.zip`, not inside a subfolder. Verify:
```bash
unzip -l source.zip
# Should show:
# lambda_function.py
# test_lambda_function.py
# buildspec.yml
# (NOT: acme-checkout-source/buildspec.yml)
```

> **Common Beginner Mistake:** If you zip the *folder* (`zip -r source.zip acme-checkout-source/`) instead of the *files* (`zip source.zip *.py buildspec.yml`), `buildspec.yml` ends up at `acme-checkout-source/buildspec.yml` inside the archive. CodeBuild looks for it at the root and fails with "YAML_FILE_ERROR: buildspec.yml does not exist".

Upload to S3:

```bash
aws s3 cp source.zip s3://acme-pipeline-src-<yourinitials>/source.zip --region us-west-2
```

Or via console: S3 > your bucket > **Upload** > **Add files** > select `source.zip` > **Upload**.

Verify the upload created a version. In S3, open the bucket > `source.zip` > **Versions** tab. You should see one version with a version ID.

---

## Part 4 — Create an SNS Topic for Approval Notifications

Before creating the pipeline, set up the SNS topic that will email approvers when the pipeline needs sign-off.

1. Open **SNS** (region `us-west-2`) > **Topics** > **Create topic**.
2. **Type**: Standard. **Name**: `acme-pipeline-approvals`.
3. Choose **Create topic**. Note the topic ARN.
4. Choose **Create subscription**:
   - Protocol: **Email**
   - Endpoint: your email address
5. Choose **Create subscription**.
6. Open the confirmation email from AWS and click **Confirm subscription**. The subscription status must become **Confirmed**.

> **Common Beginner Mistake:** If you skip email confirmation, CodePipeline will send approval notifications to SNS but the SNS subscription is in `PendingConfirmation` — no email is delivered. You'll sit at the console wondering why the email never comes. Always confirm subscriptions before testing.

---

## Part 5 — Create the CodeBuild Project

Create the CodeBuild project before creating the pipeline, so you can configure it carefully.

1. Open **CodeBuild** (region `us-west-2`) > **Build projects** > **Create build project**.
2. Configure:
   - **Project name**: `acme-checkout-build`
   - **Description**: Builds and tests the Acme Retail checkout Lambda

3. **Source**: for now, select **No source** (the pipeline will pass the source artifact).
   - When CodeBuild runs inside a pipeline, it receives the source as an artifact from CodePipeline, not directly from a source provider configured on the build project.

4. **Environment**:
   - **Provisioning model**: On-demand
   - **Environment image**: Managed image
   - **Operating system**: Amazon Linux
   - **Runtime(s)**: Standard
   - **Image**: `aws/codebuild/amazonlinux-x86_64-standard:5.0` (or the latest available — choose the newest)
   - **Image version**: Always use the latest for this environment
   - **Environment type**: Linux EC2
   - **Service role**: **New service role** (auto-named `codebuild-acme-checkout-build-service-role`)

5. **Buildspec**:
   - Choose **Use a buildspec file** — CodeBuild will use `buildspec.yml` from the root of the input artifact.
   - Do NOT paste inline — your `buildspec.yml` is in the zip, and CodeBuild will find it automatically.

6. **Artifacts**:
   - Type: **No artifacts** — artifact configuration will be handled by CodePipeline.

7. **Logs**:
   - **CloudWatch Logs**: Enable. Log group name: `/aws/codebuild/acme-checkout-build`. This lets you view build output in CloudWatch Logs.

8. Choose **Create build project**.

### Grant CodeBuild Permissions to Update Lambda

The auto-created CodeBuild service role can write CloudWatch Logs but cannot update Lambda. Add the Lambda update permission:

1. IAM > **Roles** > search for `codebuild-acme-checkout-build-service-role` > open it.
2. **Add permissions** > **Create inline policy** > JSON tab:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AllowLambdaUpdate",
         "Effect": "Allow",
         "Action": [
           "lambda:UpdateFunctionCode",
           "lambda:GetFunction",
           "lambda:PublishVersion"
         ],
         "Resource": "arn:aws:lambda:us-west-2:<ACCOUNT_ID>:function:acme-checkout-lambda"
       }
     ]
   }
   ```
   Replace `<ACCOUNT_ID>` with your 12-digit account ID.
3. Policy name: `acme-codebuild-lambda-access`. Choose **Create policy**.

> **Security Consideration:** Why scope to the specific function ARN? If the CodeBuild service role had `lambda:UpdateFunctionCode` on `Resource: "*"`, a malicious `buildspec.yml` in the source zip could update any Lambda function in the account — including security functions, billing functions, or other teams' services. Scoping to the specific function ARN limits the blast radius.

---

## Part 6 — Create the Pipeline

1. Open **CodePipeline** (region `us-west-2`) > **Pipelines** > **Create pipeline**.
2. **Step 1 — Choose creation option**: choose **Build custom pipeline** > **Next**.
3. **Step 2 — Pipeline settings**:
   - **Pipeline name**: `acme-checkout-pipeline`
   - **Pipeline type**: **V2**
     - V2 is the current default. Billed per action execution minute, not per pipeline. Supports triggers, variables, and more granular control. V1 (older, flat monthly fee per active pipeline) is still available but V2 is preferred for new pipelines.
   - **Service role**: **New service role** (leave "Allow AWS CodePipeline to create a service role" checked)
   - **Artifact store**: **Default location** (CodePipeline creates a managed S3 artifact bucket in this region, named like `codepipeline-us-west-2-xxxxxxxx`)
   - Choose **Next**.

4. **Step 3 — Source stage**:
   - **Source provider**: Amazon S3
   - **Bucket**: `acme-pipeline-src-<yourinitials>`
   - **S3 object key**: `source.zip`
   - **Change detection options**: **Amazon CloudWatch Events (recommended)**
     - This creates an EventBridge rule that fires the pipeline automatically when a new version of `source.zip` appears in the bucket. Zero polling overhead, near-instant detection (typically < 30 seconds).
   - **Output artifact format**: CodePipeline default (ZIP)
   - Choose **Next**.

5. **Step 4 — Build stage**:
   - **Build provider**: AWS CodeBuild
   - **Region**: US West (Oregon)
   - **Project name**: `acme-checkout-build` (the project you created in Part 5)
   - **Build type**: Single build
   - Choose **Next**.

6. **Step 5 — Deploy stage**: choose **Skip deploy stage** for now. You will add a deploy action after creating the pipeline.
   - Confirm the skip.

7. **Review** and choose **Create pipeline**.

The pipeline immediately tries its first execution using the current `source.zip`. Let it run — but you'll add the Approval stage next.

---

## Part 7 — Add the Manual Approval Stage

The pipeline currently runs Source → Build (no Approval). Add the approval gate between Source and Build.

1. Open `acme-checkout-pipeline` > choose **Edit**.
2. Between the **Source** and **Build** stages, choose **+ Add stage**:
   - **Stage name**: `Approval`
   - Choose **Add stage**.
3. Inside the new `Approval` stage, choose **+ Add action group** > **Add action**:
   - **Action name**: `ManualApproval`
   - **Action provider**: Manual approval
   - **SNS topic ARN**: select `acme-pipeline-approvals` (the topic from Part 4)
   - **URL for review**: `https://github.com/acme-retail/checkout-service` (or any URL relevant to your review process)
   - **Comments**: `Review the build output and test results before approving deployment.`
   - Choose **Done**.
4. Choose **Save** on the pipeline edit screen. Confirm.

Your pipeline is now: **Source → Approval → Build**.

> **What a manual approval does:** When the pipeline reaches the Approval stage, it pauses indefinitely (up to 7 days by default, configurable). An SNS email is sent to subscribers of `acme-pipeline-approvals`. The email contains the pipeline name, stage, action, comments, and (if configured) the review URL. A human logs into the console and clicks **Approve** or **Reject**. If approved, the pipeline continues; if rejected, the execution fails with the rejection reason.

---

## Part 8 — Add the Lambda Deploy Stage

Add a final stage that updates the Lambda function code using the build artifact.

1. Open `acme-checkout-pipeline` > **Edit**.
2. After the **Build** stage, choose **+ Add stage**:
   - **Stage name**: `Deploy`
   - Choose **Add stage**.
3. Inside the `Deploy` stage, choose **Add action group** > **Add action**:
   - **Action name**: `DeployToLambda`
   - **Action provider**: **AWS Lambda**
   - **Input artifacts**: select `BuildArtifact` (the output of the Build stage)
   - **Function name**: `acme-checkout-lambda`
   - **User parameters**: `{"ZipFile": "deployment.zip"}`
     - This tells the Lambda action which file in the artifact ZIP to use as the new function code package.
   - Choose **Done**.
4. Choose **Save**. Confirm.

Your pipeline is now: **Source → Approval → Build → Deploy**.

> **Lambda Versions and Aliases (Blue/Green Concept):**
> In production, Lambda deployments often use **versions** and **aliases** for zero-downtime blue/green deployments:
> - A **version** is an immutable snapshot of your Lambda code + configuration. You publish a new version after updating function code.
> - An **alias** is a pointer to a specific version (e.g., `prod` alias → version 5).
> - To do blue/green: publish new code as version 6, shift the `prod` alias 10% traffic to v6 (canary), monitor errors, then shift 100%.
> - CodeDeploy's Lambda deployment group can automate this canary/linear traffic shifting.
> This lab deploys directly without versions — sufficient for learning the pipeline mechanics. In production, use CodeDeploy with `LambdaLinear10PercentEvery1Minute` or `LambdaCanary10Percent5Minutes` deployment configurations.

---

## Part 9 — Run and Validate End-to-End

### Trigger the Pipeline

Re-upload `source.zip` to trigger a fresh execution (or choose **Release change** on the pipeline page):

```bash
aws s3 cp source.zip s3://acme-pipeline-src-<yourinitials>/source.zip --region us-west-2
```

### Watch the Execution

1. Open `acme-checkout-pipeline`. Watch each stage turn green:
   - **Source**: downloads `source.zip` from S3. Creates artifact `SourceArtifact`. Expected: ~10 seconds.
   - **Approval**: turns blue/yellow — pipeline is paused. An email arrives at your inbox.

2. Open the approval email. It contains:
   - Pipeline name: `acme-checkout-pipeline`
   - Stage: `Approval`
   - A review link back to the console
   - Your custom comment

3. In the `Approval` stage, choose **Review** > **Approve** with comment: `Reviewed build manifest — approved for build and deploy.`

4. **Build**: CodeBuild runs. Expect 1–3 minutes.
   - To watch in real time: CodeBuild > `acme-checkout-build` > latest build > **Build logs** tab.
   - **Expected log output includes:**
     ```
     === INSTALL PHASE ===
     Installing test dependencies...
     === PRE-BUILD PHASE ===
     Running unit tests before packaging...
     test_lambda_function.py::test_valid_order PASSED
     test_lambda_function.py::test_missing_product_id PASSED
     test_lambda_function.py::test_invalid_quantity PASSED
     test_lambda_function.py::test_invalid_json PASSED
     4 passed in 0.XXs
     All tests passed. Proceeding to build.
     === BUILD PHASE ===
     Packaging Lambda deployment ZIP...
     Build artifact created: deployment.zip
     === POST-BUILD PHASE ===
     Build complete for Acme Checkout Lambda v2.0
     ```

5. **Deploy**: Lambda function code updated. Expect ~10 seconds.

### Validate the Lambda Deployment

1. Open **Lambda** > `acme-checkout-lambda`.
2. In the **Code source** tab, verify the code now matches what you wrote in `lambda_function.py` (the v2.0 handler).
3. Test the function using the **Test** tab:
   - Create a test event named `CheckoutTest` with body:
     ```json
     {
       "body": "{\"productId\": \"SHOES-001\", \"quantity\": 2, \"customerId\": \"CUST-123\"}",
       "isBase64Encoded": false
     }
     ```
   - Choose **Test**. Expected response:
     ```json
     {
       "statusCode": 200,
       "headers": {"Content-Type": "application/json"},
       "body": "{\"orderId\": \"ORD-...\", \"productId\": \"SHOES-001\", \"quantity\": 2, \"customerId\": \"CUST-123\", \"status\": \"CONFIRMED\", \"version\": \"2.0\"}"
     }
     ```
4. The `"version": "2.0"` field confirms the new code was deployed (the placeholder version was `"1.0"`).

---

## Part 10 — Pipeline Execution History and Rollback

### View Execution History

1. Open `acme-checkout-pipeline`.
2. In the left navigation choose **Execution history** (or the pipeline page shows the last few executions).
3. Each execution shows: start time, status, source version (S3 version ID), and stages.
4. Click on an execution to drill into per-stage timing and status.

### Re-Run a Previous Execution (Rollback)

If a bad deployment reaches Lambda, you can re-run a previous pipeline execution to redeploy the last known-good version:

1. Execution history > find the last successful execution.
2. Choose **Stop and roll back** (or **Retry**) — if the bad execution is still in progress, stop it first.
3. For a completed execution: choose **Retry failed actions** or start a fresh execution by re-uploading the previous source version.

In practice, **true rollback** means re-uploading or re-triggering the previous good version of `source.zip`. Because the S3 bucket has versioning enabled, you can restore a specific S3 object version and trigger the pipeline with it.

### Enable/Disable Stage Transitions

To pause the pipeline from automatically advancing between stages (useful during incident response):

1. Pipeline page > find the transition arrow between two stages > **Disable transition**.
2. The pipeline will complete the current stage but stop before advancing to the next.
3. Re-enable the transition when ready.

> **Why This Matters:** During a production incident, you may want to allow in-flight builds to complete but prevent any new deployments from reaching prod. Disabling the transition between Build and Deploy gives you that control without stopping the pipeline entirely.

---

## Part 11 — CodePipeline Notifications

Set up SNS notifications for pipeline state changes (so the team knows when any execution starts, succeeds, or fails):

1. Open `acme-checkout-pipeline` > **Settings** (gear icon or top navigation) > **Notifications** > **Create notification rule**.
2. Configure:
   - **Notification rule name**: `acme-pipeline-state-notifications`
   - **Detail type**: Full
   - **Events that trigger notification**: select:
     - Pipeline: Execution Started, Execution Succeeded, Execution Failed
     - Stage: Stage Execution Failed
3. **Targets**: choose **Create SNS topic** or select `acme-pipeline-approvals` (reuse the existing topic).
4. Choose **Submit**.

Now the team gets emails when the pipeline starts, succeeds, or fails — not just when approval is needed.

---

## Concept Callouts

> **Common Beginner Mistake: CodePipeline doesn't build code — CodeBuild does.**
> CodePipeline is pure orchestration. It detects source changes, calls CodeBuild (or CodeDeploy, or Lambda, or ECS), passes artifacts between stages, and enforces order and approvals. If the build fails, it's a CodeBuild issue (look at CodeBuild logs), not a CodePipeline issue. Knowing which service owns which responsibility is critical for debugging.

> **Common Beginner Mistake: Wrong zip structure.**
> `buildspec.yml` must be at the **root** of `source.zip`. If you zip a folder instead of files, CodeBuild fails with: `YAML_FILE_ERROR: buildspec.yml does not exist`. Always verify with `unzip -l source.zip` before uploading.

> **Cost Awareness:**
> - **CodePipeline V2**: billed per action execution minute. The pipeline itself is free; you pay for each action (Source ~0 min, CodeBuild 1–3 min/build, Deploy ~0.1 min). At lab volume, total cost is pennies.
> - **CodeBuild**: billed per build minute by compute type. `general1.small` (default) is $0.005/min.
> - **S3**: two buckets — your source bucket and the auto-created artifact bucket. Both accrue small storage costs.
> - **Lambda**: near-free at test invocation volumes.
> - **Cumulative:** Delete all resources to keep this to under $1 for the lab session.

> **Security Consideration: Service Roles**
> CodePipeline uses its service role to: read from the source S3 bucket, write to the artifact store, call CodeBuild, call Lambda (deploy action), publish to SNS (notifications). CodeBuild uses its service role to: read the input artifact, write to CloudWatch Logs, and (with the inline policy you added) update the Lambda function. In production, audit these roles regularly — an over-permissioned CodeBuild role can update any function if scoped to `*`.

> **IAM Concept: PassRole**
> The IAM user creating the pipeline needs `iam:PassRole` permission to allow CodePipeline to use the service role. Without `PassRole`, you get: "User is not authorized to pass this role to AWS CodePipeline." This is a common permission error for IAM users who have CodePipeline permissions but not IAM.

---

## Validation Checkpoint

Before proceeding to challenges, verify:

- [ ] `acme-checkout-lambda` exists and shows placeholder code v1.0.
- [ ] `acme-pipeline-src-<yourinitials>` has versioning enabled and `source.zip` uploaded.
- [ ] `acme-checkout-build` CodeBuild project exists.
- [ ] `acme-checkout-pipeline` has 4 stages: Source → Approval → Build → Deploy.
- [ ] Latest execution completed: Source ✓, Approval ✓ (approved), Build ✓ (tests passed), Deploy ✓.
- [ ] Lambda function now shows v2.0 code.
- [ ] Lambda test event returns `"version": "2.0"`.
- [ ] Approval email arrived at your inbox.

---

## Challenge Exercises

### Challenge 1: Add a Test Stage with a Separate CodeBuild Project

Currently, the pipeline has Build → Deploy directly after Approval. Add a dedicated **Test** stage between Build and Deploy. This Test stage runs a separate CodeBuild project that:
- Downloads the `BuildArtifact` (the `deployment.zip`).
- Unzips it and runs the unit tests from `test_lambda_function.py` directly against the packaged Lambda code.
- Fails the pipeline if any test fails.

This models a real CI/CD pattern where you separate the "build" step from the "test" step — useful when tests take much longer than the build and you want separate visibility.

**Requirements:**
- Create a second CodeBuild project named `acme-checkout-test`.
- Write a `testspec.yml` that unzips `deployment.zip` and runs `python -m pytest test_lambda_function.py`.
- Add a **Test** stage between Build and Deploy that runs `acme-checkout-test`.
- Show how the pipeline execution history shows both Build and Test stage results separately.

**Hint:** The Test CodeBuild project's input artifact is `BuildArtifact` (from the Build stage). The `testspec.yml` file needs to be in the original `source.zip` too (CodeBuild looks for the specified buildspec by name in the input artifact).

### Challenge 2: Add EventBridge Rule for Automated Pipeline Trigger

Currently, the EventBridge rule triggering the pipeline was created automatically when you set **Amazon CloudWatch Events** as the change detection option. Explore this rule and then create an *additional* scheduled EventBridge rule that triggers the pipeline every night at midnight UTC (a nightly build/deploy cycle, independent of source changes).

**Requirements:**
- Find the auto-created EventBridge rule in the EventBridge console. Note its event pattern and target.
- Create a new EventBridge rule named `acme-nightly-build` with a **cron schedule** of `cron(0 0 * * ? *)` (midnight UTC every day).
- The target should be the `acme-checkout-pipeline` pipeline (using the CodePipeline StartPipelineExecution API).
- Create an IAM role that grants EventBridge permission to call `codepipeline:StartPipelineExecution` on the specific pipeline ARN.
- Test by temporarily changing the schedule to run in 2 minutes, verify the pipeline triggers, then change it back to midnight.

**Hint:** EventBridge rule targets can be AWS services. For CodePipeline, the target type is "CodePipeline" and you need to supply the pipeline ARN.

---

## Cleanup Instructions

Delete in this order to avoid dependency issues:

1. **Disable and delete the pipeline:**
   - CodePipeline > `acme-checkout-pipeline` > **Settings** > **Delete pipeline** > type name to confirm.
   - This does NOT delete the service role or artifact bucket.

2. **Delete the CodeBuild projects:**
   - CodeBuild > `acme-checkout-build` > **Delete build project** > confirm.
   - (If you completed Challenge 1) delete `acme-checkout-test` too.

3. **Delete the Lambda function:**
   - Lambda > `acme-checkout-lambda` > **Actions** > **Delete** > confirm.
   - Also delete the Lambda log group: CloudWatch > **Log groups** > `/aws/lambda/acme-checkout-lambda` > **Delete log group**.

4. **Empty and delete the source S3 bucket:**
   - S3 > `acme-pipeline-src-<yourinitials>` > **Empty** (type "permanently delete") > **Delete**.

5. **Empty and delete the artifact bucket:**
   - S3 > find the auto-created bucket named like `codepipeline-us-west-2-xxxxxxxxxx` > **Empty** > **Delete**.

6. **Delete the SNS topic and subscription:**
   - SNS > **Subscriptions** > select your email subscription > **Delete**.
   - SNS > **Topics** > `acme-pipeline-approvals` > **Delete** > confirm.

7. **Delete IAM service roles (optional but tidy):**
   - IAM > **Roles** > delete `AWSCodePipelineServiceRole-us-west-2-acme-checkout-pipeline`.
   - IAM > **Roles** > delete `codebuild-acme-checkout-build-service-role`.

8. **(Challenge 2) Delete the EventBridge rule:**
   - EventBridge > **Rules** > `acme-nightly-build` > **Delete**.
   - Also delete the IAM role created for EventBridge to call CodePipeline.

---

## Key Takeaways

- **CodePipeline orchestrates; CodeBuild builds; CodeDeploy/Lambda deploys.** Know which service does what.
- **Pipeline → Stage → Action** is the core hierarchy. Stages run sequentially; actions within a stage can run in parallel.
- **S3 versioning is required** for the S3 source action — CodePipeline detects changes via new object versions, not file modification times.
- **Artifacts** are ZIPs passed between stages through an artifact store (S3 bucket). Stages never communicate directly.
- A **buildspec.yml** at the zip root is how CodeBuild knows what to do. Phases: install → pre_build → build → post_build.
- **Manual approval** pauses the pipeline indefinitely until a human approves or rejects — the primary human control gate.
- **Service roles** let CodePipeline and CodeBuild call AWS services on your behalf. Always scope them to specific ARNs, not `*`.
- **Pipeline V2** is billed per action execution minute. **V1** billed a flat monthly fee per active pipeline.
- **EventBridge** rules can trigger pipeline executions both on source changes (event-driven) and on a schedule (cron).
- For production deployments, consider **Lambda versions + aliases** with CodeDeploy for zero-downtime canary/linear traffic shifting.
