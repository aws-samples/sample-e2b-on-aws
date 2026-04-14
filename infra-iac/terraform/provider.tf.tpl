provider "aws" {
  region     = "${AWSREGION}"
}

terraform {
  backend "s3" {
    bucket         = "${CFNTERRAFORMBUCKET}"
    key            = "${CFNSTACKNAME}/terraform.tfstate"
    region         = "${AWSREGION}"
    encrypt        = true
    dynamodb_table = "terraform-lock-${CFNSTACKNAME}"
  }
}
