provider "aws" {
  region = "us-east-1"
}

# Create a dev bucket
module "dev_bucket" {
  source      = "./modules/s3-bucket"
  bucket_name = "my-app-dev-bucket"
  environment = "dev"
}

# Create a prod bucket — same module, different inputs
module "prod_bucket" {
  source      = "./modules/s3-bucket"
  bucket_name = "my-app-prod-bucket"
  environment = "prod"
}

# Use the output from the module
output "dev_bucket_arn" {
  value = module.dev_bucket.bucket_arn
}

output "prod_bucket_arn" {
  value = module.prod_bucket.bucket_arn
}
