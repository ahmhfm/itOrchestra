# Dev keeps state local for simplicity. For shared/durable state, use the in-cluster MinIO from
# Phase 0.12 as an S3 backend: port-forward MinIO, create a "terraform-state" bucket, export
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (the MinIO creds), then replace the block below and
# `terraform init -migrate-state`.
terraform {
  backend "local" {}

  # backend "s3" {
  #   bucket                      = "terraform-state"
  #   key                         = "itorchestra/dev/terraform.tfstate"
  #   region                      = "us-east-1"               # arbitrary; MinIO ignores it
  #   endpoints                   = { s3 = "http://localhost:9000" }
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   skip_requesting_account_id  = true
  #   use_path_style              = true
  # }
}
