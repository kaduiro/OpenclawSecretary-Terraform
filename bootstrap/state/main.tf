provider "google" {
  project = var.project_id
}

resource "google_storage_bucket" "terraform_state" {
  name                        = var.bucket_name
  project                     = var.project_id
  location                    = var.location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age                = 90
      num_newer_versions = 30
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket_iam_member" "state_admin" {
  for_each = var.state_admin_members
  bucket   = google_storage_bucket.terraform_state.name
  role     = "roles/storage.admin"
  member   = each.value
}

resource "google_storage_bucket_iam_member" "state_writer" {
  for_each = var.state_writer_members
  bucket   = google_storage_bucket.terraform_state.name
  role     = "roles/storage.objectAdmin"
  member   = each.value
}

resource "google_storage_bucket_iam_member" "state_bucket_reader" {
  for_each = var.state_writer_members
  bucket   = google_storage_bucket.terraform_state.name
  role     = "roles/storage.legacyBucketReader"
  member   = each.value
}
