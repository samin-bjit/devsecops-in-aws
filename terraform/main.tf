# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

provider "aws" {
  region = var.region
}

# Filter out local zones, which are not currently supported 
# with managed node groups
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # cluster_name = "vaccination-system-eks-${random_string.suffix.result}"
  cluster_name = "vaccination-system-eks"
}

# resource "random_string" "suffix" {
#   length  = 4
#   special = false
# }

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "vaccination-vpc"

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  private_subnets              = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets               = ["10.0.3.0/24", "10.0.4.0/24"]
  database_subnets             = ["10.0.5.0/24", "10.0.6.0/24"]
  create_database_subnet_group = true

  enable_nat_gateway      = true
  single_nat_gateway      = true
  enable_dns_hostnames    = true
  map_public_ip_on_launch = true # disable this in production for better security

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.15.3"

  cluster_name    = local.cluster_name
  cluster_version = "1.27"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.public_subnets # should use module.vpc.private_subnets for better isolation
  cluster_endpoint_public_access = true
  cluster_enabled_log_types      = []
  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"

  }

  eks_managed_node_groups = {

    one = {
      name = "node-group-1"

      instance_types              = ["t3.large"]
     # key_name                    = var.ssh_keyname
      min_size                    = 1
      max_size                    = 2
      desired_size                = 1
      associate_public_ip_address = true # set to false in production
    }
  }
}

# https://aws.amazon.com/blogs/containers/amazon-ebs-csi-driver-is-now-generally-available-in-amazon-eks-add-ons/ 
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.7.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

resource "aws_eks_addon" "ebs-csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.22.0-eksbuild.2"
  service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
  tags = {
    "eks_addon" = "ebs-csi"
    "terraform" = "true"
  }
}

resource "aws_iam_policy" "eks-worker-nodegroup-policy" {
  name   = "${local.cluster_name}-worker"
  policy = file("policies/eks-workers.json")
}

resource "aws_iam_role_policy_attachment" "nodegroup-attached-policy" {
  role       = module.eks.eks_managed_node_groups["one"].iam_role_name # replace with the name of your node group IAM instance profile
  policy_arn = aws_iam_policy.eks-worker-nodegroup-policy.arn
}

resource "aws_iam_policy" "eks-alb-policy" {
  name   = "${local.cluster_name}-alb-policy"
  policy = file("policies/eks-alb-policy.json")
}
#----------------- RDS Provisioning --------------------

module "db" {
  source = "terraform-aws-modules/rds/aws"

  identifier                = "vaccination-rds"
  create_db_option_group    = false
  create_db_parameter_group = false

  # All available versions: http://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_MySQL.html#MySQL.Concepts.VersionMgmt
  engine               = "mysql"
  engine_version       = "8.0"
  family               = "mysql8.0" # DB parameter group
  major_engine_version = "8.0"      # DB option group
  instance_class       = "db.t3.micro"
  allocated_storage = 20
  db_name  = "vms"
  username = "root"
  password = "12345678"
  port     = 3306
  manage_master_user_password = false # set to false for production

  db_subnet_group_name   = module.vpc.database_subnet_group
  vpc_security_group_ids = [module.security_group.security_group_id]

  depends_on = [ module.eks ]
}

module "security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "vaccination-rds-sg"
  description = "Complete MySQL example security group"
  vpc_id      = module.vpc.vpc_id

  # ingress
  ingress_with_cidr_blocks = [
    {
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      description = "MySQL access from within VPC"
      cidr_blocks = module.vpc.vpc_cidr_block
    },
  ]
}
