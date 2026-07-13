# Lab 01: IAM Deep Dive — Identities, Roles, and Least Privilege

## Estimated Duration

**~120 minutes**

## Scenario / Business Context

**Acme Retail** is scaling up. The company started with a single root user sharing credentials over Slack. Now there are four distinct teams who need different levels of AWS access:

- **Developers** — Need to read the product catalog in DynamoDB and deploy Lambda functions, but must never touch production databases directly.
- **Ops/SRE team** — Need to monitor everything (CloudWatch, S3 logs) but cannot modify application code.
- **Finance auditors** — Need read-only access to billing reports in S3 and DynamoDB order tables, but must use MFA before touching any sensitive data.
- **Application services** — Lambda functions and other services that need to call AWS APIs without any hardcoded passwords.

Your job as the new **cloud security engineer** is to build the entire identity foundation from scratch. By the end of this lab, every team has the right permissions — and the right guardrails — and not a single long-lived access key is embedded in any application code.

> **Why This Matters:** IAM is the single highest-leverage skill in AWS. Every Lambda function, every DynamoDB table, every S3 bucket, every Bedrock agent you build in the rest of this course will work or fail based on IAM. When a service "can't read the database," 90% of the time the answer is an IAM permission — not a code bug. Understanding IAM here saves you hours of debugging later.

## Learning Objectives

By the end of this lab you will be able to:

- Navigate the IAM console and explain the purpose of **Users**, **User groups**, **Roles**, **Policies**, and **Identity providers**.
- Distinguish **authentication** (who you are) from **authorization** (what you may do).
- Create a **customer managed policy** in both the visual editor and the JSON editor.
- Read and explain every element of an IAM policy JSON document: `Version`, `Statement`, `Effect`, `Action`, `Resource`, `Condition`.
- Create an **IAM user group**, attach a policy, and demonstrate why group membership beats per-user attachment.
- Apply the **principle of least privilege** using both scoped resources and an explicit `Deny` statement.
- Distinguish **inline policies** from **customer managed policies** and know when to use each.
- Create an **IAM role** for an AWS service and clearly distinguish the **trust policy** from the **permissions policy**.
- Create a cross-service role allowing Lambda to write to DynamoDB.
- Enforce **MFA requirements** using IAM condition keys.
- Use the **IAM Policy Simulator** to test allowed and denied actions before anyone depends on them.
- Explain how **AWS STS** issues temporary credentials and why roles are safer than long-lived access keys.
- Scope policies using **condition keys** including `aws:RequestedRegion`, `aws:MultiFactorAuthPresent`, and resource-specific ARNs.

## AWS Services Used

| Service | Purpose | Cost |
|---------|---------|------|
| **AWS IAM** | Identities, policies, roles | Free |
| **AWS STS** | Issues temporary credentials for roles | Free |
| **Amazon S3** | Referenced in cross-service scenarios | N/A (no buckets created) |
| **Amazon DynamoDB** | Referenced in policy resources | N/A (no tables created) |
| **AWS Lambda** | Referenced in execution role scenarios | N/A (no functions created) |

## Prerequisites

- An AWS account you can access.
- Signed in as an **admin-capable IAM user** — **not** the root user. You need at minimum `IAMFullAccess` or broad `AdministratorAccess`.
- Your AWS console Region can be anything — **IAM is a global service** with no region selector.

> **Region note:** IAM itself is global. However, every ARN in this lab that references a regional service (DynamoDB, Lambda, S3) uses **`us-west-2`** (US West — Oregon). The rest of this course uses `us-west-2`.

> **Note on organizational restrictions:** Some AWS accounts have **Service Control Policies (SCPs)** or permission boundaries that restrict IAM changes. If you see an "explicit deny" or "not authorized" error even as an admin, an SCP may be blocking you — contact your account administrator.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        AWS ACCOUNT                              │
│                                                                 │
│  ┌──────────────────────────────────────────────┐              │
│  │              IAM IDENTITIES                   │              │
│  │                                              │              │
│  │  ┌──────────────┐   ┌──────────────────────┐ │              │
│  │  │  User Groups  │   │     IAM Roles        │ │              │
│  │  │               │   │                      │ │              │
│  │  │  Developers   │   │  AcmeLambdaExecRole  │ │              │
│  │  │  └─dev-anaya  │   │  AcmeLambdaDDBWrite  │ │              │
│  │  │  Auditors     │   │  (trust: Lambda svc) │ │              │
│  │  │  └─fin-carlos │   └──────────────────────┘ │              │
│  │  └──────────────┘                             │              │
│  └──────────────────────────────────────────────┘              │
│                                                                 │
│  ┌──────────────────────────────────────────────┐              │
│  │            IAM POLICIES (attached)            │              │
│  │  AcmeDynamoDBReadOnly → Developers group     │              │
│  │  DenyDynamoDBDeleteTable → dev-anaya (inline)│              │
│  │  AcmeAuditorsReadOnly → Auditors group       │              │
│  │  AWSLambdaBasicExecutionRole → Lambda roles  │              │
│  └──────────────────────────────────────────────┘              │
└─────────────────────────────────────────────────────────────────┘
```

---

## Detailed Step-by-Step Instructions

### Part A — Explore the IAM Console (~10 min)

**Goal:** Build a mental map of IAM before you create anything.

1. Sign in to the **AWS Management Console** as your admin-capable IAM user (not root).
2. In the top search bar, type `IAM` and click the **IAM** service. You land on the IAM **Dashboard**.
3. Look at the left navigation pane. Click each item below and read what it shows. Do **not** create anything yet — just explore.

   **Users** — Long-lived identities for **people** (or, historically, for applications). A user can have a console **password** and/or **access keys**. Each user represents one "who."

   **User groups** — A **collection of users** that share the same permissions. You attach policies to the *group*, and every user inherits them. **A group is not an identity** — nothing "logs in" as a group.

   **Roles** — An identity with permissions that is **assumed temporarily** rather than logged into. Roles have **no password and no long-lived access keys**. AWS services (like Lambda), users, or other accounts *assume* a role to borrow its permissions for a short time. This is the single most important IAM concept in the entire course.

   **Policies** — **JSON documents that define permissions**. They do nothing by themselves; they must be *attached* to a user, group, or role. You'll see **AWS managed policies** (maintained by AWS) and, once you create one, **Customer managed policies** (yours).

   **Identity providers** — Where you connect **external identity systems** (corporate directory via SAML, or OpenID Connect) so people can federate into AWS without a separate IAM user. Not configured today but important to know.

4. On the **Dashboard**, look at the **"Security recommendations"** area. Note any warnings about MFA on the root user. That warning is exactly the problem this lab addresses.

> **AWS Mental Model — The bouncer at every door.**
> Think of IAM as a bouncer standing in front of *every single AWS API*. Every request — whether from a person clicking in the console or a Lambda function calling DynamoDB — arrives with an identity. The bouncer checks the identity's policies and answers one yes/no question: *"Is this identity allowed to perform THIS action on THIS resource right now?"* Everything in IAM is just a way of writing down the rules the bouncer enforces.

> **Authentication vs. Authorization — the two-step model.**
> These are completely separate steps that people constantly conflate:
> - **Authentication (AuthN) = "Who are you?"** — Proving your identity. A password + MFA for a person; a signed SigV4 request for a service. This is the *sign-in* step.
> - **Authorization (AuthZ) = "What are you allowed to do?"** — Once your identity is confirmed, IAM policies decide which actions you may perform.
>
> A user can be perfectly authenticated (correct password, correct MFA code) and still be authorized for **nothing** — because no policy grants them any permissions. In this lab, Part C handles authentication (a password for `dev-anaya`), and Parts B, D, F, H, I handle authorization (policies that define what she can or cannot do).

---

### Part B — Create a "Developers" User Group with a Customer Managed Policy (~15 min)

**Goal:** Create reusable, least-privilege permissions and attach them to a group. Acme's developers should be able to **read** the DynamoDB product catalog but not modify it. They can also **invoke** Lambda functions but cannot delete them.

We'll build the policy **first**, then the group, then attach one to the other.

#### B1. Build the customer managed policy in the visual editor

1. In IAM, go to **Policies** (left nav) → click **Create policy** (top-right).
2. You'll see a **Policy editor** with two tabs: **Visual** and **JSON**. Stay on **Visual**.
3. Add the first permission block for DynamoDB reads:
   - Under **Select a service**, click **Choose a service**, type `DynamoDB`, and select **DynamoDB**.
   - Under **Actions allowed**, use the filter box to check these specific actions:
     - **GetItem**, **Query**, **Scan**, **BatchGetItem**, **DescribeTable**
   - Under **Resources**, choose **All** (`*`) for now. (You'll scope this down in the challenge.)
4. Click **Add more permissions** to add a second permission block for Lambda invocation:
   - **Service:** `Lambda`
   - **Actions:** under **Write**, check **InvokeFunction** only.
   - **Resources:** choose **All** (`*`).
5. Before proceeding, switch to the **JSON** tab (the tab is visible in the **Policy editor** section, next to the **Visual** tab) and read the full policy document. It should look like this:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "DynamoDBReadAccess",
         "Effect": "Allow",
         "Action": [
           "dynamodb:BatchGetItem",
           "dynamodb:DescribeTable",
           "dynamodb:GetItem",
           "dynamodb:Query",
           "dynamodb:Scan"
         ],
         "Resource": "*"
       },
       {
         "Sid": "LambdaInvokeAccess",
         "Effect": "Allow",
         "Action": [
           "lambda:InvokeFunction"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

   > **Why switch here?** The **JSON** and **Visual** tabs are only available on the policy editor screen. Once you click **Next**, you move to the **Review and create** page where tabs are no longer visible. Always review the JSON here to confirm the policy matches your intent before finalizing.

6. Click **Next** to proceed to the **Review and create** page.
7. On the **Review and create** page, set:
   - **Policy name:** `AcmeDeveloperPolicy`
   - **Description:** `Allows developers to read DynamoDB tables and invoke Lambda functions.`
8. Click **Create policy**.

#### B2. Understand the JSON — element by element

This is the heart of IAM. Every policy is a JSON document with these parts:

| Element | Purpose |
|---------|---------|
| `Version` | `"2012-10-17"` is the IAM policy language version. **Always use this exact date.** It is NOT "today's date." Using the wrong version silently disables newer policy features. |
| `Statement` | An **array of permission rules**. A policy can hold many statements; IAM evaluates all of them together. |
| `Sid` | An optional label for humans. Purely cosmetic — it does nothing functional. |
| `Effect` | Either `Allow` or `Deny`. This is the verdict of the statement. |
| `Action` | The API operations this statement covers, written as `service:Operation` (e.g., `dynamodb:GetItem`). |
| `Resource` | **Which** specific resources the actions apply to, written as **ARNs**. `"*"` means "all resources." |
| `Condition` | Optional constraints — "only when MFA is active," "only in this region," etc. Covered in Part I. |

> **What Is Happening Behind the Scenes?**
> When any identity makes a DynamoDB call, IAM gathers **every** policy attached to that identity (from the user directly, via group membership, via role assumption, plus any SCPs and permission boundaries), then evaluates them together. The default is **implicit deny** — if no statement explicitly allows an action, it is denied. A matching `Allow` grants access — *unless* a matching `Deny` exists anywhere, in which case `Deny` always wins. You'll exploit this in Part D.

#### B3. Create the Developers group and attach the policy

1. Go to **User groups** (left nav) → **Create group**.
2. **User group name:** `Developers`.
3. Scroll to **Attach permissions policies**. In the search box type `AcmeDeveloperPolicy` and check the box next to your policy.
4. Leave the "Add users to the group" section empty — you'll create the user next.
5. Click **Create group**.

**Validation checkpoint:** Open **User groups → Developers → Permissions** tab. You should see `AcmeDeveloperPolicy` listed as an attached **Customer managed** policy.

> **AWS Mental Model — Policies attach to identities, not the other way around.**
> The group `Developers` is a container for people. The policy `AcmeDeveloperPolicy` is the rulebook. Attaching the policy to the group means: "Every member of Developers gets these permissions." Change the group's policy once and every member updates instantly — that's why groups beat attaching policies to individual users.

> **Common Beginner Mistake:** Attaching policies directly to individual users. It works for one person, but with 20 developers you'd manage 20 separate attachments. If a permission needs to change, you make 20 edits and inevitably miss one. **Attach to groups; put users in groups.**

---

### Part C — Create IAM Users for Two Team Members (~12 min)

**Goal:** Create real human identities, give them sign-in passwords, and grant permissions purely through group membership.

#### C1. Create dev-anaya (Developer)

1. Go to **Users** (left nav) → **Create user**.
2. **User name:** `dev-anaya`.
3. Check **"Provide user access to the AWS Management Console"**.
4. Choose **"I want to create an IAM user"**.
5. **Console password:** choose **Autogenerated password**.
6. Leave **"Users must create a new password at next sign-in"** checked.
7. Click **Next**.
8. On **Set permissions**, keep **"Add user to group"** selected and check the `Developers` group.
9. Click **Next**, review, then **Create user**.
10. **Download the `.csv`** or copy the credentials — this is the only time the password is shown.

#### C2. Create fin-carlos (Finance Auditor — we'll give him a group in Part H)

1. **Users** → **Create user**.
2. **User name:** `fin-carlos`.
3. Check **"Provide user access to the AWS Management Console"**.
4. Choose **"I want to create an IAM user"**.
5. **Console password:** **Autogenerated password**.
6. Leave the new-password-on-sign-in box checked.
7. Click **Next**.
8. On **Set permissions**, do **not** add him to any group yet — we'll create the Auditors group in Part H.
9. **Create user**.

**Validation checkpoint:** Go to **Users → dev-anaya → Permissions**. You should see `AcmeDeveloperPolicy` inherited **from group Developers** — no policy attached directly. For `fin-carlos`, the Permissions tab should show **no policies** at all — he can authenticate but is authorized for nothing yet.

> **Identity-based vs. resource-based policy:**
> - **Identity-based policy** — Attached to a **user, group, or role**. Answers: *"What can THIS identity do?"* All policies in this lab so far are identity-based.
> - **Resource-based policy** — Attached to a **resource** (e.g., an S3 bucket policy, a Lambda function's resource policy). Answers: *"WHO is allowed to touch THIS resource?"* Resource-based policies can grant access to identities in **other AWS accounts** — which identity-based policies alone cannot do.

---

### Part D — Least Privilege and the Explicit Deny (~10 min)

**Goal:** Guarantee that even if someone later broadens Anaya's permissions, she can **never** delete a DynamoDB table. This is done with an **inline policy** containing an explicit `Deny`.

**Least privilege** means: grant only the permissions actually needed, nothing more. Anaya needs to *read* the catalog. She never needs to *delete* tables. A defensive approach blocks the dangerous action explicitly — as a guardrail that survives future mistakes.

1. Go to **Users → dev-anaya → Permissions** tab.
2. Click **Add permissions ▾** → **Create inline policy**.

   > **Inline policy vs. customer managed policy:**
   > - An **inline policy** is embedded directly in one identity. It has no life of its own and is deleted when the identity is deleted. Use inline policies for one-off, identity-specific guardrails.
   > - A **customer managed policy** is standalone, reusable, and can be attached to many identities. Use these for shared, reusable permissions.
   > For this deny guardrail, an inline policy is the right choice — it's specific to Anaya and should disappear with her.

3. Switch to the **JSON** tab and paste:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "DenyDangerousTableActions",
         "Effect": "Deny",
         "Action": [
           "dynamodb:DeleteTable",
           "dynamodb:CreateTable",
           "dynamodb:UpdateTable"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

4. Click **Next**.
5. **Policy name:** `DenyDynamoDBTableMutation`.
6. Click **Create policy**.

**Validation checkpoint:** On **dev-anaya → Permissions**, you now see two things:
- Inherited `AcmeDeveloperPolicy` from group Developers
- Inline `DenyDynamoDBTableMutation`

Anaya can read the catalog but is now hard-blocked from creating, updating, or deleting any DynamoDB table.

> **Explicit `Deny` always wins — no exceptions.**
> IAM's evaluation rule is absolute: if **any** applicable policy (from any source — inline, managed, SCP, permission boundary) contains a `Deny` for a matching action/resource, the request is denied. No number of `Allow` statements can override it. If someone later grants Anaya `AdministratorAccess`, this explicit `Deny` on table mutations still stands.

> **Security Consideration:** Explicit `Deny` is how organizations enforce non-negotiable rules ("nobody deletes production databases," "no resources outside approved regions"). At scale, these guardrails live in **Service Control Policies (SCPs)** at the AWS Organization level, but the evaluation logic is identical to what you just wrote. Think of SCPs as explicit `Deny` policies applied to an entire AWS account or organizational unit.

> **Common Beginner Mistake:** Assuming a broad `Allow` is "safe enough because we trust our team." Permissions creep over time. People get promoted, teams merge, roles change. Layering explicit `Deny` on truly dangerous actions is cheap insurance that survives organizational change.

---

### Part E — Create a Role for a Service: Basic Lambda Execution (~12 min)

**Goal:** Give **AWS Lambda** permission to do its job **without any password or access key**. This is where roles shine, and where the trust policy vs. permissions policy distinction becomes concrete.

So far every identity has been a *person*. But Acme's code runs on **Lambda**, and Lambda itself needs permission (for example, to write logs). You never give Lambda a password. Instead, Lambda **assumes a role** you create, and AWS hands it **temporary credentials** scoped to exactly that role.

1. Go to **Roles** (left nav) → **Create role**.
2. **Trusted entity type:** select **AWS service**.
3. Under **Use case**, choose **Lambda**, then click **Next**.

   > This pre-writes the trust policy so that the Lambda service (`lambda.amazonaws.com`) is allowed to assume the role.

4. On **Add permissions**, search for and check `AWSLambdaBasicExecutionRole`. This AWS managed policy grants the minimum a Lambda needs: permission to **create log groups/streams and write logs to CloudWatch Logs**. Click **Next**.
5. **Role name:** `AcmeLambdaBasicExecutionRole`.
6. **Description:** `Basic execution role for Acme Lambda functions. Grants CloudWatch Logs write access only.`
7. Click **Create role**.

#### E1. Inspect the two very different policies on this role

Open **Roles → AcmeLambdaBasicExecutionRole**.

**(a) The Trust policy — WHO can assume the role.** Click the **Trust relationships** tab:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

- **`Principal`** — *Who* is allowed to assume this role. `lambda.amazonaws.com` is the service principal for AWS Lambda. Only Lambda can step into this role.
- **`Action: "sts:AssumeRole"`** — The act of assuming a role calls **AWS STS (Security Token Service)**, which mints temporary credentials.
- The trust policy is itself a **resource-based policy on the role** — it guards the door.

**(b) The Permissions policy — WHAT the role can do.** Click the **Permissions** tab. You'll see `AWSLambdaBasicExecutionRole` attached, which allows `logs:CreateLogGroup`, `logs:CreateLogStream`, and `logs:PutLogEvents`. This is what the role can *do* once assumed.

> **AWS Mental Model — IAM user vs. IAM role:**
> - An **IAM user** is your **permanent employee badge** — long-lived, you sign in with it directly, and it optionally has long-lived access keys.
> - An **IAM role** is a **visitor badge at the front desk** — nobody owns it permanently. When Lambda needs to work, it presents its identity to the front desk. The **trust policy** checks whether Lambda is on the approved list. If so, Lambda is handed a **temporary badge (temporary credentials)** that expires automatically. Many different callers can borrow the same role at different times without interfering with each other.
>
> Rule of thumb: **people and long-term sign-in → users; services and temporary access → roles.**

> **Trust policy vs. permissions policy — say it out loud:**
> - **Trust policy = WHO can become this role.** (The `Principal` + `sts:AssumeRole`.)
> - **Permissions policy = WHAT this role can do.** (The `Allow` actions on resources.)
> A role needs **both** to work. A great permissions policy with a trust policy that trusts nobody = a role no one can use.

---

### Part F — Create a Cross-Service Role: Lambda Writes to DynamoDB (~15 min)

**Goal:** Build a more realistic execution role that lets a Lambda function **write order data to a DynamoDB table**. This is the pattern used in every real Acme Retail microservice.

The developer team has asked: "When a customer places an order, our Lambda function needs to write the order to the `AcmeOrders` DynamoDB table in us-west-2. What's the right way to grant this?"

The answer is a **scoped execution role** — one that allows exactly `dynamodb:PutItem`, `dynamodb:UpdateItem`, and `dynamodb:GetItem` on exactly the `AcmeOrders` table. Not `*`. Not `AdministratorAccess`.

#### F1. Create the scoped IAM policy for DynamoDB write access

1. **IAM → Policies → Create policy → JSON** tab.
2. Paste the following. **Replace `123456789012` with your real 12-digit AWS account ID** (visible in the top-right account menu):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AllowOrderTableReadWrite",
         "Effect": "Allow",
         "Action": [
           "dynamodb:PutItem",
           "dynamodb:GetItem",
           "dynamodb:UpdateItem",
           "dynamodb:Query"
         ],
         "Resource": "arn:aws:dynamodb:us-west-2:123456789012:table/AcmeOrders"
       },
       {
         "Sid": "AllowCloudWatchLogs",
         "Effect": "Allow",
         "Action": [
           "logs:CreateLogGroup",
           "logs:CreateLogStream",
           "logs:PutLogEvents"
         ],
         "Resource": "arn:aws:logs:us-west-2:123456789012:log-group:/aws/lambda/*"
       }
     ]
   }
   ```

3. Click **Next**.
4. **Policy name:** `AcmeLambdaOrderWriterPolicy`.
5. **Description:** `Allows a Lambda function to write/read from AcmeOrders DynamoDB table and write to CloudWatch Logs.`
6. Click **Create policy**.

> **ARN Anatomy — Reading the Resource field:**
> `arn:aws:dynamodb:us-west-2:123456789012:table/AcmeOrders`
> - `arn:aws` — Amazon Resource Name in the standard AWS partition
> - `dynamodb` — the service
> - `us-west-2` — the region (always us-west-2 in this course)
> - `123456789012` — your 12-digit account ID
> - `table/AcmeOrders` — resource type and name
>
> This is NOT `*`. This ARN grants access to exactly one table. If code tries to write to `AcmeProducts`, it won't match and will be implicitly denied.

#### F2. Create the Lambda execution role using this policy

1. **IAM → Roles → Create role**.
2. **Trusted entity type:** **AWS service**.
3. **Use case:** **Lambda**. Click **Next**.
4. Search for and check `AcmeLambdaOrderWriterPolicy`. Click **Next**.
5. **Role name:** `AcmeLambdaOrderWriterRole`.
6. **Description:** `Execution role for the order-processor Lambda. Can write to AcmeOrders table in us-west-2.`
7. Click **Create role**.

#### F3. Review the complete role

Open **Roles → AcmeLambdaOrderWriterRole** and verify:

- **Trust relationships tab:** `lambda.amazonaws.com` as the Principal with `sts:AssumeRole` action.
- **Permissions tab:** `AcmeLambdaOrderWriterPolicy` attached (customer managed).

**Validation checkpoint:** Click the `AcmeLambdaOrderWriterPolicy` link. In the policy JSON, confirm the `Resource` field contains a specific DynamoDB table ARN — not `"*"`. This is the difference between least-privilege and open-ended access.

> **What Is Happening Behind the Scenes?**
> When a Lambda function using this role runs, the Lambda service calls `sts:AssumeRole` on your behalf. STS returns a bundle of **temporary security credentials** (access key ID + secret access key + session token) valid for a limited time (typically 1 hour). Your function code receives these automatically via the execution environment — nothing is stored, nothing is embedded in code, and when the credentials expire, new ones are fetched seamlessly. The `AcmeOrders` table ARN ensures those credentials cannot accidentally be used on a different table.

> **Security Consideration:** Never embed AWS access keys in Lambda code or environment variables when the function runs on AWS. The execution role provides credentials automatically and securely. Embedding access keys is the #1 cause of AWS credential leaks and is completely unnecessary when using roles.

---

### Part G — Prove It with the IAM Policy Simulator (~10 min)

**Goal:** Don't *assume* your policies are correct — **test** them. The **IAM Policy Simulator** evaluates policies against specific actions without actually performing them, so you can verify allowed/denied results safely before production.

1. Open the simulator at **https://policysim.aws.amazon.com/** — sign in with your admin identity.
2. In the left panel **Users, Groups, and Roles**, select **Users**, then click **dev-anaya**. The simulator loads all of Anaya's effective policies.
3. In the center panel:
   - **Select service:** **Amazon DynamoDB**
   - **Select actions:** check **GetItem**, **Query**, **Scan**, **DescribeTable**, **DeleteTable**, **CreateTable**
4. Click **Run Simulation**.

**Expected results:**

| Action | Expected | Why |
|--------|----------|-----|
| `dynamodb:GetItem` | **allowed** | Granted by `AcmeDeveloperPolicy` |
| `dynamodb:Query` | **allowed** | Granted by `AcmeDeveloperPolicy` |
| `dynamodb:Scan` | **allowed** | Granted by `AcmeDeveloperPolicy` |
| `dynamodb:DescribeTable` | **allowed** | Granted by `AcmeDeveloperPolicy` |
| `dynamodb:DeleteTable` | **denied** | Blocked by inline `DenyDynamoDBTableMutation` |
| `dynamodb:CreateTable` | **denied** | Blocked by inline `DenyDynamoDBTableMutation` |

5. Click the **denied** result for `DeleteTable`. The simulator shows **which statement** caused the deny — you'll see it points to your inline deny policy.

Now test Lambda actions:
- **Service:** Lambda → **Action:** `InvokeFunction` → expected: **allowed**
- **Action:** `DeleteFunction` → expected: **denied** (not in any `Allow` statement → implicit deny)

> **Implicit deny vs explicit deny — spot the difference:**
> - `DeleteTable` shows **denied** with your explicit `Deny` statement called out.
> - `DeleteFunction` shows **denied** but with no explicit deny — it's an **implicit deny** (no statement allows it, so it's blocked by default).
> Both result in access denied, but the reason matters for debugging. Explicit deny is a guardrail you wrote. Implicit deny just means you never granted it.

**Validation checkpoint:** If your read actions show **allowed** and your destructive actions show **denied**, your identity design is provably correct. The Policy Simulator turns "I think this is secure" into "I have verified this is secure."

> **Why This Matters in Production:** The Policy Simulator is your safety net before any real deployment. In real incidents, "did the policy actually deny that?" is answered here in seconds instead of by risky trial-and-error in a live environment. Teams that skip this step find out their policies are wrong when a Lambda function can't write to a database at 2am on a deploy night.

---

### Part H — Create the Auditors Group with MFA Enforcement (~18 min)

**Goal:** Create a Finance Auditors group with two constraints that the developer group doesn't have:
1. Read-only access to specific S3 and DynamoDB resources.
2. **MFA must be active** before any read is allowed — a compliance requirement.

This introduces **IAM condition keys** — the powerful `Condition` block in a policy statement.

#### H1. Create the Auditors policy with MFA condition

1. **IAM → Policies → Create policy → JSON** tab.
2. Paste the following. **Replace `123456789012` with your real account ID**:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AllowDynamoDBReadWhenMFAPresent",
         "Effect": "Allow",
         "Action": [
           "dynamodb:GetItem",
           "dynamodb:Query",
           "dynamodb:Scan",
           "dynamodb:DescribeTable",
           "dynamodb:BatchGetItem"
         ],
         "Resource": [
           "arn:aws:dynamodb:us-west-2:123456789012:table/AcmeOrders",
           "arn:aws:dynamodb:us-west-2:123456789012:table/AcmeProducts"
         ],
         "Condition": {
           "Bool": {
             "aws:MultiFactorAuthPresent": "true"
           }
         }
       },
       {
         "Sid": "AllowS3AuditReadsWhenMFAPresent",
         "Effect": "Allow",
         "Action": [
           "s3:GetObject",
           "s3:ListBucket"
         ],
         "Resource": [
           "arn:aws:s3:::acme-retail-audit-logs-us-west-2",
           "arn:aws:s3:::acme-retail-audit-logs-us-west-2/*"
         ],
         "Condition": {
           "Bool": {
             "aws:MultiFactorAuthPresent": "true"
           }
         }
       },
       {
         "Sid": "DenyAllIfNoMFA",
         "Effect": "Deny",
         "Action": "*",
         "Resource": "*",
         "Condition": {
           "BoolIfExists": {
             "aws:MultiFactorAuthPresent": "false"
           }
         }
       }
     ]
   }
   ```

3. Click **Next**.
4. **Policy name:** `AcmeAuditorsPolicy`.
5. **Description:** `Read-only access to Acme audit resources in us-west-2. MFA required.`
6. Click **Create policy**.

#### H2. Understand the condition keys

| Condition Key | What It Does |
|--------------|--------------|
| `aws:MultiFactorAuthPresent` | `true` if the current session was authenticated with MFA. Available on console sessions and assumed-role sessions where MFA was used. |
| `BoolIfExists` | The `IfExists` variant applies the condition only when the key exists in the request context. Without `IfExists`, requests from services that don't provide MFA context (like many AWS SDK calls) would be blocked. |
| `aws:RequestedRegion` | (Used in challenges) Limits actions to a specific AWS region. |

> **The three-statement pattern for MFA enforcement:**
> Statement 1 allows the desired actions **when MFA is present** (`true`).
> Statement 2 (optional, for additional services) also allows **when MFA is present**.
> Statement 3 explicitly **denies everything when MFA is absent** (`false`) using `BoolIfExists`.
>
> The `DenyAllIfNoMFA` statement is the guardrail: even if someone adds a broad `Allow` later, the explicit `Deny` when MFA is absent fires first. This is defense in depth.

#### H3. Create the Auditors group and add fin-carlos

1. **IAM → User groups → Create group**.
2. **Group name:** `Auditors`.
3. Under **Attach permissions policies**, search `AcmeAuditorsPolicy` and check it.
4. Click **Create group**.
5. Now add Carlos: Open **User groups → Auditors → Users** tab → **Add users** → check `fin-carlos` → **Add users**.

**Validation checkpoint:** Open **Users → fin-carlos → Permissions**. You should see `AcmeAuditorsPolicy` inherited from group `Auditors`. Open the policy and confirm it contains the `aws:MultiFactorAuthPresent` condition.

> **Why This Matters — Compliance and the MFA gate:**
> Finance and audit functions often have regulatory requirements (SOC2, PCI-DSS, HIPAA) that demand MFA for access to sensitive data. Building MFA enforcement into the IAM policy itself means it's enforced even if an administrator forgets to configure it at the identity provider level. The IAM policy is the last line of defense.

> **Common Beginner Mistake:** Writing `Bool: aws:MultiFactorAuthPresent: true` but forgetting the `DenyAllIfNoMFA` statement. Without the explicit deny, a session without MFA could use other attached policies that don't have the MFA condition. The deny statement ensures the MFA gate applies universally for this identity.

---

### Part I — STS, Temporary Credentials, and Why Roles Beat Access Keys (~8 min)

This section has no console clicks — it's the conceptual insight that ties everything together.

An **IAM user access key** is a **long-lived credential**: an access key ID and secret access key that stay valid until someone manually rotates or deletes them. If one leaks — committed to GitHub, pasted in a Slack message, embedded in a container image — it works for an attacker **indefinitely**, and organizations often don't notice for weeks.

A **role's credentials** work completely differently. When something assumes a role:

1. The caller makes a `sts:AssumeRole` API call.
2. **AWS STS (Security Token Service)** validates the trust policy and, if the caller matches, issues a bundle of three values:
   - A **temporary access key ID** (starts with `ASIA...`)
   - A **temporary secret access key**
   - A **session token** (a long string that must accompany the access key in every API call)
3. These credentials are valid for a configured duration (default 1 hour; maximum varies by role type).
4. **They expire automatically.** No rotation needed; they simply stop working.

```
┌─────────────┐    sts:AssumeRole     ┌──────────────┐
│   Lambda    │ ──────────────────►  │   AWS STS    │
│  (service)  │                      │              │
│             │ ◄── temp credentials─│              │
└─────────────┘                      └──────────────┘
       │  (access key + secret + token, expire in ~1hr)
       ▼
┌─────────────────────────────────────────────────────┐
│          DynamoDB API call with temp credentials    │
│   IAM checks: does this role's policy allow it?     │
└─────────────────────────────────────────────────────┘
```

**The AWS best-practice hierarchy for credentials:**

| Use case | Right answer | Wrong answer |
|----------|-------------|--------------|
| Person signs into console | IAM user (+ MFA) or Identity Center | Root user |
| Code on Lambda / ECS | Execution role | Hardcoded access keys in code |
| Code on EC2 | Instance profile role | Access keys on the instance |
| CI/CD pipeline | OIDC federation → assume role | Long-lived access keys in secrets |
| Cross-account access | Assume a role in the target account | Copy access keys across accounts |

> **Key Takeaway — Part I:** Roles turn "a permanent secret that can leak forever" into "a temporary badge that expires on its own." Every service built in the rest of this course gets a **role**, not an access key. That single habit eliminates the most common and most damaging class of AWS security failures.

> **Cost Awareness:** IAM users, groups, roles, policies, and STS calls are **completely free**. There is no cost reason to cut corners on identity hygiene.

---

### Part J — S3 Cross-Service Scenario: Ops Read-Only Access (~10 min)

**Goal:** Practice building a policy for a new team — the Ops/SRE team — who need to read application logs from S3 buckets in us-west-2 but cannot delete or overwrite anything.

This part reinforces the pattern: **new team → new group → new scoped policy → test with simulator**.

#### J1. Create the Ops policy

1. **IAM → Policies → Create policy → JSON** tab.
2. Paste the following. Replace `123456789012` with your account ID:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "S3LogsReadOnly",
         "Effect": "Allow",
         "Action": [
           "s3:GetObject",
           "s3:ListBucket",
           "s3:GetBucketLocation",
           "s3:GetObjectAttributes"
         ],
         "Resource": [
           "arn:aws:s3:::acme-retail-app-logs-us-west-2",
           "arn:aws:s3:::acme-retail-app-logs-us-west-2/*"
         ]
       },
       {
         "Sid": "CloudWatchLogsRead",
         "Effect": "Allow",
         "Action": [
           "logs:DescribeLogGroups",
           "logs:DescribeLogStreams",
           "logs:GetLogEvents",
           "logs:FilterLogEvents"
         ],
         "Resource": "arn:aws:logs:us-west-2:123456789012:log-group:/aws/lambda/*"
       },
       {
         "Sid": "DenyS3Delete",
         "Effect": "Deny",
         "Action": [
           "s3:DeleteObject",
           "s3:DeleteBucket",
           "s3:PutObject"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

3. **Policy name:** `AcmeOpsReadOnlyPolicy`.
4. **Description:** `Read-only access to S3 application logs and Lambda CloudWatch logs for Ops team.`
5. Click **Create policy**.

#### J2. Create the Ops group (no users needed for validation)

1. **IAM → User groups → Create group**.
2. **Group name:** `Ops`.
3. Attach `AcmeOpsReadOnlyPolicy`.
4. Click **Create group**.

**Validation checkpoint:** Use the **Policy Simulator** with the `AcmeOpsReadOnlyPolicy` attached to a test context:
- `s3:GetObject` on `arn:aws:s3:::acme-retail-app-logs-us-west-2/some-file.log` → **allowed**
- `s3:PutObject` on the same ARN → **denied** (explicit deny)
- `s3:DeleteObject` → **denied** (explicit deny)

> **S3 ARN note:** S3 bucket ARNs use a special format — there is no region or account ID in the bucket ARN itself. The bucket name must be globally unique across all AWS accounts, so `arn:aws:s3:::bucket-name` uniquely identifies the bucket without needing the account or region. Object ARNs add a `/` suffix: `arn:aws:s3:::bucket-name/*` means "all objects in the bucket."

---

## Key Takeaways

- **IAM answers one question for every AWS API call:** *"Is this identity allowed to perform THIS action on THIS resource right now?"*
- **Authentication and authorization are separate.** A valid password grants access to nothing without a matching `Allow` policy.
- **Users are for people; roles are for services and temporary access.** Roles have no passwords and no long-lived access keys.
- **Attach policies to groups; put users in groups.** Never attach policies directly to individual users at scale.
- **A policy is JSON:** `Version`, `Statement`s with `Effect`, `Action`, `Resource`, and optional `Condition`.
- **Explicit `Deny` always wins** over any `Allow`, from any source, anywhere in the evaluation chain.
- **A role has two policies:** the **trust policy** (WHO can assume it) and the **permissions policy** (WHAT it can do).
- **Identity-based policies** attach to identities; **resource-based policies** attach to resources and enable cross-account access.
- **Condition keys** (`aws:MultiFactorAuthPresent`, `aws:RequestedRegion`, etc.) let you build context-aware policies.
- **Roles + STS temporary credentials beat long-lived access keys** — they expire automatically and are never stored in code.
- **The IAM Policy Simulator** turns "I think this is correct" into "I have verified this is correct."

---

## Challenges

> Complete these after finishing Parts A–J. Try each challenge yourself before checking the solutions file.

---

### Challenge 1 — Resource-Scoped Auditor Policy with Region Lock

Acme's **auditors** need access to **only** the `AcmeOrders` table, and only from **us-west-2**. If they call from any other region (e.g., via a VPN that routes through us-east-1), the request must be denied.

**Your task:**

1. Create a **customer managed policy** named `AcmeAuditorsOrdersReadOnly` that:
   - Allows `dynamodb:GetItem`, `dynamodb:Query`, `dynamodb:Scan`, `dynamodb:DescribeTable`, `dynamodb:BatchGetItem`
   - Applies only to `arn:aws:dynamodb:us-west-2:YOUR_ACCOUNT_ID:table/AcmeOrders`
   - Has a **Condition** block requiring `aws:RequestedRegion` equals `us-west-2`
2. Attach it to the `Auditors` group (alongside `AcmeAuditorsPolicy`).
3. Use the **Policy Simulator** to verify:
   - `dynamodb:GetItem` on `AcmeOrders` with region context `us-west-2` → **allowed**
   - `dynamodb:GetItem` on `AcmeOrders` with region context `us-east-1` → **denied**
   - `dynamodb:GetItem` on a different table (`AcmeProducts`) with `us-west-2` → **denied**

See `01-solutions.md` → Challenge 1 for the complete solution.

---

### Challenge 2 — Developer Self-Service Password Change Policy

Acme's security policy says: developers may change **their own** IAM password and manage **their own** MFA device — but they may never change anyone else's.

**Your task:**

Create a customer managed policy named `AcmeSelfServiceIAMPolicy` that allows users to:
- Change their own console password: `iam:ChangePassword`
- Enable/disable/resync their own virtual MFA: `iam:CreateVirtualMFADevice`, `iam:EnableMFADevice`, `iam:ResyncMFADevice`, `iam:DeactivateMFADevice`, `iam:DeleteVirtualMFADevice`
- List MFA devices: `iam:ListMFADevices`, `iam:ListVirtualMFADevices`

Use a **Condition** to scope the MFA actions to only `aws:username == ${aws:username}` (the calling user's own user ARN).

Attach it to the `Developers` group and validate with the simulator.

See `01-solutions.md` → Challenge 2 for the complete solution.

---

### Challenge 3 — Lambda Assume-Role: Cross-Account Access Pattern

Acme is setting up a **second AWS account** for their data analytics team. A Lambda function in the **main account** needs to read from a DynamoDB table in the **analytics account**.

**Your task (conceptual + policy writing):**

Design the IAM setup for this cross-account access:

1. **In the analytics account:** Create a trust policy (as JSON) for a role named `AcmeAnalyticsReaderRole` that trusts the main account (`123456789012`) to assume it.
2. **In the main account:** Create a permissions policy for the Lambda execution role that allows `sts:AssumeRole` on `arn:aws:iam::ANALYTICS_ACCOUNT_ID:role/AcmeAnalyticsReaderRole`.
3. **Explain in 3-4 sentences** why this pattern is more secure than copying access keys from the analytics account into the Lambda function's environment variables.

See `01-solutions.md` → Challenge 3 for the complete trust policy JSON, permissions policy JSON, and explanation.

---

## Cleanup Instructions

IAM resources are **free**, so cleanup here is about hygiene and security. Remove what you created, in this order (delete dependents before the things they depend on).

> **Do not delete your own admin identity** — you will lock yourself out of the account.

1. **Remove users from groups:**
   - `fin-carlos` from `Auditors`
   - `dev-anaya` from `Developers`

2. **Delete users:**
   - `fin-carlos` (IAM → Users → select → Delete)
   - `dev-anaya` (same)
   - Deleting a user also removes any inline policies attached to it.

3. **Delete groups (must be empty first):**
   - `Auditors`
   - `Developers`
   - `Ops`

4. **Delete customer managed policies:**
   - `AcmeDeveloperPolicy`
   - `AcmeLambdaOrderWriterPolicy`
   - `AcmeAuditorsPolicy`
   - `AcmeOpsReadOnlyPolicy`
   - Any challenge policies you created

5. **Delete roles:**
   - `AcmeLambdaBasicExecutionRole`
   - `AcmeLambdaOrderWriterRole`
   - Any challenge roles you created

> **Security Consideration:** Before deleting a role, check **IAM → Roles → [RoleName] → Access Advisor** to confirm it hasn't been used recently by anything you haven't accounted for. Deleting a role that's still being used by a running Lambda or ECS task will cause immediate failures.
