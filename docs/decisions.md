# Design decisions

This is a running log of the bigger choices in this project and why I made them. Each entry is short: what the situation was, what I picked, what else I considered, and what it costs me.

If I change my mind later, I'll add a new entry rather than rewrite an old one. The old reasoning is still useful to see.

**Status:** *Accepted* means it's in place. *Proposed* means it's the plan, but not built yet.

---

## 001. Use both Databricks and Snowflake

**Status:** Accepted

**Context.** The pipeline needs heavy Python/Spark work: merging change records into ~30M rows, fuzzy address matching and training a model. It also needs a clean, well-tested SQL model that a dashboard and analysts can query. Either platform could do all of it on its own.

**Decision.** Databricks owns the engineering side (bronze, silver, ML). Snowflake owns the analytics side (dbt models, marts, the dashboard). Silver is handed over as Parquet in S3.

**Alternatives.**
- *Databricks only, with dbt on Databricks SQL.* Simpler, with one platform and one bill. This is probably what I'd choose for a small team in real life.
- *Snowflake only, with Snowpark for the Python parts.* Possible, but Spark and MLflow on Databricks are the more common setup for this kind of work.

**Consequences.** There are two platforms to set up, secure and pay for, and a hand-off between them that can break. That hand-off is also the interesting part. Plenty of companies run exactly this split, and getting the boundary right (file format, schema contract, load timing) is a real skill.

---

## 002. Keep raw files exactly as downloaded

**Status:** Proposed

**Context.** Land Registry, ONS and EPC files are the only copy of the source as it looked at load time. Land Registry in particular only publishes the *latest* monthly update file, so past months can't be downloaded again later.

**Decision.** Land every file in S3 byte-for-byte, under `raw/<source>/load_month=YYYY-MM/`. No cleaning, no conversion, no compression. All cleaning happens downstream in Databricks.

**Alternatives.** Convert to Parquet on the way in. That would make files smaller and faster to read, but if the conversion has a bug, the original is gone.

**Consequences.** Raw storage is larger than it needs to be. A lifecycle rule moves old files to Standard-IA after 30 days and Glacier Instant Retrieval after 180 days, which keeps the cost to pennies (see 011). In return, any later stage can be rebuilt from scratch.

---

## 003. Idempotent loads with a manifest written last

**Status:** Proposed

**Context.** Monthly runs will sometimes fail halfway, or get re-run by hand. A re-run must never create duplicates or leave a half-written month that looks complete.

**Decision.** Each load works on one partition. It deletes everything under the partition's prefix, uploads the new files, and writes `_manifest.json` at the very end. The manifest holds the source URL, ETag, Last-Modified, row count and a SHA-256. Downstream jobs only read partitions that have a manifest. Before downloading, the loader compares the remote ETag with the manifest and skips the load if nothing has changed.

**Alternatives.**
- *Append with a unique filename per run.* Easy, but you get duplicates as soon as something re-runs.
- *Write to a temporary prefix and then swap it in.* S3 has no atomic rename, so this ends up much the same, just with more steps.

**Consequences.** If a run dies mid-upload, there's a short window where a partition is partly written. That's safe because it has no manifest yet, so nothing downstream reads it, and the next run cleans it up.

---

## 004. Backfill from the yearly files, not the monthly file

**Status:** Proposed

**Context.** The full history starts in 1995. The monthly update file only covers the most recent month and is replaced every month.

**Decision.** The one-off backfill loads Land Registry's yearly files (`pp-1995.csv` … `pp-<this year>.csv`) into `raw/land_registry_history/year=YYYY/`. After that, the monthly DAG only loads the update file.

**Alternatives.** Load the single `pp-complete.csv` (~5 GB). That's one file, but it's slow to re-run, and one failure means starting over.

**Consequences.** There are two raw layouts to read in bronze (history and monthly). Each year can be re-run independently, and a failed backfill only has to redo the year that failed.

---

## 005. A separate Airflow home for this project

**Status:** Accepted

**Context.** I already run Airflow locally for another project (TfL). Pointing that instance at this repo would mix the two projects' connections, variables, run history and DAGs.

**Decision.** This project has its own venv (`.venv` in the repo, with Airflow pinned to the official constraints file) and its own `AIRFLOW_HOME` (`~/airflow-uk-property`) with its own `airflow.cfg`, SQLite database and logs. Nothing is shared with the TfL setup, so upgrading a package here can't break that project. It runs on port 8082 (TfL uses 8081), so both instances can run at the same time. `make airflow` starts it with the right settings and clears any `AIRFLOW__*` variables inherited from the shell, because my `~/.bashrc` exports TfL settings that would otherwise override this project's `airflow.cfg`.

**Alternatives.**
- *One instance with two DAG bundles.* Airflow 3 supports this, but the database and connections are still shared.
- *Docker Compose per project.* The cleanest isolation, but heavier on my machine for no real benefit right now.

**Consequences.** It's easy to run an `airflow` command against the wrong instance if `AIRFLOW_HOME` is set in an old terminal. The Makefile target exists to avoid that. SQLite also limits how many tasks can run at once. If that becomes a problem, I'll move to Postgres.

---

## 006. Terraform runs with short-lived console credentials

**Status:** Accepted

**Context.** Terraform needs strong AWS permissions to create buckets and IAM. The usual quick fix is an admin IAM user with a long-lived access key sitting in `~/.aws/credentials`.

**Decision.** Locally, Terraform uses `aws login --profile terraform-admin`, which gives short-lived credentials from a console sign-in. No admin access key exists. In CI (Phase 10), GitHub Actions will assume a role through OIDC instead.

**Alternatives.** An admin user with an access key. It's simpler, but the key never expires, and if it leaks, someone has full control of the account.

**Consequences.** I have to sign in again when the session expires. That's fine for something I run a few times a week.

---

## 007. Terraform never creates access keys

**Status:** Accepted

**Context.** The pipeline user (`uk-property-pipeline`) needs an access key so local Airflow can write to S3. Terraform can create one with `aws_iam_access_key`.

**Decision.** Terraform creates the user and its policy, but not the key. I create the key by hand with the AWS CLI and keep it in the `uk-property` CLI profile and the Airflow connection.

**Alternatives.** Create the key in Terraform and output it. The problem is that the secret is then stored in plain text in the Terraform state file.

**Consequences.** There's one manual step after `terraform apply`, and rotating the key is manual too. I accept that to keep secrets out of state.

---

## 008. Least-privilege IAM for the pipeline

**Status:** Accepted (see 012 for how it's enforced)

**Context.** The pipeline only ever needs to read, write and delete objects in one bucket.

**Decision.** The pipeline user gets one inline policy: `s3:ListBucket` on the raw bucket, plus `GetObject`, `PutObject` and `DeleteObject` on objects inside it. Nothing else. The policy is written in Terraform and refers to the bucket's ARN, so the bucket name is never typed in by hand.

**Alternatives.** `AmazonS3FullAccess`. It's quicker, but it gives access to every bucket in the account, including other projects' buckets.

**Consequences.** Adding a new bucket later (for example a Parquet export bucket for Snowflake) needs a policy change. That's the point: every new permission shows up in a pull request.

One detail is easy to get wrong. S3 has two kinds of resource: the bucket (`arn:aws:s3:::name`) and the objects in it (`arn:aws:s3:::name/*`). `ListBucket` only applies to the bucket, and `Get/Put/DeleteObject` only apply to objects. My first draft gave the object actions to the bucket ARN. The plan looked fine and Terraform applied nothing wrong, but every upload would have failed with `AccessDenied` at runtime. So the policy has one statement per resource type.

---

## 009. Run everything in eu-north-1 (Stockholm)

**Status:** Accepted

**Context.** I planned to use `eu-west-2` (London), since the data is about UK property. The first `terraform apply` failed with `AccessDenied ... explicit deny in a service control policy`. My AWS account sits inside an AWS Organization, and its service control policy only allows resources in the account's home region, `eu-north-1`. An SCP can't be overridden from inside the account, not even by a full-access role.

**Decision.** Every AWS resource in this project lives in `eu-north-1`: the Terraform state bucket, the raw bucket, and anything added later. The region is set in one place per stack (the provider and the backend), and in `AWS_DEFAULT_REGION` for the Python code.

**Alternatives.**
- *Ask for the SCP to allow `eu-west-2`.* That's not in my control, and it isn't worth it for a portfolio project.
- *Use a separate AWS account without the restriction.* Possible, but it would mean managing another account and set of credentials for no real gain.

**Consequences.**
- The data still stays in the EU, and latency from the UK is fine for a monthly batch pipeline.
- The other platforms need to match. The Snowflake account (Phase 6) should be on AWS `eu-north-1`, so loading from S3 stays inside one region with no cross-region transfer charges. The same goes for Databricks, if a workspace region can be chosen.
- `aws login` also has to go through `eu-north-1` (`aws login --region eu-north-1`), even though credentials work in any region.
- If the account ever moves out of the organization, switching region means re-creating the buckets. Raw data can be copied across, and everything downstream can be rebuilt from raw (see 002).

---

## 010. S3 native state locking instead of DynamoDB

**Status:** Accepted

**Context.** Terraform state needs a lock, so that two `apply` runs (for example me locally and CI later) can't write the state at the same time and corrupt it. For years the standard answer on AWS was an S3 bucket for the state plus a DynamoDB table for the lock.

**Decision.** The S3 backend uses `use_lockfile = true` (Terraform 1.10+). Terraform writes a small `main.tfstate.tflock` object next to the state file while it runs and deletes it when it finishes. There's no DynamoDB table. Both stacks require Terraform `>= 1.10`.

**Alternatives.**
- *DynamoDB locking.* It still works, but HashiCorp has deprecated it in favour of the S3 lock file. It's one more resource to create, secure and pay for.
- *No locking.* Fine for one person on one laptop, until CI starts running Terraform too.

**Consequences.** It's one less moving part, and the state bucket is the only bootstrap resource. I saw it work on the first apply: the `.tflock` object appeared during the run and disappeared afterwards. If a run is killed mid-apply, the lock can be left behind. In that case I clear it with `terraform force-unlock <id>`, after making sure nothing else is running.

---

## 011. Raw bucket: versioning, 30-day old versions, Glacier Instant Retrieval

**Status:** Accepted

**Context.** Raw files are the permanent source of truth (002), and loads are idempotent: a re-run deletes and rewrites a month (003). Two risks follow from that. A buggy re-run could overwrite a good month with a bad one, and storage for ~30 years of files grows forever. My first lifecycle draft also had `expiration { days = 365 }`, which would have permanently deleted the backfill after a year. Land Registry only publishes the latest monthly file, so that data couldn't be downloaded again.

**Decision.**
- **Versioning on.** An overwritten or deleted file becomes a "noncurrent" version instead of disappearing.
- **Noncurrent versions expire after 30 days.** That gives a month to notice a bad load and roll back, without paying to keep every re-run forever.
- **Current files are never expired.** They only move to cheaper storage: Standard-IA after 30 days, then **Glacier Instant Retrieval** after 180 days (prefix `raw/`).
- **Incomplete multipart uploads are aborted after 7 days**, so a failed 5 GB backfill upload doesn't leave hidden, billable parts behind.

**Alternatives.**
- *Glacier Flexible Retrieval.* It's cheaper per GB, but objects can't be read until they're restored, which takes hours. Databricks would fail when reprocessing old months. Glacier IR costs a little more and can be read instantly.
- *No versioning.* It's simpler and cheaper, but there's no way back from a bad overwrite.
- *Expiring raw files.* This is ruled out by 002, because the data can't be downloaded again.

**Consequences.** Each re-run of a month briefly doubles the storage for that month, until the old version expires after 30 days. Standard-IA and Glacier IR have minimum storage periods (30 and 90 days) and per-GB retrieval fees, which are fine for data that is mostly written once and read rarely. Reading the whole history often, for example rebuilding bronze every week, would make retrieval fees noticeable. Bronze is built incrementally, so that shouldn't happen.

---

## 012. Terraform is the only source of truth for the pipeline user's permissions

**Status:** Accepted

**Context.** The `uk-property-pipeline` user was first created by hand in the console, then imported into Terraform with an `import` block. After applying the least-privilege policy (008), I tested it with the user's own key: listing the raw bucket should work, and listing the Terraform state bucket should fail. The state bucket was readable. The user still had `AdministratorAccess` attached from when I created it by hand.

Terraform hadn't removed it, because Terraform only manages what's in the code. The code declared an inline policy and said nothing about attached managed policies, so Terraform left them alone. Importing a resource doesn't clean up what's already attached to it.

**Decision.**
- I detached `AdministratorAccess` straight away and re-ran the tests. The raw bucket was still readable and writable, and the state bucket now returned `AccessDenied`.
- To stop it happening again, `iam.tf` uses two "exclusive" resources:
  - `aws_iam_user_policy_attachments_exclusive` with `policy_arns = []`: the user may have **no** managed policies.
  - `aws_iam_user_policies_exclusive` listing only `raw-bucket-access`: no other inline policies.
- If anyone attaches a policy by hand, the next `terraform plan` shows the drift and `apply` removes it.

**Alternatives.**
- *Just detach it and move on.* This fixes today's problem, but nothing stops it coming back silently.
- *An IAM permissions boundary.* It caps what the user can ever do, even if an admin policy is attached. It's stronger, but it's one more policy to maintain, and it doesn't make the drift visible. It might be worth adding later if more users or roles appear.
- *An AWS Config rule to detect admin policies on users.* This is the right tool across a whole organisation, but too heavy for one project.

**Consequences.**
- Permissions can only change through a pull request to `iam.tf`. A console change is undone on the next apply, which is the intended behaviour.
- **Lesson for every future import:** after importing anything, check what's attached to it that the code doesn't describe, and test permissions with the real credentials. A clean `terraform plan` only proves the code matches the parts of AWS that the code mentions.
- The pipeline's access key had admin rights for a few minutes before the fix. It only ever existed on my machine, so I didn't rotate it.
