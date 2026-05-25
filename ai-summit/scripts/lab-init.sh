set -e
# Lab instance Environment vars
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
export ZONE=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-zone])")
export REGION=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-zone])")

# Startup scripts

export USER_EMAIL=$(gcloud config get-value account)


TIMESTAMP=$(date +'%Y%m%d-%H%M%S')
BUCKET_NAME="cymbaldirect${PROJECT_ID}"
LOCATION="us-central1"


gcloud storage buckets create "gs://$BUCKET_NAME" \
    --project="$PROJECT_ID" \
    --location="$LOCATION" \
    --uniform-bucket-level-access


gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" \
    --member="serviceAccount:$USER_EMAIL" \
    --role="roles/storage.admin" \
    --quiet

# copying images from public bucket into the newly created bucket
gsutil -m cp -r gs://gcp-ce-storage/ce207/* gs://${BUCKET_NAME}/


# Cleanup ..
# sleep 180
# gcloud compute instances delete lab-setup --zone=$ZONE  --quiet 



# ==============================================================================
# 🤖 Cloud AI Delivery Agent - MASTER SETUP SCRIPT
# ========================================================================.======
# 1. Enables APIs
# 2. Sets up IAM & Service Accounts
# 3. Creates Storage Bucket & BigQuery Tables (with Mock Data)
# 4. Generates Application Code
# 5. Deploys to Cloud Run & Creates Trigger
# ==============================================================================

set -e  # Exit on error

# --- 1. CONFIGURATION --------------------------------------------------------
PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
REGION="us-central1"
SERVICE_NAME="delivery-agent"
SERVICE_ACCOUNT="delivery-agent-sa"
TRIGGER_TOPIC="order-events"
REPLY_TOPIC="delivery-verdict"
REPO_NAME="adk_delivery_agent" 

# Dynamic Bucket Name (Globally Unique)
BUCKET_NAME="cymbaldirect${PROJECT_ID}"

echo "🚀 STARTING FULL DEPLOYMENT FOR PROJECT: $PROJECT_ID"
echo "📍 Region: $REGION"
echo "🪣 Bucket: gs://$BUCKET_NAME"

# --- 2. ENABLE APIS ----------------------------------------------------------
echo "📦 Enabling APIs..."
gcloud services enable \
  run.googleapis.com \
  eventarc.googleapis.com \
  pubsub.googleapis.com \
  aiplatform.googleapis.com \
  bigquery.googleapis.com \
  bigquerystorage.googleapis.com \
  storage.googleapis.com \
  cloudbuild.googleapis.com \
  logging.googleapis.com \
  cloudtrace.googleapis.com

echo "⏳ Waiting 60 seconds for Google Cloud to propagate API changes..." sleep 60 



# --- 3. IAM & PERMISSIONS ----------------------------------------------------
echo "🔑 Setting up Service Account..."
if ! gcloud iam service-accounts describe "${SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" > /dev/null 2>&1; then
    gcloud iam service-accounts create $SERVICE_ACCOUNT --display-name="Delivery Agent SA"
    echo "⏳ Waiting 30 seconds for Service Account to propagate..."
    sleep 30
fi

SA_EMAIL="${SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "🛡️ Granting Permissions..."
# Pub/Sub, Vertex AI, Logging
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SA_EMAIL" --role="roles/pubsub.publisher" --condition=None > /dev/null
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SA_EMAIL" --role="roles/aiplatform.user" --condition=None > /dev/null
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SA_EMAIL" --role="roles/logging.logWriter" --condition=None > /dev/null
# BigQuery & Storage (Crucial for Tools)
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SA_EMAIL" --role="roles/bigquery.jobUser" --condition=None > /dev/null
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SA_EMAIL" --role="roles/bigquery.dataViewer" --condition=None > /dev/null

gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SA_EMAIL" --role="roles/storage.objectViewer" --condition=None > /dev/null

gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" --role="roles/storage.objectViewer" --condition=None > /dev/null

# Grant the "Cloud Trace Agent" role 
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SA_EMAIL"  --role="roles/cloudtrace.agent" --condition=None > /dev/null
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SA_EMAIL" --role="roles/bigquery.dataOwner" --condition=None > /dev/null


# --- 4. DATA LAYER SETUP (Bucket & BigQuery) ---------------------------------
echo "💾 Setting up Data Layer..."

# --- Create Analytics Dataset ---
echo "   Creating BigQuery Dataset 'agent_analytics'..."
bq --location=$REGION mk -d --force ${PROJECT_ID}:agent_analytics || true



# B. Create BigQuery Dataset
echo "   Creating BigQuery Dataset 'logistics'..."
bq --location=$REGION mk -d --force ${PROJECT_ID}:logistics || true




# --- 5. PUB/SUB SETUP --------------------------------------------------------
echo "📨 Setting up Pub/Sub..."
gcloud pubsub topics create $TRIGGER_TOPIC --message-storage-policy-allowed-regions=$REGION || true
gcloud pubsub topics create $REPLY_TOPIC --message-storage-policy-allowed-regions=$REGION || true


gcloud pubsub topics add-iam-policy-binding $REPLY_TOPIC --member="serviceAccount:$SA_EMAIL" --role="roles/pubsub.publisher" > /dev/null

# --- 6. GENERATE CODE FILES --------------------------------------------------
echo "📂 Generating Code..."
export WORKDIR="/tmp/$REPO_NAME"
mkdir -p $WORKDIR/agents/tools
mkdir -p $WORKDIR/tools 
cd $WORKDIR

# --- .env file---
echo "   Creating .env file..."
cat <<EOF > .env
GOOGLE_CLOUD_PROJECT="${PROJECT_ID}"
GOOGLE_CLOUD_LOCATION="us-central1"
MODEL="gemini-2.5-flash"
GOOGLE_GENAI_USE_VERTEXAI=True
REPLY_TOPIC_ID=projects/${PROJECT_ID}/topics/${REPLY_TOPIC}
ADK_WEB_BASE_PATH=agents/
MONITORING_DATASET_ID=agent_analytics
MONITORING_GCS_BUCKET="cymbaldirect${PROJECT_ID}"
EOF
echo "  Done Creating .env file..."

cat <<EOF > requirements.txt
google-cloud-aiplatform
google-cloud-logging
google-cloud-bigquery
google-cloud-bigquery-storage
pyarrow
google-cloud-storage
google-genai
google-adk
python-dotenv
flask
gunicorn
fastapi
cloudevents>=1.12,<2.0.0
google-cloud-pubsub>=2.33
uvicorn
opentelemetry-api
opentelemetry-sdk
opentelemetry-exporter-gcp-trace
EOF

cat <<EOF > Dockerfile
FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . /app/
CMD ["python", "main.py"]
EOF

echo "   Creating main.py file..."
cat <<EOF > main.py

import os
from dotenv import load_dotenv
load_dotenv(override=True)

from cloudevents.http import from_http
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from processor import process_request
from agents.agents import root_agent
import logging
import sys


logging.basicConfig(
   level=logging.INFO,
   force=True,
)
logger = logging.getLogger(__name__)


app = FastAPI()






@app.post('/')
async def eventarc_handler(request: Request) -> JSONResponse:
   try:
       body = await request.body()
       event = from_http(request.headers, body)
      
       # Call processor (No longer needs the topic ID argument)
       message, code = await process_request(event)
      
       status = 'error' if code != 200 else 'success'
       return JSONResponse(content={'status': status, 'message': message}, status_code=code)
   except Exception as e:
       logger.error(f"❌ failed processing Eventarc event: {e}")
       return JSONResponse(content={'status': 'error', 'message': 'Failed to parse payload to Eventarc event'}, status_code=400)




if __name__ == '__main__':
   import uvicorn
   uvicorn.run(app, host='0.0.0.0', port=int(os.environ.get('PORT', '8080')))



EOF
echo "   Done Creating main.py file..."

echo "   Creating processor.py file..."
cat <<EOF > processor.py

import base64
from cloudevents.http import CloudEvent
from google.adk import runners
from google.genai import types
import json
import logging
import uuid
from agents.agents import app
from google.adk.cli.fast_api import get_fast_api_app
from fastapi import FastAPI


logging.basicConfig(
   level=logging.INFO,
   force=True,
)
logger = logging.getLogger(__name__)


# runner = runners.InMemoryRunner(app_name='delivery_agent_cloudrun', agent=root_agent)
runner = runners.InMemoryRunner(app=app)




def _parse_pubsub_message(event: CloudEvent) -> dict:
   """Parse Pub/Sub message from Eventarc event."""
   if 'message' in event.data and 'data' in event.data['message']:
       encoded_data = event.data['message']['data']
       decoded_bytes = base64.b64decode(encoded_data)
       return json.loads(decoded_bytes.decode('utf-8'))
   else:
       raise ValueError('CloudEvent does not follow Pub/Sub message schema')


async def process_request(event: CloudEvent) -> tuple[str, int]:
   """Process incoming Eventarc event."""


   logger.info("👉 parse PubSub message from Eventarc event")
   pubsub_message = {}
   try:
       pubsub_message = _parse_pubsub_message(event)
   except Exception as e:
       logger.error(f"❌ error processing Pub/Sub message: {e}")
       return 'Error processing Pub/Sub message from Eventarc event', 400
  
   user_id = pubsub_message.get('user_id', 'pubsub')
   session_id = str(uuid.uuid4())
   logger.info(f"👉 create session for user:{user_id}, session:{session_id}")
   await runner.session_service.create_session(
       app_name=runner.app_name, user_id=user_id, session_id=session_id
   )
  
   if 'prompt' not in pubsub_message and 'message' not in pubsub_message:
       return 'Need to have "prompt" or "message" keys in Pub/Sub message', 400
  
   data = pubsub_message['prompt'] if 'prompt' in pubsub_message else pubsub_message['message']
   message = types.Content(
       role='user',
       parts=[types.Part.from_text(text=data)]
   )
  
   logger.info(f"👉 Prompt the delivery agent for '{data}'")
  
   try:
       # 🟢 CHANGED: We iterate through the whole stream without 'break'
       # This prevents the 'GeneratorExit' crash in Cloud Run.
       async for event in runner.run_async(
           user_id=user_id,
           session_id=session_id,
           new_message=message,
       ):
            if event.is_final_response():
               # Just log it. The loop will end naturally immediately after this event.
               if event.content and event.content.parts:
                   logger.info(f"🤖 Agent Finished. Final Thought: {event.content.parts[0].text}")
               elif event.actions and event.actions.escalate:
                   logger.warning(f"⚠️ Agent Escalated: {event.error_message}")
              
               # DO NOT CALL break HERE
              
   except Exception as e:
       logger.error(f"❌ Error invoking designated runner: {e}")
       # Even if it fails, we return 200 to Pub/Sub so it doesn't retry infinitely
       return 'Error invoking designated runner', 200


   return 'Agent execution completed.', 200


app: FastAPI = get_fast_api_app(
   agents_dir="agents",
   web=True,
   trace_to_cloud=True,
)


@app.get("/kfir")
async def test_api():
   # Mocking a CloudEvent structure for testing
   mock_data = {
       "message": {
           "data": base64.b64encode(
               json.dumps({"prompt": "process order id 7260 customer id 125 , keep complaining"}).encode("utf-8")
           ).decode("utf-8")
       }
   }
   mock_event = CloudEvent(
       attributes={"type": "com.google.cloud.pubsub.topic.v1.messagePublished", "source": "test"},
       data=mock_data
   )
   message, code = await process_request(mock_event)
   return {"message": message, "code": code}




if __name__ == "__main__":
   import uvicorn
   uvicorn.run(app, host="0.0.0.0", port=8080)


EOF
echo "   Done Creating processor.py file..."

echo "   Creating tools.py file..."
touch tools/__init__.py




cat <<'EOF' > tools/tools.py

"""
tools.py: Contains all external interaction tools (BigQuery, GCS, Vision, Pub/Sub).
"""
import os
import json
from google.cloud import bigquery
from google.cloud import storage
from google.cloud import pubsub_v1  # <--- Added Import
from google import genai
from google.genai import types


# --- Tool 1: SQL Order Lookup ---
def bq_get_order_details(order_id: str):
   """ gets the order details with the image URI """
   bq_client = bigquery.Client()
   print(f"🔎 SQL Lookup: Checking BigQuery for Order {order_id}")
  
   project_id = os.environ.get("GOOGLE_CLOUD_PROJECT")
   table_id = f"{project_id}.logistics.complaints_raw"
  
   query = f"SELECT uri, customer_id FROM `{table_id}` WHERE order_id = @order_id LIMIT 1"
   print(f"   ***@*@**@*@ SQL Query: {query}")
  
   job_config = bigquery.QueryJobConfig(
       query_parameters=[bigquery.ScalarQueryParameter("order_id", "INT64", order_id)]
   )
  
   try:
       query_job = bq_client.query(query, job_config=job_config)
       results = list(query_job.result())
      
       if results:
           row = results[0]
           result_str = f"Image URI: {row.uri} | Customer ID: {row.customer_id}"
           print(f"    Found: {result_str}")
           return result_str
       else:
           return "ORDER_NOT_FOUND"
   except Exception as e:
       print(f"❌ BigQuery Error: {e}")
       return "ERROR_QUERYING_DB"


# --- Tool 2: Vision Analysis ---
def vision_scan_package_tool(uri: str):
   print(f"👁️ Vision Scan: {uri}")
   storage_client = storage.Client()
   image_bytes = None


   try:
       if uri.startswith("gs://"):
           try:
               parts = uri[5:].split("/", 1)
               bucket_name = parts[0]
              
               # 🛠️ FIX: Strip leading slashes to handle 'gs://bucket//file.png' safely
               blob_name = parts[1].lstrip('/')
               print(f"this is the blob name :{blob_name}")
               bucket = storage_client.bucket(bucket_name)
               blob = bucket.blob(blob_name)
               image_bytes = blob.download_as_bytes()
               print("    Downloaded from GCS (Authenticated)")
           except Exception as e:
               print(f"   ❌ GCS Download Failed: {e}")
               return "ERROR_DOWNLOADING_GCS"
       else:
           return "UNKNOWN_IMAGE_FORMAT"


       # Call Gemini Vision (Rest of the code remains the same)
       client = genai.Client(
           vertexai=True,
           project=os.environ.get("GOOGLE_CLOUD_PROJECT"),
           location=os.environ.get("GOOGLE_CLOUD_LOCATION")
       )
       model_name = os.getenv("MODEL", "gemini-2.5-flash")
       response = client.models.generate_content(
           model=model_name,
           contents=[
               types.Content(
                   role="user",
                   parts=[
                       types.Part.from_bytes(data=image_bytes, mime_type="image/png"),
                       types.Part.from_text(text="Is this package damaged? Answer YES or NO.")
                   ]
               )
           ]
       )
       print(f"   👀 VISION MODEL SAYS: {response.text}")
       return response.text


   except Exception as e:
       print(f"❌ Vision Tool Error: {e}")
       return "ERROR_SCANNING_IMAGE"


# --- Tool 3: Customer History Lookup ---
def bq_get_customer_history(customer_id: str):
   bq_client = bigquery.Client()
   print(f"📊 SQL History Lookup: Checking behavior for {customer_id}...")
  
   project_id = os.environ.get("GOOGLE_CLOUD_PROJECT")
   table_id = f"{project_id}.logistics.customers"
  
   query = f"""
       SELECT total_spend, total_returns, false_claims_count, dispatcher_notes
       FROM `{table_id}`
       WHERE customer_id = @customer_id
       LIMIT 1
   """
  
   job_config = bigquery.QueryJobConfig(
       query_parameters=[bigquery.ScalarQueryParameter("customer_id", "STRING", customer_id)]
   )
  
   try:
       query_job = bq_client.query(query, job_config=job_config)
       results = list(query_job.result())
      
       if results:
           row = results[0]
           summary = (
               f"Customer {customer_id} Profile:\n"
               f"- Total Spend: ${row.total_spend}\n"
               f"- False Claims: {row.false_claims_count}\n"
               f"- Dispatcher Notes: \"{row.dispatcher_notes}\" (CRITICAL: Analyze this text)"
           )
           print(f"    Data Found:\n{summary}")
           return summary
       else:
           return "CUSTOMER_NOT_FOUND"
   except Exception as e:
       print(f"❌ BigQuery Error: {e}")
       return "ERROR_QUERYING_CUSTOMER_DB"


# --- Tool 4: Action Tool (Updated) ---
def process_to_pubsub(reason: str):
   """
   Publishes a message to the verdict topic if the Agent decides to act.
   """
   print("******************")
   print(f"🚀 AGENT DECIDED TO ACT: {reason}")
   print("******************")


   # 1. Get Topic from Env (This ensures dynamic configuration)
   topic_id = os.getenv('REPLY_TOPIC_ID')
  
   if not topic_id:
       error_msg = "❌ Error: REPLY_TOPIC_ID not set in environment."
       print(error_msg)
       return error_msg


   try:
       # 2. Configure Publisher
       publisher = pubsub_v1.PublisherClient()
      
       # 3. Prepare Payload
       # We wrap it in JSON so the receiver can parse it easily
       payload_data = {
           "decision": "COMPENSATION_GRANTED",
           "agent_reason": reason,
           "source": "DeliveryAgent-CloudRun"
       }
       data_str = json.dumps(payload_data)
       data_bytes = data_str.encode("utf-8")


       # 4. Publish
       future = publisher.publish(topic_id, data=data_bytes)
       message_id = future.result()
      
       success_msg = f" Verdict published to {topic_id}. Message ID: {message_id}"
       print(success_msg)
       return success_msg


   except Exception as e:
       error_msg = f"❌ Failed to publish to Pub/Sub: {e}"
       print(error_msg)
       return error_msg


EOF


cat <<'EOF' > agents/__init__.py
from .agents import root_agent

EOF

cat <<'EOF' > agents/agents.py
import os
from dotenv import load_dotenv
from google.adk import Agent
from google.adk.apps import App
from google.adk.models import Gemini
from google.adk.agents import ParallelAgent, SequentialAgent
import sys
from google.genai import types




# try:
#     from opentelemetry import trace
#     from opentelemetry.sdk.trace import TracerProvider
#     trace.set_tracer_provider(TracerProvider())
# except ImportError:
#     pass # OpenTelemetry is optional


from google.adk.plugins.bigquery_agent_analytics_plugin import (
   BigQueryAgentAnalyticsPlugin,
   BigQueryLoggerConfig
)
# ---------------------------------------------------------
# 🚨 PATH FIX
current_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(current_dir)
sys.path.append(parent_dir)
# ---------------------------------------------------------


load_dotenv(override=True)
model_name = os.getenv("MODEL", "gemini-2.5-flash")
print(f"🤖 AGENTS INIT: Using Model '{model_name}'")
project_id = os.environ.get("GOOGLE_CLOUD_PROJECT")
dataset_id = os.environ.get("MONITORING_DATASET_ID")
location = os.environ.get("GOOGLE_CLOUD_LOCATION")
gcs_bucket_name = os.environ.get("MONITORING_GCS_BUCKET")


def get_model_config():
   return Gemini(model=model_name)


# --- IMPORTS & STATE TOOLS ---
from tools.tools import (
   bq_get_order_details,
   vision_scan_package_tool,
   bq_get_customer_history,
   process_to_pubsub
  
)


# --- 1. MONITORING ---




# --- Initialize the Plugin with Config ---
bq_config = BigQueryLoggerConfig(
   enabled=True,
   gcs_bucket_name=gcs_bucket_name, # Enable GCS offloading for multimodal content
   log_multi_modal_content=True,
   max_content_length=500 * 1024, # 500 KB limit for inline text
   batch_size=5, # Default is 1 for low latency, increase for high throughput
   shutdown_timeout=10.0
)
bq_logging_plugin = BigQueryAgentAnalyticsPlugin(
   project_id=project_id,
   dataset_id=dataset_id,
   table_id="agent_events",
   config=bq_config,
   location=location
)




# --- 1. WORKER AGENTS (WRITERS) ---


customer_analyst_agent = Agent(
   name="customer_history_analyst",
   model=get_model_config(),
   generate_content_config=types.GenerateContentConfig(
       temperature=0.0
   ),
   description="Analyzes customer risk.",
   output_key="custumer_history_analyst_output",
   instruction="""
       1. Call `bq_get_customer_history` once.
       2. Analyze logic:
          - Spend > 10000 -> "GOLD"
          - Spend > 1000 -> "SILVER"
          - Else -> "BRONZE"
   """,
   # Added save_finding
   tools=[bq_get_customer_history]
)


vision_agent = Agent(
   name="vision_scan_package",
   model=get_model_config(),
   description="Checks package for damage.",
   output_key="vision_scan_package_output",
   generate_content_config=types.GenerateContentConfig(
       temperature=0.0
   ),
   # output_schema={'isDamaged': bool},
   instruction="""
       1. Call `bq_get_order_details` then `vision_scan_package_tool`.
       Output *only* the summary.
   """,
   # Added save_finding
   tools=[bq_get_order_details, vision_scan_package_tool]
)


# Parallel Group
gatherer = ParallelAgent(
   name="FactsAnalyisis",
   sub_agents=[vision_agent, customer_analyst_agent],
   description="Runs multiple facts agents in parallel to gather information call to `vision_agent` and `customer_analyst_agent` ."
)






# --- 2. ACTION AGENT ---


communication_agent = Agent(
   name="communication_agent",
   model=get_model_config(),
   generate_content_config=types.GenerateContentConfig(
       temperature=0.0
   ),
   description="Sends notifications.",
   instruction="""
       Send a polite apology message using the `process_to_pubsub` tool.
   """,
   tools=[process_to_pubsub]
)


merge_agent = Agent(
   name="fact_checker",
   model=get_model_config(),
   description="Main decision maker.",
   instruction="""
       You are the System Orchestrator. Follow this EXACT sequence:
  
       Use this data to take action:
  
       Vision Analysis:
      
       {vision_scan_package_output}


       Customer History Analysis:
      
       {custumer_history_analyst_output}


       If vision analysis retruns DAMAGE or customer history is SILVER, BRONSE or GOLD
       call to `communication_agent`


       otherwire write output "NO ACTION NEEDED"


   """,
   # Root now has the 'Reader' tool
   sub_agents=[communication_agent],
)


root_agent = SequentialAgent(
   name="ResearchAndSynthesisPipeline",
   # Run parallel research first, then merge
   sub_agents=[gatherer, merge_agent],
   description="Coordinates parallel research and synthesizes the results.",
)
# --- 3. ROOT AGENT (READER) ---
app = App(
   name="delivery_agent_app",
   root_agent=root_agent,
   plugins=[bq_logging_plugin], #  CORRECT: Attach plugin to the App
)






# print(" AGENTS LOADED SUCCESSFULLY")

EOF

# --- 7. DEPLOYMENT -----------------------------------------------------------
echo "🚀 Deploying to Cloud Run..."
set +e
gcloud run deploy $SERVICE_NAME \
  --source . \
  --region=$REGION \
  --project=$PROJECT_ID \
  --service-account=$SA_EMAIL \
  --allow-unauthenticated \
  --clear-base-image \
  --memory=2048Mi \
  --quiet \
  --set-env-vars "GOOGLE_CLOUD_PROJECT=${PROJECT_ID},REPLY_TOPIC_ID=projects/${PROJECT_ID}/topics/${REPLY_TOPIC},MODEL=gemini-2.5-flash,GOOGLE_CLOUD_LOCATION=${REGION},MONITORING_DATASET_ID=agent_analytics,MONITORING_GCS_BUCKET=cymbaldirect${PROJECT_ID}"
DEPLOY_STATUS=$?
set -e

if [ $DEPLOY_STATUS -ne 0 ]; then
  echo "❌ Cloud Run deployment failed! Waiting 15 seconds for logs to propagate..."
  sleep 30
  gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=$SERVICE_NAME" --limit=50
  exit 1
fi



echo "🔗 Creating Eventarc Trigger..."
gcloud eventarc triggers delete "$SERVICE_NAME-trigger" --location=$REGION --quiet || true
gcloud eventarc triggers create "$SERVICE_NAME-trigger" \
  --location=$REGION \
  --destination-run-service=$SERVICE_NAME \
  --destination-run-region=$REGION \
  --transport-topic="projects/${PROJECT_ID}/topics/${TRIGGER_TOPIC}" \
  --event-filters="type=google.cloud.pubsub.topic.v1.messagePublished" \
  --service-account=$SA_EMAIL

echo "🔐 Granting Invoker permission to the Service Account..." 
gcloud run services add-iam-policy-binding $SERVICE_NAME \
  --region=$REGION \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/run.invoker"



echo "========================================================"
echo " DEPLOYMENT SUCCESSFUL!"
echo "========================================================"


echo "========================================================"
echo " NOW, JUST TEST THE AGENTIC SYSTEM WITH MOCK DATA"
echo "========================================================"





