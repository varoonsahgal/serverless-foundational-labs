# Exercise 03: Build an Order Processor with AWS Lambda

## Estimated Duration

~40 minutes

## Scenario / Business Context

**Acme Retail** is adding automated order handling to its online store. Before
an order is charged and shipped, it must be validated: it needs at least one
item and a total greater than zero. The team wants this logic to run without
managing any servers — it should just execute when an order arrives and cost
nothing when idle.

Your job is to build a small **AWS Lambda** function called
`acme-order-processor` that takes an order, validates it, and returns a
confirmation (or a rejection if the order is invalid). Lambda is AWS's
**serverless compute** service: you upload code, and AWS runs it on demand
without you provisioning or managing servers.

## Learning Objectives

By the end of this exercise you will be able to:

- Create a Lambda function from scratch and choose a supported runtime.
- Explain what a Lambda **execution role** is and how it differs from a
  **resource-based policy**.
- Write and deploy a Python handler that reads an event and returns a
  structured response.
- Invoke a function synchronously with a test event and read the results.
- Find and read a function's logs in **Amazon CloudWatch Logs**.
- Use **environment variables** to configure a function without changing code.
- Explain the default **timeout** and **memory** settings and where to change
  them.
- Clean up the function, its logs, and its auto-created role.

## AWS Services Used

- **AWS Lambda** — serverless compute that runs your code on demand.
- **Amazon CloudWatch Logs** — where Lambda automatically sends log output.
- **AWS IAM** (Identity and Access Management) — provides the **execution role**
  that grants the function permission to write logs.

## Prerequisites

- An AWS account you can sign in to.
- You are signed in as an **IAM user** (Identity and Access Management user),
  **not** the root user. Using an everyday IAM user instead of the all-powerful
  root user is an AWS security best practice.
- Your console Region is **US East (N. Virginia)** / **us-east-1** (check the
  Region menu in the top-right corner).

---

## Step-by-Step Instructions

### Step 1 — Create the function

1. Sign in to the AWS Management Console as your IAM user and confirm the Region
   is **N. Virginia (us-east-1)**.
2. In the top search bar, type `Lambda` and open the **Lambda** service.
3. Click **Create function**.
4. Choose **Author from scratch** (the option to build a brand-new function
   rather than use a blueprint or container image).
5. Fill in the basic information:
   - **Function name**:

     ```
     acme-order-processor
     ```

   - **Runtime**: select **Python 3.12**. (A runtime is the language and version
     AWS uses to run your code. Python 3.12 is a currently supported runtime.)
   - **Architecture**: leave the default (**x86_64**).
6. Expand **Change default execution role** (if collapsed) and keep the option
   **Create a new role with basic Lambda permissions** selected.

> **Security Consideration — the execution role**
> An **execution role** is an IAM role that Lambda *assumes* while your code
> runs. It defines what AWS actions your function is allowed to perform. The
> "basic Lambda permissions" option creates a role that can do exactly one
> thing: write logs to CloudWatch Logs. That is **least privilege** — the
> function gets only the permissions it needs and nothing more.

> **AWS Mental Model — execution role vs resource-based policy**
> - The **execution role** answers: *"What is my function allowed to do to
>   other AWS services?"* (e.g., write logs, read a DynamoDB table).
> - A **resource-based policy** answers the opposite: *"Who is allowed to invoke
>   my function?"* (e.g., letting API Gateway or an S3 bucket call it). We are
>   not adding one here because we will invoke the function ourselves via the
>   Test button.

7. Click **Create function**. After a few seconds you land on the function's
   configuration page with a **Code source** editor.

> **AWS Mental Model — what a function *is***
> A Lambda function is three things bundled together: **code** (your handler),
> **configuration** (runtime, memory, timeout, environment variables), and a
> **role** (its permissions). Keep those three ideas separate in your head and
> Lambda becomes much easier to reason about.

### Step 2 — Add the handler code

1. In the **Code source** panel, open the file `lambda_function.py` (it is open
   by default).
2. Select all existing code and replace it with the following. This is complete,
   valid Python 3.12.

   ```python
   import os
   import json


   def lambda_handler(event, context):
       store_name = os.environ.get("STORE_NAME", "AcmeRetail")

       order_id = event.get("orderId")
       items = event.get("items", [])
       total = event.get("total", 0)

       # Validate: must have at least one item and a positive total.
       if not items:
           return {
               "statusCode": 400,
               "body": json.dumps({
                   "message": "Order rejected: no items in the order.",
                   "orderId": order_id
               })
           }

       if not isinstance(total, (int, float)) or total <= 0:
           return {
               "statusCode": 400,
               "body": json.dumps({
                   "message": "Order rejected: total must be greater than zero.",
                   "orderId": order_id
               })
           }

       # Valid order -> build a confirmation.
       return {
           "statusCode": 200,
           "body": json.dumps({
               "message": f"Order confirmed by {store_name}.",
               "orderId": order_id,
               "itemCount": len(items),
               "total": total
           })
       }
   ```

3. Note the **Handler** setting (shown under **Runtime settings**, below the
   editor) is `lambda_function.lambda_handler`. This means: file
   `lambda_function.py`, function `lambda_handler`. It must match your file name
   and function name exactly.
4. Click **Deploy** (the button above the editor) to save and publish your code.

> **Common Beginner Mistake**
> Two mistakes trip up almost everyone:
> 1. **Forgetting to click Deploy.** Editing the code in the browser does *not*
>    activate it. Until you Deploy, tests run the old code.
> 2. **A wrong handler name.** If you rename the function or file, the
>    `Handler` value must change to match, or you get an error like
>    `Unable to import module 'lambda_function'` or
>    `Handler 'lambda_handler' missing`.

> **What Is Happening Behind the Scenes?**
> When you invoke the function, Lambda finds or creates an **execution
> environment** — a small, isolated, temporary compute sandbox — loads your
> code into it, and calls `lambda_handler(event, context)`. The first call may
> take slightly longer while the environment starts (a "cold start"); later
> calls reuse the warm environment and are faster. You never see or manage the
> underlying servers.

### Step 3 — Test a valid order (synchronous invocation)

1. Click the **Test** tab.
2. Select **Create new event**.
3. **Event name**:

   ```
   validOrder
   ```

4. Replace the event JSON with:

   ```json
   {
     "orderId": "O-1001",
     "items": ["Coffee Mug", "Water Bottle"],
     "total": 21.49
   }
   ```

5. Click **Save**, then click **Test**.
6. Read the green **Execution result: succeeded** panel. The response should be:

   ```json
   {
     "statusCode": 200,
     "body": "{\"message\": \"Order confirmed by AcmeRetail.\", \"orderId\": \"O-1001\", \"itemCount\": 2, \"total\": 21.49}"
   }
   ```

> **AWS Mental Model — synchronous vs asynchronous invocation**
> Clicking **Test** is a **synchronous** invocation: you send the event and wait
> for the function to finish and return a value right then. In an **asynchronous**
> invocation (for example, when an S3 upload event triggers the function) the
> caller does *not* wait for a return value — Lambda queues the event and runs it
> in the background. Same code; different way of calling it.

### Step 4 — Test an invalid order

1. Still on the **Test** tab, click **Create new event** again.
2. **Event name**:

   ```
   emptyOrder
   ```

3. Event JSON (note the empty `items` list):

   ```json
   {
     "orderId": "O-1002",
     "items": [],
     "total": 0
   }
   ```

4. Click **Save**, then **Test**. The response should be:

   ```json
   {
     "statusCode": 400,
     "body": "{\"message\": \"Order rejected: no items in the order.\", \"orderId\": \"O-1002\"}"
   }
   ```

> **Validation:** You now have proof both paths work — `validOrder` returns
> `statusCode 200` with a confirmation, and `emptyOrder` returns `statusCode
> 400` with a rejection.

### Step 5 — View the logs in CloudWatch

Every invocation writes log lines automatically.

1. Click the **Monitor** tab.
2. Click **View CloudWatch logs**. This opens the CloudWatch Logs **log group**
   named:

   ```
   /aws/lambda/acme-order-processor
   ```

3. Inside the log group, click the newest **log stream**. You will see entries
   such as `START RequestId: ...`, `END RequestId: ...`, and `REPORT ...` lines
   showing the duration and memory used for each invocation.

> **What Is Happening Behind the Scenes?**
> The **basic Lambda permissions** in your execution role are what allow the
> function to create this log group and write these streams. If you ever removed
> those permissions, the function would still run but produce no logs — a common
> "why can't I see my logs?" puzzle.

### Step 6 — Add an environment variable

Environment variables let you change a function's behavior **without editing
code** — useful for values that differ between environments (dev/test/prod).

1. Click the **Configuration** tab → **Environment variables** (left submenu).
2. Click **Edit** → **Add environment variable**.
3. Set:
   - **Key**:

     ```
     STORE_NAME
     ```

   - **Value**:

     ```
     AcmeRetail
     ```

4. Click **Save**.
5. Your code already reads it with
   `store_name = os.environ.get("STORE_NAME", "AcmeRetail")`. To prove the
   variable is being read, change the value to `AcmeRetail-East`, **Save**, then
   run the `validOrder` test again. The confirmation message now reads
   `Order confirmed by AcmeRetail-East.`

> **Why This Matters**
> Because the store name comes from an environment variable, you could deploy
> the same code for multiple stores or regions just by changing the variable —
> no code change, no redeploy of the code itself.

### Step 7 — Review timeout and memory

1. Go to **Configuration** → **General configuration** → **Edit**.
2. Observe the defaults:
   - **Memory**: **128 MB** (megabytes). More memory also proportionally
     increases CPU power.
   - **Timeout**: **3 seconds** (`0 min 3 sec`). If your code runs longer than
     the timeout, Lambda stops it and reports a timeout error.
3. You do **not** need to change these for this exercise. Click **Cancel** (or
   **Save** if you changed nothing) to leave them at their defaults.

> **AWS Mental Model**
> Right-sizing memory/timeout is part of a function's **configuration**, not its
> code. A too-low timeout kills legitimate work; excessive memory wastes money.
> Start small and raise only if logs show you need to.

> **Cost Awareness**
> Lambda bills on **two things**: the number of **requests** and the
> **duration × memory** of each run (measured in gigabyte-seconds). An idle
> function that no one invokes costs nothing. There is also a generous monthly
> free tier. Still, delete the function when finished so nothing lingers.

> **Assessment Connection**
> Exams love to ask where Lambda logs go (**CloudWatch Logs**, group
> `/aws/lambda/<function-name>`), what the execution role is for (permissions
> the function has), and the difference between synchronous and asynchronous
> invocation. You have now touched all three.

---

## Key Takeaways

- A Lambda function = **code + configuration + execution role**.
- The **execution role** grants the function permissions (here: write to
  CloudWatch Logs); a **resource-based policy** controls *who can invoke* the
  function.
- **Deploy** after every code edit, and keep the **handler** value
  (`lambda_function.lambda_handler`) matching your file and function names.
- **Test = synchronous** invocation; you get the return value immediately.
- Logs land in CloudWatch Logs at `/aws/lambda/acme-order-processor`.
- **Environment variables** configure behavior without code changes.
- Defaults are **128 MB memory** and **3 second timeout**, changeable under
  **Configuration → General configuration**.

---

## Cleanup Instructions

Delete everything this exercise created so nothing lingers.

1. **Delete the function**
   - Lambda console → **Functions** → select **acme-order-processor**.
   - **Actions** → **Delete** → type `delete` to confirm → **Delete**.

2. **Delete the CloudWatch log group**
   - Open the **CloudWatch** service → **Logs** → **Log groups**.
   - Select `/aws/lambda/acme-order-processor`.
   - **Actions** → **Delete log group(s)** → confirm.
   - (Deleting the function does **not** remove its logs automatically, so this
     step matters.)

3. **Delete the auto-created execution role**
   - Open the **IAM** service → **Roles**.
   - In the search box, type `acme-order-processor`. Find the role named
     something like `acme-order-processor-role-xxxxxxxx` (the suffix is random).
   - Select it → **Delete** → type the role name to confirm → **Delete**.

> **Cost Awareness**
> None of these resources cost anything while idle, but removing them keeps your
> account clean and avoids clutter for the next exercise.

---

## Early-Finisher Challenge

Add a spending guard. Introduce an environment variable **`MAX_ORDER_TOTAL`**
and update the function so that any order whose `total` exceeds that maximum is
rejected with `statusCode 400` and a clear message. Orders at or below the
maximum (and otherwise valid) should still return `statusCode 200`.

Try it yourself before reading the solution.

---

## Challenge Solution

### Full updated code

Replace the handler with this version (it adds the `MAX_ORDER_TOTAL` check and
keeps all previous behavior):

```python
import os
import json


def lambda_handler(event, context):
    store_name = os.environ.get("STORE_NAME", "AcmeRetail")
    max_order_total = float(os.environ.get("MAX_ORDER_TOTAL", "1000"))

    order_id = event.get("orderId")
    items = event.get("items", [])
    total = event.get("total", 0)

    # Validate: must have at least one item.
    if not items:
        return {
            "statusCode": 400,
            "body": json.dumps({
                "message": "Order rejected: no items in the order.",
                "orderId": order_id
            })
        }

    # Validate: total must be a positive number.
    if not isinstance(total, (int, float)) or total <= 0:
        return {
            "statusCode": 400,
            "body": json.dumps({
                "message": "Order rejected: total must be greater than zero.",
                "orderId": order_id
            })
        }

    # Validate: total must not exceed the configured maximum.
    if total > max_order_total:
        return {
            "statusCode": 400,
            "body": json.dumps({
                "message": f"Order rejected: total {total} exceeds max allowed {max_order_total}.",
                "orderId": order_id
            })
        }

    # Valid order -> build a confirmation.
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": f"Order confirmed by {store_name}.",
            "orderId": order_id,
            "itemCount": len(items),
            "total": total
        })
    }
```

### Steps to set the environment variable

1. Paste the code above into the editor and click **Deploy**.
2. **Configuration** → **Environment variables** → **Edit** → **Add environment
   variable**.
   - **Key**:

     ```
     MAX_ORDER_TOTAL
     ```

   - **Value**:

     ```
     100
     ```

3. Click **Save**.

### Test events proving accept and reject

**Accepted order** (`total` ≤ 100) — create/reuse a test event named
`underLimit`:

```json
{
  "orderId": "O-2001",
  "items": ["Desk Lamp"],
  "total": 90
}
```

Expected result — `statusCode 200`:

```json
{
  "statusCode": 200,
  "body": "{\"message\": \"Order confirmed by AcmeRetail.\", \"orderId\": \"O-2001\", \"itemCount\": 1, \"total\": 90}"
}
```

**Rejected order** (`total` > 100) — create a test event named `overLimit`:

```json
{
  "orderId": "O-2002",
  "items": ["Desk Lamp", "Coffee Mug"],
  "total": 250
}
```

Expected result — `statusCode 400`:

```json
{
  "statusCode": 400,
  "body": "{\"message\": \"Order rejected: total 250 exceeds max allowed 100.0, ... }"
}
```

(The exact `body` string reads: `Order rejected: total 250 exceeds max allowed
100.0.`)

### Why It Works

The function reads `MAX_ORDER_TOTAL` from the environment at runtime and
converts it to a number with `float(...)`. Because environment variables are
always **strings**, the `float()` conversion is required to compare it
numerically against `total`. The new check runs only after the "has items" and
"positive total" checks pass, so the rejection messages stay specific. Changing
the limit is now a **configuration change** (edit the variable) — no code edit
needed.

### Validation

- `underLimit` (total 90) returns `statusCode 200`.
- `overLimit` (total 250) returns `statusCode 400` with the "exceeds max
  allowed" message.
- Changing `MAX_ORDER_TOTAL` to `500` and re-running `overLimit` now returns
  `statusCode 200`, proving the behavior is driven by the variable, not the
  code.

### Cleanup

No extra resources were created for this challenge — the environment variable
lives inside the same function. Follow the main **Cleanup Instructions** above
(delete the function, its log group, and its execution role) and you are done.
