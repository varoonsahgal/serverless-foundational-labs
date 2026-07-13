# Lab 03: Lambda Order Processor — Serverless Compute, Validation, and Observability

## Estimated Duration

**~90 minutes**

## Scenario / Business Context

**Acme Retail's** order management system is getting more complex. The simple "does the order have items and a positive total?" check from the original prototype isn't enough anymore. The platform team has a list of requirements:

- Validate that the order has at most **20 items** (warehouse capacity constraint)
- Validate that each `productId` follows the naming convention (`ELEC-xxx`, `HOME-xxx`, or `APRL-xxx`)
- Validate that the order total is within a **configurable price range** (min and max set via environment variables — different for retail vs. wholesale customers)
- Reject orders with a **negative total** with a specific error code
- Log enough detail that the support team can debug any rejected order from CloudWatch alone
- Keep the function's configuration (store name, tax rate, limits) out of the code — so the same code runs for different store configurations

Additionally, the architecture team wants to understand the broader Lambda ecosystem: **Dead Letter Queues** for failed async invocations, **Lambda Layers** for shared dependencies, **versions and aliases** for safe deployments, and **concurrency controls** for cost management.

By the end of this lab, you'll have a production-realistic Lambda function with comprehensive observability.

## Learning Objectives

By the end of this lab you will be able to:

- Create a Lambda function with `python3.12` runtime.
- Write a handler with multiple validation rules and structured logging.
- Configure **multiple environment variables** and explain their purpose.
- Run multiple **test events** covering all validation paths (happy path + all error cases).
- Read and interpret **CloudWatch Logs** including `START`, `END`, and `REPORT` log lines.
- Run a **CloudWatch Logs Insights** query to analyze Lambda behavior across multiple invocations.
- Explain the Lambda **execution model**: execution environments, cold starts, and warm reuse.
- Explain the **Dead Letter Queue (DLQ)** concept and why it matters for asynchronous invocations.
- Explain **Lambda Layers** — what they are, what problem they solve, and when to use them.
- Explain **Lambda versions and aliases** — how they enable safe deployments and traffic shifting.
- Explain **reserved concurrency** vs. **provisioned concurrency** and the trade-offs of each.
- Correctly identify timeout, memory, and handler settings under **Configuration → General configuration**.
- Clean up the function, its logs, and its execution role.

## AWS Services Used

| Service | Purpose | Cost |
|---------|---------|------|
| **AWS Lambda** | Serverless compute | Free tier: 1M requests/month, 400,000 GB-seconds/month |
| **Amazon CloudWatch Logs** | Automatic log capture | ~$0 for this lab volume |
| **AWS IAM** | Execution role | Free |

## Prerequisites

- An AWS account, signed in as an **IAM user** — not the root user.
- Your console Region is **US West (Oregon) — us-west-2**. Confirm this in the Region menu top-right.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    LAMBDA FUNCTION                              │
│                                                                 │
│  acme-order-processor (Python 3.12)                            │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │  ENVIRONMENT VARIABLES                              │       │
│  │  STORE_NAME       = AcmeRetail                     │       │
│  │  TAX_RATE         = 0.09                           │       │
│  │  MAX_ITEMS        = 20                             │       │
│  │  MIN_ORDER_TOTAL  = 5.00                           │       │
│  │  MAX_ORDER_TOTAL  = 10000.00                       │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │  EXECUTION ROLE: AcmeLambdaBasicExecutionRole       │       │
│  │  └─ Permissions: logs:* on CloudWatch               │       │
│  └─────────────────────────────────────────────────────┘       │
└───────────────────────┬──────────────────────────────────────────┘
                        │ writes logs
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│          CloudWatch Logs                                        │
│          /aws/lambda/acme-order-processor                       │
│          └─ Log streams (one per execution environment)         │
└─────────────────────────────────────────────────────────────────┘
```

---

## Step-by-Step Instructions

### Step 1 — Create the Lambda Function

1. Sign in to the AWS Management Console. Confirm the Region is **US West (Oregon) us-west-2**.
2. In the top search bar, type `Lambda` and open the **Lambda** service.
3. Click **Create function**.
4. Choose **Author from scratch**.
5. Fill in the basic information:
   - **Function name:** `acme-order-processor`
   - **Runtime:** **Python 3.12**
   - **Architecture:** `x86_64` (default)
6. Expand **Change default execution role** and select **Create a new role with basic Lambda permissions**.

   > **Why a new role?** The "basic Lambda permissions" option creates an IAM role that grants exactly one capability: writing logs to CloudWatch Logs. The role name will be something like `acme-order-processor-role-xxxxxxxx` with a random suffix. This is the **principle of least privilege** in action — the function gets only what it needs to do its job.

7. Click **Create function**. You land on the function's configuration page.

> **AWS Mental Model — What a Lambda function IS:**
> A Lambda function is three separate, independent things bundled together:
> - **Code** — your handler file(s), written in Python 3.12 in this case
> - **Configuration** — runtime, memory, timeout, environment variables, execution role
> - **Role** — the IAM execution role that defines what the function can do in AWS
>
> Keep these three distinct in your mental model. A code bug is in the first. A "function can't write to DynamoDB" problem is in the third. A timeout error is in the second. Diagnosing Lambda problems correctly starts with knowing which of these three you're looking at.

> **Security Consideration — the execution role:**
> The execution role is an IAM role that Lambda *assumes* when your code runs. It defines what AWS services and resources your function is allowed to call. The "basic Lambda permissions" role created here allows only `logs:CreateLogGroup`, `logs:CreateLogStream`, and `logs:PutLogEvents`. Nothing else. If you later want your function to read from DynamoDB, you must explicitly add that permission to the role — it will not just work because you wrote code that calls DynamoDB.

---

### Step 2 — Add the Handler Code

1. Click the **Code** tab at the top of the function page. In the file explorer on the left, click `lambda_function.py` to open it in the code editor.
2. Select **all** existing code and replace it with the following:

```python
import os
import json
import re
import logging

# Use structured logging at the module level so it's reused across warm starts.
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Valid product ID patterns for Acme Retail.
VALID_PRODUCT_PREFIXES = ("ELEC-", "HOME-", "APRL-")


def validate_product_ids(items):
    """Return a list of invalid product IDs, or empty list if all are valid."""
    invalid = []
    for item in items:
        if not isinstance(item, str):
            invalid.append(str(item))
            continue
        if not any(item.upper().startswith(prefix) for prefix in VALID_PRODUCT_PREFIXES):
            invalid.append(item)
    return invalid


def lambda_handler(event, context):
    # Read configuration from environment variables with safe defaults.
    store_name = os.environ.get("STORE_NAME", "AcmeRetail")
    tax_rate = float(os.environ.get("TAX_RATE", "0.09"))
    max_items = int(os.environ.get("MAX_ITEMS", "20"))
    min_order_total = float(os.environ.get("MIN_ORDER_TOTAL", "5.00"))
    max_order_total = float(os.environ.get("MAX_ORDER_TOTAL", "10000.00"))

    order_id = event.get("orderId", "UNKNOWN")
    items = event.get("items", [])
    total = event.get("total", None)
    customer_id = event.get("customerId", "GUEST")

    logger.info(
        "Processing order",
        extra={
            "orderId": order_id,
            "customerId": customer_id,
            "itemCount": len(items),
            "total": total
        }
    )

    # --- Validation 1: Items must be a non-empty list ---
    if not items or not isinstance(items, list):
        logger.warning("Order rejected: no items provided", extra={"orderId": order_id})
        return _reject(order_id, 400, "ORDER_EMPTY", "Order must contain at least one item.")

    # --- Validation 2: Item count must not exceed warehouse limit ---
    if len(items) > max_items:
        logger.warning(
            "Order rejected: too many items",
            extra={"orderId": order_id, "itemCount": len(items), "maxItems": max_items}
        )
        return _reject(
            order_id, 400, "TOO_MANY_ITEMS",
            f"Order exceeds maximum of {max_items} items. Got {len(items)}."
        )

    # --- Validation 3: Product IDs must follow naming convention ---
    invalid_ids = validate_product_ids(items)
    if invalid_ids:
        logger.warning(
            "Order rejected: invalid product IDs",
            extra={"orderId": order_id, "invalidIds": invalid_ids}
        )
        return _reject(
            order_id, 400, "INVALID_PRODUCT_IDS",
            f"The following product IDs are not recognized: {invalid_ids}. "
            f"Valid prefixes: ELEC-, HOME-, APRL-"
        )

    # --- Validation 4: Total must be a number ---
    if total is None or not isinstance(total, (int, float)):
        logger.warning("Order rejected: total is missing or non-numeric", extra={"orderId": order_id})
        return _reject(order_id, 400, "INVALID_TOTAL", "Order total must be a numeric value.")

    # --- Validation 5: Total must be positive ---
    if total <= 0:
        logger.warning("Order rejected: total is not positive", extra={"orderId": order_id, "total": total})
        return _reject(order_id, 400, "NEGATIVE_TOTAL", f"Order total must be greater than zero. Got {total}.")

    # --- Validation 6: Total must meet minimum order value ---
    if total < min_order_total:
        logger.warning(
            "Order rejected: below minimum",
            extra={"orderId": order_id, "total": total, "minTotal": min_order_total}
        )
        return _reject(
            order_id, 400, "BELOW_MINIMUM",
            f"Order total {total} is below the minimum order value of {min_order_total}."
        )

    # --- Validation 7: Total must not exceed maximum ---
    if total > max_order_total:
        logger.warning(
            "Order rejected: exceeds maximum",
            extra={"orderId": order_id, "total": total, "maxTotal": max_order_total}
        )
        return _reject(
            order_id, 400, "EXCEEDS_MAXIMUM",
            f"Order total {total} exceeds the maximum allowed order value of {max_order_total}."
        )

    # All validations passed — calculate tax and confirm.
    tax_amount = round(total * tax_rate, 2)
    total_with_tax = round(total + tax_amount, 2)

    logger.info(
        "Order confirmed",
        extra={
            "orderId": order_id,
            "customerId": customer_id,
            "itemCount": len(items),
            "subtotal": total,
            "taxAmount": tax_amount,
            "totalWithTax": total_with_tax
        }
    )

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": f"Order confirmed by {store_name}.",
            "orderId": order_id,
            "customerId": customer_id,
            "itemCount": len(items),
            "subtotal": total,
            "taxAmount": tax_amount,
            "totalWithTax": total_with_tax
        })
    }


def _reject(order_id, status_code, error_code, message):
    """Helper to build a consistent rejection response."""
    return {
        "statusCode": status_code,
        "body": json.dumps({
            "errorCode": error_code,
            "message": message,
            "orderId": order_id
        })
    }
```

3. Verify the **Handler** setting (under **Runtime settings**, below the editor) is `lambda_function.lambda_handler`.
4. Click **Deploy** to save and publish the code.

> **Common Beginner Mistake — Forgetting to click Deploy:**
> Editing the code in the browser does NOT deploy it. Until you click Deploy, every test runs the previous version. The code editor shows unsaved changes with a dot indicator — always Deploy before testing.

> **Common Beginner Mistake — Wrong handler name:**
> If you rename the function or file, the `Handler` setting must be updated to match. Lambda finds your entry point via `filename.function_name`. If these don't match, you get `Unable to import module 'lambda_function'` — a very common and confusing error.

> **What Is Happening Behind the Scenes?**
> When you deploy, Lambda packages your code (in this case, a single .py file) into a deployment package and stores it in S3. When the function is invoked, Lambda creates an **execution environment** — an isolated, ephemeral compute sandbox (a microVM). Your code is loaded into this environment and `lambda_handler` is called. The first call may be slightly slower while the environment starts (a **cold start**); subsequent calls that reuse the same environment are faster (**warm starts**). You never see or manage the underlying infrastructure.

---

### Step 3 — Configure Environment Variables

Environment variables decouple configuration from code. The same Python file can serve `AcmeRetail` with a 9% tax rate and a $10,000 max order, or `AcmeWholesale` with a 5% tax rate and a $100,000 max order — just by changing environment variables, with no code changes and no redeployment of the package.

1. Click the **Configuration** tab → **Environment variables** (left submenu).
2. Click **Edit** → **Add environment variable**.
3. Add all five variables:

   | Key | Value | Purpose |
   |-----|-------|---------|
   | `STORE_NAME` | `AcmeRetail` | Shown in confirmation messages |
   | `TAX_RATE` | `0.09` | 9% sales tax rate |
   | `MAX_ITEMS` | `20` | Maximum items per order |
   | `MIN_ORDER_TOTAL` | `5.00` | Minimum order value in dollars |
   | `MAX_ORDER_TOTAL` | `10000.00` | Maximum order value (anti-fraud) |

4. Click **Save**.

> **Security Consideration — what NOT to store in environment variables:**
> Environment variables in Lambda are encrypted at rest using AWS KMS. They are visible in the console and in CloudTrail logs to anyone with `lambda:GetFunctionConfiguration` permission. **Never store passwords, API keys, database connection strings, or other secrets in environment variables.** Use **AWS Secrets Manager** or **AWS Systems Manager Parameter Store** (SecureString) for secrets. Those services are covered in a later lab.

> **Why This Matters — The 12-Factor App Principle:**
> Separating configuration from code (Factor III of the [12-Factor App](https://12factor.net/)) means your code is environment-agnostic. You can deploy to dev, staging, and prod with different settings without touching the code. It also means configuration changes (e.g., updating the tax rate) don't require a code review — just update the environment variable.

---

### Step 4 — Test Seven Edge Cases

Create and run each test event. Save each with a descriptive name.

1. Click the **Test** tab.

#### Test 1 — Happy Path (valid order)

**Event name:** `validOrder`
```json
{
  "orderId": "O-1001",
  "customerId": "C-500",
  "items": ["ELEC-001", "HOME-001", "APRL-001"],
  "total": 1569.94
}
```
**Expected statusCode: 200** — includes tax calculation.

#### Test 2 — Empty Items List

**Event name:** `emptyItems`
```json
{
  "orderId": "O-1002",
  "customerId": "C-501",
  "items": [],
  "total": 0
}
```
**Expected statusCode: 400** — `errorCode: "ORDER_EMPTY"`

#### Test 3 — Too Many Items (over MAX_ITEMS = 20)

**Event name:** `tooManyItems`
```json
{
  "orderId": "O-1003",
  "customerId": "C-502",
  "items": [
    "ELEC-001","ELEC-002","ELEC-003",
    "HOME-001","HOME-002","HOME-003",
    "APRL-001","APRL-002","APRL-001",
    "ELEC-001","ELEC-002","ELEC-003",
    "HOME-001","HOME-002","HOME-003",
    "APRL-001","APRL-002","APRL-001",
    "ELEC-001","HOME-001","APRL-001"
  ],
  "total": 9999.00
}
```
(21 items — one over the limit)  
**Expected statusCode: 400** — `errorCode: "TOO_MANY_ITEMS"`

#### Test 4 — Invalid Product IDs

**Event name:** `invalidProductIds`
```json
{
  "orderId": "O-1004",
  "customerId": "C-503",
  "items": ["ELEC-001", "UNKNOWN-XYZ", "SHOE-999"],
  "total": 150.00
}
```
**Expected statusCode: 400** — `errorCode: "INVALID_PRODUCT_IDS"` with a list of invalid IDs.

#### Test 5 — Negative Total

**Event name:** `negativeTotal`
```json
{
  "orderId": "O-1005",
  "customerId": "C-504",
  "items": ["ELEC-001"],
  "total": -50.00
}
```
**Expected statusCode: 400** — `errorCode: "NEGATIVE_TOTAL"`

#### Test 6 — Below Minimum Order Value

**Event name:** `belowMinimum`
```json
{
  "orderId": "O-1006",
  "customerId": "C-505",
  "items": ["APRL-001"],
  "total": 2.50
}
```
**Expected statusCode: 400** — `errorCode: "BELOW_MINIMUM"` (below $5.00 minimum)

#### Test 7 — Missing Required Fields

**Event name:** `missingFields`
```json
{
  "orderId": "O-1007"
}
```
(No `items` or `total` at all)  
**Expected statusCode: 400** — `errorCode: "ORDER_EMPTY"` (no items list triggers the first validation)

After running all 7 tests, check the **Execution result** panel for each. Verify the `statusCode` and `errorCode` match the expected values above.

> **Validation checkpoint:** You should have:
> - 1 successful confirmation (Test 1)
> - 6 rejections with different error codes and messages (Tests 2–7)
> This proves every validation path in the function is exercised.

---

### Step 5 — View and Understand CloudWatch Logs

Every Lambda invocation writes structured log entries automatically.

1. Click the **Monitor** tab → **View CloudWatch logs**.
2. This opens the log group `/aws/lambda/acme-order-processor` in CloudWatch.
3. Click the **newest log stream** (the stream name is a UUID-like string).
4. Look at a few log entries. You'll see several types:

   **START line:**
   ```
   START RequestId: abc123-... Version: $LATEST
   ```
   Marks the beginning of a function invocation. `RequestId` is a unique identifier for this invocation — critical for correlating all log entries for the same call.

   **Your logger.info() lines** — for example, from the valid order:
   ```
   [INFO] Processing order {"orderId": "O-1001", "customerId": "C-500", "itemCount": 3, "total": 1569.94}
   [INFO] Order confirmed {"orderId": "O-1001", ...}
   ```

   **END line:**
   ```
   END RequestId: abc123-...
   ```

   **REPORT line:**
   ```
   REPORT RequestId: abc123-... Duration: 2.34 ms   Billed Duration: 3 ms   Memory Size: 128 MB   Max Memory Used: 45 MB   Init Duration: 189.45 ms
   ```

> **Reading the REPORT line:**
> - **Duration** — actual execution time in milliseconds
> - **Billed Duration** — rounded up to the nearest millisecond (minimum 1ms)
> - **Memory Size** — configured memory (128 MB default)
> - **Max Memory Used** — actual memory used by this invocation
> - **Init Duration** — only on cold starts — time to initialize the execution environment and load your code. This is the "cold start tax." On subsequent warm invocations, this line disappears.

> **What Is Happening Behind the Scenes?**
> Lambda writes these standard lines for every invocation. Your `logger.info()` calls are interspersed between them. The `RequestId` is the same value in `START`, `END`, `REPORT`, and any `logger` lines — this lets you grep for one RequestId and reconstruct the full execution of a single invocation even when many invocations are running in parallel.

---

### Step 6 — CloudWatch Logs Insights Queries

CloudWatch Logs Insights lets you query log data using a SQL-like syntax. This is how you analyze Lambda behavior across many invocations — for example, "how many orders were rejected in the last hour, and for which reasons?"

1. In the CloudWatch console, click **Logs Insights** in the left navigation (under **Logs**).
2. In the **Select log group(s)** dropdown, search for and select `/aws/lambda/acme-order-processor`.
3. Set the time range to **Last 30 minutes**.

#### Query 1 — Count invocations by outcome

```
fields @timestamp, @message
| filter @message like /Order/ 
| stats count(*) by bin(5m)
```

Click **Run query**. This shows how many log entries matching "Order" appeared in each 5-minute bucket.

#### Query 2 — Find all rejected orders and their error codes

```
fields @timestamp, @message
| filter @message like /Order rejected/
| sort @timestamp desc
| limit 20
```

This returns the most recent 20 rejection log lines, newest first.

#### Query 3 — Analyze cold starts (Init Duration)

```
filter @type = "REPORT"
| fields @requestId, @duration, @billedDuration, @memorySize, @maxMemoryUsed, @initDuration
| sort @initDuration desc
| limit 10
```

This finds the 10 invocations with the longest cold start times. Non-cold-start invocations have no `@initDuration` field and are excluded.

#### Query 4 — Average and max duration over time

```
filter @type = "REPORT"
| stats avg(@duration), max(@duration), min(@duration) by bin(1m)
```

Useful for identifying performance outliers — if max duration spikes while average stays low, you likely have occasional cold starts or resource contention.

> **Why This Matters:**
> In production, you won't manually look at individual log streams. CloudWatch Logs Insights lets you aggregate across thousands of invocations. "How many orders failed today?" "Which error code is most common?" "Are our cold starts increasing?" — these are Insights queries, not console scrolling.

> **Cost Awareness:** Logs Insights charges per GB of log data scanned. For this lab's tiny log volume, cost is negligible. In production, be thoughtful about query time ranges — scanning 30 days of logs for a high-volume function can incur meaningful cost.

---

### Step 7 — Review Timeout and Memory Settings

1. Click **Configuration** → **General configuration** → **Edit**.
2. Observe the defaults:
   - **Memory:** `128 MB` — memory allocated to the execution environment. More memory = more CPU proportionally.
   - **Timeout:** `3 seconds` — if your function takes longer than this, Lambda terminates it and logs a `Task timed out after 3.00 seconds` error.
   - **Ephemeral storage:** `512 MB` — the `/tmp` directory scratch space.
3. Change **Timeout** to `30` seconds, **Memory** to `256 MB` for this exercise (to handle more complex future scenarios).
4. Click **Save**.

> **AWS Mental Model — Memory vs. CPU in Lambda:**
> Lambda does not let you configure CPU directly. Instead, CPU power scales proportionally with memory. At 128 MB, you get 1/10th of a vCPU. At 1,792 MB, you get 1 full vCPU. At 3,584 MB, you get 2 vCPUs. This means CPU-intensive functions (heavy computation, image processing, ML inference) should use more memory even if they don't need the RAM — the extra CPU makes them significantly faster, and the total cost (billed duration × memory) often decreases.

> **Common Beginner Mistake:** Setting timeout too low for functions that call external services (other APIs, DynamoDB, S3). A slow downstream service can push your function past a 3-second timeout even though your code is fine. Always set timeout generously — Lambda only bills you for actual duration used.

---

### Step 8 — Dead Letter Queue (DLQ) — Concept and Setup

A **Dead Letter Queue** is a safety net for **asynchronous** Lambda invocations. When Lambda invokes a function synchronously (like our Test button), failures are returned directly to the caller. But when Lambda invokes functions **asynchronously** (from S3 events, SNS notifications, EventBridge rules), failures behave differently:

- Lambda **retries automatically** — it will retry a failed async invocation up to **2 additional times** (3 total attempts) with a delay between retries.
- If all retries are exhausted and the function still fails (with an exception, timeout, or OOM error), the event is **dropped** by default.
- Dropped events mean **silent data loss** — no alert, no recovery, no audit trail.

A **Dead Letter Queue** (an SQS queue or SNS topic) receives these permanently-failed events. Your operations team can then inspect what failed and re-process or alert on it.

#### View the DLQ configuration

1. Click **Configuration** → **Asynchronous invocation**.
2. Click **Edit**.
3. Notice:
   - **Maximum age of event:** how long Lambda keeps an unprocessed async event (up to 6 hours)
   - **Retry attempts:** 0, 1, or 2 (default is 2)
   - **Dead-letter queue service:** None (default) or an SQS/SNS destination

For this lab, we won't create an SQS queue, but understand the pattern:

```
Async caller (S3, SNS, EventBridge)
         │
         ▼
   Lambda function (attempt 1) ── fails
         │ auto-retry with backoff
         ▼
   Lambda function (attempt 2) ── fails
         │ auto-retry with backoff
         ▼
   Lambda function (attempt 3) ── fails
         │
         ▼
   Dead Letter Queue (SQS) ── ops team inspects and re-processes
```

4. Click **Cancel** — no changes needed here.

> **Why This Matters:** In production, every async Lambda integration should have a DLQ. Without it, you're flying blind — failed events disappear and you don't know until a customer complains that their order wasn't processed. With a DLQ, failed events are preserved, auditable, and re-drivable. This pattern becomes critical in the async eventing lab (SQS/SNS/EventBridge).

---

### Step 9 — Lambda Layers Overview

**Lambda Layers** are a mechanism for sharing code and dependencies across multiple Lambda functions without including them in every deployment package.

#### The problem Layers solve

Imagine Acme Retail has 15 Lambda functions that all:
- Use the same internal `acme-utils` library (order formatting, customer ID validation)
- Use a specific version of the `requests` library (not included in the Python runtime)
- Use the same data validation schemas

Without Layers, you'd include these dependencies in every function's deployment package. Result: 15 copies of the same library, each needing updating independently when a bug is fixed.

With Layers:
- You publish `acme-utils` and `requests` as a single Layer once
- Each function adds the Layer in its configuration
- When the library is updated, you publish a new Layer version and update the functions — one change propagates everywhere

#### Layer mechanics

- A Layer is a `.zip` file containing files (typically in a `python/` directory for Python runtimes).
- A function can reference up to **5 Layers**.
- Layers are versioned — you pin to a specific version (`arn:aws:lambda:us-west-2:123456789012:layer:acme-utils:3`).
- AWS provides managed Layers for common use cases (e.g., AWS SDK extensions, pandas/numpy for data science).
- Layers are extracted to `/opt/` in the execution environment.

#### Viewing Layers in the console

1. In the Lambda console, click **Layers** in the left navigation.
2. You'll see any existing Layers in your account. For this lab, you don't need to create one, but note the **Create layer** button and the versioning system.

> **When NOT to use Layers:** Layers add deployment complexity. For single-purpose functions with no shared dependencies, deploying everything in the function package is simpler. Use Layers when multiple functions share non-trivial dependencies that change independently of the function code.

---

### Step 10 — Lambda Versions and Aliases

#### Versions

Every time you **Deploy** in Lambda, you're updating `$LATEST` — the mutable, "work in progress" version. In production, you want **immutable snapshots** for safe rollbacks.

**Publishing a version** creates an immutable copy of the current code + configuration, tagged with a sequential number (v1, v2, v3...).

1. In your `acme-order-processor` function, click **Actions ▾** → **Publish new version**.
2. **Description:** `Initial production release — all validations active`
3. Click **Publish**.

You now have **Version 1** — an immutable snapshot. Changes to `$LATEST` don't affect v1.

#### Aliases

An **alias** is a named pointer to a specific version (or a weighted split between two versions). Instead of hardcoding version numbers in your API Gateway or event source configurations, you point them at an alias. When you want to promote a new version, you update the alias — your callers never change.

Common alias names: `live`, `prod`, `staging`, `current`

1. In your function, click the **Aliases** tab → **Create alias**.
2. **Name:** `live`
3. **Version:** `1` (the version you just published)
4. Click **Save**.

Now you can invoke the function at `arn:aws:lambda:us-west-2:123456789012:function:acme-order-processor:live` — this always runs v1, regardless of what `$LATEST` becomes.

#### Weighted aliases for canary deployments

Suppose you publish v2 with new validation logic. Rather than switching all traffic at once, you can do a **canary release**: route 10% of traffic to v2, 90% to v1.

1. Edit the `live` alias.
2. Under **Additional version**, add v2 with weight `10%` (and v1 remains at 90%).
3. Monitor CloudWatch for errors on v2.
4. If healthy, shift to 100% v2. If broken, shift back to 100% v1 instantly.

This pattern — zero downtime, gradual rollout, instant rollback — is why production systems use aliases.

> **Versions and Aliases — mental model summary:**
> Think of versions as **git commit SHAs** — immutable historical snapshots. Aliases are **git branch names** — named pointers that can move. `$LATEST` is like the `main` branch — always the newest, always mutable.

---

### Step 11 — Concurrency Concepts

**Concurrency** in Lambda is the number of instances of your function running simultaneously.

#### Reserved Concurrency

**Reserved concurrency** sets a hard ceiling on how many simultaneous instances of a specific function can run. It serves two purposes:

1. **Throttle** — Limit a function from consuming too many concurrent executions (and potentially crowding out other functions in the same account).
2. **Guarantee** — Reserve capacity for a function so other functions can't starve it.

To set reserved concurrency:
1. **Configuration** → **Concurrency** → **Edit** → **Reserve concurrency**.
2. Set a value (e.g., `10`). This means at most 10 simultaneous invocations.

> **Warning:** Setting reserved concurrency to `0` **completely throttles** the function — all invocations are rejected with a throttle error. This is useful for emergency shutoffs.

#### Provisioned Concurrency

**Provisioned concurrency** pre-warms a specified number of execution environments — they start initialized and ready, eliminating cold starts entirely.

The trade-off: you pay for provisioned concurrency even when the function isn't being invoked (unlike the standard pay-per-use model).

Use provisioned concurrency for:
- **Latency-sensitive APIs** where even occasional cold starts are unacceptable
- **Functions with heavy initialization** (loading ML models, parsing large config files)
- **Predictable traffic peaks** where you know demand is coming

> **Reserved vs. Provisioned Concurrency:**
>
> | | Reserved Concurrency | Provisioned Concurrency |
> |-|---------------------|------------------------|
> | **Purpose** | Throttle limit or capacity guarantee | Eliminate cold starts |
> | **Cost** | Free (no charge to reserve) | Pay per pre-warmed instance × time |
> | **Cold starts** | Doesn't help with cold starts | Eliminates them for pre-warmed instances |
> | **When to use** | Always set for production functions | Latency-sensitive or heavy-init functions |

For this lab, leave concurrency at defaults (unreserved).

---

## Key Takeaways

- A Lambda function = **code + configuration + execution role**. Diagnose problems by identifying which of the three is involved.
- The **execution role** grants the function permissions; a **resource-based policy** controls who can invoke the function.
- **Deploy** after every code edit. The Test button runs whatever was last deployed, not what's in the editor.
- **Environment variables** separate configuration from code — enabling the same code to run in multiple environments.
- **CloudWatch Logs** captures every invocation automatically. The `RequestId` in `START`, `END`, `REPORT`, and `logger` lines ties a single invocation together.
- **CloudWatch Logs Insights** lets you query log data across thousands of invocations with a SQL-like syntax.
- **Dead Letter Queues** are the safety net for failed async invocations — without one, failed events disappear silently.
- **Lambda Layers** share code and dependencies across multiple functions, avoiding duplication.
- **Versions** are immutable code + config snapshots; **aliases** are named pointers to versions. Together they enable safe canary deployments and instant rollbacks.
- **Reserved concurrency** throttles or guarantees capacity; **provisioned concurrency** eliminates cold starts at extra cost.

---

## Challenges

> Try each challenge yourself before looking at the solutions file.

---

### Challenge 1 — Add DynamoDB Product Validation

The order processor currently validates product ID **format** (must start with `ELEC-`, `HOME-`, or `APRL-`). But it doesn't check whether the product ID **actually exists** in the `AcmeProducts` DynamoDB table. A customer could order `ELEC-999` (non-existent product) and pass format validation.

**Your task:**

1. Update the IAM execution role for `acme-order-processor` to grant `dynamodb:GetItem` on the `AcmeProducts` table in `us-west-2` (use a specific resource ARN, not `*`).
2. Update the Lambda function code to call `dynamodb:GetItem` for each unique product ID in the order, and reject the order with `errorCode: "PRODUCT_NOT_FOUND"` if any product ID doesn't exist in the table.
3. Create a test event with a valid-format but non-existent product ID (e.g., `ELEC-999`) and verify the rejection.
4. Create a test event with a real product ID from the AcmeProducts table (if you still have it from Lab 02) and verify the order is confirmed.

**Hint:** Use `boto3.client('dynamodb')` to call `get_item`. The table uses a composite key: partition key `category` and sort key `productId`. You'll need to know the category to look up a product by ID — think about how you'd derive or store category information.

See `03-solutions.md` → Challenge 1 for the complete solution.

---

### Challenge 2 — CloudWatch Alarm on Order Rejection Rate

The engineering team wants an automated alert when more than 5 orders are rejected per 5-minute window. If the rejection rate suddenly spikes, it might indicate a bug in a front-end form sending invalid data to the API.

**Your task:**

1. Create a **custom CloudWatch metric** from Lambda. Modify the function code to publish a custom metric `OrderRejected` (count = 1) each time an order is rejected, using the `boto3` CloudWatch client and `put_metric_data`.
   - **Namespace:** `AcmeRetail/Orders`
   - **Metric name:** `OrderRejected`
   - **Dimensions:** `{"FunctionName": "acme-order-processor"}`
   - **Unit:** `Count`, **Value:** `1`
2. Update the execution role to grant `cloudwatch:PutMetricData` permission (scoped to the `AcmeRetail/Orders` namespace — note: CloudWatch `PutMetricData` doesn't support resource-level restrictions, so `"Resource": "*"` is required here).
3. Create a CloudWatch **Alarm** on the `OrderRejected` metric:
   - Threshold: more than 5 rejected orders in a 5-minute period
   - Action: send a notification to an SNS topic (you can create a simple SNS topic with your email for this)
4. Run your 6 rejection test events back-to-back and observe whether the alarm transitions to `In Alarm` state.

See `03-solutions.md` → Challenge 2 for the complete code changes, policy JSON, and alarm setup steps.

---

## Cleanup Instructions

Delete everything this lab created to avoid any lingering charges or clutter.

1. **Delete the Lambda function:**
   - Lambda console → **Functions** → select `acme-order-processor` → **Actions** → **Delete** → type `delete` → confirm.

2. **Delete the CloudWatch log group:**
   - CloudWatch → **Logs** → **Log groups** → select `/aws/lambda/acme-order-processor` → **Actions** → **Delete log group(s)** → confirm.
   - Note: deleting the function does **not** automatically delete its log group.

3. **Delete the execution role:**
   - IAM → **Roles** → search for `acme-order-processor-role-` → select the role → **Delete** → type the role name → confirm.

4. **If you published a version and created an alias:** These are deleted automatically when the function is deleted.

> **Cost Awareness:** Lambda functions cost nothing when idle (no invocations = no charges). The log group has a small storage cost for retained log data. Deleting both the function and log group ensures a completely clean account.
