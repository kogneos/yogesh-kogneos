
data "google_project" "project" {
    project_id = var.gcp_project_id
}

/******************************************
1. Activate APIs - Data Storage Project
 *****************************************/
module "activate_service_apis" {
  
  source = "github.com/CloudVLab/terraform-lab-foundation//basics/api_service/stable/v1"
  # source         = "gcs::https://www.googleapis.com/storage/v1/terraform-lab-foundation/basics/api_service/stable/v1"
  gcp_project_id = var.gcp_project_id
  gcp_region     = var.gcp_region
  gcp_zone       = var.gcp_zone
  api_services = [
    "compute.googleapis.com",
    "bigquery.googleapis.com", 
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "aiplatform.googleapis.com",
    "dialogflow.googleapis.com",
    "discovery.googleapis.com",
    "connectors.googleapis.com", 
    "secretmanager.googleapis.com"
  ]
  
}

resource "google_project_iam_member" "compute_sa_role" {
  project = var.gcp_project_id
  for_each = toset(["roles/resourcemanager.projectIamAdmin", "roles/editor", "roles/owner" ])
  role     = each.key
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}


# [2] Create Startup VM
# Module: Google Compute Engine
module "lab_setup_vm" {
  source = "github.com/CloudVLab/terraform-lab-foundation//basics/gce_instance/stable"
  # source = "gcs::https://www.googleapis.com/storage/v1/terraform-lab-foundation/basics/gce_instance/stable/v1"

  # Pass values to the module
  gcp_project_id = var.gcp_project_id
  gcp_region     = var.gcp_region
  gcp_zone       = var.gcp_zone
  gce_zone       = var.gcp_zone

  # Customise the GCE instance
  gce_name            = "lab-setup"
  gce_machine_type    = "e2-medium" 
  gce_tags            = ["lab-setup"] 
  gce_machine_image   = "debian-cloud/debian-12" 
  gce_machine_network = "default" 
  gce_scopes          = ["cloud-platform"]
}

# [3] Run startup bash script
resource "null_resource" "remote-exec-resource" {
   provisioner "remote-exec" {
     connection {
       type     = "ssh"
       user     = "${var.username}"
       private_key = "${var.ssh_pvt_key}"
       host     = module.lab_setup_vm.gce_external_ip
     }
     script = "scripts/lab-init.sh"
   }

   depends_on = [module.lab_setup_vm, google_project_iam_member.compute_sa_role]
}
