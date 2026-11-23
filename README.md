# UK Property Platform

Every month HM Land Registry publishes every residential property sale in England and Wales. It goes back to 1995 and comes to about 30 million rows. It's one of the best free datasets in the UK. It's also messy. Postcodes are formatted inconsistently, records get changed or deleted after they're published, and on its own it tells you nothing about the house itself.

This project builds a monthly pipeline around that data. It pulls in Price Paid sales, the ONS Postcode Directory and Energy Performance Certificates. It cleans and joins them, models them into a star schema, trains a model that estimates a "fair" price for each sale, and puts the results in a dashboard.

I'm building it to practise the tools I use (or want to use) at work, on a dataset that's big enough to cause real problems.

> **Status:** the AWS foundation is in place (Phase 1). Ingestion is next. See the [roadmap](#roadmap) for what's done and what isn't.

## Architecture

```
 Land Registry ─┐
 ONS Postcodes ─┼─► Airflow (monthly) ─► S3 raw ─► Databricks ─► S3 Parquet ─► Snowflake ─► dbt ─► Streamlit
 EPC API ───────┘                                 bronze/silver                                   marts
                                                     + ML
```

1. **Ingestion:** Python scripts download each source and land it in S3 unchanged, partitioned by month. Every load is idempotent, so re-running a month replaces that month and nothing else.
2. **Databricks:**
   - **Bronze:** raw files go into Delta tables with a fixed schema.
   - **Silver:** applies Land Registry's add/change/delete records with `MERGE`, standardises postcodes, joins location data and matches sales to EPC certificates.
   - **ML:** an XGBoost model is trained and tracked in MLflow.
3. **Snowflake and dbt:** Silver is exported to Parquet and loaded into Snowflake, where dbt builds the star schema: an incremental fact table, an SCD2 property dimension and monthly regional marts, with tests on every layer.
4. **Serving:** a Streamlit dashboard reads from the marts.
5. **Infrastructure:** everything in AWS and Snowflake is created with Terraform. GitHub Actions runs linting, tests and slim dbt CI on every pull request.

A proper diagram will go in `docs/architecture.png` once there's something to draw.

## Why both Databricks and Snowflake?

Fair question, because most companies would pick one.

The split here is deliberate. Databricks handles the parts that really need Spark and Python: merging change records into 30M+ rows, fuzzy address matching and model training. Snowflake handles the parts that are mostly SQL and get read by other people: the dimensional model, dbt tests and the tables the dashboard queries.

It also mirrors a setup I've seen at a lot of companies, where data engineering works in Databricks and analytics works in Snowflake. The tricky part is the hand-off between the two, and that's part of what this project is about.

The longer reasoning, and the trade-offs, are in [docs/decisions.md](docs/decisions.md).

## Tech stack

| Area | Tools |
|---|---|
| Orchestration | Apache Airflow 3 |
| Storage | AWS S3 |
| Processing | Databricks (PySpark, Delta Lake) |
| ML | XGBoost, MLflow |
| Warehouse | Snowflake |
| Transformation | dbt |
| Dashboard | Streamlit |
| Infrastructure | Terraform |
| CI/CD | GitHub Actions |
| Language | Python 3.12, SQL |

## Roadmap

| Phase | What | Status |
|---|---|---|
| 0 | Repo setup: folder structure, `.gitignore`, `.env.example`, Makefile, dedicated Airflow instance | ✅ Done |
| – | CI with GitHub Actions (ruff, pytest), branch protection | ✅ Done |
| 1 | AWS with Terraform: remote state with S3 native locking, raw bucket (encryption, versioning, lifecycle to IA/Glacier IR), least-privilege pipeline IAM user enforced by Terraform, budget alert; Terraform checks in CI | ✅ Done |
| 2 | Ingestion: Land Registry, ONS Postcodes, EPC API → S3 raw; idempotent monthly partitions with manifests; one-off 1995→today backfill (~30M rows) | ⬜ Not started |
| 3 | Airflow orchestration: monthly DAG, skip if no new file, parallel ingest, retries, backfills, DAG tests in CI | ⬜ Not started |
| 4 | Databricks Bronze: Delta tables with enforced schema, metadata columns, partition overwrite with `replaceWhere` | ⬜ Not started |
| 5 | Databricks Silver: Delta MERGE handling add/change/delete records, postcode standardisation, ONS join, EPC address matching; transform tests in CI; Asset Bundle | ⬜ Not started |
| 6 | Snowflake with Terraform: database, warehouse, roles, storage integration; Silver → Parquet → external stage → `COPY INTO` | ⬜ Not started |
| 7 | dbt: staging → intermediate → marts, incremental `fact_sales`, SCD2 `dim_property` snapshot, tests and source freshness, dbt docs; slim CI (`state:modified+`) | ⬜ Not started |
| 8 | ML: XGBoost fair-price model, MLflow tracking, score every sale, flag anomalous prices | ⬜ Not started |
| 9 | Streamlit dashboard on Snowflake marts: regional price trends, EPC rating vs price, anomaly explorer; deployed publicly with a read-only role | ⬜ Not started |
| 10 | Production: full DAG (ingest → Databricks → Snowflake → dbt → notify), failure alerts, continuous deployment (Terraform apply and bundle deploy), GitHub OIDC instead of keys | ⬜ Not started |
| 11 | Results: backfill stats, first automated monthly run, model accuracy by region, actual monthly cost | ⬜ Not started |

## Running it locally

You'll need:

- Python 3.12
- An AWS account, with the AWS CLI v2 installed
- Terraform 1.10 or newer
- [uv](https://docs.astral.sh/uv/) and `make`

Airflow runs from the project's own virtual environment, not Docker.

```bash
git clone https://github.com/Muhammad234871/uk-property-platform.git
cd uk-property-platform

cp .env.example .env              # then fill in your own values
make venv                         # creates .venv with Python 3.12
make install                      # Airflow 3.3.2 + providers + this project

make lint
make test
make airflow                      # Airflow UI on http://localhost:8082
```

More setup detail (Databricks, Snowflake) will be added as each phase lands.

## Infrastructure

Everything in AWS is created with Terraform and lives in `eu-north-1` (the account's organisation only allows that region, see [decision 009](docs/decisions.md)). There are two stacks:

| Stack | What it creates | Where its state lives |
|---|---|---|
| `terraform/aws/bootstrap` | The S3 bucket that holds Terraform state | A local file (run once) |
| `terraform/aws/main` | Raw data bucket, pipeline IAM user and policy, monthly budget | `s3://<state bucket>/aws/main.tfstate`, locked with an S3 lock file |

A few things worth knowing:

- **Terraform runs with short-lived credentials** from `aws login`. There's no admin access key on disk.
- **The pipeline user can only touch the raw bucket.** That's list, read, write and delete, nothing else. Terraform also removes any policy that gets attached to it by hand.
- **Terraform never creates access keys,** because they'd end up in plain text in the state file. The pipeline's key is created once with the AWS CLI.
- **Raw files are never deleted.** They move to cheaper storage as they age (Standard-IA after 30 days, Glacier Instant Retrieval after 180), and overwritten versions are kept for 30 days.

To run it:

```bash
aws login --profile terraform-admin --region eu-north-1

cd terraform/aws/main
cp terraform.tfvars.example terraform.tfvars   # add your email for budget alerts
terraform init
terraform plan
```

Every pull request runs `terraform fmt -check` and `terraform validate` on both stacks, and `main` can't be merged into until they pass. The reasoning behind each choice is in [docs/decisions.md](docs/decisions.md) (006–012).

## Project structure

```
uk-property-platform/
├── airflow/dags/        # the monthly pipeline DAG
├── ingestion/           # download scripts for each source → S3
├── databricks/          # bronze, silver and ML notebooks, job config, tests
├── snowflake/setup/     # stage and load SQL
├── dbt/                 # staging, intermediate and mart models, snapshots, tests
├── dashboard/           # Streamlit app
├── terraform/           # AWS and Snowflake infrastructure
├── tests/               # pytest for the Python code
└── docs/                # architecture diagram and design decisions
```

## Results

Nothing to report yet. This section will show real numbers once the pipeline is running: row counts, run times, model error and what it actually costs per month.

## Data sources and licences

- **Price Paid Data:** contains HM Land Registry data © Crown copyright and database right 2026. This data is licensed under the [Open Government Licence v3.0](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).
- **ONS Postcode Directory:** source: Office for National Statistics, licensed under the Open Government Licence v3.0. Contains OS data © Crown copyright and database right 2026.
- **Energy Performance Certificates:** Department for Levelling Up, Housing and Communities (now the Ministry of Housing, Communities and Local Government), Open Government Licence v3.0. Address data in the EPC register is subject to Royal Mail and Ordnance Survey terms, so it's only used for matching here and isn't republished.
