provider "aws" {
  region     = "${AWSREGION}"
}

terraform {
  backend "s3" {
    bucket     = "${CFNTERRAFORMBUCKET}"
    key        = "terraform-state/${CFNSTACKNAME}/terraform.tfstate"
    region     = "${AWSREGION}"
    encrypt    = true
  }
}
