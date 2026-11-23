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

**Consequences.** Raw storage is larger than it needs to be. A lifecycle rule moves old files to Standard-IA after 30 days and Glacier after 180 days, which keeps the cost to pennies. In return, any later stage can be rebuilt from scratch.

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

**Status:** Proposed

**Context.** The pipeline only ever needs to read, write and delete objects in one bucket.

**Decision.** The pipeline user gets one inline policy: `s3:ListBucket` on the raw bucket, plus `GetObject`, `PutObject` and `DeleteObject` on objects inside it. Nothing else. The policy is written in Terraform and refers to the bucket's ARN, so the bucket name is never typed in by hand.

**Alternatives.** `AmazonS3FullAccess`. It's quicker, but it gives access to every bucket in the account, including other projects' buckets.

**Consequences.** Adding a new bucket later (for example a Parquet export bucket for Snowflake) needs a policy change. That's the point: every new permission shows up in a pull request.

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
