# terraform/ec2-free/main.tf

# ==========================================
# 1. ECR Repository
# ==========================================
resource "aws_ecr_repository" "repo" {
  name         = var.app_name
  force_delete = true
}

resource "aws_ecr_lifecycle_policy" "cleanup" {
  repository = aws_ecr_repository.repo.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 }
      action       = { type = "expire" }
    }]
  })
}

# ==========================================
# 2. Networking & Security
# ==========================================
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security Group for the EC2 Instance (The "Host")
resource "aws_security_group" "ec2_sg" {
  name        = "${var.app_name}-ec2-sg"
  description = "Security group for ECS Node"
  vpc_id      = data.aws_vpc.default.id

  # Allow all outbound (Required for Repo pull and SOCKS connection)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==========================================
# 3. IAM Roles (Permissions)
# ==========================================

# Role for the EC2 VM (Host)
resource "aws_iam_role" "ec2_role" {
  name = "${var.app_name}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ 
      Action = "sts:AssumeRole", 
      Effect = "Allow", 
      Principal = { Service = "ec2.amazonaws.com" } 
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_role_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.app_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# Role for the ECS Agent (Task Execution)
resource "aws_iam_role" "ecs_exec_role" {
  name = "${var.app_name}-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ 
      Action = "sts:AssumeRole", 
      Effect = "Allow", 
      Principal = { Service = "ecs-tasks.amazonaws.com" } 
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_exec_role_policy" {
  role       = aws_iam_role.ecs_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ==========================================
# 4. ECS Cluster & Compute (The Free Tier Part)
# ==========================================
resource "aws_ecs_cluster" "cluster" {
  name = "${var.app_name}-cluster"
}

# Get the latest "ECS-Optimized" Amazon Linux 2023 AMI
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

resource "aws_launch_template" "ecs_lt" {
  name_prefix   = "${var.app_name}-lt-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = "t2.micro" # <--- FREE TIER ELIGIBLE

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }
  
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ec2_sg.id]
  }

  # This script runs on boot to join the cluster
  user_data = base64encode(<<-EOF
              #!/bin/bash
              echo "ECS_CLUSTER=${aws_ecs_cluster.cluster.name}" >> /etc/ecs/ecs.config
              EOF
  )
}

resource "aws_autoscaling_group" "ecs_asg" {
  name                = "${var.app_name}-asg"
  vpc_zone_identifier = data.aws_subnets.default.ids
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  launch_template {
    id      = aws_launch_template.ecs_lt.id
    version = "$Latest"
  }
}

# ==========================================
# 5. Application Definition
# ==========================================
resource "aws_cloudwatch_log_group" "logs" {
  name              = "/ecs/${var.app_name}"
  retention_in_days = 1
}

resource "aws_ecs_task_definition" "app" {
  family                   = var.app_name
  network_mode             = "bridge" 
  requires_compatibilities = ["EC2"]
  cpu                      = "256"
  memory                   = "400"
  execution_role_arn       = aws_iam_role.ecs_exec_role.arn

  container_definitions = jsonencode([{
    name      = var.app_name
    image     = "${aws_ecr_repository.repo.repository_url}:latest"
    essential = true
    memory    = 400
    
    # Environment Variables
    environment = [
      { name = "CHAT_ID", value = var.chat_id },
      { name = "MONITOR_CONFIG", value = var.monitor_config },
      { name = "BOT_TOKEN", value = var.bot_token },
      { name = "HTTPS_PROXY", value = var.proxy_url },
      { name = "HTTP_PROXY", value = var.proxy_url },
      { name = "PYTHONUNBUFFERED", value = "1" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.logs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ec2"
      }
    }
  }])
}

resource "aws_ecs_service" "main" {
  name            = "${var.app_name}-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "EC2"
}

# ==========================================
# 6. Outputs
# ==========================================
output "ecr_repository_url" {
  value = aws_ecr_repository.repo.repository_url
}