import azure.functions as func
import logging
import json
import os
import uuid
from datetime import datetime, timezone

from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from openai import AzureOpenAI
from azure.cosmos import CosmosClient

app = func.FunctionApp()


def get_secret(secret_name: str) -> str:
    vault_url = os.environ["KEY_VAULT_URL"]
    credential = DefaultAzureCredential()
    client = SecretClient(vault_url=vault_url, credential=credential)
    return client.get_secret(secret_name).value


def build_openai_client() -> AzureOpenAI:
    return AzureOpenAI(
        azure_endpoint=get_secret("openai-endpoint"),
        api_key=get_secret("openai-api-key"),
        api_version="2024-02-01",
    )


def build_cosmos_container():
    connection_str = os.environ.get("COSMOS_CONNECTION_STRING") or get_secret("cosmos-connection-string")
    client = CosmosClient.from_connection_string(connection_str)
    database = client.get_database_client(os.environ["COSMOS_DATABASE"])
    return database.get_container_client(os.environ["COSMOS_CONTAINER"])


def analyse_document(content: str) -> dict:
    openai_client = build_openai_client()
    deployment = os.environ["AZURE_OPENAI_DEPLOYMENT"]

    prompt = (
        "Analyse the following document and return ONLY a valid JSON object "
        "with these exact keys:\n"
        "  summary        – one-paragraph plain-English summary\n"
        "  key_points     – list of up to 5 important takeaways (strings)\n"
        "  sentiment      – one of: positive | neutral | negative\n"
        "  entities       – list of named entities (people, orgs, locations)\n"
        "  word_count     – integer word count of the original text\n\n"
        f"Document:\n{content}"
    )

    response = openai_client.chat.completions.create(
        model=deployment,
        messages=[
            {
                "role": "system",
                "content": (
                    "You are a document analysis assistant. "
                    "Always respond with valid JSON only — no markdown fences."
                ),
            },
            {"role": "user", "content": prompt},
        ],
        response_format={"type": "json_object"},
        temperature=0.2,
        max_tokens=1000,
    )

    analysis = json.loads(response.choices[0].message.content)
    analysis["_token_usage"] = {
        "prompt": response.usage.prompt_tokens,
        "completion": response.usage.completion_tokens,
        "total": response.usage.total_tokens,
    }

    return analysis


@app.blob_trigger(
    arg_name="myblob",
    path="input-documents/{name}",
    connection="AzureWebJobsStorage",
)
def process_document(myblob: func.InputStream) -> None:
    blob_name = myblob.name.split("/")[-1]
    logging.info("Blob trigger fired — file: %s  size: %s bytes", blob_name, myblob.length)

    try:
        content = myblob.read().decode("utf-8")
    except UnicodeDecodeError:
        logging.error("File %s is not UTF-8 text — skipping.", blob_name)
        return

    if not content.strip():
        logging.warning("File %s is empty — skipping.", blob_name)
        return

    try:
        analysis = analyse_document(content)
        logging.info(
            "Analysis complete — sentiment: %s  tokens used: %d",
            analysis.get("sentiment", "unknown"),
            analysis.get("_token_usage", {}).get("total", 0),
        )
    except Exception as exc:
        logging.exception("OpenAI call failed for %s: %s", blob_name, exc)
        raise

    try:
        container = build_cosmos_container()
        document = {
            "id": str(uuid.uuid4()),
            "partitionKey": blob_name,
            "blob_name": blob_name,
            "processed_at": datetime.now(timezone.utc).isoformat(),
            "source": "azure-blob",
            "analysis": analysis,
        }
        container.upsert_item(document)
        logging.info("Saved to Cosmos DB — document id: %s", document["id"])
    except Exception as exc:
        logging.exception("Cosmos DB write failed for %s: %s", blob_name, exc)
        raise


@app.route(route="results/{blob_name}", methods=["GET"])
def get_results(req: func.HttpRequest) -> func.HttpResponse:
    blob_name = req.route_params.get("blob_name")

    try:
        container = build_cosmos_container()
        query = (
            "SELECT * FROM c WHERE c.blob_name = @name "
            "ORDER BY c.processed_at DESC OFFSET 0 LIMIT 10"
        )
        items = list(
            container.query_items(
                query=query,
                parameters=[{"name": "@name", "value": blob_name}],
                enable_cross_partition_query=True,
            )
        )
        return func.HttpResponse(
            json.dumps(items, indent=2),
            mimetype="application/json",
            status_code=200,
        )
    except Exception as exc:
        logging.exception("Failed to fetch results: %s", exc)
        return func.HttpResponse(str(exc), status_code=500)