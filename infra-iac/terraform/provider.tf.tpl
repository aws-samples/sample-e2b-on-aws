provider "aws" {
  region     = "${AWSREGION}"
  skip_region_validation = true
}

terraform {
  backend "s3" {
    bucket     = "${CFNE2BBUCKET}"
    key        = "terraform-state/${CFNSTACKNAME}/terraform.tfstate"
    region     = "${AWSREGION}"
    encrypt    = true
    skip_region_validation = true
  }
}
