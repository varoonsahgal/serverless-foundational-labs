# IAM Deep Dive: Identities, Roles, and Least Privilege

## Estimated Duration

**~75 minutes**

## Scenario / Business Context

You have just been hired as the **new cloud administrator at Acme Retail**, a small online store that is moving its systems onto AWS. Right now there is exactly one way into the AWS account: the **root user** — the email address and password used to sign up. That is dangerous. If that one login leaks, an attacker owns everything: customer data, billing, the ability to delete every resource.

Your first job is to set up **secure, appropriately-scoped access** for two kinds of "who":

1. **People** — the small developer team who need to work in the account (but should *not* be able to delete production databases).
2. **Application services** — the AWS services (like AWS Lambda) that run Acme's code and need permission to do their job *without* anyone embedding a password in the application.

By the end of this lab you will have built the identity foundation that every other lab in this course depends on. You will create a group, a user, custom permissions, a service role, and you will *prove* — using the IAM Policy Simulator — exactly what each identity can and cannot do.

**AWS Identity and Access Management (IAM)** is the AWS service that answers one question for every single API call in the account: *"Is this identity allowed to perform this action on this resource?"* Learning IAM well is the highest-leverage skill in all of AWS.

## Learning Objectives

By the end of this exercise you will be able to:

- Navigate the IAM console and explain the purpose of **Users**, **User groups**, **Roles**, **Policies**, and **Identity providers**.
- Explain the difference between **authentication** (who you are) and **authorization** (what you may do).
- Create a **user group** and attach a **customer managed policy** built in the visual editor.
- Read and explain every element of an IAM policy JSON document: `Version`, `Statement`, `Effect`, `Action`, `Resource`.
- Create an **IAM user**, add it to a group, and understand how **identity-based policies** grant permissions through group membership.
- Apply the **principle of least privilege** and use an **explicit `Deny`** to block a dangerous action — and explain why explicit `Deny` always wins.
- Create an **IAM role** for an AWS service and clearly distinguish the **trust policy** (who can assume the role) from the **permissions policy** (what the role can do).
- Use the **IAM Policy Simulator** to test allowed and denied actions before anyone relies on them.
- Explain how roles issue **temporary credentials** via **AWS STS (Security Token Service)** and why roles are safer than long-lived access keys.

## AWS Services Used

- **AWS IAM (Identity and Access Management)** — identities, policies, and roles. IAM is **free**.
- **AWS STS (Security Token Service)** — issues the temporary credentials that roles hand out. You will observe it conceptually; you won't be billed.

## Prerequisites

- An **AWS account**.
- The ability to sign in as an **admin-capable IAM user** or an **IAM Identity Center user** — **not** the root user. You need permissions to create IAM users, groups, policies, and roles (for example, the AWS managed policy `IAMFullAccess`, or broader admin access).
- A modern web browser.

> **Note on organizational restrictions:** Some AWS accounts belong to an **AWS Organization** with **Service Control Policies (SCPs)** or permission boundaries that restrict IAM changes. If you hit an "explicit deny" or "not authorized" error even though your identity looks like an admin, an SCP may be blocking you. **Contact your account administrator** — this is expected in managed corporate accounts and is not a mistake on your part.

> **Region note:** **IAM is a global service.** There is no region selector for IAM resources — a user, group, role, or policy you create is the same everywhere. You may see "Global" where a region name normally appears. (The *services* IAM protects, like DynamoDB, are regional; for the rest of this course use `us-east-1`.)

---

## Detailed Step-by-Step Instructions

### Part A — Explore the IAM Console (~10 min)

**Goal:** Build a mental map of IAM before you create anything.

1. Sign in to the **AWS Management Console** as your admin-capable IAM user (not root).
2. In the top search bar, type `IAM` and click the **IAM** service. You land on the IAM **Dashboard**.
3. Look at the left navigation pane. Click each item below and read what it shows. Do **not** create anything yet — just explore.

   - **Users** — Long-lived identities for **people** (or, historically, for applications). A user can have a console **password** and/or **access keys**. Each user represents one "who."
   - **User groups** — A **collection of users** that share the same permissions. You attach policies to the *group*, and every user in it inherits them. Groups make permissions manageable: change the group once, everyone updates. **A group is not an identity** — nothing "logs in" as a group.
   - **Roles** — An identity with permissions that is **assumed temporarily** rather than logged into. Roles have **no password and no long-lived access keys**. AWS services (like Lambda), users, or other accounts *assume* a role to borrow its permissions for a short time. This is the most important IAM concept for the rest of the course.
   - **Policies** — **JSON documents that define permissions** (a list of allowed or denied actions). Policies do nothing by themselves; they must be *attached* to a user, group, or role. You'll see **AWS managed policies** (maintained by AWS, names like `AmazonDynamoDBReadOnlyAccess`) and, once you create one, **Customer managed policies** (yours).
   - **Identity providers** — Where you connect **external identity systems** (like a corporate directory via SAML, or an OpenID Connect provider) so people or workloads can federate into AWS without a separate IAM user. You won't configure one today, but know it exists.

4. On the **Dashboard**, note the **"Security recommendations"** area. It may warn you to enable MFA on the root user and to avoid using root. That warning is exactly the problem this lab solves.

> **AWS Mental Model — The bouncer at the door.**
> Think of IAM as a bouncer standing in front of *every* AWS API. Every request — from a person clicking in the console or a service calling an API — arrives with an identity. The bouncer checks the identity's policies and answers one yes/no question: *"Are you allowed to do THIS action on THIS resource right now?"* Everything in IAM is just a way of writing down the rules the bouncer enforces.

> **Authentication vs. Authorization.**
> These are two different steps and people constantly confuse them.
> - **Authentication (AuthN) = *Who are you?*** Proving your identity — a password + MFA for a person, or a signed request for a service. This is the *sign-in* step.
> - **Authorization (AuthZ) = *What are you allowed to do?*** Once your identity is known, IAM policies decide which actions you may perform.
> A user can be perfectly authenticated (correct password) and still be authorized for **nothing**. In this lab, Part C handles authentication (a password for `dev-anaya`), and Parts B, D, F handle authorization (policies).

> **Why This Matters:** Every other lab — Lambda, DynamoDB, API Gateway, Step Functions, and later the Bedrock agents — fails or succeeds based on IAM. When a Lambda "can't write to DynamoDB," 90% of the time the answer is an IAM permission, not a code bug. Understanding IAM here saves you hours later.

---

### Part B — Create a "Developers" User Group with a Customer Managed Policy (~15 min)

**Goal:** Create reusable, least-privilege permissions and attach them to a group. Acme's developers should be able to **read** the DynamoDB product catalog but not modify it.

We'll build the policy **first**, then the group, then attach one to the other.

#### B1. Build the customer managed policy in the visual editor

1. In IAM, go to **Policies** (left nav) → click **Create policy** (top-right).
2. You'll see a **Policy editor** with two tabs: **Visual** and **JSON**. Stay on **Visual**.
3. Under **Select a service**, click **Choose a service**, type `DynamoDB`, and select **DynamoDB**.
4. Under **Actions allowed**, expand **Read** (the access level groups are: List, Read, Write, Permissions management, Tagging). Instead of hand-picking, use the filter box:
   - In the **Filter actions** box type `Get`, then check **GetItem**.
   - Clear the filter, type `Query`, check **Query**.
   - Clear the filter, type `Scan`, check **Scan**.
   - Clear the filter, type `BatchGetItem`, check **BatchGetItem**.
   - Clear the filter, type `DescribeTable`, check **DescribeTable**.

   These five actions are the common "read" surface for a catalog: fetch one item, run indexed queries, scan the table, batch-read, and inspect the table's structure.
5. Under **Resources**, for this teaching policy choose **All** (select the **"All"** radio button, sometimes shown as `Specify: All resources` or the `*` option). We keep the resource broad here so the lesson stays on *actions*; you will tighten the resource ARN to a single table in the **early-finisher challenge**.
6. Click **Next**.
7. Set:
   - **Policy name:** `AcmeDynamoDBReadOnly`
   - **Description:** `Read-only access to DynamoDB for the Acme developer team.`
8. Before clicking Create, switch the top of the editor to the **JSON** tab and read the document. It should look essentially like this:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AcmeDynamoDBRead",
         "Effect": "Allow",
         "Action": [
           "dynamodb:BatchGetItem",
           "dynamodb:DescribeTable",
           "dynamodb:GetItem",
           "dynamodb:Query",
           "dynamodb:Scan"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

9. Click **Create policy**.

#### B2. Understand the JSON — element by element

This is the heart of IAM. Every policy is a JSON document with these parts:

- **`Version`** — `"2012-10-17"` is the current IAM policy language version. **Always use this exact date.** It is a language version, not "today's date," and using anything else silently disables newer policy features.
- **`Statement`** — An **array of permission rules**. A policy can hold many statements; IAM evaluates all of them.
- **`Sid`** (Statement ID) — An optional label for humans. It does nothing functional; it just helps you find a statement later.
- **`Effect`** — Either **`Allow`** or **`Deny`**. This is the verdict of the statement.
- **`Action`** — The API operations this statement covers, written as `service:Operation` (e.g., `dynamodb:GetItem`). Actions are how AWS names "the things you can do."
- **`Resource`** — **Which** resources the actions apply to, written as **ARNs (Amazon Resource Names)**. `"*"` means "all resources." A specific table would look like `arn:aws:dynamodb:us-east-1:123456789012:table/Products`.

> **What Is Happening Behind the Scenes?** When any identity makes a DynamoDB call, IAM gathers **every** policy attached to that identity (directly, via groups, via role, plus any SCPs and boundaries), then evaluates them together. The default is **implicit deny** (if nothing allows it, it's denied). A matching `Allow` grants access — *unless* a matching `Deny` exists, in which case `Deny` wins. You'll exploit this in Part D.

#### B3. Create the group and attach the policy

1. Go to **User groups** (left nav) → **Create group**.
2. **User group name:** `Developers`.
3. Scroll to **Attach permissions policies**. In the search box type `AcmeDynamoDBReadOnly` and **check the box** next to your policy.
4. (Leave the "Add users to the group" section empty — you'll create the user next.)
5. Click **Create group**.

**Validation:** Open **User groups → Developers → Permissions** tab. You should see `AcmeDynamoDBReadOnly` listed as an attached **Customer managed** policy.

> **AWS Mental Model — Policies attach to *identities*, not the other way around.** The group `Developers` is a container. The policy `AcmeDynamoDBReadOnly` is the rulebook. Attaching the policy to the group means: *"Every member of Developers gets these DynamoDB read permissions."* Change the group's policy once and every member updates instantly — that's why groups beat attaching policies to users one by one.

> **Common Beginner Mistake:** Attaching policies directly to individual users. It works, but it doesn't scale — with 20 developers you'd manage 20 separate attachments. **Attach to groups; put users in groups.**

---

### Part C — Create the IAM User "dev-anaya" (~10 min)

**Goal:** Create a real human identity, give it a sign-in password (authentication), and grant permissions purely through group membership (authorization).

1. Go to **Users** (left nav) → **Create user**.
2. **User name:** `dev-anaya`.
3. Check **"Provide user access to the AWS Management Console"** (this is the authentication step — it gives the user a password to sign in).
4. A sub-section appears:
   - Choose **"I want to create an IAM user"** (as opposed to Identity Center).
   - **Console password:** choose **Autogenerated password**. AWS creates a strong random password so you never invent a weak one.
   - **Leave "Users must create a new password at next sign-in" checked.** This forces `dev-anaya` to set her own password on first login — you never learn her final password.
5. Click **Next**.
6. On **Set permissions**, keep **"Add user to group"** selected and **check the `Developers` group**. This is how Anaya gets her permissions — she inherits everything attached to `Developers`. Do **not** attach any policy directly.
7. Click **Next**, review, then **Create user**.
8. On the confirmation screen, AWS shows a **console sign-in URL**, the **username**, and the **autogenerated password** (behind a "Show" toggle). In a real job you would deliver these to Anaya over a secure channel. **Download the `.csv`** or copy them somewhere safe now — this is the **only** time the password is shown.

**Validation:** Go to **Users → dev-anaya → Permissions** tab. You should see the `Developers` group listed, and the effective policy `AcmeDynamoDBReadOnly` inherited **from group Developers**. Notice she has **no policy attached directly** — all her power flows through the group.

> **Identity-based policy defined.** The `AcmeDynamoDBReadOnly` policy is an **identity-based policy**: it is attached to an *identity* (here, indirectly via her group) and says what **that identity** can do. Contrast this with a **resource-based policy**, covered below.

> **Identity-based vs. resource-based policy.**
> - **Identity-based policy** — Attached to a **user, group, or role**. Answers: *"What can THIS identity do?"* Most IAM policies (including everything in this lab except one note) are identity-based.
> - **Resource-based policy** — Attached to a **resource** (e.g., an S3 bucket policy, an SQS queue policy, a Lambda function's resource policy). Answers: *"WHO is allowed to touch THIS resource?"* Resource-based policies can grant access to identities in **other accounts** without a role — which identity-based policies alone cannot do.
> The two are evaluated **together**. For same-account access, an `Allow` in *either* is generally enough (still subject to any explicit `Deny`).

> **Authentication vs. Authorization (in action):** The password you just created authenticates `dev-anaya` — it proves she is who she claims when she signs in. Her group membership authorizes her — it decides she may read DynamoDB and nothing else. Two separate mechanisms, two separate steps.

---

### Part D — Least Privilege and the Explicit Deny (~10 min)

**Goal:** Guarantee that even if someone later broadens Anaya's permissions, she can **never** delete a DynamoDB table. You'll do this with an **inline policy** containing an **explicit `Deny`**.

**Least privilege** means: grant only the permissions actually needed, and no more. Anaya needs to *read* the catalog. She never needs to *delete tables*. A defensive administrator blocks the dangerous action explicitly.

1. Go to **Users → dev-anaya → Permissions** tab.
2. Click **Add permissions ▾** → **Create inline policy**. (An **inline policy** is a policy embedded directly in one identity — it has no life of its own and is deleted when the identity is. Use inline policies for one-off, identity-specific rules like this guardrail.)
3. Switch to the **JSON** tab and paste:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "DenyDeleteTable",
         "Effect": "Deny",
         "Action": "dynamodb:DeleteTable",
         "Resource": "*"
       }
     ]
   }
   ```

4. Click **Next**.
5. **Policy name:** `DenyDynamoDBDeleteTable`.
6. Click **Create policy**.

**Validation:** On **dev-anaya → Permissions**, you now see two things: the inherited `AcmeDynamoDBReadOnly` (from the group) and the inline `DenyDynamoDBDeleteTable`. Anaya can read the catalog but is now *hard-blocked* from deleting any DynamoDB table. You'll prove this in Part F.

> **Explicit `Deny` always wins.** IAM's evaluation rule is absolute: **if any applicable policy contains a `Deny` for an action/resource, the request is denied — no matter how many `Allow` statements exist.** Order does not matter; a `Deny` anywhere overrides every `Allow` everywhere. This is the safest way to build guardrails: even if a future admin accidentally grants Anaya `AdministratorAccess`, this explicit `Deny` still stops table deletion.

> **Security Consideration:** Explicit `Deny` is how organizations enforce non-negotiable rules ("nobody deletes production databases," "no resources outside approved regions"). At scale these live in **Service Control Policies** at the Organization level, but the evaluation logic is identical to what you just wrote.

> **Common Beginner Mistake:** Assuming a broad `Allow` is "safe enough." Permissions creep over time. Layering an explicit `Deny` on the truly dangerous actions is cheap insurance that survives future mistakes.

---

### Part E — Create a Role for a Service (Lambda Execution Role) (~10 min)

**Goal:** Give an **application service** — AWS Lambda — permission to do its job **without any password or access key**. This is where roles shine, and where the **trust policy vs. permissions policy** distinction becomes concrete.

So far every identity has been a *person*. But Acme's code runs on **Lambda**, a service that executes your functions. Lambda itself needs permission (for example, to write logs). You never give Lambda a password. Instead, Lambda **assumes a role** you create, and AWS hands it **temporary credentials** to run with.

1. Go to **Roles** (left nav) → **Create role**.
2. **Trusted entity type:** select **AWS service**. (Your choices are: *AWS service*, *AWS account*, *Web identity*, *SAML 2.0 federation*, *Custom trust policy*. "AWS service" means "an AWS service will assume this role.")
3. Under **Use case**, choose **Lambda**, then click **Next**. This pre-writes the trust policy so that the Lambda service is allowed to assume the role.
4. On **Add permissions**, search for and **check** `AWSLambdaBasicExecutionRole`. This AWS managed policy grants the minimum a Lambda needs: permission to **create log groups/streams and write logs to CloudWatch Logs**. Click **Next**.
5. **Role name:** `AcmeLambdaExecutionRole`.
6. **Description:** `Execution role for Acme Lambda functions. Grants CloudWatch Logs write access.`
7. Click **Create role**.

#### E1. Inspect the two very different policies on this role

Open **Roles → AcmeLambdaExecutionRole**. A role has **two** kinds of policy, and confusing them is the #1 role mistake.

**(a) The Trust policy — WHO can assume the role.** Click the **Trust relationships** tab. You'll see:

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

Read it carefully:
- **`Principal`** — *Who* is allowed to assume this role. Here it's the **Lambda service** itself, identified by its service principal `lambda.amazonaws.com`. Only Lambda can step into this role.
- **`Action: "sts:AssumeRole"`** — The specific action of **assuming a role**. `sts:` means it's handled by **AWS STS (Security Token Service)**, the service that mints temporary credentials. Assuming a role literally means "call STS and ask for temporary credentials for this role."
- **`Effect: "Allow"`** — Lambda is allowed to make that assume-role call.

The trust policy is a **resource-based policy on the role**: it guards the *door* to the role.

**(b) The Permissions policy — WHAT the role can do.** Click the **Permissions** tab. You'll see `AWSLambdaBasicExecutionRole` attached, which allows `logs:CreateLogGroup`, `logs:CreateLogStream`, and `logs:PutLogEvents`. This is what the role can actually *do* once assumed.

> **AWS Mental Model — IAM user vs. IAM role.**
> - An **IAM user** is like your **personal employee badge**: it's *you*, it's long-lived, you sign in with it, and (optionally) it has long-lived access keys.
> - An **IAM role** is like a **visitor badge kept at the front desk**: nobody owns it permanently. When Lambda needs to work, it walks up to the desk, the **trust policy** checks whether Lambda is on the approved list, and if so it's handed a **temporary badge (temporary credentials)** that expires automatically. Many different callers can borrow the same role at different times.
> Rule of thumb: **people and their long-term sign-in → users; services and any short-term/temporary access → roles.**

> **Trust policy vs. permissions policy — say it out loud:**
> - **Trust policy = WHO can become this role.** (The `Principal` + `sts:AssumeRole`.)
> - **Permissions policy = WHAT this role can do.** (The `Allow` actions on resources.)
> A role needs **both** to be useful. A great permissions policy with a trust policy that trusts nobody = a role no one can use. A generous trust policy with no permissions = a role that can be assumed but can do nothing.

> **What Is Happening Behind the Scenes?** When a Lambda function using this role runs, the Lambda service calls `sts:AssumeRole` on your behalf. STS returns a bundle of **temporary security credentials** (an access key ID, a secret access key, and a session token) that are valid for a limited time. Your function code uses those automatically. Nothing is stored, nothing is embedded in your code, and when the credentials expire, new ones are fetched. You'll use this exact role in the Lambda lab.

---

### Part F — Prove It with the IAM Policy Simulator (~10 min)

**Goal:** Don't *assume* your policies are correct — **test** them. The **IAM Policy Simulator** evaluates policies against specific actions without actually performing them, so you can verify allowed/denied results safely.

1. Open the simulator at **https://policysim.aws.amazon.com/** (or from the IAM console, some views link it as **"Simulate"** on a user/role). Sign in with the same admin identity.
2. In the left panel **Users, Groups, and Roles**, select **Users**, then click **dev-anaya**. The simulator loads all of Anaya's effective policies (the group's `AcmeDynamoDBReadOnly` **and** her inline `DenyDynamoDBDeleteTable`).
3. In the center **Policy Simulator** panel:
   - **Select service:** choose **Amazon DynamoDB**.
   - **Select actions:** check **GetItem**, **Query**, **Scan**, **DescribeTable**, and **DeleteTable**.
4. Click **Run Simulation**.

**Expected results:**

| Action | Expected result | Why |
|--------|-----------------|-----|
| `GetItem` | **allowed** | Granted by `AcmeDynamoDBReadOnly` |
| `Query` | **allowed** | Granted by `AcmeDynamoDBReadOnly` |
| `Scan` | **allowed** | Granted by `AcmeDynamoDBReadOnly` |
| `DescribeTable` | **allowed** | Granted by `AcmeDynamoDBReadOnly` |
| `DeleteTable` | **denied** | Blocked by the explicit `Deny` in `DenyDynamoDBDeleteTable` |

5. Click the **denied** result for `DeleteTable`. The simulator shows **which statement caused the deny** — you'll see it points to your explicit `Deny`. This is exactly the "explicit Deny wins" rule made visible.

**Validation:** If your five read actions show **allowed** and `DeleteTable` shows **denied**, your identity design is provably correct. If `DeleteTable` shows *allowed*, re-check that the inline `Deny` policy from Part D is actually attached to `dev-anaya`.

> **Why This Matters:** The Policy Simulator is your safety net. Before you ever tell a teammate "you can do X," you can prove it. In real incidents, "did the policy actually deny that?" is answered here in seconds instead of by risky trial-and-error in production.

> **Assessment Connection:** The microcredential assessment expects you to (1) distinguish authentication from authorization, (2) explain that explicit `Deny` overrides `Allow`, (3) distinguish a role's trust policy from its permissions policy, and (4) apply least privilege. Every one of those was demonstrated in Parts A–F. Being able to *show* the denied result in the simulator is exactly the kind of evidence that distinguishes "I read about IAM" from "I can operate IAM."

---

### Part G — Insight: Temporary Credentials, STS, and Why Roles Beat Access Keys (~5 min)

There's nothing to click here — this is the *insight* that ties the lab together.

An **IAM user access key** is a **long-lived** credential: an access key ID and secret access key that stay valid until someone manually rotates or deletes them. If one leaks — committed to GitHub, pasted in a ticket, stolen from a laptop — it works for the attacker **indefinitely**, and often nobody notices for weeks.

A **role** works completely differently. When something assumes a role, **AWS STS (Security Token Service)** issues **temporary credentials** that:

- **Expire automatically** (commonly in 1 hour, up to a configurable maximum). A leaked temporary credential is worthless soon after.
- **Are never stored** in your code or config. The service fetches fresh ones as needed.
- **Are tightly scoped** to exactly the role's permissions.

That's why the AWS best practice is blunt: **prefer roles over long-lived access keys everywhere you can.**

- A **person** signing into the console? Authenticate as an IAM (or Identity Center) user, ideally with **MFA**.
- **Code on Lambda / EC2 / ECS**? Give it a **role** — never embedded access keys.
- **A CI/CD pipeline or another AWS account** needing access? Have it **assume a role** rather than handing it standing keys.

> **Key Takeaway (Part G):** Roles turn "a permanent secret that can leak forever" into "a temporary badge that expires on its own." Every service you build in the rest of this course will get a **role**, not an access key. That single habit eliminates the most common and most damaging cloud security failure.

> **Cost Awareness:** IAM users, groups, roles, and policies are **completely free** — you can create as many as you need at no charge. STS temporary credentials are free too. There is no cost reason to skimp on good identity hygiene.

---

## Key Takeaways

- **IAM answers one question for every AWS call:** *is this identity allowed to do this action on this resource?*
- **Authentication (who you are) and authorization (what you may do) are separate steps.** A valid password grants access to nothing without a policy.
- **Users are for people; roles are for services and temporary access.** Roles have no passwords or long-lived keys — they're assumed via STS.
- **Attach policies to groups, put users in groups.** It scales; per-user attachment doesn't.
- **A policy is JSON:** `Version`, then `Statement`s, each with `Effect` (`Allow`/`Deny`), `Action`, and `Resource`.
- **Explicit `Deny` always wins** over any `Allow`, anywhere — the foundation of guardrails.
- **A role has two policies:** the **trust policy** (WHO can assume it) and the **permissions policy** (WHAT it can do). It needs both.
- **Identity-based policies** attach to identities; **resource-based policies** attach to resources and can grant cross-account access.
- **Least privilege + the Policy Simulator** let you grant exactly what's needed and *prove* it before anyone depends on it.
- **Roles/STS temporary credentials beat long-lived access keys** because they expire automatically and are never stored.

---

## Cleanup Instructions

IAM resources are **free**, so cleanup here is about **hygiene and least clutter**, not cost. Remove what you created for this lab, in this order (delete dependents before the things they depend on). **Do not delete your own admin identity** — you need it to keep working.

1. **Delete the inline policy on dev-anaya** — Go to **Users → dev-anaya → Permissions**, find `DenyDynamoDBDeleteTable`, click **Remove** on that inline policy (or simply delete the user in the next step, which removes inline policies automatically).
2. **Delete the user `dev-anaya`** — **Users** → select `dev-anaya` → **Delete** → type the username to confirm.
3. **Delete the `Developers` group** — **User groups** → select `Developers` → **Delete**. (A group must be empty of users first; deleting `dev-anaya` already handled that.)
4. **Delete the customer managed policy `AcmeDynamoDBReadOnly`** — **Policies** → search `AcmeDynamoDBReadOnly` → select it → **Actions ▾ → Delete**. (A managed policy can't be deleted while still attached; removing the group in the previous step detaches it.)
5. **Delete the role `AcmeLambdaExecutionRole`** — **only if you will not reuse it.** If you plan to do the Lambda lab next, **keep it** — you'll use it there. Otherwise: **Roles** → search `AcmeLambdaExecutionRole` → select → **Delete**.

> **Security Consideration:** Never delete the identity you are currently signed in with, and never remove access that would lock you out of the account. If you ever must remove an admin, create and verify a replacement admin first.

---

## Early-Finisher Challenge

Acme's **auditors** need to read **only one specific table** — the `Products` catalog table — and **nothing else**, and only from the `us-east-1` region. Build a tightly-scoped, resource-specific policy and attach it to a brand-new group.

**Your task:**

1. Create a **customer managed policy** named `AcmeAuditorsProductsReadOnly` that:
   - Allows only **read** actions: `dynamodb:GetItem`, `dynamodb:Query`, `dynamodb:Scan`, `dynamodb:DescribeTable`, `dynamodb:BatchGetItem`.
   - Applies **only** to a single table named `Products` via a specific **Resource ARN** (not `*`).
   - Includes a **`Condition`** block that only permits the action when the request region is `us-east-1`.
2. Create a **user group** named `Auditors` and attach the policy.
3. **Validate** with the Policy Simulator that the group can `GetItem` on the `Products` table but is denied on a different table.
4. **Clean up** the policy and group.

Use your own account ID (a 12-digit number, visible in the top-right account menu). Assume the region is `us-east-1`.

---

## Challenge Solution

### Step 1 — Create the resource-scoped, conditional policy

1. **IAM → Policies → Create policy → JSON** tab.
2. Paste the following, **replacing `123456789012` with your real 12-digit AWS account ID**:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "ReadOnlyProductsTableUsEast1",
         "Effect": "Allow",
         "Action": [
           "dynamodb:BatchGetItem",
           "dynamodb:DescribeTable",
           "dynamodb:GetItem",
           "dynamodb:Query",
           "dynamodb:Scan"
         ],
         "Resource": "arn:aws:dynamodb:us-east-1:123456789012:table/Products",
         "Condition": {
           "StringEquals": {
             "aws:RequestedRegion": "us-east-1"
           }
         }
       }
     ]
   }
   ```

3. Click **Next**. **Policy name:** `AcmeAuditorsProductsReadOnly`. **Description:** `Read-only access to only the Products table, only in us-east-1.` Click **Create policy**.

### Step 2 — Create the Auditors group and attach the policy

1. **IAM → User groups → Create group.**
2. **User group name:** `Auditors`.
3. Under **Attach permissions policies**, search `AcmeAuditorsProductsReadOnly` and check it.
4. Click **Create group**.

### Why it works — element by element

- **`Resource: "arn:aws:dynamodb:us-east-1:123456789012:table/Products"`** — This is a specific **ARN (Amazon Resource Name)**, not `*`. It names exactly one table:
  - `arn:aws` — standard ARN prefix (partition).
  - `dynamodb` — the service.
  - `us-east-1` — the region.
  - `123456789012` — your account ID.
  - `table/Products` — the resource type and name.
  Because the resource is pinned to `Products`, the same actions on any **other** table simply don't match this statement, so they fall through to the default **implicit deny**.
- **`Condition` with `StringEquals` on `aws:RequestedRegion`** — Even the allowed actions on `Products` are only permitted when the request targets **`us-east-1`**. `aws:RequestedRegion` is a **global condition key** AWS provides on every request. If a request came in for another region, the `StringEquals` check fails, the `Allow` doesn't apply, and the request is denied. This enforces "read this one table, in this one region, and nowhere else."
- **Least privilege in action:** narrow **actions** (read-only) × narrow **resource** (one table) × narrow **condition** (one region) = the smallest useful permission set.

### Step 3 — Validate with the Policy Simulator

1. Open **https://policysim.aws.amazon.com/**.
2. In the left panel select **Groups → Auditors** (or, to simulate a user, first add a test user to the group and select that user).
3. Center panel: **Select service → Amazon DynamoDB**, **Select actions → GetItem**.
4. Expand **Simulation Settings** and set the **Resource ARN** to your `Products` table:
   `arn:aws:dynamodb:us-east-1:123456789012:table/Products`. Click **Run Simulation** → **GetItem** should show **allowed**.
5. Now change the **Resource ARN** to a *different* table, e.g.
   `arn:aws:dynamodb:us-east-1:123456789012:table/Orders`, and **Run Simulation** again → **GetItem** should show **denied** (the ARN no longer matches the statement's `Resource`).
6. (Optional) Set a **global condition** in Simulation Settings for `aws:RequestedRegion` to `us-west-2` while keeping the `Products` ARN — **GetItem** should now show **denied**, proving the `Condition` works.

### Step 4 — Cleanup

1. **User groups → Auditors → Delete** (remove any test users first).
2. **Policies → `AcmeAuditorsProductsReadOnly` → Actions ▾ → Delete** (it detaches automatically once the group is gone).

> **Key Takeaway (Challenge):** The most secure real-world policies combine **specific actions**, **specific resource ARNs**, and **conditions** — and you can prove all three with the Policy Simulator before anyone relies on them. This exact pattern (scope by action, by resource ARN, by condition) is how you'll write permissions for Lambda, S3, and every other service in this course.
