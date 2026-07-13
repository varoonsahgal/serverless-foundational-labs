# Exercise 08 — Orchestrating an Order Workflow with AWS Step Functions

## Estimated Duration

~45 minutes

## Scenario / Business Context

**Acme Retail** processes thousands of online orders every day. Right now, the logic that handles an order — checking that it is valid, charging the customer, and sending a confirmation — is buried inside one giant function that is hard to read, hard to change, and hard to debug. When something fails, nobody can tell *which* step failed.

Your job is to model the order process as a **visual workflow**: `validate order → decide → confirm order`. You will build this with **AWS Step Functions**, so the whole team can *see* the flow as a flowchart, watch each order move through it step by step, and know exactly where any order stopped.

## Learning Objectives

By the end of this exercise you will be able to:

- Explain what a Step Functions **state machine** is and how it differs from a single execution (one run).
- Choose between **Standard** and **Express** workflow types and justify the choice.
- Build a workflow visually in **Workflow Studio** using **Task**, **Choice**, **Pass**, **Succeed**, and **Fail** states.
- Read and understand **Amazon States Language (ASL)** — the JSON that defines a state machine.
- Invoke AWS Lambda functions as **Task** states and branch on their output with a **Choice** state.
- Run executions with sample input and trace the path through the visual graph.

## AWS Services Used

- **AWS Step Functions** (the workflow orchestrator)
- **AWS Lambda** (the functions each workflow step calls)
- **AWS Identity and Access Management (IAM)** (the execution role that lets the workflow invoke Lambda)
- **Amazon CloudWatch Logs** (auto-created log groups for the Lambda functions)

## Prerequisites

- An AWS account.
- An **IAM user** with permissions to use Step Functions, Lambda, and IAM. **Do not use the root user** — sign in as an IAM user (or an IAM Identity Center user) with administrative or equivalent permissions.
- Working in region **US East (N. Virginia) `us-east-1`**. Confirm the region selector in the top-right of the console reads **N. Virginia** before you start.
- **A Lambda function to call.** This lab is self-contained: Step 1 below walks you through creating two tiny **Python 3.12** Lambda functions. If you already built a Lambda function in **Lab 03**, you may reuse it, but the code here is written specifically for this workflow, so creating the two new ones is recommended.

> **AWS Mental Model:** Think of **Step Functions as a flowchart that coordinates other AWS services**. The **state machine** is the flowchart itself (the design). An **execution** is one trip through that flowchart for one specific order. The same state machine can have thousands of executions running at once — just like one recipe can be cooked many times.

---

## Step 1 — Create the two Lambda functions the workflow will call

A workflow step (a **Task** state) doesn't *do* the work itself — it *calls* something that does. Here that "something" is a Lambda function. We'll create two: one that validates an order, one that confirms it.

### 1a. Create `acme-validate-order`

1. In the console search bar, type **Lambda** and open the **Lambda** service.
2. Confirm the region (top-right) is **N. Virginia `us-east-1`**.
3. Click **Create function**.
4. Choose **Author from scratch**.
5. **Function name:** `acme-validate-order`
6. **Runtime:** **Python 3.12**.
7. **Architecture:** leave as **x86_64** (default).
8. Under **Change default execution role**, leave **Create a new role with basic Lambda permissions** selected.
   - **What this does:** AWS automatically creates an IAM role (named something like `acme-validate-order-role-xxxx`) that lets this function write logs to CloudWatch. You do **not** need to configure permissions yourself.
9. Click **Create function**.
10. Scroll to the **Code source** editor. Replace all the code in `lambda_function.py` with:

```python
import json

def lambda_handler(event, context):
    # 'event' is the JSON that Step Functions passes into this state.
    order_id = event.get("orderId", "unknown")
    amount = event.get("amount", 0)

    # Simple validation rule: an order is approved if the amount is
    # greater than 0 and less than or equal to 1000.
    approved = 0 < amount <= 1000

    print(f"Validating order {order_id} for amount {amount} -> approved={approved}")

    # Whatever we return becomes the OUTPUT of this Task state and the
    # INPUT to the next state in the workflow.
    return {
        "orderId": order_id,
        "amount": amount,
        "approved": approved
    }
```

11. Click **Deploy** (above the editor). Wait for **"Changes deployed."**

> **What Is Happening Behind the Scenes?** Step Functions passes JSON between states. Whatever JSON enters a Task state is handed to the Lambda function as its `event`. Whatever the function `return`s becomes that state's output, which becomes the *input* to the next state. Your workflow is essentially a pipeline of JSON transformations.

### 1b. Create `acme-confirm-order`

1. Go back to **Lambda** → **Create function** → **Author from scratch**.
2. **Function name:** `acme-confirm-order`
3. **Runtime:** **Python 3.12**.
4. Leave **Create a new role with basic Lambda permissions** selected.
5. Click **Create function**.
6. Replace the code with:

```python
import json

def lambda_handler(event, context):
    order_id = event.get("orderId", "unknown")
    amount = event.get("amount", 0)

    confirmation_number = f"ACME-{order_id}-CONFIRMED"
    print(f"Confirming order {order_id}, confirmation={confirmation_number}")

    return {
        "orderId": order_id,
        "amount": amount,
        "status": "CONFIRMED",
        "confirmationNumber": confirmation_number
    }
```

7. Click **Deploy** and wait for **"Changes deployed."**

**Validation for Step 1:** In each function, click **Test**, create a test event named `t1` with the body `{"orderId": "1001", "amount": 250}`, and click **Test**. You should see **Execution result: succeeded** and, in the response, `"approved": true` for the validate function and `"status": "CONFIRMED"` for the confirm function.

> **Common Beginner Mistake:** Confusing a **workflow step (state)** with the **Lambda function it calls**. They are two different things. The *state* is a box in the flowchart named, say, "Validate Order." The *Lambda function* is the code that box invokes (`acme-validate-order`). One state calls one resource; renaming the box does not rename the function, and vice versa.

---

## Step 2 — Create the state machine

1. In the console search bar, type **Step Functions** and open it.
2. Confirm the region is **N. Virginia `us-east-1`**.
3. In the left menu, click **State machines**, then **Create state machine**.
4. On the template screen, choose **Blank**, then click **Select**. This opens **Workflow Studio** in **Design** mode.

### Choosing the workflow type

At this point (or in the top toolbar of Workflow Studio under **Config**), the **Type** is set to **Standard**. Leave it as **Standard**.

> **AWS Mental Model — Standard vs Express:**
> - **Standard** workflows are for long-running, auditable processes. They can run up to **1 year**, guarantee **exactly-once** execution of each step, and keep a **full visual execution history** you can inspect afterward. Billed **per state transition**. This is what order fulfillment wants.
> - **Express** workflows are for **high-volume, short-duration** event processing (up to 5 minutes). They are billed on number of executions and duration, and do **not** keep the same detailed visual history. Great for streaming/ingest, not for a workflow you want to audit order-by-order.
>
> For an order workflow that we want to *see* and *audit*, **Standard** is the right choice.

---

## Step 3 — Build the workflow in Workflow Studio

Workflow Studio has a **states palette** on the left, a **canvas** in the middle, and an **Inspector** panel on the right.

### 3a. Add the "Validate Order" Task state

1. From the **Actions** tab of the palette (left), find **AWS Lambda Invoke** and drag it onto the canvas, dropping it just below the **Start** marker.
2. With the new state selected, look at the **Inspector** (right panel), **Configuration** tab:
   - **State name:** change it to `Validate Order`.
   - **Function name:** select **`acme-validate-order`** from the dropdown (it lists functions in this region).
   - Leave **Payload** set to **Use state input as payload** (default). This passes the incoming JSON straight into the Lambda.
   - Under **Output**, check **Transform result with ResultSelector**? Leave it off for now, but expand **Output** and note there's an option to filter output. Leave defaults.

> **What this does / Why it matters:** The **AWS Lambda Invoke** Task calls your function synchronously and waits for the result. Because we pass state input as the payload, the order JSON flows straight into `acme-validate-order`, and the function's returned JSON (which includes `"approved"`) becomes this state's output — exactly what the next step needs to make a decision.

### 3b. Add the "Approved?" Choice state

1. From the palette **Flow** tab, drag a **Choice** state and drop it *below* **Validate Order**.
2. Select the Choice state and rename it (Inspector → **State name**) to `Approved?`.
3. In the Inspector, under **Choice Rules**, you'll see **Rule #1**. Click **Edit** (the pencil) on Rule #1, then **Add conditions**.
4. Configure the condition:
   - **Variable:** `$.approved`  (the `$` means "the current state input"; `$.approved` reads the `approved` field the validate step produced).
   - **Operator:** **is equal to** → **Boolean constant**.
   - **Value:** **true**.
5. Click **Save conditions**. This rule means: *if `approved` is true, go down this branch.*
6. Note the **Default** (else) branch — anything not matching Rule #1 falls through here. We'll wire both branches next.

> **Why This Matters:** A **Choice** state is how a workflow makes decisions. Without it, every execution would run in a straight line. The Choice state reads a field from the JSON flowing through it and picks a path — this is the "if/else" of your flowchart.

### 3c. Add the "Confirm Order" Task on the approved (true) branch

1. From the palette **Actions** tab, drag another **AWS Lambda Invoke** and drop it onto the **Rule #1** branch (the "true" path coming out of the Choice state).
2. Rename this state to `Confirm Order`.
3. **Function name:** select **`acme-confirm-order`**.
4. Leave payload as **Use state input as payload**.

### 3d. Add a Succeed state after Confirm Order

1. From the **Flow** tab, drag a **Succeed** state and drop it *after* **Confirm Order**.
2. Rename it to `Order Complete`.
   - **What this does:** A **Succeed** state ends the execution successfully. It's the "happy path" finish line.

### 3e. Add a Fail state on the not-approved (default) branch

1. From the **Flow** tab, drag a **Fail** state and drop it onto the **Default** branch of the `Approved?` Choice state.
2. Rename it to `Order Rejected`.
3. In the Inspector for this Fail state:
   - **Error:** `OrderRejected`
   - **Cause:** `Order failed validation (amount out of allowed range).`
   - **What this does:** A **Fail** state ends the execution with a failure status and an error/cause you define. This clearly marks rejected orders as failed, which is exactly what you want for auditing.

> **State types you just used:**
> - **Task** — does work by calling a service (here, Lambda). Has `Resource` and `Next`/`End`.
> - **Choice** — branches based on the JSON. Has `Choices` (rules) and a `Default`.
> - **Succeed** — ends the run successfully.
> - **Fail** — ends the run with an error.
> - *(A **Pass** state, not used here, simply passes input through or injects fixed JSON — handy for placeholders and testing.)*

---

## Step 4 — Review the generated Amazon States Language (ASL)

**ASL (Amazon States Language)** is the JSON that defines your state machine. Workflow Studio generates it for you as you drag boxes around.

1. In Workflow Studio, click the **{} Code** button (top toolbar) to switch from **Design** to the code view.
2. You should see JSON very close to this (state names must match what you typed). This is valid ASL:

```json
{
  "Comment": "Acme Retail order workflow: validate -> decide -> confirm",
  "StartAt": "Validate Order",
  "States": {
    "Validate Order": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "acme-validate-order",
        "Payload.$": "$"
      },
      "ResultSelector": {
        "orderId.$": "$.Payload.orderId",
        "amount.$": "$.Payload.amount",
        "approved.$": "$.Payload.approved"
      },
      "Next": "Approved?"
    },
    "Approved?": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.approved",
          "BooleanEquals": true,
          "Next": "Confirm Order"
        }
      ],
      "Default": "Order Rejected"
    },
    "Confirm Order": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "acme-confirm-order",
        "Payload.$": "$"
      },
      "ResultSelector": {
        "orderId.$": "$.Payload.orderId",
        "status.$": "$.Payload.status",
        "confirmationNumber.$": "$.Payload.confirmationNumber"
      },
      "Next": "Order Complete"
    },
    "Order Complete": {
      "Type": "Succeed"
    },
    "Order Rejected": {
      "Type": "Fail",
      "Error": "OrderRejected",
      "Cause": "Order failed validation (amount out of allowed range)."
    }
  }
}
```

> **Note:** If your generated JSON does not include the `ResultSelector` blocks, that's fine — the default `lambda:invoke` output wraps the function's return value under a `Payload` key. The `ResultSelector` above "unwraps" it so the `Choice` state can read `$.approved` directly. If you *don't* use `ResultSelector`, your Choice `Variable` would instead be `$.Payload.approved`. To keep things simple, **paste the JSON above** over the generated code so the rest of the lab matches exactly, then click **Design** to confirm the graph still renders correctly.

**Understanding the top-level ASL fields:**

- **`Comment`** — a human-readable description. Optional but good practice.
- **`StartAt`** — the name of the first state to run. Must match a key in `States`.
- **`States`** — an object whose keys are state names and whose values describe each state.

**Understanding per-state fields:**

- **`Type`** — the kind of state (`Task`, `Choice`, `Pass`, `Succeed`, `Fail`, etc.).
- **`Resource`** — for a Task, *what* it calls (here, the special ARN `arn:aws:states:::lambda:invoke`).
- **`Next`** — the name of the state to run after this one.
- **`End`** — set to `true` on a state that terminates the flow (Succeed/Fail don't need it; they inherently end).
- **`Choices`** — for a Choice state, the list of rules; each rule has a comparison and a `Next`.

---

## Step 5 — Name the state machine and let the console create the execution role

1. Click **Create** (top-right of Workflow Studio). A configuration dialog appears (or a **Review and create** step).
2. **State machine name:** `acme-order-workflow`.
3. **Type:** confirm **Standard**.
4. **Permissions:** choose **Create new role**. The console inspects your workflow and generates an IAM execution role that grants exactly the permissions the workflow needs — here, `lambda:InvokeFunction` on your two functions.
5. Leave logging/tracing at defaults (off is fine for this lab).
6. Click **Create** (and **Confirm** if prompted about the new IAM role).

> **Security Consideration:** A state machine runs *as* its **execution role**, not as you. For a Task state to call Lambda, that role **must** include `lambda:invoke` permission (specifically `lambda:InvokeFunction`) on the target functions. When you pick **Create new role**, the console scopes this automatically — least privilege. If you later add a new Lambda Task and reuse an old role, you may get an **`AccessDeniedException`** because the role wasn't granted permission to invoke the *new* function.

> **Common Beginner Mistake:** Forgetting that the **execution role needs invoke permission**. Symptom: the execution fails at the Task state with `Lambda.AccessDenied` / `States.TaskFailed`. Fix: add `lambda:InvokeFunction` for that function to the state machine's execution role.

---

## Step 6 — Run the workflow (approved path)

1. On the `acme-order-workflow` detail page, click **Start execution**.
2. In the **Input** box, paste a valid order that should be approved:

```json
{
  "orderId": "1001",
  "amount": 250
}
```

3. Leave the execution **Name** blank (an ID is auto-generated). Click **Start execution**.
4. Watch the **Graph view**. The path should light up: **Validate Order → Approved? → Confirm Order → Order Complete**. Each executed state turns green.

**Validation (approved path):**

- **Execution status:** **Succeeded** (green banner at top).
- The **graph** highlights the `Confirm Order` branch (not `Order Rejected`).
- Click the **Confirm Order** state, then the **Output** tab in the details pane. You should see JSON like:

```json
{
  "orderId": "1001",
  "status": "CONFIRMED",
  "confirmationNumber": "ACME-1001-CONFIRMED"
}
```

- Click **Validate Order** → **Input** and **Output** tabs to see the JSON flowing in and out (`"approved": true`).

---

## Step 7 — Run the workflow (rejected path)

1. Click **Start execution** again.
2. Use an amount that fails validation (over 1000):

```json
{
  "orderId": "1002",
  "amount": 5000
}
```

3. Click **Start execution** and watch the graph.

**Validation (rejected path):**

- **Execution status:** **Failed**.
- The **graph** highlights **Validate Order → Approved? → Order Rejected** (the default branch). `Confirm Order` is **not** executed.
- Click the **Order Rejected** state → the error is `OrderRejected` with your cause message.
- This is the *expected* outcome — the workflow correctly routed an invalid order to the Fail state. In a real system you'd route this to a "notify customer" step instead of failing.

> **Assessment Connection:** This validate → decide → confirm pattern is the backbone of **order fulfillment orchestration**. In an assessment you may be asked to identify which **state type** performs branching (Choice), how data moves between steps (JSON input/output), and why you'd choose **Standard** over **Express** for an auditable business process. You just built and observed all three.

---

## Key Takeaways

- **Step Functions is a flowchart for coordinating services.** The **state machine** is the design; an **execution** is one run through it.
- **Standard vs Express:** Standard = long-running, exactly-once, full visual history, billed per transition (use for auditable business workflows). Express = high-volume, short, cheaper at scale, less history.
- The core state types: **Task** (do work / call a service), **Choice** (branch on JSON), **Pass** (pass through / inject data), **Succeed** and **Fail** (end the run).
- **ASL** is just JSON with `StartAt` and a `States` map; each state has a `Type` and usually a `Next` or `End`.
- Data flows between states as **JSON input/output** — a state's output is the next state's input.
- A **workflow step (state)** is *not* the **Lambda function** it calls — keep the two concepts separate.
- The **execution role** must have permission to invoke every Lambda the workflow calls.

> **Cost Awareness:** Standard workflows are billed **per state transition**. This lab runs only a handful of transitions, so the cost is effectively pennies (and often within the free tier). Lambda invocations here are tiny too. Still, **delete everything when done** (see Cleanup) so nothing lingers.

---

## Cleanup Instructions

Delete resources in this order to avoid leaving anything behind.

1. **State machine:**
   - **Step Functions** → **State machines** → select **`acme-order-workflow`** → **Delete** → confirm. (Executions are deleted with it.)
2. **Step Functions execution role:**
   - **IAM** → **Roles** → search for the role the console created (name usually starts with `StepFunctions-acme-order-workflow-role-` or `service-role/StepFunctions...`).
   - Select it → **Delete** → confirm.
3. **Lambda functions:**
   - **Lambda** → select **`acme-validate-order`** → **Actions** → **Delete** → confirm.
   - Repeat for **`acme-confirm-order`**.
4. **Lambda auto-created execution roles:**
   - **IAM** → **Roles** → search `acme-validate-order-role` and `acme-confirm-order-role` → **Delete** each.
5. **CloudWatch log groups (from the Lambda functions):**
   - **CloudWatch** → **Log groups** → delete **`/aws/lambda/acme-validate-order`** and **`/aws/lambda/acme-confirm-order`**.

After cleanup, confirm the Step Functions **State machines** list is empty of `acme-*` entries and the Lambda **Functions** list has no `acme-validate-order`/`acme-confirm-order`.

---

## Early-Finisher Challenge

Real orders don't just get rejected cleanly — sometimes the validation code itself *crashes* (a bug, a bad input, a downstream timeout). Right now, if `acme-validate-order` throws an exception, your whole execution fails abruptly with a raw `States.TaskFailed`, and nobody handles it gracefully.

**Challenge:** Add **error handling** to the `Validate Order` Task state so that if the Lambda *throws an exception* (as opposed to returning `approved: false`), the workflow **catches** the error and routes to a friendly `Handle Error` state instead of crashing. Then trigger the catch path and prove it worked.

---

## Challenge Solution

### Step 1 — Make the validate function able to fail on demand

1. **Lambda** → open **`acme-validate-order`** → **Code**. Replace the code with a version that raises when the order is flagged:

```python
import json

def lambda_handler(event, context):
    order_id = event.get("orderId", "unknown")
    amount = event.get("amount", 0)

    # Simulate an unexpected crash for testing the Catch path.
    if event.get("forceError") is True:
        raise Exception("Simulated validation system failure")

    approved = 0 < amount <= 1000
    print(f"Validating order {order_id} for amount {amount} -> approved={approved}")

    return {
        "orderId": order_id,
        "amount": amount,
        "approved": approved
    }
```

2. Click **Deploy**.

### Step 2 — Add a Catch in Workflow Studio

1. **Step Functions** → **State machines** → **`acme-order-workflow`** → **Edit**.
2. In **Design** mode, select the **Validate Order** state.
3. In the Inspector (right), open the **Error handling** tab (or scroll to the **Error handling** section).
4. Under **Catch errors**, click **Add catcher**:
   - **Errors:** enter `States.ALL` (catches every error type).
   - **Fallback state:** we'll create a new one — first add the target state, then point the catcher at it. From the **Flow** palette, drag a **Pass** state onto the canvas and rename it `Handle Error`. (A Pass state is a clean, cheap place to land; in production you'd swap it for a "notify ops" Task.)
   - Set the catcher's **Fallback state** dropdown to **`Handle Error`**.
   - Optionally set **ResultPath** to `$.error` so the error details are attached to the output.
5. Give `Handle Error` a `Next` of `Order Rejected` (or add its own **Succeed**/**Fail**). For clarity, wire `Handle Error` → the existing **`Order Rejected`** Fail state.

### Step 3 — The resulting ASL snippet

Your `Validate Order` state now includes a `Catch` block, and there's a new `Handle Error` Pass state:

```json
"Validate Order": {
  "Type": "Task",
  "Resource": "arn:aws:states:::lambda:invoke",
  "Parameters": {
    "FunctionName": "acme-validate-order",
    "Payload.$": "$"
  },
  "ResultSelector": {
    "orderId.$": "$.Payload.orderId",
    "amount.$": "$.Payload.amount",
    "approved.$": "$.Payload.approved"
  },
  "Catch": [
    {
      "ErrorEquals": ["States.ALL"],
      "ResultPath": "$.error",
      "Next": "Handle Error"
    }
  ],
  "Next": "Approved?"
},
"Handle Error": {
  "Type": "Pass",
  "Comment": "Gracefully handle a crashed validation step.",
  "Next": "Order Rejected"
}
```

**Optional — add a Retry instead of/alongside Catch.** A `Retry` re-attempts the Task before giving up, which is ideal for *transient* failures (timeouts, throttling):

```json
"Retry": [
  {
    "ErrorEquals": ["States.TaskFailed"],
    "IntervalSeconds": 2,
    "MaxAttempts": 2,
    "BackoffRate": 2.0
  }
]
```

Place the `"Retry"` array inside the `Validate Order` state alongside `"Catch"`. Step Functions applies **Retry first**; only after retries are exhausted does the **Catch** fire.

6. Click **Save**, then **Create/Confirm** the role update if prompted.

### Step 4 — Trigger and validate the catch path

1. **Start execution** with an input that forces the crash:

```json
{
  "orderId": "1003",
  "amount": 250,
  "forceError": true
}
```

2. Watch the graph. Expected path: **Validate Order** (throws) → **Handle Error** → **Order Rejected**.

**Validation:**

- The execution does **not** stop with a raw `States.TaskFailed` at `Validate Order`. Instead the graph shows the **`Handle Error`** state executed (proving the catcher fired).
- Click **Handle Error** → **Input** and you'll see the error attached under `$.error` (with `Error` and `Cause` from the Lambda exception).
- With the `Retry` added, the execution history (**Events** table) shows the Task being **retried** the configured number of times before the Catch routed to `Handle Error`.

### Step 5 — Cleanup for the challenge

No new *services* were added — only states inside the existing state machine and edited Lambda code. The main **Cleanup Instructions** above remove everything (state machine, Lambda functions, roles, log groups). Just run those and you're done.
