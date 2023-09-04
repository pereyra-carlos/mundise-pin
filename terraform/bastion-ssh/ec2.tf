/**/
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.latest_amazon_linux.id
  instance_type               = "t2.micro"
  key_name                    = aws_key_pair.key_pair.id
  associate_public_ip_address = true
  subnet_id                   = data.aws_subnets.subnets_public.ids[0]
  security_groups             = [aws_security_group.bastion_security_group.id]
  # WARN : it must target the aws_iam_instance_profile name (and not the aws_iam_role name)
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  # https://www.terraform.io/language/functions/templatefile
  user_data = templatefile("${path.module}/tpl/userdata.tpl", {})

  tags = {
    Name = "${var.project_name}-bastion"
  }

  lifecycle {
    ignore_changes = [
      ami, disable_api_termination, ebs_optimized,
      hibernation, security_groups, credit_specification,
      network_interface, ephemeral_block_device
    ]
  }
}

# create a security group : allows SSH inbound only for my IP
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group
resource "aws_security_group" "bastion_security_group" {
  name   = "${var.project_name}-bastion-sg"
  vpc_id = data.aws_vpc.vpc.id

  ingress {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
    # https://stackoverflow.com/a/53782560
    # https://stackoverflow.com/a/68833352
    cidr_blocks = ["${data.http.my_ip.body}/32"]
  }

  egress {
    protocol    = -1
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-bastion-sg"
  }
}

# /!\ allow access from bation instance to postgres db instance
# add an Inboud Rule to the default VPC security group
# it allows the port 5432
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule
# allow the ec2 instances (endorsed by the security group `aws_security_group.instance`) to
# be connected with the rds mysql instance (allow inbound port 5432)
resource "aws_security_group_rule" "postgres_bastion_instances_sg" {
  # this rule is added to the security group defined by `security_group_id`
  # and this id target the `default` security group associated with the created VPC
  security_group_id = data.aws_security_group.default_security_group.id

  type      = "ingress"
  protocol  = "tcp"
  from_port = 5432
  to_port   = 5432

  # One of ['cidr_blocks', 'ipv6_cidr_blocks', 'self', 'source_security_group_id', 'prefix_list_ids']
  # must be set to create an AWS Security Group Rule
  source_security_group_id = aws_security_group.bastion_security_group.id

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "${var.project_name}-ec2-role"
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key
resource "tls_private_key" "private_key" {
  #
  # /!\ IMPORTANT SECURITY ISSUE /!\
  # The private key generated by this resource will be stored unencrypted in your Terraform state file. 
  # Use of this resource for production deployments is NOT recommended. Instead, generate a private key
  # file outside of Terraform and distribute it securely to the system where Terraform will be run.
  #
  algorithm = "RSA"
  rsa_bits  = 4096
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/key_pair
resource "aws_key_pair" "key_pair" {
  key_name   = var.project_name
  public_key = tls_private_key.private_key.public_key_openssh
}

# https://registry.terraform.io/providers/hashicorp/local/latest/docs/resources/file
resource "local_file" "rsa_key_file" {
  content = tls_private_key.private_key.private_key_pem
  # target the $PROJECT_DIR
  filename        = "${path.module}/../../${var.project_name}-bastion.pem"
  file_permission = "0400"
}

# SSH add key to known_hosts to not be prompt by :
# 'key fingerprint ... Are you sure you want to continue connecting (yes/no) ?'
# https://www.techrepublic.com/article/how-to-easily-add-an-ssh-fingerprint-to-your-knownhosts-file-in-linux/
# https://superuser.com/a/1533678
resource "null_resource" "ssh_known_hosts" {

  provisioner "local-exec" {
    # option -t type : Specify the type of the key to fetch from the scanned hosts.
    # The possible values are “dsa”, “ecdsa”, “ed25519”, or “rsa”.  Multiple values may be specified by
    # separating them with commas.  The default is to fetch “rsa”, “ecdsa”, and “ed25519” keys.

    # WARN : if you don't specify a type (ignore option -t) 3 lines will be added in ~/.ssh/known_hosts
    # 3 lines like :
    # $BASTION_PUBLIC_DNS ssh-rsa AAAAB3N....
    # $BASTION_PUBLIC_DNS ecdsa-sha2-nistp256 AAAAE2VjZ....
    # $BASTION_PUBLIC_DNS ssh-ed25519 AAAAC3Nz....
    # So, if you already know the type of you SSH Key you want to add (and it's probably the case),
    # it's cleaner to specify it here 

    # /!\ add line in ~/.ssh/known_hosts if ${...public_dns} NOT already exists in this file
    # https://stackoverflow.com/a/3557165
    command = "grep -q ${aws_instance.bastion.public_dns} < ~/.ssh/known_hosts || ssh-keyscan -t ${tls_private_key.private_key.algorithm} ${aws_instance.bastion.public_dns} >> ~/.ssh/known_hosts"
  }

  depends_on = [aws_instance.bastion]
}
