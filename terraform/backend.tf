# Remote state in S3 with S3-native locking (a .tflock object written with a
# conditional PUT). Partial configuration: bucket/key/region come from
# envs/<env>.backend.hcl so staging and production never share a state file:
#
#   terraform init -backend-config=envs/staging.backend.hcl
terraform {
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
