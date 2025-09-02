terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.46.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "6.46.0"
    }
  }

  backend "gcs" {
    bucket = "your-terraform-state-bucket"
    prefix = "atlantis-on-cloud-run"
  }
}
