provider "aws" {
  region     = "${AWSREGION}"
}

terraform {
  backend "s3" {
    bucket     = "${CFNE2BBUCKET}"
    key        = "terraform-state/${CFNSTACKNAME}/terraform.tfstate"
    region     = "${AWSREGION}"
    encrypt    = true
  }
}
