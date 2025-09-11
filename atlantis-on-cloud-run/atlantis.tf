locals {
  atlantis_domain = "atlantis.acme.org"
}

# Enables the IAP service for the project
resource "google_project_service_identity" "iap" {
  provider = google-beta
  service  = "iap.googleapis.com"
  project  = local.project_id
}

# This grants the platform-engineers group access to IAP so they can access the Atlantis UI
resource "google_project_iam_member" "gcp_platform_engineers_iap_https_resource_accessor" {
  project = local.project_id
  role    = "roles/iap.httpsResourceAccessor"
  member  = "group:platform-engineers@acme.org"
}

# Redis is used by the different Atlantis instances to read and write locks
resource "google_redis_instance" "atlantis" {
  name               = "atlantis"
  tier               = "STANDARD_HA"
  redis_version      = "REDIS_7_2"
  memory_size_gb     = 1
  region             = "europe-west4"
  authorized_network = google_compute_network.example.name
  connect_mode       = "PRIVATE_SERVICE_ACCESS"
  # RDB is important to enable, as it ensures Atlantis lock data is not lost on failover or restarts
  persistence_config {
    persistence_mode    = "RDB"
    rdb_snapshot_period = "TWENTY_FOUR_HOURS"
  }
  maintenance_policy {
    weekly_maintenance_window {
      day = "TUESDAY"
      start_time {
        hours   = 0
        minutes = 30
        seconds = 0
        nanos   = 0
      }
    }
  }
  project = local.project_id
  lifecycle {
    prevent_destroy = true
  }
  depends_on = [
    # Dependecy you need to add, or completely remove Private Service Access.
    google_service_networking_connection.service_networking,
  ]
}

# Remote Artifact Registry for GitHub Container Registry,
# allowing Cloud Run to the runatlantis/atlantis image from GHCR
resource "google_artifact_registry_repository" "ghcr" {
  repository_id = "ghcr"
  format        = "DOCKER"
  location      = "europe-west4"
  mode          = "REMOTE_REPOSITORY"
  description   = "Proxy to GitHub Container Registry"
  remote_repository_config {
    common_repository {
      uri = "https://ghcr.io"
    }
  }
  project = local.project_id
}

# Replace this with GitHub, or BitBucket if you use that
resource "google_secret_manager_secret" "atlantis_gitlab_token" {
  secret_id = "atlantis-gitlab-token"
  replication {
    user_managed {
      replicas {
        location = "europe-west4"
      }
      replicas {
        location = "europe-west1"
      }
    }
  }
  deletion_protection = true
  project             = local.project_id
}

resource "google_secret_manager_secret" "atlantis_webhook" {
  secret_id = "atlantis-webhook"
  replication {
    user_managed {
      replicas {
        location = "europe-west4"
      }
      replicas {
        location = "europe-west1"
      }
    }
  }
  deletion_protection = true
  project             = local.project_id
}

# Generate a random webhook secret for Atlantis, to protect the /events endpoint with
ephemeral "random_password" "atlantis_webhook" {
  length  = 16
  special = false
}

# Write the ephemeral secret to Secret Manager, the `secret_data_wo` does not persist in state
resource "google_secret_manager_secret_version" "atlantis_webhook" {
  secret                 = google_secret_manager_secret.atlantis_webhook.id
  secret_data_wo         = ephemeral.random_password.atlantis_webhook.result
  secret_data_wo_version = 1
}

### Below we're creating a single shared External HTTP(S) Load Balancer for all Atlantis services
### Each Atlantis service gets its own subdomain, SSL certificate, backend service and Cloud Run service
### The URL map, target HTTPS proxy and global forwarding rule are shared
resource "google_compute_global_address" "atlantis" {
  name    = "atlantis"
  project = local.project_id
}

resource "google_compute_managed_ssl_certificate" "atlantis" {
  provider = google-beta
  name     = "atlantis"
  managed {
    domains = [local.atlantis_domain]
  }
  project = local.project_id
}

# This is where the load balancing magic happens, 
## routing traffic to the correct backend service based on the hostname and path
resource "google_compute_url_map" "atlantis" {
  name = "atlantis"
  default_url_redirect {
    host_redirect          = local.atlantis_domain
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
  host_rule {
    hosts        = ["management.${local.atlantis_domain}"]
    path_matcher = "atlantis-management-webhooks"
  }
  host_rule {
    hosts        = ["network.${local.atlantis_domain}"]
    path_matcher = "atlantis-network-webhooks"
  }
  host_rule {
    # Workloads does not exist yet, but it's to give you an idea of how to scale this
    hosts        = ["workloads.${local.atlantis_domain}"]
    path_matcher = "atlantis-workloads-webhooks"
  }
  path_matcher {
    name            = "atlantis-management-webhooks"
    default_service = google_compute_backend_service.atlantis_management.id
    path_rule {
      paths   = ["/events"]
      service = google_compute_backend_service.atlantis_management_webhooks.id
    }
  }
  path_matcher {
    name            = "atlantis-network-webhooks"
    default_service = google_compute_backend_service.atlantis_network.id
    path_rule {
      paths   = ["/events"]
      service = google_compute_backend_service.atlantis_network_webhooks.id
    }
  }
  path_matcher {
    # Workloads does not exist yet, but it's to give you an idea of how to scale this
    name            = "atlantis-workloads-webhooks"
    default_service = google_compute_backend_service.atlantis_workloads.id
    path_rule {
      paths   = ["/events"]
      service = google_compute_backend_service.atlantis_workloads_webhooks.id
    }
  }
  project = local.project_id
}

resource "google_compute_ssl_policy" "restricted" {
  name            = "restricted"
  profile         = "RESTRICTED"
  min_tls_version = "TLS_1_2"
  project         = local.project_id
}

resource "google_compute_target_https_proxy" "atlantis" {
  name    = "atlantis"
  url_map = google_compute_url_map.atlantis.id
  ssl_certificates = [
    google_compute_managed_ssl_certificate.atlantis.id,
    google_compute_managed_ssl_certificate.atlantis_network.id,
    google_compute_managed_ssl_certificate.atlantis_management.id,
    # Workloads does not exist yet, but it's to give you an idea of how to scale this
    google_compute_managed_ssl_certificate.atlantis_workloads.id,
  ]
  ssl_policy = google_compute_ssl_policy.restricted.id
  project    = local.project_id
}

resource "google_compute_global_forwarding_rule" "atlantis" {
  name                  = "atlantis"
  target                = google_compute_target_https_proxy.atlantis.id
  port_range            = "443"
  ip_address            = google_compute_global_address.atlantis.address
  load_balancing_scheme = "EXTERNAL_MANAGED"
  project               = local.project_id
}
