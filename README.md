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
- Word count and token usage

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
| Secrets | Azure Key Vault (RBAC) |
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

---

## What I'd Do Differently

- Add dead-letter handling — right now a failed document just gets skipped after 3 retries with no alerting
- Use managed identity everywhere instead of connection strings, even locally
- Add a proper CI/CD pipeline instead of deploying from the CLI

---

## Infrastructure

All resources are in `terraform/main.tf`. Run `terraform apply` to provision from scratch.

---

## Part of a Larger Portfolio

| # | Project | Status |
|---|---------|--------|
| 1 | Serverless LLM Pipeline | ✅ Complete |
| 2 | AI Chatbot on Azure | 🔄 In progress |
| 3 | Kubernetes AI Inference (AKS) | 📋 Planned |
| 4 | Multi-Region Architecture | 📋 Planned |

**Woedem Malorku** — AZ-104 · AWS SOA-C03 · AZ AI-900