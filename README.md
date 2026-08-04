# Azure Serverless LLM Pipeline

I'm a Systems Administrator working toward a Cloud Solutions Architect role.

The idea was simple: build something that uses real Azure services in a way that reflects how cloud workloads actually get designed — event-driven, serverless, secure secrets management, AI integration. Not a tutorial. Not a sandbox. Something deployed and running.

---

## What It Does

You drop a text file into Azure Blob Storage. Within seconds, an Azure Function wakes up, sends the document to GPT-4o for analysis, and saves the results to Cosmos DB. No servers to manage, no polling loop — the function fires automatically when the blob is created.

The AI analysis returns:
- A plain-English summary
- Up to 5 key takeaways
- Sentiment (positive / neutral / negative)
- Named entities (people, orgs, locations)
- Token usage, plus a word count computed in Python — language models
  can't count reliably, and `len(content.split())` is exact and free

Results are retrievable anytime via a built-in HTTP endpoint.

---

## Architecture

```
File upload
    │
    ▼
Azure Blob Storage
    │  (blob trigger)
    ▼
Azure Function (Python 3.12)
    │
    ├──► Azure Key Vault       (secrets fetched at runtime)
    ├──► Azure OpenAI / GPT-4o (document analysis)
    └──► Azure Cosmos DB       (stores structured results)
                │
                ▼
    GET /api/results/{filename}
```

---

## Stack

| Layer | Service |
|-------|---------|
| Compute | Azure Functions, Consumption plan |
| AI | Azure OpenAI — GPT-4o |
| Storage | Azure Blob Storage |
| Database | Azure Cosmos DB (serverless) |
| Secrets | Azure Key Vault (access policies) |
| Monitoring | Application Insights |
| IaC | Terraform |

---

## Running It Locally

```bash
git clone https://github.com/woedem24/azure-llm-pipeline
cd azure-llm-pipeline
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp local.settings.json.example local.settings.json
# fill in your Azure resource values
func start
```

Upload a `.txt` file to the `input-documents` blob container to trigger the function.

---

## What I Actually Struggled With

This section exists because anyone can copy a tutorial. Here's where things broke:

- **Blob receipts** — Azure writes a receipt after 3 failed executions so it stops retrying. I spent a while uploading new files and wondering why nothing fired, not realising all my test files were permanently skipped. Fixed by deleting the receipt blobs and understanding the at-least-once delivery guarantee.

- **Connection string format** — The Cosmos DB connection string I stored in Key Vault was just the endpoint URL, not the full `AccountEndpoint=...;AccountKey=...` format the SDK expects. The error message wasn't obvious. Took longer than I'd like to admit.

- **Mac to Linux deployment** — Local packages compiled for ARM64 (my MacBook) don't run on Azure's Linux x86 workers. Had to use remote build so Azure compiled the dependencies server-side.

- **Python worker isolation** — Without `PYTHON_ISOLATE_WORKER_DEPENDENCIES=1`, the Azure Functions worker couldn't see the venv packages. One setting, not obvious at all.

- **Retries can cost money** — the blob trigger retries 3× on an unhandled exception, which is right for a transient Cosmos timeout and wrong for a document that's simply too long. Every retry was another GPT-4o call reaching the same failure, so one bad upload got billed four times. Now failures are sorted into retryable and not, and oversized documents are rejected before any call is made.

- **Asking the model to count** — the prompt originally requested `word_count` from GPT-4o. It was confidently wrong often enough to notice. Anything deterministic belongs in code, not in a prompt.

---

## What I'd Do Differently

- Add dead-letter handling — right now a failed document just gets skipped after 3 retries with no alerting
- Use managed identity everywhere instead of connection strings, even locally
- Add a proper CI/CD pipeline instead of deploying from the CLI

---

## Infrastructure

All resources are in `terraform/main.tf`.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then fill it in
terraform init && terraform plan && terraform apply
```

Two things this config does **not** do, stated up front:

- **It does not provision the Azure OpenAI resource.** Create that separately
  and pass its endpoint and key in via `terraform.tfvars`; Terraform stores
  both in Key Vault for the function to read at runtime.
- **`prefix` must be globally unique.** Storage account, Key Vault and Cosmos DB
  names share a namespace across all of Azure, so applying with the default
  prefix will fail with "name already taken". Set your own.

State is local. That means `terraform.tfstate` holds the Cosmos connection
string and the OpenAI key in plaintext on one machine — fine for a solo demo,
wrong for anything shared. A remote backend block is stubbed in `main.tf`.

---

## Part of a Larger Portfolio

| # | Project | Status |
|---|---------|--------|
| 1 | Serverless LLM Pipeline | ✅ Complete |
| 2 | AI Chatbot on Azure | ✅ Deployed — [live demo](https://woedem24.github.io/azure-ai-chatbot/) |
| 3 | Kubernetes AI Inference (AKS) | 📋 Planned |
| 4 | Multi-Region Architecture | 📋 Planned |

**Woedem Malorku** — AZ-104 · AWS CloudOps Engineer Associate (SOA-C03) · AI-900