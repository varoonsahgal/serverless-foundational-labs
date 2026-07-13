# Lab 11: Automated Deployment with AWS CodePipeline

## Estimated Duration

~45 minutes

## Scenario / Business Context

**Acme Retail** has been deploying application updates by hand: an engineer copies files onto production and hopes nothing breaks. Twice this quarter a bad manual change took the store offline. The engineering lead wants a **repeatable, controlled pipeline**: every change flows through the same automated path, and a human must **explicitly approve** before anything reaches the build/deploy step.

In this lab you build a minimal **CI/CD (Continuous Integration / Continuous Delivery)** pipeline with **AWS CodePipeline** that pulls source from Amazon S3, pauses for a **manual approval**, and then runs a build with **AWS CodeBuild**.

## Learning Objectives

By the end of this exercise you will be able to:

- Explain the difference between a **pipeline**, a **stage**, and an **action**.
- Understand that CodePipeline **orchestrates** but does not itself compile or test code.
- Create a versioned S3 source and understand **why versioning is required**.
- Add a **manual approval** stage as a control gate.
- Create a minimal **CodeBuild** project driven by a `buildspec.yml`.
- Understand **artifacts** and the **artifact store**, and the role of a **service role**.

## AWS Services Used

- AWS CodePipeline
- AWS CodeBuild
- Amazon S3 (source + artifact storage)
- Amazon SNS (optional, for the early-finisher challenge)
- AWS IAM (auto-created service roles)

## Prerequisites

- An AWS account.
- Sign in as an **IAM user** (or IAM Identity Center user) with permissions for CodePipeline, CodeBuild, S3, and IAM. **Do not use the root user.**
- Region: **us-east-1** (N. Virginia).
- **Lab-specific:** ability to create a small `.zip` on your machine (any OS zip tool works). No GitHub account needed — we use S3 as the source.

---

## Part 1 — Create the Source in S3

CodePipeline needs somewhere to fetch source code. We'll use an S3 bucket holding a `source.zip`.

1. In the Console, open **S3**. Confirm the region is **us-east-1**.
2. Choose **Create bucket**.
   - Bucket name: `acme-pipeline-src-<yourinitials>` (for example `acme-pipeline-src-jsmith`).
     - **Bucket names are globally unique** across *all* AWS accounts worldwide, not just yours — that's why you add initials. If the name is taken, pick another suffix.
   - Region: **US East (N. Virginia) us-east-1**.
   - **Bucket Versioning: Enable.**
     - **Why it matters:** an S3 **source action requires versioning**. CodePipeline detects a new deployment by watching for a new **object version** of your source file. Without versioning, the pipeline has no reliable way to know the source changed.
   - Leave other defaults (Block Public Access **on**). Choose **Create bucket**.

3. **Build the source.zip locally.** Create a folder with two files.

   `buildspec.yml` (must be at the **root** of the zip):

   ```yaml
   version: 0.2

   phases:
     install:
       commands:
         - echo "Install phase - nothing to install for this demo"
     pre_build:
       commands:
         - echo "Pre-build phase - preparing"
     build:
       commands:
         - echo "Build phase - Acme app build starting"
         - echo "Compiling... (simulated)"
         - cat app.txt
     post_build:
       commands:
         - echo "Post-build phase - Acme build complete!"

   artifacts:
     files:
       - app.txt
   ```

   `app.txt`:

   ```text
   Acme Retail sample application v1.0
   ```

4. **Zip these two files** so that `buildspec.yml` and `app.txt` are at the **top level** of the archive (not inside a subfolder).
   - macOS/Linux: `cd` into the folder and run `zip source.zip buildspec.yml app.txt`
   - Windows: select both files, right-click > **Send to > Compressed (zipped) folder**, and rename to `source.zip`.
   - **Common layout mistake:** if you zip the *folder* instead of the *files*, `buildspec.yml` ends up at `myfolder/buildspec.yml` and CodeBuild won't find it. It must be at the zip root.
5. In your S3 bucket, choose **Upload** > **Add files** > select `source.zip` > **Upload**.

---

## Part 2 — Create the Pipeline

1. Open **CodePipeline** in the Console (region us-east-1). Choose **Create pipeline**.
2. **Step 1 — Choose creation option:** choose **Build custom pipeline**. Choose **Next**.
3. **Step 2 — Pipeline settings:**
   - Pipeline name: `acme-pipeline`.
   - **Pipeline type:** choose **V2** (the current default).
     - **What it does:** V2 supports richer features (triggers, variables). Unlike the older **V1** type (which charged a flat fee per active pipeline per month), **V2 is billed per action execution minute** — you pay only for the actions that actually run.
   - **Service role:** choose **New service role**. Leave "Allow AWS CodePipeline to create a service role" checked.
     - **What a service role is:** an IAM role that CodePipeline **assumes** to act on your behalf — reading from S3, starting CodeBuild, writing artifacts. The pipeline itself has no permissions; the role grants them. This is how AWS services call other services securely without you embedding credentials.
   - Expand **Advanced settings**. **Artifact store:** leave **Default location** (CodePipeline creates/uses a managed S3 bucket in this region).
     - **What the artifact store is:** the S3 bucket where CodePipeline hands the output of one stage to the input of the next.
   - Choose **Next**.
4. **Step 3 — Add source stage:**
   - Source provider: **Amazon S3**.
   - Bucket: select `acme-pipeline-src-<yourinitials>`.
   - S3 object key: `source.zip`.
   - **Change detection options:** choose **Amazon CloudWatch Events** (recommended) — an EventBridge rule fires the pipeline automatically when a new version of `source.zip` is uploaded. *(The alternative, periodic checks, polls on a schedule.)*
   - Choose **Next**.
5. **Step 4 — Add build stage:**
   - Build provider: **AWS CodeBuild**.
   - Region: **US East (N. Virginia)**.
   - Project name: choose **Create project** (opens a sub-window).
     - Project name: `acme-build`.
     - Environment > **Provisioning model:** On-demand. **Environment image:** Managed image. **Operating system:** Amazon Linux. **Runtime:** Standard. **Image:** choose the latest `aws/codebuild/amazonlinux` standard image offered. **Image version:** latest.
     - **Service role:** New service role (CodeBuild also needs its own role to write logs and read artifacts).
     - **Buildspec:** choose **Use a buildspec file** (this uses the `buildspec.yml` at the root of the source). Do **not** paste inline.
     - Choose **Continue to CodePipeline**.
   - Back in the pipeline wizard, `acme-build` is now selected. Choose **Next**.
     - **buildspec.yml phases (high level):** `install` (set up tools/runtimes), `pre_build` (login, prep), `build` (the actual work), `post_build` (package/publish). `artifacts` declares which files to hand to the next stage.
6. **Step 5 — Add deploy stage:** choose **Skip deploy stage** and confirm. *(For this lab, the CodeBuild step demonstrates the concept; a real pipeline would add a deploy provider here.)*
7. **Review** and choose **Create pipeline**.

CodePipeline immediately runs a first execution using the current `source.zip`. **But we still need the approval gate**, so let's add it before relying on the pipeline.

---

## Part 3 — Add a Manual Approval Stage

1. Open `acme-pipeline` and choose **Edit**.
2. Between the **Source** and **Build** stages, choose **Add stage**.
   - Stage name: `Approval`. Choose **Add stage**.
3. Inside the new `Approval` stage choose **Add action group** > **Add action**.
   - Action name: `ManualApproval`.
   - Action provider: **Manual approval**.
   - (Optional) SNS topic / comments — leave blank for now (covered in the challenge).
   - Choose **Done**.
     - **What a manual approval action does:** it **pauses** the pipeline indefinitely until a human clicks **Approve** or **Reject**. This is your control gate — nothing proceeds to Build until someone signs off.
4. Choose **Save** on the pipeline edit screen. Confirm.

Your pipeline is now: **Source (S3) → Approval (manual) → Build (CodeBuild)**.

---

## Part 4 — Run and Validate

1. Trigger an execution. Either:
   - Re-upload `source.zip` to the bucket (creates a new version → CloudWatch Event fires the pipeline), **or**
   - On the pipeline page choose **Release change**.
2. Watch the stages:
   - **Source:** turns green — **Succeeded**. It downloaded `source.zip` and placed it in the artifact store.
   - **Approval:** turns blue/yellow — **In progress / pending**. The pipeline is now paused.
3. In the `Approval` stage choose **Review** > **Approve**, add an optional comment, and confirm.
4. **Build:** now runs. Wait for it to turn green — **Succeeded**.
5. **Validate the build output.** In the Build stage choose **Details** (or open CodeBuild > `acme-build` > latest build > **Build logs**). **Expected log lines** include:
   ```
   Build phase - Acme app build starting
   Compiling... (simulated)
   Acme Retail sample application v1.0
   Post-build phase - Acme build complete!
   ```
   Seeing `Acme Retail sample application v1.0` proves CodeBuild read `app.txt` from your source, confirming the artifact flowed Source → Build.

> **What Is Happening Behind the Scenes?** When Source succeeds, CodePipeline zips the source output and stores it as an **input artifact** in the artifact S3 bucket. The Build stage downloads that artifact into the CodeBuild container, runs `buildspec.yml`, and (per the `artifacts` section) can hand `app.txt` onward as an **output artifact**. Stages never talk directly — they pass work through the artifact store.

---

## Concept Callouts

**AWS Mental Model:** A pipeline is an **assembly line**. Each **stage** is a station on the line (Source, Approval, Build). Each **action** is a specific task performed at a station. The product (your code, as an artifact) moves from station to station; a supervisor (manual approval) can halt the line before the next station.

**pipeline vs stage vs action:**
- A **pipeline** is the whole automated workflow (`acme-pipeline`).
- A **stage** is a phase of that workflow (`Source`, `Approval`, `Build`). Stages run in sequence.
- An **action** is a single unit of work inside a stage (the S3 source fetch, the manual approval, the CodeBuild run). A stage can hold multiple actions.

**Common Beginner Mistake:**
- Believing **CodePipeline compiles or tests code itself.** It does not — it **orchestrates**. The actual building/testing is done by **CodeBuild**; deploying is done by deploy providers (CodeDeploy, ECS, S3, etc.). CodePipeline just moves artifacts between them and enforces order.
- **Forgetting to enable S3 versioning** — an S3 source silently fails or won't trigger without it.
- **Wrong `source.zip` layout** — `buildspec.yml` must be at the zip **root**, or CodeBuild reports it can't find the buildspec.

**Cost Awareness:** **This lab creates several billable resources.** CodePipeline **V2** bills **per action execution minute** — you pay for the pipeline actions that run, not a flat monthly per-pipeline fee (that flat model is the older **V1** type). **CodeBuild** bills **per build minute** by compute type. **S3** bills for stored objects (your source bucket *and* the auto-created artifact bucket). Costs here are small but **not zero** — **delete the pipeline, the CodeBuild project, and both S3 buckets** when done.

**Security Consideration:** The auto-created **service roles** follow the principle of least privilege for their job, but review them in production — an over-permissioned pipeline role is a real risk because it can touch many services. The **manual approval** stage is itself a security/quality control: it forces human sign-off, preventing an unreviewed change from reaching build/deploy automatically.

---

## Key Takeaways

- **CodePipeline orchestrates**; **CodeBuild builds**; deploy providers deploy. Know which does what.
- **Pipeline → Stage → Action** is the core hierarchy.
- An **S3 source requires versioning** so CodePipeline can detect new source.
- **Artifacts** move between stages through an **artifact store** (S3), never directly.
- A **manual approval** stage is a human control gate that pauses execution.
- **Service roles** let CodePipeline/CodeBuild act on your behalf without embedded credentials.
- CodePipeline V2 and CodeBuild both **cost money** — clean up.

---

## Cleanup Instructions

1. **Delete the pipeline:** CodePipeline > `acme-pipeline` > **Delete pipeline** (or **Settings** > **Delete**). Type the confirmation.
2. **Delete the CodeBuild project:** CodeBuild > **Build projects** > select `acme-build` > **Delete**.
3. **Empty then delete the source bucket:** S3 > `acme-pipeline-src-<yourinitials>` > **Empty** (type confirmation) > then **Delete**.
4. **Empty then delete the artifact bucket:** S3 > find the auto-created bucket named like `codepipeline-us-east-1-xxxxxxxx` > **Empty** > **Delete**.
5. **(If you did the challenge) delete the SNS topic:** SNS > **Topics** > select `acme-approval-notify` > **Delete**; also remove the subscription.
6. **Delete the auto-created service roles (optional but tidy):** IAM > **Roles** > search for roles named like `AWSCodePipelineServiceRole-us-east-1-acme-pipeline` and `codebuild-acme-build-service-role` > **Delete** each. *(Deleting roles has no cost impact but keeps the account clean.)*

---

## Early-Finisher Challenge

Add an **SNS (Simple Notification Service) email notification** to the manual approval action so that approvers receive an **email containing the approval link** whenever the pipeline pauses for sign-off. Validate that the email arrives, then clean up.

---

## Challenge Solution

1. **Create the SNS topic.**
   - Open **SNS** (region us-east-1) > **Topics** > **Create topic**.
   - Type: **Standard**. Name: `acme-approval-notify`. Choose **Create topic**.
2. **Subscribe your email.**
   - On the topic page choose **Create subscription**.
   - Protocol: **Email**. Endpoint: your email address. Choose **Create subscription**.
   - **Confirm it:** open the "AWS Notification - Subscription Confirmation" email and click **Confirm subscription**. The subscription status must read **Confirmed** (not "PendingConfirmation") or emails won't send.
3. **Attach the topic to the approval action.**
   - CodePipeline > `acme-pipeline` > **Edit** > edit the `Approval` stage > edit the `ManualApproval` action.
   - **SNS topic ARN:** select `acme-approval-notify`.
     - This may prompt that the pipeline **service role** needs `sns:Publish` permission on the topic; allow the console to update it, or add it manually.
   - (Optional) add a URL/comments for the reviewer. Choose **Done** > **Save**.
4. **Trigger and validate.**
   - Choose **Release change** (or re-upload `source.zip`).
   - When the pipeline reaches **Approval**, check your inbox. **Expected:** an email from AWS CodePipeline with the pipeline name and an **approval review link**. Clicking it takes you to the approve/reject screen.
   - Approve to let the pipeline continue to Build.
5. **Cleanup the challenge.**
   - Detach the topic (edit the approval action, clear the SNS topic, Save) — optional if you're deleting the whole pipeline anyway.
   - SNS > `acme-approval-notify` > delete the **subscription**, then **Delete** the topic.
   - Then complete the main **Cleanup Instructions** above.
