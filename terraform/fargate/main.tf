# ==========================================
# 1. ECR Repository (Store Docker Images)
# ==========================================
resource "aws_ecr_repository" "repo" {
  name = var.app_name
  force_delete = true # For learning purposes only
}

# ==========================================
# 2. IAM Roles (Permissions)
# ==========================================
# Role for ECS to pull images and write logs
resource "aws_iam_role" "ecs_execution_role" {
  name = "${var.app_name}-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ==========================================
# 3. CloudWatch Logs
# ==========================================
resource "aws_cloudwatch_log_group" "logs" {
  name              = "/ecs/${var.app_name}"
  retention_in_days = 7
}

# ==========================================
# 4. ECS Cluster
# ==========================================
resource "aws_ecs_cluster" "cluster" {
  name = "${var.app_name}-cluster"
}

# ==========================================
# 5. ECS Task Definition ( The Blueprint )
# ==========================================
resource "aws_ecs_task_definition" "app" {
  family                   = var.app_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256" # 0.25 vCPU
  memory                   = "512" # 512 MB RAM
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([{
    name      = var.app_name
    image     = "${aws_ecr_repository.repo.repository_url}:latest"
    essential = true
    
    # ENVIRONMENT VARIABLES
    environment = [
      { name = "CHAT_ID", value = var.chat_id },
      { name = "MONITOR_CONFIG", value = var.monitor_config },
      { name = "CHECK_INTERVAL", value = "300" },
      # THIS IS THE MAGIC: Direct requests to use your SOCKS proxy
      { name = "HTTPS_PROXY", value = var.proxy_url },
      { name = "HTTP_PROXY", value = var.proxy_url }
    ]
    
    # We pass the Token as a "secret" if using SecretsManager, 
    # but for simplicity here we use environment var via Terraform variable.
    # In strict production, use secrets = [] pointing to SSM/SecretsManager.
    environment = concat([
        { name = "CHAT_ID", value = var.chat_id },
        { name = "MONITOR_CONFIG", value = var.monitor_config },
        { name = "BOT_TOKEN", value = var.bot_token },
        { name = "HTTPS_PROXY", value = var.proxy_url },
        { name = "HTTP_PROXY", value = var.proxy_url }
    ])

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.logs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

# ==========================================
# 6. Networking (Default VPC for simplicity)
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

# Security Group to allow outbound traffic (to Telegram and your Mikrotik)
resource "aws_security_group" "ecs_sg" {
  name        = "${var.app_name}-sg"
  description = "Allow outbound traffic"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==========================================
# 7. ECS Service (Runs the Task)
# ==========================================
resource "aws_ecs_service" "main" {
  name            = "${var.app_name}-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true # Required for Fargate to reach internet/ECR
  }
}