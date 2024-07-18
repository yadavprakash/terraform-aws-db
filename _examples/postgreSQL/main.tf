provider "aws" {
  region = "eu-west-1"
}

module "vpc" {
  source      = "git::https://github.com/yadavprakash/terraform-aws-vpc?ref=v1.0.0"
  name        = "vpc"
  environment = "test"
  label_order = ["environment", "name"]

  cidr_block = "10.0.0.0/16"
}

module "private_subnets" {
  source      = "git::https://github.com/yadavprakash/terraform-aws-subnet?ref=v1.0.0"
  name        = "subnets"
  environment = "test"
  label_order = ["name", "environment"]

  nat_gateway_enabled = true

  availability_zones = ["eu-west-1a", "eu-west-1b"]
  vpc_id             = module.vpc.id
  type               = "public-private"
  igw_id             = module.vpc.igw_id
  cidr_block         = module.vpc.vpc_cidr_block
  ipv6_cidr_block    = module.vpc.ipv6_cidr_block
  #  assign_ipv6_address_on_creation = false
}

module "postgresql" {
  source = "./../../"

  name        = "postgresql"
  environment = "test"
  label_order = ["environment", "name"]

  engine            = "postgres"
  engine_version    = "14.6"
  instance_class    = "db.t3.medium"
  allocated_storage = 50
  engine_name       = "postgres"
  storage_encrypted = true
  family            = "postgres14"

  db_name  = "test"
  username = "dbname"
  password = "esfsgcGdfawAhdxtfjm!"
  port     = "5432"

  maintenance_window = "Mon:00:00-Mon:03:00"
  backup_window      = "03:00-06:00"
  multi_az           = false


  vpc_id        = module.vpc.id
  allowed_ip    = [module.vpc.vpc_cidr_block]
  allowed_ports = [5432]

  backup_retention_period = 0

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  subnet_ids          = module.private_subnets.public_subnet_id
  publicly_accessible = true

  major_engine_version = "14"

  deletion_protection = true


  ssm_parameter_endpoint_enabled = true

}

