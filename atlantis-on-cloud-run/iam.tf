# Retrieves the Terraform state bucket
data "google_storage_bucket" "terraform_state" {
  name = "${local.project_id}-tf-state"
}
